#!/bin/bash
# auto_vm_create_password.sh
# Использование:
# ./auto_vm_create_password.sh <VM_NAME> <RAM_MB> <CPU_COUNT> <DISK_GB> <USER_PASSWORD>

set -e

VM_NAME="$1"
RAM_MB="$2"
CPU_COUNT="$3"
DISK_GB="$4"
USER_PASSWORD="$5"

BASE_IMAGE="$HOME/Images/jammy.img"
VM_DISK="$HOME/Images/${VM_NAME}.qcow2"
CLOUD_INIT_DIR="$HOME/${VM_NAME}-cloudinit"
SEED_ISO="$CLOUD_INIT_DIR/seed.img"

# --- 1. Создаём диск VM ---
echo "[1] Создаём диск для VM..."
qemu-img create -f qcow2 -b "$BASE_IMAGE" "$VM_DISK" "${DISK_GB}G"

# --- 2. Подготовка cloud-init ---
echo "[2] Создаём cloud-init конфиг..."
mkdir -p "$CLOUD_INIT_DIR"

# Шифруем пароль в hash для cloud-init
PASSWORD_HASH=$(python3 -c "import crypt; print(crypt.crypt('$USER_PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))")

cat > "$CLOUD_INIT_DIR/user-data" <<EOF
#cloud-config
users:
  - name: clouduser
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $PASSWORD_HASH
    shell: /bin/bash

ssh_pwauth: true
disable_root: true
EOF

cat > "$CLOUD_INIT_DIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

cloud-localds "$SEED_ISO" "$CLOUD_INIT_DIR/user-data" "$CLOUD_INIT_DIR/meta-data"

# --- 3. Автоматически назначаем SSH порт ---
PORT_FILE="$HOME/used_ports.txt"
mkdir -p "$(dirname $PORT_FILE)"
touch "$PORT_FILE"

SSH_PORT=$(seq 2222 2299 | grep -vxFf "$PORT_FILE" | head -n 1)
if [ -z "$SSH_PORT" ]; then
    echo "Нет свободных портов для SSH"
    exit 1
fi
echo "$SSH_PORT" >> "$PORT_FILE"

# --- 4. Создаём VM ---
echo "[3] Создаём VM $VM_NAME..."
sudo virt-install \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$CPU_COUNT" \
  --disk "$VM_DISK" \
  --disk "$SEED_ISO",device=cdrom \
  --os-variant ubuntu22.04 \
  --virt-type kvm \
  --graphics none \
  --import \
  --network network=default

# --- 5. Настройка port forwarding на хосте ---
echo "[4] Настраиваем iptables port forwarding..."
sleep 5
VM_IP=$(virsh domifaddr "$VM_NAME" --source agent | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -n1)
if [ -z "$VM_IP" ]; then
    VM_IP="192.168.122.100"
fi

sudo iptables -t nat -A PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "$VM_IP":22
sudo iptables -A FORWARD -p tcp -d "$VM_IP" --dport 22 -j ACCEPT

echo "Готово! Пользователь может подключиться через:"
echo "ssh clouduser@<HOST_IP> -p $SSH_PORT"

echo "Пароль: $USER_PASSWORD"



# --- 6. Настройка проброса SSH через libvirt NAT ---
# VM_IP: IP виртуалки
# SSH_PORT: порт на хосте, который хотим пробросить

# Получаем IP виртуалки (если virsh agent работает, иначе оставь статический)
VM_IP=$(virsh domifaddr "$VM_NAME" --source agent | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -n1)
if [ -z "$VM_IP" ]; then
    echo "[!] Не удалось получить IP через virsh agent, укажи вручную"
    VM_IP="192.168.122.100"
fi

# Свободный порт хоста для SSH (уже выбран ранее)
# SSH_PORT="$SSH_PORT"

NET_NAME="default"
TMP_XML=$(mktemp /tmp/libvirt-net-XXXX.xml)

echo "[6] Настройка port forwarding $SSH_PORT → $VM_IP:22 через libvirt NAT..."

# Получаем текущую XML сети
sudo virsh net-dumpxml $NET_NAME > "$TMP_XML"

# Проверяем, есть ли <forward> уже
if grep -q "<forward mode='nat'" "$TMP_XML"; then
    # Вставляем правило <port> после <forward>
    sudo sed -i "/<forward mode='nat'/a\\
    <port start='$SSH_PORT' end='$SSH_PORT'/>" "$TMP_XML"
else
    # Если forward нет, добавляем полностью
    sudo sed -i "/<network>/a\\
  <forward mode='nat'>\\
    <port start='$SSH_PORT' end='$SSH_PORT'/>\\
  </forward>" "$TMP_XML"
fi

# Перезапускаем сеть с новым XML
sudo virsh net-destroy $NET_NAME
sudo virsh net-undefine $NET_NAME
sudo virsh net-define "$TMP_XML"
sudo virsh net-start $NET_NAME
sudo virsh net-autostart $NET_NAME

echo "[6] Готово! Пользователь может подключиться:"
echo "ssh clouduser@<HOST_IP> -p $SSH_PORT"
