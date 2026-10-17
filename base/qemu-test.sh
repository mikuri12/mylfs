#!/bin/bash
# base/qemu-test.sh — Prueba de arranque: disco GPT + kernel mikuri + OVMF UEFI,
# hasta el prompt de login de agetty por consola serial (PLAN fase 1).
# Requiere en el runner: qemu-system-x86_64, ovmf, sgdisk, mtools (se instalan aquí).
set -euo pipefail
. "$(dirname "$0")/env.sh"

T0=$SECONDS
step() { printf '\n==> [qemu] %s (t+%dm)\n' "$*" $(( (SECONDS-T0)/60 )); }

step "dependencias QEMU/OVMF en el runner"
sudo apt-get update -q
sudo apt-get install -y -q qemu-system-x86 ovmf gdisk mtools >/dev/null

step "crear disco de prueba (12G, GPT: 512M EFI + root ext4)"
DISK=/mnt/work/mylfs-test.img
mkdir -p /mnt/work
rm -f "$DISK"
truncate -s 12G "$DISK"
sudo sgdisk --zap-all "$DISK"
sudo sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sudo sgdisk -n 2:0:0 -t 2:8300 "$DISK"
sudo losetup -fP "$DISK"
LOOP=$(losetup -j "$DISK" | head -1 | cut -d: -f1)
echo "loop: $LOOP"
sudo partprobe "$LOOP" 2>/dev/null || true
# esperar nodos de partición
for i in $(seq 1 10); do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && break
    sleep 1
done
[ -b "${LOOP}p2" ] || { echo "no apareció ${LOOP}p2"; exit 1; }
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.ext4 -q -L root ${LOOP}p2

step "montar, poblar rootfs y configurar (TODO en un montaje)"
sudo mkdir -p /mnt/root-part
sudo mount ${LOOP}p2 /mnt/root-part
sudo mkdir -p /mnt/root-part/boot/efi
sudo mount ${LOOP}p1 /mnt/root-part/boot/efi
# el tarball lleva prefijo lfs/ (creado con -C /mnt lfs): strip 1 nivel
sudo tar --zstd -xpf "$1" -C /mnt/root-part --numeric-owner --keep-directory-symlink --strip-components=1

# UUID reales para fstab y grub
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
echo "root uuid: $ROOT_UUID / efi uuid: $EFI_UUID"
sudo sed -i "s/UUID=00000000-0000-0000-0000-000000000000/UUID=$ROOT_UUID/" /mnt/root-part/etc/fstab
sudo sed -i "s/UUID=0000-0000/UUID=$EFI_UUID/" /mnt/root-part/etc/fstab
sudo sed -i "s/ROOTUUID/$ROOT_UUID/g" /mnt/root-part/boot/grub/grub.cfg
# consola serial para el test (getty serial + cmdline)
sudo ln -sf /etc/sv/agetty-ttyS0 /mnt/root-part/etc/runit/runsvdir/default/
sudo sed -i 's/ ro mitigations=off/ ro mitigations=off console=ttyS0,115200 console=tty0/' /mnt/root-part/boot/grub/grub.cfg

step "GRUB UEFI en el disco (grub-install del runner)"
sudo grub-install --target=x86_64-efi \
    --efi-directory=/mnt/root-part/boot/efi \
    --boot-directory=/mnt/root-part/boot \
    --bootloader-id=mylfs \
    --modules="part_gpt ext2" \
    --no-nvram \
    --removable > /tmp/grub-install.log 2>&1
tail -3 /tmp/grub-install.log

step "desmontar y liberar loop (antes de arrancar)"
sudo umount /mnt/root-part/boot/efi
sudo umount /mnt/root-part
sudo losetup -d "$LOOP"

step "arrancar QEMU con OVMF, esperar login (timeout 300s)"
OVMF=$(ls /usr/share/OVMF/OVMF_CODE*.fd 2>/dev/null | head -1)
[ -n "$OVMF" ] || OVMF=/usr/share/ovmf/OVMF.fd

LOG=/mnt/work/qemu-boot.log
rm -f "$LOG"
sudo qemu-system-x86_64 \
    -machine q35 -m 2048 -smp 2 \
    -drive file=$DISK,format=raw,if=virtio \
    -net none \
    -serial file:$LOG \
    -display none \
    -bios "$OVMF" \
    -no-reboot &
QEMU_PID=$!

# Esperar el prompt de login en el log serial
ok=0
for i in $(seq 1 150); do
    if sudo grep -q "login:" "$LOG" 2>/dev/null; then
        ok=1
        break
    fi
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo "QEMU terminó antes del login"
        break
    fi
    sleep 2
done
sudo kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

if [ $ok -eq 1 ]; then
    echo "== QEMU ARRANCÓ HASTA LOGIN =="
    sudo grep -E "runit|stage|Welcome|login:|Linux" "$LOG" > /tmp/qemu-grep.txt || true
    sudo tail -20 /tmp/qemu-grep.txt
    exit 0
else
    echo "== QEMU NO LLEGÓ A LOGIN — últimos 40 líneas del serial =="
    sudo tail -40 "$LOG" 2>/dev/null || echo "(log serial vacío — no arrancó ni el firmware)"
    exit 1
fi
