#!/bin/bash
# live/mylfs-install.sh — instalador de mylfs al disco (corre DENTRO del
# sistema live, como root). Escribe: particiones GPT (EFI+root), copia
# el rootfs de la ISO al disco, kernel, initramfs, GRUB y fstab con los
# UUIDs REALES del disco destino. Uso: mylfs-install /dev/sdX [usuario]
set -euo pipefail

DISK=${1:?uso: mylfs-install /dev/sdX [nombre-usuario]}
NEWUSER=${2:-mikuri}

[ "$(id -u)" -eq 0 ] || { echo "corre como root (doas mylfs-install …)"; exit 1; }
# overlay live: el rootfs completo está montado en / (squashfs+overlay).
# Las fuentes del sistema live SON el sistema a copiar.

echo "==> mylfs-install: destino $DISK (SE BORRARÁ COMPLETO)"
lsblk -o NAME,SIZE,MODEL "$DISK"
read -r -p "¿Seguro? Escribe SI: " ok
[ "$ok" = "SI" ] || { echo "abortado"; exit 1; }

# 1) particiones: 512M EFI + resto root
echo "==> particionando"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0    -t 2:8300 -c 2:root "$DISK"
sgdisk -p "$DISK"
PART_EFI="${DISK}1"
PART_ROOT="${DISK}2"
#esperar a que el kernel vea las particiones nuevas
udevadm settle 2>/dev/null || sleep 2

# 2) filesystems
echo "==> filesystems"
mkfs.vfat -F32 -n MYLFS_EFI "$PART_EFI"
mkfs.ext4 -L mylfs "$PART_ROOT"

# 3) montar
ROOT=/mnt/mylfs-target
mkdir -p $ROOT
mount "$PART_ROOT" $ROOT
mkdir -p $ROOT/boot/efi
mount "$PART_EFI" $ROOT/boot/efi

# 4) copiar el sistema EN VIVO (todo menos pseudo-fs y /mnt)
echo "==> copiando sistema (esto tarda)"
tar --one-file-system -cpf - / \
  --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
  --exclude=./mnt --exclude=./tmp --exclude=./media --exclude=./var/tmp \
  | tar -xpf - -C $ROOT --numeric-owner --keep-directory-symlink

# 5) fstab con UUIDs reales
echo "==> fstab"
UUID_ROOT=$(blkid -s UUID -o value "$PART_ROOT")
UUID_EFI=$(blkid -s UUID -o value "$PART_EFI")
cat > $ROOT/etc/fstab << FSTEOF
# /etc/fstab — generado por mylfs-install
UUID=$UUID_ROOT  /          ext4   defaults,noatime  0 1
UUID=$UUID_EFI   /boot/efi  vfat   defaults,noatime  0 2
tmpfs            /tmp       tmpfs  nosuid,nodev      0 0
FSTEOF

# 6) usuario (contraseña se pide interactiva) + doas poweroff
echo "==> usuario $NEWUSER"
chroot $ROOT useradd -m -G video,audio,input,wheel,seat -s /bin/bash "$NEWUSER" 2>/dev/null || true
echo "define la contraseña de $NEWUSER:"
chroot $ROOT passwd "$NEWUSER"
# root: bloquear de nuevo en disco (la live trae mylfs de prueba)
chroot $ROOT passwd -l root 2>/dev/null || true
# fstab live → disco: getty serial ya no hace falta (pero no estorba)

# 7) GRUB UEFI apuntando al disco real
echo "==> GRUB"
for d in dev proc sys; do mount --bind /$d $ROOT/$d; done
chroot $ROOT grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=mylfs --recheck
# grub.cfg con los UUIDs del disco
KVER=$(ls $ROOT/lib/modules | head -1)
cat > $ROOT/boot/grub/grub.cfg << GRUBEOF
set default=0
set timeout=3
menuentry "mylfs (kernel $KVER)" {
    search.fs_uuid $UUID_ROOT root
    linux /boot/vmlinuz-$KVER root=UUID=$UUID_ROOT ro mitigations=off
    initrd /boot/initramfs-$KVER.img
}
GRUBEOF
for d in dev proc sys; do umount $ROOT/$d; done

echo "==> initramfs del disco (dracut con el root real)"
for d in dev proc sys run; do mount --bind /$d $ROOT/$d 2>/dev/null || true; done
chroot $ROOT dracut --no-hostonly --add-drivers "ahci ext4" \
    --force /boot/initramfs-$KVER.img "$KVER"
for d in dev proc sys run; do umount $ROOT/$d 2>/dev/null || true; done

umount $ROOT/boot/efi
umount $ROOT
echo "==> LISTO. Revisa sgdisk -p $DISK, quita el USB y reinicia."
echo "    (Si no bootea, en firmware desactiva Secure Boot.)"
