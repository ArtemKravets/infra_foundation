#!/usr/bin/env bash

set -euo pipefail

# A function to log errors to stderrs and terminate the script
die() {
    echo "Error: $*" >&2
    exit 1
}

# Explicitly instruct the hypervisor that it's working with system VMs
export LIBVIRT_DEFAULT_URI="qemu:///system"

USAGE_MSG="Usage: $0 <node_name> [-d disk_size] [-r ram] [-c vcpu]"

# --- PARSING ARGUMENTS ---

if [[ $# -lt 1 ]] || [[ "$1" == -* ]]; then
    echo "$USAGE_MSG" >&2
    die "no node name specified."
fi

# Node name as a required argument
NODE_NAME=$1
shift

# Set default params
DISK_SIZE="10G"
RAM="1024"
VCPU="1"

# Processing the passed flags
while getopts "d:r:c:" opt; do
    case "$opt" in
        d) DISK_SIZE="$OPTARG" ;;
        r) RAM="$OPTARG" ;;
        c) VCPU="$OPTARG" ;;
        *)  echo "$USAGE_MSG" >&2 
            die "unknown parameter." 
            ;;
    esac
done


# --- PATHS ---

# Get absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

POOL_DIR="/var/lib/libvirt/vmpool"
TEMPLATE_DISK="${POOL_DIR}/ubuntu-2404-golden.qcow2"
NODE_DISK="${POOL_DIR}/${NODE_NAME}.qcow2"
SEED_ISO="${POOL_DIR}/${NODE_NAME}-seed.iso"

USER_DATA_TMPL="${PROJECT_ROOT}/configs/cloud-init/user-data.tmpl"
NETWORK="labnet"

# The variable is created before the script or fallback is executed
SSH_KEY_PATH=${SSH_KEY_PATH:-${HOME}/.ssh/client_mac_key.pub}

# --- Check whether the parameters have been passed. ---

# Check: does the template exist
if [[ ! -f "$TEMPLATE_DISK" ]]; then
    die "the $TEMPLATE_DISK template wasn't found!"
fi

# Check: Is there already a VM with that name in libvirt ?
if virsh dominfo "$NODE_NAME" >/dev/null 2>&1; then
    die "a VM named '$NODE_NAME' already exists!"
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

echo "=> Rendering user-data.tmpl using a key from $SSH_KEY_PATH"
SSH_PUBKEY=$(cat "$SSH_KEY_PATH")
export SSH_PUBKEY


# Rendering a template
USER_DATA_RENDERED="${TEMP_DIR}/user-data.rendered"
envsubst '$SSH_PUBKEY' < "$USER_DATA_TMPL" > "$USER_DATA_RENDERED"


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

sudo cloud-localds "$SEED_ISO" "$USER_DATA_RENDERED" "$META_DATA"

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