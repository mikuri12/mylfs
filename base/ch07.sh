#!/bin/bash
# base/ch07.sh — Etapa 2: chroot + herramientas temporales (LFS 12.4 cap. 7).
#
# FUENTE: LFS-BOOK-12.4 §7.2-7.11:
#   §7.2 changingowner, §7.3 kernfs/bind/kernfsmount (vfs virtuales),
#   §7.4 chroot, §7.6 creatingdirs, §7.7 createfiles,
#   §7.8 gettext, §7.9 bison, §7.10 perl, §7.11 python, §7.12 texinfo,
#   §7.13 util-linux, §7.14 cleanup.
# Comandos transcritos literalmente del libro.
#
# EN CI: este script corre como root (sudo) DENTRO del job de la etapa 2,
# tras restaurar el artifact de la etapa 1 en /mnt/lfs. Todo el capítulo 7
# se ejecuta con `chroot "$LFS" ...` como manda el libro; no hay usuario lfs.
#
# PLAN: set -euo pipefail, MAKEFLAGS, RUN_TESTS=0 (el libro tampoco corre
# test suites en cap. 7).

set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/make.conf.sh"

T0=$SECONDS
step() { printf '\n==> [stage2] %s (t+%dm)\n' "$*" $(( (SECONDS-T0)/60 )); }

SRC=$SOURCES

# Helper: ejecuta un bloque de comandos DENTRO del chroot de $LFS (§7.4).
# Entorno limpio igual al libro: env -i HOME=/root TERM PATH MAKEFLAGS.
chroot_run() {
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root TERM="$TERM" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="$MAKEFLAGS" TESTSUITEFLAGS="$TESTSUITEFLAGS" \
        LFS="$LFS" \
        /bin/bash --noprofile --norc -s
}

pkg() {
    local name=$1
    step "$name (chroot)"
    chroot_run
    step "$name OK"
}

# ---------------------------------------------------------------------------
# §7.2 Cambiar propietario: todo a root:root (era de lfs)
# NOTA CI: el usuario 'lfs' del job stage1 no existe en este runner; el tarball
# guarda UIDs numéricos. Resolvemos el UID real de $LFS/tools y chown desde ahí.
# ---------------------------------------------------------------------------
step "chown root:root \$LFS (§7.2)"
LFS_UID="$(stat -c '%u' "$LFS/tools")"
LFS_GID="$(stat -c '%g' "$LFS/tools")"
step "propietario actual de \$LFS/tools: uid=$LFS_UID gid=$LFS_GID"
chown --from "$LFS_UID:$LFS_GID" -R root:root "$LFS"/{usr,var,etc,tools,lib64}
chown -R root:root "$LFS/sources" "$LFS/bin" "$LFS/lib" "$LFS/sbin" 2>/dev/null || true

# ---------------------------------------------------------------------------
# §7.3 Virtual kernel file systems
# ---------------------------------------------------------------------------
step "vfs virtuales (§7.3)"
mkdir -pv "$LFS"/{dev,proc,sys,run}
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

# ---------------------------------------------------------------------------
# §7.6/7.7 (dirs completos + archivos esenciales) — DENTRO del chroot
# ---------------------------------------------------------------------------
pkg creating-files <<'CH07-EOF'
set -euo pipefail
# §7.6 creatingdirs (dentro de chroot las rutas son /, no $LFS)
mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/lib/locale
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}
ln -sfv /run /var/run
ln -sfv /run/lock /var/lock
install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp
# §7.7 createfiles
ln -sv /proc/self/mounts /etc/mtab
cat > /etc/hosts << EOF
127.0.0.1  localhost $(hostname)
::1        localhost
EOF
cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
echo "tester:x:101:" >> /etc/group
install -o tester -d /home/tester
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664 /var/log/lastlog
chmod -v 600 /var/log/btmp
CH07-EOF

# ---------------------------------------------------------------------------
# §7.8 Gettext (solo msgfmt, msgmerge, xgettext)
# ---------------------------------------------------------------------------
pkg gettext <<'EOF'
set -euo pipefail
cd /sources
rm -rf gettext-0.26
tar -xpf gettext-0.26.tar.xz
cd gettext-0.26
./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
EOF

# ---------------------------------------------------------------------------
# §7.9 Bison
# ---------------------------------------------------------------------------
pkg bison <<'EOF'
set -euo pipefail
cd /sources
rm -rf bison-3.8.2
tar -xpf bison-3.8.2.tar.xz
cd bison-3.8.2
./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
make
make install
EOF

# ---------------------------------------------------------------------------
# §7.10 Perl
# ---------------------------------------------------------------------------
pkg perl <<'EOF'
set -euo pipefail
cd /sources
rm -rf perl-5.42.0
tar -xpf perl-5.42.0.tar.xz
cd perl-5.42.0
sh Configure -des \
             -D prefix=/usr \
             -D vendorprefix=/usr \
             -D useshrplib \
             -D privlib=/usr/lib/perl5/5.42/core_perl \
             -D archlib=/usr/lib/perl5/5.42/core_perl \
             -D sitelib=/usr/lib/perl5/5.42/site_perl \
             -D sitearch=/usr/lib/perl5/5.42/site_perl \
             -D vendorlib=/usr/lib/perl5/5.42/vendor_perl \
             -D vendorarch=/usr/lib/perl5/5.42/vendor_perl
make
make install
EOF

# ---------------------------------------------------------------------------
# §7.11 Python
# ---------------------------------------------------------------------------
pkg python <<'EOF'
set -euo pipefail
cd /sources
rm -rf Python-3.13.7
tar -xpf Python-3.13.7.tar.xz
cd Python-3.13.7
./configure --prefix=/usr \
            --enable-shared \
            --without-ensurepip \
            --without-static-libpython
make
make install
EOF

# ---------------------------------------------------------------------------
# §7.12 Texinfo
# ---------------------------------------------------------------------------
pkg texinfo <<'EOF'
set -euo pipefail
cd /sources
rm -rf texinfo-7.2
tar -xpf texinfo-7.2.tar.xz
cd texinfo-7.2
./configure --prefix=/usr
make
make install
EOF

# ---------------------------------------------------------------------------
# §7.13 Util-linux
# ---------------------------------------------------------------------------
pkg util-linux <<'EOF'
set -euo pipefail
mkdir -pv /var/lib/hwclock
cd /sources
rm -rf util-linux-2.41.1
tar -xpf util-linux-2.41.1.tar.xz
cd util-linux-2.41.1
./configure --libdir=/usr/lib \
            --runstatedir=/run \
            --disable-chfn-chsh \
            --disable-login \
            --disable-nologin \
            --disable-su \
            --disable-setpriv \
            --disable-runuser \
            --disable-pylibmount \
            --disable-static \
            --disable-liblastlog2 \
            --without-python \
            ADJTIME_PATH=/var/lib/hwclock/adjtime \
            --docdir=/usr/share/doc/util-linux-2.41.1
make
make install
EOF

# ---------------------------------------------------------------------------
# §7.14 Cleanup (dentro del chroot)
# ---------------------------------------------------------------------------
pkg cleanup <<'EOF'
set -euo pipefail
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name \*.la -delete
rm -rf /tools
EOF

# ---------------------------------------------------------------------------
# Verificación de salida de la etapa (fuera del chroot)
# ---------------------------------------------------------------------------
step "verificación rápida del resultado"
test -x "$LFS/usr/bin/perl"    || { echo "FALTA perl"; exit 1; }
test -x "$LFS/usr/bin/python3" || { echo "FALTA python3"; exit 1; }
test -x "$LFS/usr/bin/msgfmt"  || { echo "FALTA gettext tools"; exit 1; }
test ! -e "$LFS/tools"         || { echo "NO se borró /tools"; exit 1; }
df -h "$LFS"
du -sh "$LFS/usr"
echo "==> ETAPA 2 COMPLETA (t=$(( (SECONDS-T0)/60 ))min)"
