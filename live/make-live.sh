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
PKGS_DIR=${2:-}   # FASE 3: dir con los .tar.zst del Release 'packages' de mymypkgs
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
# 1b) Paquetes del escritorio (Release 'packages' de mymypkgs) — FASE 3
#     PKGS_DIR (2º arg): .tar.zst descargados por el workflow.
#     SE EXTRAEN DENTRO DEL CHROOT: /var/run -> /run es un symlink ABSOLUTO;
#     con 'tar -C rootfs' el kernel resuelve /run al del HOST (tmpfs) y falla
#     con EXDEV "Invalid cross-device link" (runs 43127886452/43131507506).
#     Dentro del chroot el symlink resuelve a rootfs/run (mismo fs) → OK.
#     linux-mikuri NO: el kernel ya viene en el rootfs.
# ============================================================================
if [ -n "$PKGS_DIR" ] && ls "$PKGS_DIR"/*.tar.zst >/dev/null 2>&1; then
  step "instalar paquetes mymypkgs ($(ls "$PKGS_DIR"/*.tar.zst 2>/dev/null | wc -l) tarballs, en chroot)"
  sudo mkdir -p "$WORK/rootfs/packages"
  sudo cp "$PKGS_DIR"/*.tar.zst "$WORK/rootfs/packages/"
  rm -f "$PKGS_DIR"/*.tar.zst   # liberar disco del runner ya
  sudo chroot "$WORK/rootfs" /usr/bin/env -i HOME=/root TERM="$TERM" \
    PATH=/usr/bin:/usr/sbin LC_ALL=POSIX \
    bash -e -c '
      set -euo pipefail
      n=0
      for p in /packages/*.tar.zst; do
        case "$(basename "$p")" in linux-mikuri-*) continue ;; esac
        tar --zstd -xpf "$p" -C / --numeric-owner --keep-directory-symlink
        rm -f "$p"
        n=$((n+1))
      done
      echo "instalados $n paquetes en el rootfs"
      ldconfig 2>/dev/null || true
      command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true
      rm -rf /packages
      true
    '
  step "paquetes OK + ldconfig"
else
  step "sin PKGS_DIR: ISO solo con rootfs base (live-v1)"
fi

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
# 3c) Sesión de escritorio — FASE 3: greetd + noctalia-greeter + runit
#     Los paquetes ya traen /etc/sv/{seatd,turnstiled,dbus,greetd}/run y
#     /usr/share/mymy/user-services/* (turnstile). Aquí: usuario greeter,
#     config de greetd (vt1 + noctalia-greeter-session), PAM de greetd con
#     pam_turnstile, servicios en runsvdir y marker serial para el test QEMU.
# ============================================================================
step "configurar sesión de escritorio (greetd/noctalia-greeter/runit)"
sudo chroot "$WORK/rootfs" /usr/bin/env -i HOME=/root TERM="$TERM" \
  PATH=/usr/bin:/usr/sbin LC_ALL=POSIX \
  bash -e << 'SESEOF'
set -euo pipefail
# usuario greeter (el setup script de noctalia-greeter crea /var/lib)
if ! id greeter >/dev/null 2>&1; then
  useradd -r -d /var/lib/noctalia-greeter -s /usr/sbin/nologin -G video,input,seat greeter
fi
install -d -o greeter -g greeter /var/lib/noctalia-greeter 2>/dev/null || {
  mkdir -p /var/lib/noctalia-greeter; chown greeter:greeter /var/lib/noctalia-greeter; }
# config de greetd: greeter de Noctalia en vt1 (printf: evita heredocs anidados)
printf '%s\n' '[terminal]' 'vt = 1' '' '[default_session]' \
  'command = "/usr/bin/noctalia-greeter-session"' 'user = "greeter"' \
  > /etc/greetd/config.toml
# PAM de greetd: pam_unix + pam_turnstile si el módulo está (turnstile)
{
  echo '# greetd PAM (mylfs-live)'
  echo 'auth     required  pam_unix.so'
  [ -f /usr/lib/security/pam_turnstile.so ] && echo 'auth     optional  pam_turnstile.so'
  echo 'account  required  pam_unix.so'
  echo 'session  required  pam_unix.so'
  [ -f /usr/lib/security/pam_turnstile.so ] && echo 'session  optional  pam_turnstile.so'
} > /etc/pam.d/greetd
# servicios del sistema (void-runit runsvdir)
for s in seatd turnstiled dbus greetd; do
  [ -d "/etc/sv/$s" ] && ln -sf "/etc/sv/$s" /etc/runit/runsvdir/default/
done
# marker para el test QEMU por consola serial (autologin imprime estado)
printf '%s\n' \
  '#!/bin/sh' \
  'echo "MYLFS_LIVE_READY tty=$(tty 2>/dev/null)"' \
  'for s in seatd turnstiled dbus greetd; do' \
  '  printf "MYLFS_SVC %s: %s\n" "$s" "$(sv status /etc/sv/$s 2>&1 | head -1)"' \
  'done' \
  > /etc/profile.d/mylfs-live-check.sh
chmod 755 /etc/profile.d/mylfs-live-check.sh
SESEOF
step "sesión OK"

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
    # fstab de LIVE: el fstab de la base trae UUID placeholder (para el
    # disco real al instalar) y void-runit corre fsck -A + mount -a sobre
    # él → emergency shell. En live SOLO pseudo-fs; nada que montar.
    printf '%s\n' \
      '# mylfs-live fstab: solo pseudo-filesystems (overlay RAM)' \
      'tmpfs /tmp tmpfs nosuid,nodev 0 0' \
      'devtmpfs /dev devtmpfs mode=0755,nosuid 0 0' \
      'proc /proc proc nosuid,noexec,nodev 0 0' \
      'sysfs /sys sysfs nosuid,noexec,nodev 0 0' \
      > /etc/fstab
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
    printf '%s\n' 'BAUD_RATE=115200' 'TERM_NAME=linux' 'GETTY_ARGS=--autologin live' > /etc/sv/agetty-ttyS0/conf
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
# dracut corre en el chroot (root); recuperar el initramfs con sudo + chown
sudo mv "$WORK/rootfs/initramfs-live.img" "$WORK/initramfs-live.img"
sudo chown "$(id -un):$(id -gn)" "$WORK/initramfs-live.img"
ls -la "$WORK/initramfs-live.img"

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

menuentry "mylfs live v2 (rootfs-base-v1 + escritorio + mikuri 7.1.5)" {
    linux /boot/vmlinuz-mikuri root=live:LABEL=MYLFS_LIVE rd.live.image rd.live.overlay.overlayfs=1 mitigations=off console=ttyS0,115200
    initrd /boot/initramfs-live.img
}
GRUBEOF

# EFI/BOOT/grub.cfg (UEFI lee EFI/BOOT/grub.cfg)
cp "$WORK/isosrc/boot/grub/grub.cfg" "$WORK/isosrc/EFI/BOOT/grub.cfg"

# xorriso: ISO híbrida (BIOS+UEFI) con grub-mkrescue
# -- -volid MYLFS_LIVE: el label del volumen es lo que dracut matchea
# con root=live:LABEL=MYLFS_LIVE (sin esto, nunca encuentra el LiveOS).
grub-mkrescue -o "$ISO" "$WORK/isosrc" -- -volid MYLFS_LIVE 2>/dev/null || \
  sudo grub-mkrescue -o "$ISO" "$WORK/isosrc" -- -volid MYLFS_LIVE
[ -f "$ISO" ] || { echo "no se generó la ISO"; exit 1; }

# ============================================================================
# 6) Verificación del contenido de la ISO
# ============================================================================
step "verificación ISO"
ls -la "$ISO"
sha256sum "$ISO" > "${ISO}.sha256"
# Verificación por LISTADO (-ls imprime 'nombre' citado; -find tiene
# formato distinto al que asumí y el grep fallaba siempre).
iso_has() {  # iso_has <dir> <archivo>
  xorriso -indev "$ISO" -ls "$1" 2>/dev/null | grep -q "'$2'"
}
iso_has /LiveOS squashfs.img      || { echo "FALTA /LiveOS/squashfs.img"; exit 1; }
echo "ISO contiene: /LiveOS/squashfs.img"
iso_has /boot vmlinuz-mikuri      || { echo "FALTA /boot/vmlinuz-mikuri"; exit 1; }
echo "ISO contiene: /boot/vmlinuz-mikuri"
iso_has /boot initramfs-live.img  || { echo "FALTA /boot/initramfs-live.img"; exit 1; }
echo "ISO contiene: /boot/initramfs-live.img"
iso_has /boot/grub grub.cfg        || { echo "FALTA /boot/grub/grub.cfg"; exit 1; }
echo "ISO contiene: /boot/grub/grub.cfg"
echo "==> ISO lista: $ISO"
