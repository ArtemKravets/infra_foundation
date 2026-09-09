# Этап 1. Гипервизор: KVM/libvirt и хранилище ВМ

Узел-гипервизор — физическая машина, которая понесёт весь парк. На этом этапе на неё ставится гипервизор, а под диски будущих ВМ выделяется отдельный том LVM: парк не должен делить место с системным разделом.

## Установка KVM/libvirt

Ставим на предполагаемый гипервизор пакеты для работы с виртуализацией.

```bash
# Устанавливаем пакеты
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils iputils-arping

# Даём своему пользователю доступ к KVM/libvirt без sudo
sudo usermod -aG libvirt,kvm $USER
```

Перезаходим в новую сессию — добавленные группы не подхватываются в текущей:

```bash
exit
ssh hypervisor   # подставь свой алиас или адрес гипервизора
groups           # в списке должны появиться libvirt и kvm
```

Проверяем, что служба `libvirtd` запустилась, и фиксируем системное подключение libvirt:

```bash
sudo systemctl enable --now libvirtd   # будим службу и ставим её на автозапуск при загрузке ОС
systemctl is-active libvirtd           # ожидаем active
lsmod | grep kvm                       # проверяем, что модуль KVM подхвачен ядром

# Без явного URI virsh от обычного пользователя идёт в qemu:///session — отдельный
# «пользовательский» гипервизор, где нет ни нашего пула, ни сети, ни ВМ.
# Фиксируем системное подключение, чтобы дальнейшие команды работали как написано.
export LIBVIRT_DEFAULT_URI="qemu:///system"
echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' >> ~/.bashrc

virsh list --all                       # без sudo; пустой список с шапкой — норма
```

## LVM storage pool под диски ВМ

### Подготовка системного хранилища

По умолчанию libvirt создаёт storage pool прямо на системном диске (в томе `ubuntu-lv`). В таком случае ВМ делят одно пространство с системным разделом — это небезопасно и плохо масштабируется. Поэтому определяем storage pool на LVM с типом `dir`: диски ВМ будут храниться на отдельном LV, примонтированном в каталог, в виде файлов `qcow2`. Концепция «диск как файл» позволяет легко и безопасно автоматизировать создание клонов от golden image.

Установщик Ubuntu по умолчанию создаёт VG (`ubuntu-vg`) и на нём корневой LV (`ubuntu-lv`). Как правило, на `ubuntu-vg` остаётся неиспользуемое пространство — им мы и воспользуемся: создадим LV, примонтируем его к каталогу и укажем `libvirt`, что там будет его storage pool.

Делаем диагностику хранилища, чтобы понять текущее состояние:

```bash
lsblk -f
sudo vgs
sudo lvs
sudo pvs
df -h /
```

Убеждаемся, что в системе присутствует VG `ubuntu-vg` со свободным местом (мы собираемся выделять 300G):

```text
VG        #PV #LV #SN Attr   VSize    VFree
ubuntu-vg   1   2   0 wz--n- <950.82g <550.82g
```

Создаём LV → накатываем ФС → монтируем к каталогу:

```bash
# 1. LV под образы ВМ
sudo lvcreate -L 300G -n libvirt-images ubuntu-vg

# 2. Файловая система
sudo mkfs.ext4 /dev/ubuntu-vg/libvirt-images

# 3. Точка монтирования
sudo mkdir -p /var/lib/libvirt/vmpool

# 4. Персистентный маунт по UUID
UUID=$(sudo blkid -s UUID -o value /dev/ubuntu-vg/libvirt-images)
echo "UUID=$UUID  /var/lib/libvirt/vmpool  ext4  defaults  0 2" | sudo tee -a /etc/fstab
sudo mount -a
df -h /var/lib/libvirt/vmpool   # должен показать монтирование нового LV
```

### Инициализация пула в libvirt

Используем готовое определение пула из файла [`configs/host/storage-pool.xml`](../../configs/host/storage-pool.xml). Указываем `libvirt`, что `/var/lib/libvirt/vmpool` становится его пулом.

```bash
# Определить, поднять и включить автозапуск пула
virsh pool-define configs/host/storage-pool.xml
virsh pool-start vmpool
virsh pool-autostart vmpool

# Проверяем, что пул определился в libvirt
virsh pool-list --all
```

