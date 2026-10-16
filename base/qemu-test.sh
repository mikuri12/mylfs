#!/bin/bash
# base/qemu-test.sh — Prueba de arranque: disco ext4 + kernel mikuri + OVMF,
# hasta el prompt de login de agetty (PLAN fase 1).
# Requiere en el runner: qemu-system-x86_64, ovmf, mtools. Se instala aquí.
set -euo pipefail
. "$(dirname "$0")/env.sh"

T0=$SECONDS
step() { printf '\n==> [qemu] %s (t+%dm)\n' "$*" $(( (SECONDS-T0)/60 )); }

step "dependencias QEMU/OVMF en el runner"
sudo apt-get update -q
sudo apt-get install -y -q qemu-system-x86 ovmf mtools >/dev/null

step "crear disco de prueba (12G, GPT, ext4)"
DISK=/mnt/work/mylfs-test.img
mkdir -p /mnt/work
rm -f "$DISK"
truncate -s 12G "$DISK"
# GPT: 512M EFI, resto root
sudo sgdisk --zap-all "$DISK"
sudo sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sudo sgdisk -n 2:0:0 -t 2:8300 "$DISK"
# loop con particiones
sudo losetup -fP "$DISK"
LOOP=$(losetup -j "$DISK" | cut -d: -f1)
echo "loop: $LOOP"
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.ext4 -q -L root ${LOOP}p2

step "montar y poblar rootfs desde el tarball stage4"
sudo mkdir -p /mnt/efi-part /mnt/root-part
sudo mount ${LOOP}p2 /mnt/root-part
sudo mkdir -p /mnt/root-part/boot/efi
sudo mount ${LOOP}p1 /mnt/root-part/boot/efi
sudo tar --zstd -xpf "$1" -C /mnt/root-part --numeric-owner --keep-directory-symlink

# UUID real para fstab/grub
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
echo "root uuid: $ROOT_UUID / efi uuid: $EFI_UUID"
sudo sed -i "s/UUID=00000000-0000-0000-0000-000000000000/UUID=$ROOT_UUID/" /mnt/root-part/etc/fstab
sudo sed -i "s/UUID=0000-0000/UUID=$EFI_UUID/" /mnt/root-part/etc/fstab
sudo sed -i "s/ROOTUUID/$ROOT_UUID/g" /mnt/root-part/boot/grub/grub.cfg

step "GRUB UEFI install (desde el runner hacia el disco)"
# grub del rootfs no puede ejecutarse en el runner (binarios del chroot LFS);
# usar grub-install del RUNNER apuntando al rootfs (modulesdir del sistema LFS).
sudo mkdir -p /mnt/root-part/boot/efi/EFI/mylfs
sudo grub-install --target=x86_64-efi \
    --efi-directory=/mnt/root-part/boot/efi \
    --boot-directory=/mnt/root-part/boot \
    --bootloader-id=mylfs \
    --modules="part_gpt ext2" \
    --no-nvram \
    --removable 2>&1 | tail -3
# copiar la grub.cfg al lugar correcto
sudo cp /mnt/root-part/boot/grub/grub.cfg /mnt/root-part/boot/grub/grub.cfg 2>/dev/null || true

step "desmontar y liberar loop"
sudo umount /mnt/root-part/boot/efi
sudo umount /mnt/root-part
sudo losetup -d "$LOOP"

step "arrancar en QEMU con OVMF, esperar login (timeout 300s)"
# serial: agetty del kernel? No configuíamos getty serial. El test vigila
# la consola VGA con OCR no disponible — mejor: agetty-ttyS0 en el rootfs
# ya viene de void-runit (services/agetty-ttyS0). Activarlo:
sudo mount ${LOOP}p2 /mnt/root-part
sudo ln -sf /etc/sv/agetty-ttyS0 /mnt/root-part/etc/runit/runsvdir/default/
# kernel cmdline serial console
sudo sed -i 's/ ro mitigations=off/ ro mitigations=off console=ttyS0,115200 console=tty0/' /mnt/root-part/boot/grub/grub.cfg
sudo umount /mnt/root-part

OVMF=$(ls /usr/share/OVMF/OVMF_CODE*.fd 2>/dev/null | head -1)
[ -n "$OVMF" ] || OVMF=/usr/share/ovmf/OVMF.fd

LOG=/mnt/work/qemu-boot.log
timeout 300 bash <<QEOF &
set -e
qemu-system-x86_64 \\
    -machine q35 -m 2048 -smp 2 \\
    -drive file=$DISK,format=raw,if=virtio \\
    -net none \\
    -serial file:$LOG \\
    -display none \\
    -bios "$OVMF" \\
    -no-reboot
QEOF
QEMU_PID=$!

# Esperar el prompt de login en el log serial
ok=0
for i in $(seq 1 150); do
    if sudo grep -q "login:" "$LOG" 2>/dev/null; then
        ok=1
        break
    fi
    sleep 2
done
sudo kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

if [ $ok -eq 1 ]; then
    echo "== QEMU ARRANCÓ HASTA LOGIN =="
    sudo grep -E "runit|stage|Welcome|login:" "$LOG" | tail -20
    exit 0
else
    echo "== QEMU NO LLEGÓ A LOGIN — últimos 40 líneas =="
    sudo tail -40 "$LOG" 2>/dev/null || echo "(log vacío)"
    exit 1
fi
