#!/bin/bash
# base/setup-user.sh — Crea el usuario lfs y su entorno limpio (LFS 12.4 §4.3-4.4).
# El libro exige construir los caps. 5-6 como usuario NO privilegiado, con
# entorno aislado (env -i) para que nada del host contamine el build.
set -euo pipefail
. "$(dirname "$0")/env.sh"

# §4.3 usuario lfs
groupadd -f lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true

# §4.4 .bash_profile: shell de login → entorno limpio (HOME se expande al del usuario lfs)
cat > /home/lfs/.bash_profile << 'EOF'
exec env -i HOME="$HOME" TERM="$TERM" PS1='\u:\w\$ ' /bin/bash
EOF

# §4.4 .bashrc: variables del build (LFS, LFS_TGT, PATH con $LFS/tools delante)
cat > /home/lfs/.bashrc << 'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
user=$(uname -m)
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
MAKEFLAGS=-j$(nproc)
TESTSUITEFLAGS=-j$(nproc)
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS TESTSUITEFLAGS
EOF

chown lfs:lfs /home/lfs/.bash_profile /home/lfs/.bashrc
chmod 644 /home/lfs/.bash_profile /home/lfs/.bashrc

# El libro (§4.4) manda mover /etc/bash.bashrc si existe (Ubuntu lo tiene)
[ ! -e /etc/bash.bashrc ] || mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE

# Layout mínimo §5.1 (as root): dirs + symlinks + $LFS/tools
mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}
for i in bin lib sbin; do
  ln -sv "usr/$i" "$LFS/$i"
done
mkdir -pv "$LFS/lib64"
mkdir -pv "$LFS/tools"

# §4.3 chown a lfs de lo creado
chown -v lfs "$LFS"/{usr{,/*},var,etc,tools}
case $(uname -m) in
  x86_64) chown -v lfs "$LFS/lib64" ;;
esac

# Fuentes: $LFS/sources con sticky bit (§4.2) y propias de lfs
mkdir -pv "$LFS/sources"
chmod -v a+wt "$LFS/sources"
chown -v lfs "$LFS/sources"

echo "OK: usuario lfs + entorno + layout $LFS listos"
