# Этап 3. Golden image: базовый образ узла парка

Узлы парка не устанавливаются вручную. Из cloud-образа Ubuntu 24.04 собирается обезличенный шаблон, из которого дальше клонируется каждый узел, а персональная конфигурация узла подаётся через cloud-init.

## Установка cloud-образа и вспомогательных утилит

Скрипт развёртывания [`scripts/provision-node.sh`](../../scripts/provision-node.sh) ожидает подготовленный cloud-образ Ubuntu 24.04 (Noble Numbat). Такой образ уже приходит обезличенным и готовым к cloud-init: `/etc/machine-id` пуст, host-ключей нет, `/var/lib/cloud/` чистый. Несмотря на это, мы хотим подготовить его под себя — зафиксировать версии установленных пакетов. Тогда каждый клон из golden image получает предустановленный набор пакетов: это экономит время на развёртывании каждого узла и фиксирует начальное состояние системы.

Скачиваем cloud-образ и ставим утилиты для cloud-init:

```bash
# Даёт утилиту cloud-localds — ей будем собирать seed-образ с данными для cloud-init
sudo apt install -y cloud-image-utils

cd /var/lib/libvirt/vmpool
sudo curl -fLO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
sudo curl -fLO https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS

# Обновляем информацию о пуле, чтобы libvirt увидел образ
virsh pool-refresh vmpool
virsh vol-list vmpool

# Проверяем формат образа — должны увидеть file format: qcow2
qemu-img info noble-server-cloudimg-amd64.img
```

## Подготовка для cloud-init

Cloud-образ при первой загрузке ищет `datasource` — источник данных о том, как себя настроить. Наш источник данных — ISO-образ из трёх файлов: `user-data` (как конфигурируем ОС: пользователи, права, SSH-ключи, правила обновления пакетов), `meta-data` (идентификация узла: instance-id, hostname) и `network-config` (конфигурация сетевого интерфейса, из которой cloud-init рендерит netplan). Собираем эти файлы в ISO утилитой `cloud-localds` и подключаем к ВМ вторым диском. `user-data` лежит в репозитории по пути [`configs/cloud-init/user-data.tmpl`](../../configs/cloud-init/user-data.tmpl) в виде шаблона, который ожидает подстановки публичного SSH-ключа для доступа к ВМ; `network-config` — по пути [`configs/cloud-init/network-config.tmpl`](../../configs/cloud-init/network-config.tmpl), он ожидает подстановки статического адреса узла и адреса DNS-сервера и применяется при развёртывании узлов парка (этап [Развёртывание узла](04-node-provisioning.md)). Golden image собираем без него: шаблон не должен нести адрес конкретного узла — на время сборки он получит адрес по DHCP. Из пакетов в `user-data` указан `qemu-guest-agent` — канал взаимодействия между гипервизором и гостем.

**Поднимаем ВМ**

Собираем всё необходимое для старта cloud-образа:

```bash
cd ~/infra_foundation

# Подставляем публичный SSH-ключ рабочей машины в шаблон и сохраняем готовый конфиг.
# envsubst читает переменную из окружения, поэтому её обязательно экспортировать.
export SSH_PUBKEY="$(cat ~/.ssh/client_mac_key.pub)"
envsubst '$SSH_PUBKEY' < configs/cloud-init/user-data.tmpl > /tmp/user-data

# Создаём meta-data
cat << 'EOF' > /tmp/meta-data
instance-id: template-01
local-hostname: ubuntu-template
EOF

# Увеличиваем виртуальный размер диска. При первой загрузке growpart и resize2fs
# (они входят в cloud-образ) сами растянут раздел и файловую систему под новый размер.
sudo qemu-img resize /var/lib/libvirt/vmpool/noble-server-cloudimg-amd64.img 10G

# Собираем seed-образ, который подключаем к ВМ как CD-ROM
cloud-localds \
    /tmp/seed.img \
    /tmp/user-data  \
    /tmp/meta-data
```

Разворачиваем ВМ, импортируя готовый диск и указывая настройки:

```bash
virt-install \
    --name golden-vm \
    --memory 1024 \
    --vcpus 1 \
    --disk path="/var/lib/libvirt/vmpool/noble-server-cloudimg-amd64.img",bus=virtio \
    --disk path="/tmp/seed.img",device=cdrom \
    --network network="labnet",model=virtio \
    --os-variant ubuntu24.04 \
    --import \
    --noautoconsole \
    --channel unix,target_type=virtio,name=org.qemu.guest_agent.0
```

- `memory`, `vcpus` — параметры «железа».
- `disk path` — cloud-образ и seed-образ в качестве дисков.
- `network` — название созданной виртуальной сети в libvirt.
- `channel` — канал общения гипервизора с ВМ.

Затем libvirt развернёт ВМ, и можно делать диагностику.

На гипервизоре:

```bash
# Покажет ВМ в состоянии running
virsh list

# Возвращает адрес — это одновременно доказывает, что qemu-guest-agent жив и виден гипервизору
virsh domifaddr golden-vm --source agent
```

Подключаемся по SSH к поднятой ВМ через ProxyJump на гипервизоре и делаем диагностику:

```bash
cloud-init status                      # status: done
id devops                              # показывает членство в sudo
sudo -n true                           # должен отработать молча
systemctl is-active qemu-guest-agent   # active
ping -c1 8.8.8.8                       # проходит во внешнюю сеть
ip -br a                               # показывает адрес из DHCP-пула .100–.200
df -h /                                # проверяем, что growpart отработал
```

## Обезличивание ВМ в golden image

Работающая система накапливает данные, которые однозначно её идентифицируют: machine-id, host-ключи SSH, отметку «cloud-init уже отработал», логи и кэши. Если разворачивать новые ВМ на базе такого «грязного» образа, все машины станут конфликтующими копиями: `cloud-init` не выполнит первичную инициализацию, DHCP начнёт выдавать одинаковые IP-адреса, а одинаковые SSH-ключи создадут дыру в безопасности.

Для обезличивания образа существует готовая утилита `virt-sysprep` — она вычищает уникальные данные автоматически. Но в рамках обучения выполним эти действия вручную.

Очищаем систему от уникальных данных, чтобы при инициализации они были сгенерированы заново, и устанавливаем обновления:

```bash
# Ставим актуальные пакеты и убираем неиспользуемые
sudo apt update && sudo apt -y upgrade
sudo apt -y autoremove --purge
sudo apt clean

# Сбрасываем состояние cloud-init
sudo cloud-init clean --logs --seed

# Удаляем host-ключи SSH текущей ВМ. При следующей загрузке будут сгенерированы новые.
sudo rm -f /etc/ssh/ssh_host_*

# Обнуляем размер файла, не удаляя его: systemd генерирует новый ID при загрузке
# именно по признаку «файл существует, но он пустой».
sudo truncate -s 0 /etc/machine-id

# Находим все файлы логов и обнуляем их содержимое, сохраняя структуру каталогов
# и права доступа. Это гарантирует, что службы вроде journald не сломаются при старте клона.
sudo find /var/log -type f -exec truncate -s 0 {} \;

# Удаляем файлы истории команд для пользователя и root
rm -f ~/.bash_history
sudo rm -f /root/.bash_history

# Очищаем буфер истории команд текущей сессии bash. Выполняется строго после удаления
# файлов, иначе при выходе из сессии bash запишет команды из RAM обратно в файл.
history -c

# Выключаем машину, чтобы система не сгенерировала новые данные в процессе работы
sudo poweroff
```

Почему логи именно обнуляются, а не удаляются вместе с каталогами — см. [Что ломалось и как чинил](../../README.md#что-ломалось-и-как-чинил).

## Снять домен и зафиксировать образ как golden image

Сейчас поднятая ВМ `golden-vm` — это две сущности: XML-описание домена в libvirt и файл диска в пуле. Домен описывает полную конфигурацию ВМ: он указывает гипервизору, какие ресурсы выделить системе и как именно ими управлять. Файл диска — просто виртуальный накопитель с ОС. Для механизма клонирования нам нужен только подготовленный виртуальный диск, без домена: домен будет определять `virt-install` для каждой новой ВМ из скрипта `provision-node.sh`.

```bash
# Удаляет регистрацию виртуальной машины из libvirt
virsh undefine golden-vm

# Переименовывает оригинальный диск в осмысленное имя шаблона (golden image)
sudo mv /var/lib/libvirt/vmpool/noble-server-cloudimg-amd64.img /var/lib/libvirt/vmpool/ubuntu-2404-golden.qcow2

# Делает шаблон доступным только для чтения: ВМ, запущенная на этом образе, не сможет
# открыть его на запись и упадёт с ошибкой — так golden image защищён от «загрязнения».
sudo chmod 444 /var/lib/libvirt/vmpool/ubuntu-2404-golden.qcow2

virsh pool-refresh vmpool
```

Golden image готов.

