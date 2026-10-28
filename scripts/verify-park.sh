#!/usr/bin/env bash
# Smoke-тест (приёмочная проверка) парка ВМ — DoD задачи 3.
# Запускается с рабочей машины (macOS, совместим с Bash 3.2+).

set -euo pipefail

# Ожидаемая конфигурация парка согласно docs/addressing.md
NODES=(
  "web:10.10.10.10"
  "app:10.10.10.20"
  "mgmt:10.10.10.30"
)

HYPERVISOR_HOST="lab"
LIBVIRT_URI="qemu:///system"
DOMAIN="lab.internal"
DNS_SERVER="10.10.10.30"
DIG_TARGET="app.lab.internal"
DIG_EXPECTED="10.10.10.20"
PING_TARGET="web.lab.internal"

SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=5)

total=0
fails=0

pass() {
  total=$((total + 1))
  printf "[OK]   %s\n" "$1"
}

fail() {
  total=$((total + 1))
  fails=$((fails + 1))
  printf "[FAIL] %s\n" "$1"
}

# Схлопывает многострочный вывод ошибки в одну строку для отчёта
one_line() {
  local s="${1//$'\r'/}"
  s="${s//$'\n'/; }"
  printf "%s" "${s%;}"
}

echo "=== 1. Гипервизор (${HYPERVISOR_HOST}): состояние ВМ ==="
for item in "${NODES[@]}"; do
  node="${item%%:*}"
  rc=0
  state=$(ssh "${SSH_OPTS[@]}" "${HYPERVISOR_HOST}" \
    "LC_ALL=C virsh -c ${LIBVIRT_URI} domstate ${node}" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    if [[ "${state}" == "running" ]]; then
      pass "vm/${node}: state is running"
    else
      fail "vm/${node}: expected 'running', got '$(one_line "${state}")'"
    fi
  else
    fail "vm/${node}: virsh error (exit=${rc}: $(one_line "${state}"))"
  fi
done

echo ""
echo "=== 2. Узлы парка: SSH, IPv4, DNS (dig), связность (ping) ==="
for item in "${NODES[@]}"; do
  node="${item%%:*}"
  expected_ip="${item#*:}"
  fqdn="${node}.${DOMAIN}"

  # 2.1. Доступ по SSH (вход по ключу)
  rc=0
  ssh_err=$(ssh "${SSH_OPTS[@]}" "${fqdn}" true 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    pass "${fqdn} [ssh]: вход по ключу"
  else
    fail "${fqdn} [ssh]: ошибка подключения (exit=${rc}: $(one_line "${ssh_err}"))"
    fail "${fqdn} [ip]: не выполнено (нет SSH до узла, ожидался ${expected_ip})"
    fail "${fqdn} [dig]: не выполнено (нет SSH до узла, ожидался ${DIG_EXPECTED})"
    fail "${fqdn} [ping]: не выполнено (нет SSH до узла, цель ${PING_TARGET})"

    echo  ""
    echo "----------------------------------------"

    continue
  fi

  # 2.2. Глобальный IPv4 совпадает с планом
  rc=0
  actual_ip=$(ssh "${SSH_OPTS[@]}" "${fqdn}" \
    "ip -4 -o addr show scope global | awk '{sub(/\/.*/, \"\", \$4); print \$4}'" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    if [[ "${actual_ip}" == "${expected_ip}" ]]; then
      pass "${fqdn} [ip]: глобальный IPv4 ${actual_ip}"
    else
      fail "${fqdn} [ip]: ожидался '${expected_ip}', получен '$(one_line "${actual_ip:-пусто}")'"
    fi
  else
    fail "${fqdn} [ip]: ошибка выполнения (exit=${rc}: $(one_line "${actual_ip}"))"
  fi

  # 2.3. Прямой запрос к серверу зоны (dig @10.10.10.30)
  rc=0
  dig_out=$(ssh "${SSH_OPTS[@]}" "${fqdn}" \
    "dig +short +time=2 +tries=1 ${DIG_TARGET} @${DNS_SERVER}" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    if [[ "${dig_out}" == "${DIG_EXPECTED}" ]]; then
      pass "${fqdn} [dig]: ${DIG_TARGET} @${DNS_SERVER} -> ${dig_out}"
    else
      fail "${fqdn} [dig]: ${DIG_TARGET} @${DNS_SERVER} -> ожидался '${DIG_EXPECTED}', получен '$(one_line "${dig_out:-пусто}")'"
    fi
  else
    fail "${fqdn} [dig]: ошибка выполнения (exit=${rc}: $(one_line "${dig_out}"))"
  fi

  # 2.4. Штатный резолвинг и ICMP-связность (ping web.lab.internal)
  # Коды ping: 0 — получен ответ, 1 — нет ответа (таймаут), 2 — ошибка резолвинга/вызова, 255 — ошибка SSH
  rc=0
  ping_err=$(ssh "${SSH_OPTS[@]}" "${fqdn}" \
    "ping -c1 -W2 -q ${PING_TARGET} > /dev/null" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    pass "${fqdn} [ping]: ${PING_TARGET} доступен (1 packet received)"
  elif [[ "${rc}" -eq 1 ]]; then
    fail "${fqdn} [ping]: нет ответа от ${PING_TARGET} (exit=1)"
  else
    fail "${fqdn} [ping]: ошибка (exit=${rc}: $(one_line "${ping_err}"))"
  fi

  echo  ""
  echo "----------------------------------------"
done

echo "Итог: OK=$((total - fails)), FAIL=${fails} (всего проверок: ${total})"

if [[ "${fails}" -gt 0 ]]; then
  exit 1
fi
exit 0