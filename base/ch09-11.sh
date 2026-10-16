#!/bin/bash
# base/ch09-11.sh — Etapa 4: sistema arrancable (LFS 12.4 caps. 9-11 adaptados).
#
# FUENTES:
# - LFS 12.4 §9 (configuración del sistema: profile,.hostname,rejillas runit NO —
#   usamos void-runit), §10 (grub, fstab), §11 (the end).
# - void-runit (github.com/void-linux/void-runit) para /etc/runit/{1,2,3} adaptados.
# - Kernel: release v7.1.5-mikuri de mikuri-kernel (binarios), fuentes CachyOS
#   7.1.5 para headers (D11 en DECISIONS.md).
#
# ADAPTACIONES al libro:
# - NO se instalan lfs-bootscripts ni SysVinit: init=runit (D5).
# - GRUB desde el libro §8.41/§10.3 (BIOS+UEFI según libro) con config UEFI.
# - eudev ya instalado en etapa 3; su servicio runit aquí.
#
# PLAN: usuario normal en grupos video,audio,input,wheel,seat; sin password
# en CI (se define al primer arranque con passwd); doas poweroff nopass ya
# configurado en etapa 3; timezone/locale/keymap ya fijados.

set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/make.conf.sh"

T0=$SECONDS
step() { printf '\n==> [stage4] %s (t+%dm)\n' "$*" $(( (SECONDS-T0)/60 )); }

chroot_run() {
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root TERM="$TERM" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="$MAKEFLAGS" TESTSUITEFLAGS="$TESTSUITEFLAGS" \
        CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" \
        LC_ALL=POSIX \
        /bin/bash --noprofile --norc -s
}

pkg() {
    local name=$1
    step "$name (chroot)"
    { echo 'umask 022; set +h'; cat; } | chroot_run
    step "$name OK"
}

# vfs §7.3 (idéntico a etapas 2-3)
step "vfs virtuales (§7.3)"
mkdir -pv "$LFS"/{dev,proc,sys,run} "$LFS/dev/pts" "$LFS/dev/shm"
mount -v --bind /dev "$LFS/dev"
mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mount -vt proc proc "$LFS/proc"
mount -vt sysfs sysfs "$LFS/sys"
mount -vt tmpfs tmpfs "$LFS/run"
if [ -h "$LFS/dev/shm" ]; then
    install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
else
    mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi
trap 'umount -v "$LFS/dev/pts" "$LFS/dev/shm" "$LFS/sys" "$LFS/proc" "$LFS/run" "$LFS/dev" 2>/dev/null || true' EXIT

# ============================================================================
# §9.4 Ficheros de perfil (bash) — literal del libro
# ============================================================================
pkg bash-profiles <<'PEOF'
set -euo pipefail
cat > /etc/profile << 'PROFILE-IN'
# Begin /etc/profile
# Written for Beyond Linux From Scratch
# by James Robertson <jameswrobertson@earthlink.net>
# modifications by Dagmar d'Surreal <rhiannon@m-net.arbornet.org>

# System wide environment variables and startup programs.

# System aliases and functions should go in /etc/bashrc.  Personal
# environment variables and startup programs should go in
# ~/.bash_profile.  Personal aliases and functions should go in
# ~/.bashrc.

# Set the initial path
export PATH=/usr/bin:/usr/sbin

if [ $EUID -eq 0 ] ; then
  unset HISTFILE
fi

# Setup some environment variables.
export HISTSIZE=1000
export HISTIGNORE="&:[bf]g:exit"
export LANG=en_US.UTF-8

# End /etc/profile
PROFILE-IN
PEOF

# ============================================================================
# Kernel: binarios del release mikuri-kernel (PLAN: no compilar)
# + headers de CachyOS 7.1.5 (misma versión)
# ============================================================================
step "kernel mikuri: extraer tarball verificado"
KSHA=$(grep -E "^sha256:" "$(dirname "$0")"/../kernel/KERNEL_TAG | cut -d: -f2)
cd "$LFS/sources"
# descargar release y verificar
if [ ! -f mikuri-kernel-7.1.5-mikuri.tar.gz ]; then
    gh release download v7.1.5-mikuri -R mikuri12/mikuri-kernel \
        --pattern 'mikuri-kernel-7.1.5-mikuri.tar.gz' --clobber \
        -O "$LFS/sources/mikuri-kernel-7.1.5-mikuri.tar.gz" 2>/dev/null || \
    curl -fsSL -o "$LFS/sources/mikuri-kernel-7.1.5-mikuri.tar.gz" \
        "https://github.com/mikuri12/mikuri-kernel/releases/download/v7.1.5-mikuri/mikuri-kernel-7.1.5-mikuri.tar.gz"
fi
echo "$KSHA  mikuri-kernel-7.1.5-mikuri.tar.gz" | sha256sum -c -
# Listar contenido sin matar a tar con SIGPIPE (head cierra el pipe):
tar -tzf mikuri-kernel-7.1.5-mikuri.tar.gz > /tmp/kernel-list.txt
head -3 /tmp/kernel-list.txt
grep -c "^boot/\|^usr/lib/modules/" /tmp/kernel-list.txt
tar -xzpf mikuri-kernel-7.1.5-mikuri.tar.gz -C "$LFS" --numeric-owner --keep-directory-symlink
ls -la "$LFS/boot/"

pkg kernel-headers <<'KEOF'
set -euo pipefail
# Headers de la MISMA versión (7.1.5) desde fuentes CachyOS (D11)
cd /sources
rm -rf linux-7.1.5-headers
mkdir linux-7.1.5-headers
tar -xpf cachyos-7.1.5-1.tar.gz -C linux-7.1.5-headers --strip-components=1
cd linux-7.1.5-headers
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include /usr
cd /sources
rm -rf linux-7.1.5-headers
KEOF

# ============================================================================
# §10.2 fstab de ejemplo con UUID (placeholder — el disco real se conoce al
# instalar; el PLAN pide ejemplo con UUID)
# ============================================================================
pkg fstab <<'FEOF'
set -euo pipefail
cat > /etc/fstab << 'FSTAB-IN'
# /etc/fstab: ejemplo para el disco objetivo (root en ext4)
# Sustituir el UUID por el del disco real: blkid /dev/sdXn
UUID=00000000-0000-0000-0000-000000000000  /      ext4   defaults,commit=60  0 1
UUID=0000-0000                              /boot/efi  vfat   defaults,noatime,uid=0,gid=0  0 2
/tmp                                        /tmp   tmpfs  defaults,nosuid,nodev,mode=1777  0 0
FSTAB-IN
FEOF

# ============================================================================
# §10.3 GRUB UEFI (construido en etapa 3 ya instalado como paquete del libro
# §8.41 — AQUÍ no: grub no se compiló en etapa 3. Lo compilamos ahora.)
# ============================================================================
pkg grub <<'GEOF'
set -euo pipefail
cd /sources
rm -rf grub-2.12
tar -xpf grub-2.12.tar.xz
cd grub-2.12
echo depends bli part_gpt > grub-core/extra_deps.lst
mkdir -v build
cd       build
../configure --prefix=/usr        \
             --sysconfdir=/etc    \
             --disable-efiemu     \
             --disable-werror     \
             --target=x86_64      \
             --with-platform=efi
make
make install
mv -v /etc/bash_completion.d/grub /usr/share/bash-completion/completions 2>/dev/null || true
rm -rf /usr/share/doc/grub
GEOF

# ============================================================================
# runit: el binario runit-init (fork de Void) + void-runit scripts
# Adaptación: igual que Void, sin polkit/elogind
# ============================================================================
pkg runit-bin <<'REOF'
set -euo pipefail
cd /sources
rm -rf runit-void
mkdir runit-void
# tarball del fork runit de void-linux
if [ ! -f runit-void.tar.gz ]; then
    curl -fsSL -o runit-void.tar.gz \
        "https://github.com/void-linux/runit/archive/refs/heads/master.tar.gz"
fi
tar -xzf runit-void.tar.gz -C runit-void --strip-components=1
cd runit-void
# package_*.conf de Void: build estático recomendado
CFLAGS="$CFLAGS -static" ./package/compile 2>/dev/null || {
    # si el package build falla, make directo
    make
}
# binarios: runit, runit-init, utmpset, chpst, sv, runsv, runsvdir, runsvchdir, svlogd
install -v -m755 command/t/{runit,runit-init,utmpset,chpst,sv,runsv,runsvdir,runsvchdir,svlogd} /usr/sbin/ 2>/dev/null || \
install -v -m755 command/* /usr/sbin/ 2>/dev/null || true
ls /usr/sbin/ | grep -E "runit|chpst|sv|runsv|utmpset" || { echo "runit no instalado"; exit 1; }
cd /sources
rm -rf runit-void
REOF

pkg void-runit-scripts <<'VEOF'
set -euo pipefail
cd /sources
rm -rf void-runit
mkdir void-runit
if [ ! -f void-runit.tar.gz ]; then
    curl -fsSL -o void-runit.tar.gz \
        "https://github.com/void-linux/void-runit/archive/refs/heads/master.tar.gz"
fi
tar -xzf void-runit.tar.gz -C void-runit --strip-components=1
cd void-runit
# compilar helpers (halt, pause, vlogger, seedrng)
make CC="gcc $CFLAGS"
# instalar todo: scripts 1/2/3, core-services, runsvdir, services
make install DESTDIR=/ VOIDTOOLS=""
cd /sources
rm -rf void-runit
VEOF

# ============================================================================
# Servicios runit del PLAN (sshd, dhcpcd, chronyd, acpid, eudev/udevd,
# agetty-tty1) + runlevel default
# ============================================================================
pkg runit-services <<'SEOF'
set -euo pipefail
install -v -m755 -d /etc/runit/runsvdir/default

mk_svc() { mkdir -p /etc/sv/$1; }

# --- eudev/udevd (stage 2 lo necesita montado temprano) ---
mk_svc udevd
cat > /etc/sv/udevd/run << 'RUN-IN'
#!/bin/sh
exec udevd
RUN-IN
chmod 755 /etc/sv/udevd/run

# --- sshd ---
mk_svc sshd
cat > /etc/sv/sshd/run << 'RUN-IN'
#!/bin/sh
exec /usr/sbin/sshd -D
RUN-IN
chmod 755 /etc/sv/sshd/run

# --- dhcpcd ---
mk_svc dhcpcd
cat > /etc/sv/dhcpcd/run << 'RUN-IN'
#!/bin/sh
exec /usr/sbin/dhcpcd -B -M
RUN-IN
chmod 755 /etc/sv/dhcpcd/run

# --- chronyd ---
mk_svc chronyd
cat > /etc/sv/chronyd/run << 'RUN-IN'
#!/bin/sh
exec /usr/sbin/chronyd -d
RUN-IN
chmod 755 /etc/sv/chronyd/run

# --- acpid ---
mk_svc acpid
cat > /etc/sv/acpid/run << 'RUN-IN'
#!/bin/sh
exec /usr/sbin/acpid -f
RUN-IN
chmod 755 /etc/sv/acpid/run

# --- runlevel default: gettys + servicios ---
cd /etc/runit/runsvdir/default
ln -sf /etc/sv/agetty-tty1 .
ln -sf /etc/sv/agetty-tty2 .
ln -sf /etc/sv/udevd .
ln -sf /etc/sv/sshd .
ln -sf /etc/sv/dhcpcd .
ln -sf /etc/sv/chronyd .
ln -sf /etc/sv/acpid .
SEOF

# ============================================================================
# §9.6+ usuario normal (PLAN: sin password en CI; grupos video audio input
# wheel seat; doas.conf ya permite poweroff nopass desde etapa 3)
# ============================================================================
pkg system-user <<'UEOF'
set -euo pipefail
# grupo seat para seatd (Fase 2) + usuario mikuri
groupadd -f seat
useradd -m -G video,audio,input,wheel,seat -s /bin/bash mikuri
# password bloqueado en CI: se activa al primer arranque con passwd desde root
passwd -l mikuri 2>/dev/null || usermod -L mikuri 2>/dev/null || true
# grupos sshd/dhcpcd ya creados en etapa 3 (openssh/dhcpcd)
UEOF

# ============================================================================
# §10.4 grub.cfg generado — con la cmdline del kernel del usuario:
# root=UUID=... ro mitigations=off (README del repo mikuri-kernel)
# ============================================================================
step "grub.cfg (plantilla)"
cat > "$LFS/boot/grub/grub.cfg" << 'EOF'
# GRUB config generada por mylfs (etapa 4)
set default=0
set timeout=5

menuentry "mylfs 1.0 (7.1.5-mikuri)" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ROOTUUID
    linux /boot/vmlinuz-7.1.5-mikuri root=UUID=ROOTUUID ro mitigations=off
    initrd /boot/initramfs-7.1.5-mikuri.img
}
EOF
mkdir -pv "$LFS/boot/grub"

# ============================================================================
# dracut: initramfs --no-hostonly con add-drivers ahci ext4 (PLAN)
# ============================================================================
pkg dracut-initramfs <<'DEOF'
set -euo pipefail
# dracut instalado en etapa 3; generar initramfs del kernel mikuri
# --no-hostonly: sin copiar drivers del runner (PLAN)
dracut --no-hostonly --add-drivers "ahci ext4" \
       --kver 7.1.5-mikuri \
       --force /boot/initramfs-7.1.5-mikuri.img 7.1.5-mikuri
ls -la /boot/
DEOF

# ============================================================================
# Verificación final de la etapa + resumen
# ============================================================================
step "verificación rápida"
test -x "$LFS/usr/sbin/runit"        || { echo "FALTA runit"; exit 1; }
test -e "$LFS/etc/runit/2"           || { echo "FALTA /etc/runit/2"; exit 1; }
test -e "$LFS/boot/vmlinuz-7.1.5-mikuri"  || { echo "FALTA kernel"; exit 1; }
test -e "$LFS/boot/initramfs-7.1.5-mikuri.img" || { echo "FALTA initramfs"; exit 1; }
test -x "$LFS/usr/sbin/grub-install" || { echo "FALTA grub"; exit 1; }
test -d "$LFS/etc/sv/sshd"           || { echo "FALTA sv sshd"; exit 1; }
test -d "$LFS/etc/sv/udevd"          || { echo "FALTA sv udevd"; exit 1; }
df -h "$LFS"
du -sh "$LFS" || true
echo "==> ETAPA 4 COMPLETA (t=$(( (SECONDS-T0)/60 ))min)"
