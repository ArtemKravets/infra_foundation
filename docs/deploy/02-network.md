# Этап 2. Сеть парка: labnet 10.10.10.0/24

Парк живёт в собственном сегменте внутри гипервизора: узлы видят друг друга, выходят наружу через NAT, а из домашней сети напрямую не доступны. План адресации — [`docs/addressing.md`](../addressing.md).

Определяем и запускаем изолированную сеть для ВМ (её описание содержит настройки NAT и DHCP-пула):

```bash
virsh net-define configs/host/labnet.xml
virsh net-start labnet
virsh net-autostart labnet
```

- `net-define` — регистрирует сеть в libvirt на основе XML-манифеста.
- `net-start` — поднимает интерфейс сети: создаётся виртуальный мост `virbr-lab`, запускается экземпляр `dnsmasq` (на нём DHCP и разрешение имён). Создаются правила файрвола: маскарадинг для исходящего трафика и разрешение форварда.
- `net-autostart` — добавляет сеть в автозагрузку при старте хоста-гипервизора.

Проверяем, что сеть развернулась:

```bash
# labnet в состоянии active, autostart yes, persistent yes
virsh net-list --all

# 10.10.10.1/24 на интерфейсе
ip -br addr show virbr-lab

# Есть экземпляр dnsmasq, привязанный к мосту
ps aux | grep dnsmasq

# Файрвол разрешает ВМ выходить во внешнюю сеть — ищем в правилах 10.10.10.0/24
sudo nft list ruleset | grep -i masquerade
```

