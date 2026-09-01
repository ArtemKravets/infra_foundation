#!/usr/bin/env bash

set -euo pipefail

# A function to log errors to stderrs and terminate the script
die() {
    echo "Error: $*" >&2
    exit 1
}

validate_ip() {
    local ip=$1

    # Step 1: check the basic pattern - 4 groups of 1 to 3 digits, separated by periods
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Step 2: Check that each octet is <= 255
    local IFS="."
    read -ra octets <<< "$ip"

    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            return 1
        fi
    done

    return 0
}

# Explicitly instruct the hypervisor that it's working with system VMs
export LIBVIRT_DEFAULT_URI="qemu:///system"

USAGE_MSG="Usage: $0 <node_name> --ip <IP_ADDRESS> [--disk SIZE] [--ram MB] [--vcpu COUNT] [--dns DNS_IP]"

NETWORK="labnet"

if ! [ "$(virsh net-info "$NETWORK" | awk '/^Active:/ {print $2}')" = "yes" ]; then
    die "The '$NETWORK' network does not exist or has been stopped."
fi

BRIDGE=$(virsh net-info "$NETWORK" | awk '/^Bridge:/ {print $2}')

# --- PARSING ARGUMENTS ---

# Node name as a required argument
NODE_NAME=$1

if [[ -z "$NODE_NAME" ]] || [[ "$NODE_NAME" == -* ]]; then
    echo "$USAGE_MSG" >&2
    die "no node name specified."
fi

# Shift the argument one place to the left
# Now $1 is not a node name, but the first flag (for example, --ip)
shift

# Set default params
VM_IP=""
VM_DNS="10.10.10.30"
DISK_SIZE="10G"
RAM="1024"
VCPU="1"

# Example of parameter processing: $1 $2 == --ip 10.10.10.30
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip)   
                VM_IP="${2:-}"
                if [[ -z "$VM_IP" ]]; then
                    echo "$USAGE_MSG" >&2
                    die "The node's IP address isn't specified."
                fi

                if ! validate_ip "$VM_IP"; then
                    die "The value of the --ip parameter: '$VM_IP' isn't correct"
                fi
                shift ;;
        --dns)  
                VM_DNS="${2:-}";
                if [[ -z "$VM_DNS" ]]; then
                    echo "$USAGE_MSG" >&2
                    die "The DNS's IP address isn't specified."
                fi

                if ! validate_ip "$VM_DNS"; then
                    die "The value of the --dns parameter: '$VM_DNS' isn't correct"
                fi
                shift ;;
        --disk) 
                if [[ -z "${2:-}" ]]; then
                    echo "$USAGE_MSG" >&2
                    die "The disk size isn't specified."
                fi

                DISK_SIZE="$2"
                shift ;;
        --ram)
                if [[ -z "${2:-}" ]]; then
                    echo "$USAGE_MSG" >&2
                    die "The ram size isn't specified."
                fi 
                RAM="$2"
                shift ;;
        --vcpu) 
                if [[ -z "${2:-}" ]]; then
                    echo "$USAGE_MSG" >&2
                    die "The vcpu size isn't specified."
                fi
                VCPU="$2"
                shift ;;
        *)      
                echo  "$USAGE_MSG" >&2
                die unknown parameter.
                ;;
    esac
    shift
done

if [[ -z "$VM_IP" ]]; then
    echo "$USAGE_MSG" >&2
    die "The node's IP address is a required parameter."
fi

# Check: Is there already a VM with that name in libvirt ?
if virsh dominfo "$NODE_NAME" &> /dev/null; then
    die "a VM named '$NODE_NAME' already exists!"
fi

# --- DUPLICATE ADDRESS DETECTION ---

# Checking whether the arping utility is present on the system
if ! command -v arping &> /dev/null; then
    die "The arping utility is required to test the network.
On the server, run the following command: 'sudo apt update && sudo apt install iputils-arping -y'"
fi

# DAD (Duplicate Address Detection) - Checking IP Address Usage on the Network
# Limitation: this method only captures VMs that are currently running
echo "Checking if the address '$VM_IP' is reachable on the network..."
if ! arping -D -c 2 -I "$BRIDGE" "$VM_IP" &> /dev/null; then
    die "The IP address '$VM_IP' is already in use by another machine (the MAC address is responding to ARP)!"
fi

echo "The address is available. Continuing deployment..."

# --- PATHS ---

# Get absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

POOL_DIR="/var/lib/libvirt/vmpool"
TEMPLATE_DISK="${POOL_DIR}/ubuntu-2404-golden.qcow2"
NODE_DISK="${POOL_DIR}/${NODE_NAME}.qcow2"
SEED_ISO="${POOL_DIR}/${NODE_NAME}-seed.iso"

USER_DATA_TMPL="${PROJECT_ROOT}/configs/cloud-init/user-data.tmpl"
NETWORK_CONFIG_TMPL="${PROJECT_ROOT}/configs/cloud-init/network-config.tmpl"

# The variable is created before the script or fallback is executed
SSH_KEY_PATH=${SSH_KEY_PATH:-${HOME}/.ssh/client_mac_key.pub}

# --- Check whether the parameters have been passed. ---

# Check: does the template exist
if [[ ! -f "$TEMPLATE_DISK" ]]; then
    die "the $TEMPLATE_DISK template wasn't found!"
fi

if [[ -f "$NODE_DISK" ]]; then
    die "a disk at the path '$NODE_DISK' already exists!"
fi

# Check if we found the public key
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    die "the public SSH key wasn't found at the following path: $SSH_KEY_PATH"
fi

# --- CREATING A TEMPORARY ENVIROMENT  ---

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Rendering user-data ---

echo "=> Rendering user-data.tmpl using a key from $SSH_KEY_PATH"
SSH_PUBKEY=$(cat "$SSH_KEY_PATH")
export SSH_PUBKEY

USER_DATA_RENDERED="${TEMP_DIR}/user-data.rendered"
envsubst '$SSH_PUBKEY' < "$USER_DATA_TMPL" > "$USER_DATA_RENDERED"

# --- Rendering network-config ---

echo "=> Rendering network-config.tmpl using values ip: '$VM_IP' dns: '$VM_DNS'"
export VM_IP VM_DNS

NETWORK_CONFIG_RENDERED="${TEMP_DIR}/network-config.rendered"
envsubst '$VM_IP, $VM_DNS' < "$NETWORK_CONFIG_TMPL" > "$NETWORK_CONFIG_RENDERED"

# --- PREPARING THE DISK ---

echo "=> Cloning a disk from a template..."
sudo cp "$TEMPLATE_DISK" "$NODE_DISK"
sudo chmod 644 "$NODE_DISK"

echo "=> Expanding the disk to $DISK_SIZE..."
sudo qemu-img resize "$NODE_DISK" "$DISK_SIZE"


# --- PREPARING CLOUD-INIT SEED ---

echo "=> Generating a unique seed.iso..."

META_DATA="${TEMP_DIR}/meta-data"

echo "instance-id: i-${NODE_NAME}-$(date +%s)" > "$META_DATA"
echo "local-hostname: ${NODE_NAME}" >> "$META_DATA"

sudo cloud-localds \
    "$SEED_ISO" \
    --network-config "$NETWORK_CONFIG_RENDERED" \
    "$USER_DATA_RENDERED" \
    "$META_DATA"

virsh pool-refresh vmpool


# --- STARTING A VM ---

echo "=> Creating and starting a VM in libvirt..."

sudo virt-install \
    --name "$NODE_NAME" \
    --memory "$RAM" \
    --vcpus "$VCPU" \
    --disk path="$NODE_DISK",bus=virtio \
    --disk path="$SEED_ISO",device=cdrom \
    --network network="$NETWORK",model=virtio \
    --os-variant ubuntu24.04 \
    --import \
    --noautoconsole \
    --channel unix,target_type=virtio,name=org.qemu.guest_agent.0

echo "=> Done! The '$NODE_NAME' node is running!"
echo "Wait a minute for cloud-init to finish running, then check the IP: virsh domifaddr $NODE_NAME --source agent"