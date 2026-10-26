#!/bin/bash
# live/make-live.sh — Construye mylfs-live.iso desde el rootfs validado.
# CORRE EN CI (ubuntu runner), NO en el chroot: hace chroot puntual para
# lvm2 (dmsetup que dmsquash-live necesita) y para el initramfs.
#
# ENTRADA (ya descargado por el workflow):
#   $ROOTFS_TAR — rootfs-base.tar.zst reconstruido y verificado (el rootfs
#                 YA contiene boot/vmlinuz-7.1.5-mikuri y lib/modules/)
# SALIDA:
#   mylfs-live.iso — híbrida GRUB (BIOS+UEFI), squashfs zstd + overlay RAM
set -euo pipefail

ROOTFS_TAR=$1
WORK=$(pwd)/live-work
ISO=mylfs-live.iso
LABEL="MYLFS_LIVE"

rm -rf "$WORK"
mkdir -p "$WORK"/{isosrc/LiveOS,efi,initrd-work,dl}
# NOTA: no crear $WORK/rootfs aquí — el mv de abajo RENOMBRA lfs → rootfs
# (si rootfs ya existe, mv lo mete DENTRO: rootfs/lfs/...)

# ============================================================================
# 1) Extraer el rootfs base
# ============================================================================
step() { printf '\n==> [live] %s (t+%ds)\n' "$*" "$SECONDS"; }

step "extraer rootfs"
sudo tar --zstd -xpf "$ROOTFS_TAR" -C "$WORK" --numeric-owner --keep-directory-symlink
# el tarball lleva lfs/ dentro: mover a rootfs/
sudo mv "$WORK/lfs" "$WORK/rootfs"

# ============================================================================
# 2) Kernel: ya viene en el rootfs (boot/vmlinuz-7.1.5-mikuri)
# ============================================================================
step "kernel (del rootfs)"
VMLINUX=$(find "$WORK/rootfs/boot" -name 'vmlinuz*' | head -1)
[ -n "$VMLINUX" ] || { echo "no encontré vmlinuz en rootfs/boot"; exit 1; }
echo "kernel: $VMLINUX"

# ============================================================================
# 3) dmsetup (lvm2, build-only) DENTRO del chroot — dmsquash-live lo exige
#    (BLFS 12.4: LVM2 2.03.34 + libaio 0.3.3.113; solo herramientas dm)
# ============================================================================
step "lvm2 (dmsetup) en chroot"
mkdir -p "$WORK/dl"
# pagure.io (upstream de BLFS) caído: mirror del pool de Ubuntu noble,
# MISMO tarball upstream (md5 7d5be185... = BLFS-git 12.4)
curl -fsSL --retry 3 -o "$WORK/dl/libaio-0.3.113.tar.gz" \
  "https://archive.ubuntu.com/ubuntu/pool/main/liba/libaio/libaio_0.3.113.orig.tar.gz"
echo "7d5be185f20eeaae15e267419950aaf7  $WORK/dl/libaio-0.3.113.tar.gz" | md5sum -c -
curl -fsSL --retry 3 -o "$WORK/dl/LVM2.2.03.34.tgz" \
  "https://sourceware.org/ftp/lvm2/LVM2.2.03.34.tgz"
echo "947741079e22a35d76aefa99861b406a  $WORK/dl/LVM2.2.03.34.tgz" | md5sum -c -

# mounts para compilar en chroot
sudo mkdir -p "$WORK"/rootfs/{dev,proc,sys,run,dev/pts,dev/shm}
sudo mount --bind /dev "$WORK/rootfs/dev"
sudo mount -vt devpts devpts -o gid=5,mode=0620 "$WORK/rootfs/dev/pts"
sudo mount -vt proc proc "$WORK/rootfs/proc"
sudo mount -vt sysfs sysfs "$WORK/rootfs/sys"
sudo mount -vt tmpfs tmpfs "$WORK/rootfs/run"
sudo mount -vt tmpfs -o nosuid,nodev tmpfs "$WORK/rootfs/dev/shm"
cleanup_mounts() {
  sudo umount -l "$WORK/rootfs/dev/pts" 2>/dev/null || true
  sudo umount -l "$WORK/rootfs/dev/shm" 2>/dev/null || true
  sudo umount -l "$WORK/rootfs/sys" 2>/dev/null || true
  sudo umount -l "$WORK/rootfs/proc" 2>/dev/null || true
  sudo umount -l "$WORK/rootfs/run" 2>/dev/null || true
  sudo umount -l "$WORK/rootfs/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

# libaio + lvm2 — comandos BLFS (dm-only: dmsetup para dmsquash-live)
sudo cp "$WORK"/dl/* "$WORK/rootfs/sources/"
sudo chroot "$WORK/rootfs" /usr/bin/env -i HOME=/root TERM="$TERM" \
  PATH=/usr/bin:/usr/sbin LC_ALL=POSIX \
  bash -e << 'DMEOF'
    set -euo pipefail
    cd /sources
    rm -rf libaio-0.3.113 LVM2.2.03.34
    tar -xpf libaio-0.3.113.tar.gz && cd libaio-0.3.113
    make -j"$(nproc)"
    make install
    cd .. && rm -rf libaio-0.3.113
    tar -xpf LVM2.2.03.34.tgz && cd LVM2.2.03.34
    ./configure --prefix=/usr \
      --with-default-locking-dir=/run/lock/lvm \
      --with-default-run-dir=/run/lvm \
      --disable-udev-systemd-background-jobs \
      --disable-nls --disable-readline --disable-tests
    make -j"$(nproc)" device-mapper
    make install_device-mapper
DMEOF
# VERIFY: dmsetup presente en el chroot (dracut módulo dm lo exige)
sudo test -x "$WORK/rootfs/usr/sbin/dmsetup" || { echo "dmsetup no instalado"; exit 1; }
step "dmsetup OK"

# ============================================================================
# 4) Usuario live + config de sesión live (contraseña live de prueba)
# ============================================================================
step "usuario live"
# Hash SHA-512 de "mylfs" con openssl DEL RUNNER: el python3 del chroot es
# 3.13 (sin módulo crypt, PEP 594) y whois/mkpasswd no está en LFS.
# usermod -p planta el hash directo; pam_unix autentica por prefijo.
LIVE_HASH=$(openssl passwd -6 "mylfs")
sudo chroot "$WORK/rootfs" /usr/bin/env -i HOME=/root TERM="$TERM" \
  PATH=/usr/bin:/usr/sbin LC_ALL=POSIX LIVE_HASH="$LIVE_HASH" \
  bash -e << 'LIVEOF'
    set -euo pipefail
    useradd -m -G video,audio,input,wheel,seat -s /bin/bash live
    usermod -p "$LIVE_HASH" live
    usermod -p "$LIVE_HASH" root
    echo "mylfs-live" > /etc/hostname
    # getty serial SOLO para la ISO (patrón void-runit; sin heredocs
    # anidados: printf, para que los delimitadores cierren siempre)
    mkdir -p /etc/sv/agetty-ttyS0
    printf '%s\n' \
      '#!/bin/sh' '' 'tty=${PWD##*-}' '' '[ -r conf ] && . ./conf' \
      '' 'if [ -x /sbin/getty -o -x /bin/getty ]; then' \
      '	GETTY=getty' \
      'elif [ -x /sbin/agetty -o -x /bin/agetty ]; then' \
      '	GETTY=agetty' 'fi' '' \
      'exec chpst -P ${GETTY} ${GETTY_ARGS} "${tty}" "${BAUD_RATE}" "${TERM_NAME}"' \
      > /etc/sv/agetty-ttyS0/run
    chmod 755 /etc/sv/agetty-ttyS0/run
    printf '%s\n' 'BAUD_RATE=115200' 'TERM_NAME=linux' > /etc/sv/agetty-ttyS0/conf
    ln -sf /etc/sv/agetty-ttyS0 /etc/runit/runsvdir/default/
LIVEOF
# ============================================================================
# 5) Initramfs con dracut: dmsquash-live + overlayfs + serial
# ============================================================================
step "dracut initramfs"
# dracut corre en el chroot; los módulos del mikuri ya están en el rootfs
# (--no-hostonly: toma squashfs/overlay/iso9660/loop de lib/modules)
sudo chroot "$WORK/rootfs" /usr/bin/env -i HOME=/root TERM="$TERM" \
  PATH=/usr/bin:/usr/sbin LC_ALL=POSIX \
  bash -e -c '
    set -euo pipefail
    KVER=$(basename /lib/modules/*/)
    echo "kver: $KVER"
    dracut --no-hostonly --add-drivers "ahci ext4" \
      --add "dmsquash-live overlayfs" \
      /initramfs-live.img "$KVER"
  '
sudo mv "$WORK/rootfs/initramfs-live.img" "$WORK/initramfs-live.img"

# ============================================================================
#  híbrida: GRUB (xorriso): BIOS + UEFI, label MYLFS_LIVE
# ============================================================================
step "xorriso GRUB híbrida"
# El rootfs con el lvm2 instalado se comprime al squashfs
sudo mksquashfs "$WORK/rootfs" "$WORK/isosrc/LiveOS/squashfs.img" \
  -comp zstd -Xcompression-level 19 -noappend -quiet \
  -wildcards -e 'proc/*' -e 'sys/*' -e 'dev/*' -e 'run/*' -e 'tmp/*' -e 'sources/*'
sudo chown runner:runner "$WORK/isosrc/LiveOS/squashfs.img"
# EFI: grub.cfg estándar live
mkdir -p "$WORK/isosrc/boot/grub" "$WORK/isosrc/EFI/BOOT"
cp "$VMLINUX" "$WORK/isosrc/boot/vmlinuz-mikuri"
cp "$WORK/initramfs-live.img" "$WORK/isosrc/boot/initramfs-live.img"

cat > "$WORK/isosrc/boot/grub/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=3
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "mylfs live (rootfs-base-v1 + mikuri 7.1.5)" {
    linux /boot/vmlinuz-mikuri root=live:LABEL=MYLFS_LIVE rd.live.image rd.live.overlay.overlayfs=1 console=ttyS0,115200 console=tty0
    initrd /boot/initramfs-live.img
}
GRUBEOF

# EFI/BOOT/grub.cfg (UEFI lee EFI/BOOT/grub.cfg)
cp "$WORK/isosrc/boot/grub/grub.cfg" "$WORK/isosrc/EFI/BOOT/grub.cfg"

# xorriso: ISO híbrida (BIOS+UEFI) con grub-mkrescue
grub-mkrescue -o "$ISO" "$WORK/isosrc" 2>/dev/null || sudo grub-mkrescue -o "$ISO" "$WORK/isosrc"
[ -f "$ISO" ] || { echo "no se generó la ISO"; exit 1; }

# ============================================================================
# 6) Verificación del contenido de la ISO
# ============================================================================
step "verificación ISO"
ls -la "$ISO"
sha256sum "$ISO" > "${ISO}.sha256"
# que exista LiveOS/squashfs.img dentro de la ISO
xorriso -osirrox on -indev "$ISO" -extract /LiveOS "$WORK/extract-check" 2>/dev/null || \
  sudo xorriso -osirrox on -indev "$ISO" -extract /LiveOS "$WORK/extract-check"
ls -la "$WORK/extract-check/LiveOS/"
echo "==> ISO lista: $ISO"
