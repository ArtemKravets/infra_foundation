# Этап 4. Развёртывание узла парка из golden image

Готовый шаблон превращается в узел парка одной командой: скрипт клонирует образ, готовит для него cloud-init с персональными данными узла и поднимает домен в libvirt.

Скрипт развёртывания [`scripts/provision-node.sh`](../../scripts/provision-node.sh) запускается так:

```text
./provision-node.sh <node_name> --ip <IP_ADDRESS> [--disk SIZE] [--ram MB] [--vcpu COUNT] [--dns DNS_IP]
```

Обязательные аргументы — имя узла и его статический IP-адрес; необязательные флаги задают параметры «железа» и адрес DNS-сервера. Что делает скрипт: проверяет переданные параметры и допустимость создания ВМ с ними (нет ли уже такого домена или диска, на месте ли шаблон и публичный ключ, не занят ли адрес в сети) → находит публичный SSH-ключ клиента → создаёт временный каталог, рендерит в него `user-data` и `network-config` (подставляя статический адрес узла и адрес DNS-сервера), генерирует уникальный `meta-data` и собирает из них seed-образ для cloud-init → делает клон golden image и при необходимости меняет размер диска → финальным шагом передаёт параметры ВМ в `virt-install` и поднимает её.

**Важно про передачу SSH-ключа скрипту**

По умолчанию скрипт ищет публичный ключ клиента по пути `~/.ssh/client_mac_key.pub`. Путь можно переопределить переменной `SSH_KEY_PATH` при вызове:

```bash
SSH_KEY_PATH=~/.ssh/my_key.pub scripts/provision-node.sh test-vm --ip 10.10.10.50
```

**Пример развёртывания из golden image**

```bash
scripts/provision-node.sh test-vm --ip 10.10.10.50

virsh list --all                         # видим test-vm в списке
virsh domifaddr test-vm --source agent   # видим статический адрес, переданный скрипту

# Подключаемся с клиента через ProxyJump — пускает по ключу, без пароля
ssh devops@10.10.10.50                   # адрес из вывода virsh domifaddr

# Внутри ВМ
cloud-init status   # done
ping -c1 8.8.8.8    # 0% packet loss
hostname            # test-vm
```

Узел парка из golden image поднят.

Чтобы удалить домен ВМ из libvirt вместе со связанными файлами-образами:

```bash
# Принудительно останавливаем ВМ
virsh destroy test-vm

# libvirt стирает домен и файлы-образы
virsh undefine test-vm --remove-all-storage

virsh pool-refresh vmpool
ls -l /var/lib/libvirt/vmpool/
```

**Пример XML-описания домена**

В репозитории приложен [`configs/host/test-vm.xml`](../../configs/host/test-vm.xml) — дамп домена узла, поднятого из этого же шаблона. В воспроизведении он не участвует: домен каждой ВМ создаёт `virt-install`. Файл лежит как справка — по нему видно, во что разворачиваются флаги `virt-install`: описание дисков, сетевого интерфейса, канала guest-agent. Снять такой дамп со своей ВМ можно так:

```text
virsh dumpxml <имя_домена> > configs/host/<имя_домена>.xml
```

