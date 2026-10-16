#!/bin/bash
# base/ch08.sh — Etapa 3: sistema base final (LFS 12.4 cap. 8).
#
# FUENTE: LFS-BOOK-12.4 §8.1-8.76 (comandos transcritos literalmente).
# ADICIONES DEL PLAN (tras el cap. 8 del libro, en orden de dependencia):
#   Linux-PAM 1.7.1 (BLFS) → shadow recompilado con PAM (BLFS) → opendoas,
#   eudev 3.2.15 (sustituye al udev de systemd del libro), openssh 10.0p1
#   (--with-pam), curl 8.15.0, ca-certificates (cacert.pem), dhcpcd 10.2.4,
#   chrony 4.5, acpid 2.0.34, dracut 112 (se usa en etapa 4).
# OMITIDOS del libro (etapa 4 o sustituidos): grub, sysvinit, lfs-bootscripts,
#   udev(systemd-257.8), systemd-man-pages.
#
# PLAN: MAKEFLAGS -j$(nproc), RUN_TESTS=0, CFLAGS de make.conf.sh aplicados
# vía config.site (los exports del chroot los inyecta chroot_run), strip al
# final (§8.77 stripping del libro), sin docs/locales de más (§8.78 cleanup).
# make.conf.sh: NUNCA -O3/LTO en glibc/gcc/binutils (se compila limpio).

set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/make.conf.sh"

T0=$SECONDS
step() { printf '\n==> [stage3] %s (t+%dm)\n' "$*" $(( (SECONDS-T0)/60 )); }

# Igual que ch07.sh: bloque por stdin al chroot con entorno limpio §7.4.
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

# ---------------------------------------------------------------------------
# §7.3 vfs virtuales ANTES del primer chroot de la etapa (el libro los exige;
# sin /dev/null y devpts los builds explotan — bug del run 38808354088)
# ---------------------------------------------------------------------------
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
# §8.3 Linux man-pages
# ============================================================================
pkg man-pages <<'EOF'
set -euo pipefail
cd /sources
rm -rf man-pages-6.15
tar -xpf man-pages-6.15.tar.xz
cd man-pages-6.15
rm -rf man/*.html
make -R GIT=/bin/true prefix=/usr install
EOF

# ============================================================================
# §8.4 Iana-Etc
# ============================================================================
pkg iana-etc <<'EOF'
set -euo pipefail
cd /sources
rm -rf iana-etc-20250807
tar -xpf iana-etc-20250807.tar.gz
cd iana-etc-20250807
cp services protocols /etc
EOF

# ============================================================================
# §8.5 Glibc final
# ============================================================================
pkg glibc-final <<'EOF'
set -euo pipefail
ln -sfv ../lib/ld-linux-x86-64.so.2 /lib64
ln -sfv ../lib/ld-linux-x86-64.so.2 /lib64/ld-lsb-x86-64.so.3
cd /sources
rm -rf glibc-2.42
tar -xpf glibc-2.42.tar.xz
cd glibc-2.42
patch -Np1 -i ../glibc-2.42-fhs-1.patch
# Fix Valgrind (§8.5 del libro)
sed -e '/unistd.h/i #include <string.h>' \
    -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
    -i stdlib/abort.c
mkdir -v build
cd       build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr                   \
             --disable-werror                \
             --disable-nscd                  \
             libc_cv_slibdir=/usr/lib        \
             --enable-stack-protector=strong \
             --enable-kernel=5.4
make
touch /etc/ld.so.conf
sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
make install
sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
# Locale en_US.UTF-8 (PLAN: variables editables; resto de locales NO)
mkdir -p /usr/lib/locale
localedef -i en_US -f UTF-8 en_US.UTF-8 || { echo "localedef falló"; exit 1; }
# /etc/nsswitch.conf (§8.5.1 configuración del libro)
cat > /etc/nsswitch.conf << 'NSS'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
NSS
# Timezone America/Guatemala (PLAN) — zic como manda §9.1 del libro
cd /sources
rm -rf tzdata-2025b
mkdir tzdata-2025b
tar -xpf tzdata2025b.tar.gz -C tzdata-2025b
cd tzdata-2025b
ZONEINFO=/usr/share/zoneinfo
mkdir -pv $ZONEINFO/{posix,right}
for tz in etcetera southamerica northamerica europe africa antarctica  \
          asia australasia backward; do
    zic -L /dev/null   -d $ZONEINFO       ${tz}
    zic -L /dev/null   -d $ZONEINFO/posix ${tz}
    zic -L leapseconds -d $ZONEINFO/right ${tz}
done
cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
zic -d $ZONEINFO -p America/New_York
cp -v $ZONEINFO/America/Guatemala /etc/localtime
echo "America/Guatemala" > /etc/timezone
unset ZONEINFO tz
cd /sources
rm -rf tzdata-2025b
EOF

# ============================================================================
# §8.6-8.10 zlib, bzip2, xz, lz4, zstd
# ============================================================================
pkg zlib <<'EOF'
set -euo pipefail
cd /sources
rm -rf zlib-1.3.1
tar -xpf zlib-1.3.1.tar.gz
cd zlib-1.3.1
./configure --prefix=/usr
make
make install
rm -f /usr/lib/libz.a
EOF

pkg bzip2 <<'EOF'
set -euo pipefail
cd /sources
rm -rf bzip2-1.0.8
tar -xpf bzip2-1.0.8.tar.gz
cd bzip2-1.0.8
patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch
sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
sed -i 's@\(dc_doc_path.*\)@dc_doc_path= /usr/share/doc/bzip2-1.0.8@' Makefile
make -f Makefile-libbz2_so
make clean
make
make PREFIX=/usr install
cp -av libbz2.so.* /usr/lib
ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so
cp -v bzip2-shared /usr/bin/bzip2
for i in /usr/bin/{bzcat,bunzip2}; do ln -sfv bzip2 $i; done
rm -fv /usr/lib/libbz2.a
EOF

pkg xz <<'EOF'
set -euo pipefail
cd /sources
rm -rf xz-5.8.1
tar -xpf xz-5.8.1.tar.xz
cd xz-5.8.1
./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.8.1
make
make install
EOF

pkg lz4 <<'EOF'
set -euo pipefail
cd /sources
rm -rf lz4-1.10.0
tar -xpf lz4-1.10.0.tar.gz
cd lz4-1.10.0
make BUILD_STATIC=no PREFIX=/usr
make BUILD_STATIC=no PREFIX=/usr install
EOF

pkg zstd <<'EOF'
set -euo pipefail
cd /sources
rm -rf zstd-1.5.7
tar -xpf zstd-1.5.7.tar.gz
cd zstd-1.5.7
make prefix=/usr
make prefix=/usr install
rm -v /usr/lib/libzstd.a
EOF

# ============================================================================
# §8.11 File
# ============================================================================
pkg file <<'EOF'
set -euo pipefail
cd /sources
rm -rf file-5.46
tar -xpf file-5.46.tar.gz
cd file-5.46
./configure --prefix=/usr
make
make install
rm -v /usr/lib/libmagic.la
EOF

# ============================================================================
# §8.12 Readline
# ============================================================================
pkg readline <<'EOF'
set -euo pipefail
cd /sources
rm -rf readline-8.3
tar -xpf readline-8.3.tar.gz
cd readline-8.3
sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
./configure --prefix=/usr    \
            --disable-static \
            --with-curses    \
            --docdir=/usr/share/doc/readline-8.3
make SHLIB_LIBS="-lncursesw"
make install
EOF

# ============================================================================
# §8.13 M4 final
# ============================================================================
pkg m4-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf m4-1.4.20
tar -xpf m4-1.4.20.tar.xz
cd m4-1.4.20
./configure --prefix=/usr
make
make install
EOF

# ============================================================================
# §8.14 BC
# ============================================================================
pkg bc <<'EOF'
set -euo pipefail
cd /sources
rm -rf bc-7.0.3
tar -xpf bc-7.0.3.tar.xz
cd bc-7.0.3
CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r
make
make install
EOF

# ============================================================================
# §8.15 Flex
# ============================================================================
pkg flex <<'EOF'
set -euo pipefail
cd /sources
rm -rf flex-2.6.4
tar -xpf flex-2.6.4.tar.gz
cd flex-2.6.4
./configure --prefix=/usr --docdir=/usr/share/doc/flex-2.6.4 --disable-static
make
make install
ln -sfv flex /usr/bin/lex
EOF

# ============================================================================
# §8.16-8.18 Tcl, Expect, DejaGNU (para tests; los builds corren sin tests)
# ============================================================================
pkg tcl <<'EOF'
set -euo pipefail
cd /sources
rm -rf tcl8.6.16
tar -xpf tcl8.6.16-src.tar.gz
cd tcl8.6.16
SRCDIR=$(pwd)
cd unix
./configure --prefix=/usr           \
            --mandir=/usr/share/man \
            --disable-rpath
make
sed -e "s|$SRCDIR/unix|/usr/lib|" \
    -e "s|$SRCDIR|/usr/include|"  \
    -i tclConfig.sh
sed -e "s|$SRCDIR/unix/pkgs/tdbc1.1.10|/usr/lib/tdbc1.1.10|" \
    -e "s|$SRCDIR/pkgs/tdbc1.1.10/generic|/usr/include|"     \
    -e "s|$SRCDIR/pkgs/tdbc1.1.10/library|/usr/lib/tcl8.6|"  \
    -e "s|$SRCDIR/pkgs/tdbc1.1.10|/usr/include|"             \
    -i pkgs/tdbc1.1.10/tdbcConfig.sh
sed -e "s|$SRCDIR/unix/pkgs/itcl4.3.2|/usr/lib/itcl4.3.2|" \
    -e "s|$SRCDIR/pkgs/itcl4.3.2/generic|/usr/include|"    \
    -e "s|$SRCDIR/pkgs/itcl4.3.2|/usr/include|"            \
    -i pkgs/itcl4.3.2/itclConfig.sh
unset SRCDIR
make install
chmod 644 /usr/lib/libtclstub8.6.a
chmod -v u+w /usr/lib/libtcl8.6.so
make install-private-headers
ln -sfv tclsh8.6 /usr/bin/tclsh
mv /usr/share/man/man3/{Thread,Tcl_Thread}.3
EOF

pkg expect <<'EOF'
set -euo pipefail
# Verificación PTY del libro (§8.17)
python3 -c 'from pty import spawn; spawn(["echo", "ok"])'
cd /sources
rm -rf expect5.45.4
tar -xpf expect5.45.4.tar.gz
cd expect5.45.4
patch -Np1 -i ../expect-5.45.4-gcc15-1.patch
./configure --prefix=/usr           \
            --with-tcl=/usr/lib     \
            --enable-shared         \
            --disable-rpath         \
            --mandir=/usr/share/man \
            --with-tclinclude=/usr/include
make
make install
ln -svf expect5.45.4/libexpect5.45.4.so /usr/lib
EOF

pkg dejagnu <<'EOF'
set -euo pipefail
cd /sources
rm -rf dejagnu-1.6.3
tar -xpf dejagnu-1.6.3.tar.gz
cd dejagnu-1.6.3
mkdir -v build
cd       build
../configure --prefix=/usr
makeinfo --html --no-split -o doc/dejagnu.html ../doc/dejagnu.texi
makeinfo --plaintext       -o doc/dejagnu.txt  ../doc/dejagnu.texi
make install
install -v -dm755  /usr/share/doc/dejagnu-1.6.3
install -v -m644   doc/dejagnu.{html,txt} /usr/share/doc/dejagnu-1.6.3
EOF

# ============================================================================
# §8.23 Pkgconf
# ============================================================================
pkg pkgconf <<'EOF'
set -euo pipefail
cd /sources
rm -rf pkgconf-2.5.1
tar -xpf pkgconf-2.5.1.tar.xz
cd pkgconf-2.5.1
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/pkgconf-2.5.1
make
make install
ln -sv pkgconf   /usr/bin/pkg-config
ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
EOF

# ============================================================================
# §8.24 Binutils final
# ============================================================================
pkg binutils-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf binutils-2.45
tar -xpf binutils-2.45.tar.xz
cd binutils-2.45
mkdir -v build
cd       build
../configure --prefix=/usr       \
             --sysconfdir=/etc   \
             --enable-ld=default \
             --enable-plugins    \
             --enable-shared     \
             --disable-werror    \
             --enable-64-bit-bfd \
             --enable-new-dtags  \
             --with-system-zlib  \
             --enable-default-hash-style=gnu
make tooldir=/usr
make tooldir=/usr install
rm -rfv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a \
        /usr/share/doc/gprofng/
EOF

# ============================================================================
# §8.25-8.27 GMP, MPFR, MPC (tests críticos del libro OFF por PLAN: RUN_TESTS=0)
# ============================================================================
pkg gmp <<'EOF'
set -euo pipefail
cd /sources
rm -rf gmp-6.3.0
tar -xpf gmp-6.3.0.tar.xz
cd gmp-6.3.0
sed -i '/long long t1;/,+1s/()/(...)/' configure
./configure --prefix=/usr    \
            --enable-cxx     \
            --disable-static \
            --docdir=/usr/share/doc/gmp-6.3.0
make
make install
rm -rf /usr/share/doc/gmp-6.3.0
EOF

pkg mpfr <<'EOF'
set -euo pipefail
cd /sources
rm -rf mpfr-4.2.2
tar -xpf mpfr-4.2.2.tar.xz
cd mpfr-4.2.2
./configure --prefix=/usr        \
            --disable-static     \
            --enable-thread-safe \
            --docdir=/usr/share/doc/mpfr-4.2.2
make
make install
rm -rf /usr/share/doc/mpfr-4.2.2
EOF

pkg mpc <<'EOF'
set -euo pipefail
cd /sources
rm -rf mpc-1.3.1
tar -xpf mpc-1.3.1.tar.gz
cd mpc-1.3.1
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpc-1.3.1
make
make install
rm -rf /usr/share/doc/mpc-1.3.1
EOF

# ============================================================================
# §8.28-8.30 Attr, Acl, Libcap
# ============================================================================
pkg attr <<'EOF'
set -euo pipefail
cd /sources
rm -rf attr-2.5.2
tar -xpf attr-2.5.2.tar.gz
cd attr-2.5.2
./configure --prefix=/usr     \
            --disable-static  \
            --sysconfdir=/etc \
            --docdir=/usr/share/doc/attr-2.5.2
make
make install
rm -rf /usr/share/doc/attr-2.5.2
EOF

pkg acl <<'EOF'
set -euo pipefail
cd /sources
rm -rf acl-2.3.2
tar -xpf acl-2.3.2.tar.xz
cd acl-2.3.2
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/acl-2.3.2
make
make install
rm -rf /usr/share/doc/acl-2.3.2
EOF

pkg libcap <<'EOF'
set -euo pipefail
cd /sources
rm -rf libcap-2.76
tar -xpf libcap-2.76.tar.xz
cd libcap-2.76
sed -i '/install -m.*STA/d' libcap/Makefile
make prefix=/usr lib=lib
make prefix=/usr lib=lib install
EOF

# ============================================================================
# §8.31 Libxcrypt
# ============================================================================
pkg libxcrypt <<'EOF'
set -euo pipefail
cd /sources
rm -rf libxcrypt-4.4.38
tar -xpf libxcrypt-4.4.38.tar.xz
cd libxcrypt-4.4.38
./configure --prefix=/usr                \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=no     \
            --disable-static             \
            --disable-failure-tokens
make
make install
EOF

# ============================================================================
# §8.32 Shadow (con Linux-PAM ya instalado, BLFS manda: PAM PRIMERO).
# Orden del PLAN: PAM se instala ANTES de shadow. Vamos a saltar shadow aquí
# y hacer PAM+shadow juntos tras los paquetes del libro (bloque "pam-shadow").
# ============================================================================

# ============================================================================
# §8.33 GCC final (el más largo; MAKEFLAGS -j4)
# ============================================================================
pkg gcc-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf gcc-15.2.0
tar -xpf gcc-15.2.0.tar.xz
cd gcc-15.2.0
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir -v build
cd       build
../configure --prefix=/usr            \
             LD=ld                    \
             --enable-languages=c,c++ \
             --enable-default-pie     \
             --enable-default-ssp     \
             --enable-host-pie        \
             --disable-multilib       \
             --disable-bootstrap      \
             --disable-fixincludes    \
             --with-system-zlib
make
make install
mkdir -pv /usr/lib/bfd-plugins
ln -sfv ../../libexec/gcc/$(gcc -dumpmachine)/15.2.0/liblto_plugin.so /usr/lib/bfd-plugins/
# Limpieza de headers "fixed" obsoletos (nota del libro para upgrades; el
# --disable-fixincludes ya evita que se creen en build fresco)
DIR=$(dirname $(gcc -print-libgcc-file-name))
[ -e $DIR/include/limits.h ]    || mv $DIR/include{-fixed,}/limits.h
[ -e $DIR/include/syslimits.h ] || mv $DIR/include{-fixed,}/syslimits.h
rm -rfv $DIR/include-fixed/*
unset DIR
EOF

# ============================================================================
# §8.34 Ncurses final
# ============================================================================
pkg ncurses-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf ncurses-6.5-20250809
tar -xpf ncurses-6.5-20250809.tgz
cd ncurses-6.5-20250809
./configure --prefix=/usr           \
            --mandir=/usr/share/man \
            --with-shared           \
            --without-debug         \
            --without-normal        \
            --with-cxx-shared       \
            --enable-pc-files       \
            --with-pkg-config-libdir=/usr/lib/pkgconfig
make
make DESTDIR=$PWD/dest install
install -vm755 dest/usr/lib/libncursesw.so.6.5 /usr/lib
rm -v  dest/usr/lib/libncursesw.so.6.5
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i dest/usr/include/curses.h
cp -av dest/* /
for lib in ncurses form panel menu ; do
    ln -sfv lib${lib}w.so /usr/lib/lib${lib}.so
    ln -sfv ${lib}w.pc    /usr/lib/pkgconfig/${lib}.pc
done
ln -sfv libncursesw.so /usr/lib/libcurses.so
rm -rf /usr/share/doc/ncurses-6.5-20250809
EOF

# ============================================================================
# §8.35-8.42 Sed, Psmisc, Gettext, Bison, Grep, Bash, Libtool, GDBM
# ============================================================================
pkg sed-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf sed-4.9
tar -xpf sed-4.9.tar.xz
cd sed-4.9
./configure --prefix=/usr
make
make install
rm -rf /usr/share/doc/sed-4.9
EOF

pkg psmisc <<'EOF'
set -euo pipefail
cd /sources
rm -rf psmisc-23.7
tar -xpf psmisc-23.7.tar.xz
cd psmisc-23.7
./configure --prefix=/usr
make
make install
EOF

pkg gettext-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf gettext-0.26
tar -xpf gettext-0.26.tar.xz
cd gettext-0.26
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/gettext-0.26
make
make install
chmod -v 0755 /usr/lib/preloadable_libintl.so
rm -rf /usr/share/doc/gettext-0.26
EOF

pkg bison-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf bison-3.8.2
tar -xpf bison-3.8.2.tar.xz
cd bison-3.8.2
./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
make
make install
rm -rf /usr/share/doc/bison-3.8.2
EOF

pkg grep-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf grep-3.12
tar -xpf grep-3.12.tar.xz
cd grep-3.12
sed -i "s/echo/#echo/" src/egrep.sh
./configure --prefix=/usr
make
make install
EOF

pkg bash-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf bash-5.3
tar -xpf bash-5.3.tar.gz
cd bash-5.3
./configure --prefix=/usr             \
            --without-bash-malloc     \
            --with-installed-readline \
            --docdir=/usr/share/doc/bash-5.3
make
make install
rm -rf /usr/share/doc/bash-5.3
exec /usr/bin/bash --login
EOF

pkg libtool <<'EOF'
set -euo pipefail
cd /sources
rm -rf libtool-2.5.4
tar -xpf libtool-2.5.4.tar.xz
cd libtool-2.5.4
./configure --prefix=/usr
make
make install
rm -fv /usr/lib/libltdl.a
EOF

pkg gdbm <<'EOF'
set -euo pipefail
cd /sources
rm -rf gdbm-1.26
tar -xpf gdbm-1.26.tar.gz
cd gdbm-1.26
./configure --prefix=/usr    \
            --disable-static \
            --enable-libgdbm-compat
make
make install
EOF

# ============================================================================
# §8.43-8.47 Gperf, Expat, Inetutils, Less, Perl
# ============================================================================
pkg gperf <<'EOF'
set -euo pipefail
cd /sources
rm -rf gperf-3.3
tar -xpf gperf-3.3.tar.gz
cd gperf-3.3
./configure --prefix=/usr --docdir=/usr/share/doc/gperf-3.3
make
make install
rm -rf /usr/share/doc/gperf-3.3
EOF

pkg expat <<'EOF'
set -euo pipefail
cd /sources
rm -rf expat-2.7.1
tar -xpf expat-2.7.1.tar.xz
cd expat-2.7.1
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/expat-2.7.1
make
make install
rm -rf /usr/share/doc/expat-2.7.1
EOF

pkg inetutils <<'EOF'
set -euo pipefail
cd /sources
rm -rf inetutils-2.6
tar -xpf inetutils-2.6.tar.xz
cd inetutils-2.6
sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
./configure --prefix=/usr        \
            --bindir=/usr/bin    \
            --localstatedir=/var \
            --disable-logger     \
            --disable-whois      \
            --disable-rcp        \
            --disable-rexec      \
            --disable-rlogin     \
            --disable-rsh        \
            --disable-servers
make
make install
mv -v /usr/{,s}bin/ifconfig
EOF

pkg less <<'EOF'
set -euo pipefail
cd /sources
rm -rf less-679
tar -xpf less-679.tar.gz
cd less-679
./configure --prefix=/usr --sysconfdir=/etc
make
make install
EOF

pkg perl-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf perl-5.42.0
tar -xpf perl-5.42.0.tar.xz
cd perl-5.42.0
export BUILD_ZLIB=False
export BUILD_BZIP2=0
sh Configure -des                                          \
             -D prefix=/usr                                \
             -D vendorprefix=/usr                          \
             -D privlib=/usr/lib/perl5/5.42/core_perl      \
             -D archlib=/usr/lib/perl5/5.42/core_perl      \
             -D sitelib=/usr/lib/perl5/5.42/site_perl      \
             -D sitearch=/usr/lib/perl5/5.42/site_perl     \
             -D vendorlib=/usr/lib/perl5/5.42/vendor_perl  \
             -D vendorarch=/usr/lib/perl5/5.42/vendor_perl \
             -D man1dir=/usr/share/man/man1                \
             -D man3dir=/usr/share/man/man3                \
             -D pager="/usr/bin/less -isR"                 \
             -D useshrplib                                 \
             -D usethreads
make
make install
unset BUILD_ZLIB BUILD_BZIP2
EOF

# ============================================================================
# §8.48-8.52 XML::Parser, Intltool, Autoconf, Automake, OpenSSL
# ============================================================================
pkg xml-parser <<'EOF'
set -euo pipefail
cd /sources
rm -rf XML-Parser-2.47
tar -xpf XML-Parser-2.47.tar.gz
cd XML-Parser-2.47
perl Makefile.PL
make
make install
EOF

pkg intltool <<'EOF'
set -euo pipefail
cd /sources
rm -rf intltool-0.51.0
tar -xpf intltool-0.51.0.tar.gz
cd intltool-0.51.0
sed -i 's:\\\${:\\\$\\{:g' intltool-update.in
./configure --prefix=/usr
make
make install
install -v -Dm644 doc/I18N-HOWTO /usr/share/doc/intltool-0.51.0/I18N-HOWTO
rm -rf /usr/share/doc/intltool-0.51.0
EOF

pkg autoconf <<'EOF'
set -euo pipefail
cd /sources
rm -rf autoconf-2.72
tar -xpf autoconf-2.72.tar.xz
cd autoconf-2.72
./configure --prefix=/usr
make
make install
EOF

pkg automake <<'EOF'
set -euo pipefail
cd /sources
rm -rf automake-1.18.1
tar -xpf automake-1.18.1.tar.xz
cd automake-1.18.1
./configure --prefix=/usr --docdir=/usr/share/doc/automake-1.18.1
make
make install
rm -rf /usr/share/doc/automake-1.18.1
EOF

pkg openssl <<'EOF'
set -euo pipefail
cd /sources
rm -rf openssl-3.5.2
tar -xpf openssl-3.5.2.tar.gz
cd openssl-3.5.2
./config --prefix=/usr         \
         --openssldir=/etc/ssl \
         --libdir=lib          \
         shared                \
         zlib-dynamic
make
sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
make MANSUFFIX=ssl install
mv -v /usr/share/doc/openssl /usr/share/doc/openssl-3.5.2
rm -rf /usr/share/doc/openssl-3.5.2
EOF

# ============================================================================
# §8.53-8.55 Libelf (de elfutils), Libffi, Python
# ============================================================================
pkg libelf <<'EOF'
set -euo pipefail
cd /sources
rm -rf elfutils-0.193
tar -xpf elfutils-0.193.tar.bz2
cd elfutils-0.193
./configure --prefix=/usr        \
            --disable-debuginfod \
            --enable-libdebuginfod=dummy
make
make -C libelf install
install -vm644 config/libelf.pc /usr/lib/pkgconfig
rm /usr/lib/libelf.a
EOF

pkg libffi <<'EOF'
set -euo pipefail
cd /sources
rm -rf libffi-3.5.2
tar -xpf libffi-3.5.2.tar.gz
cd libffi-3.5.2
# PLAN: NUNCA -march=native → gcc-arch=skylake (CPU objetivo fija del build)
./configure --prefix=/usr    \
            --disable-static \
            --with-gcc-arch=skylake
make
make install
EOF

pkg python-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf Python-3.13.7
tar -xpf Python-3.13.7.tar.xz
cd Python-3.13.7
./configure --prefix=/usr          \
            --enable-shared        \
            --with-system-expat    \
            --enable-optimizations \
            --without-static-libpython
make
make install
cat > /etc/pip.conf << EOF2
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF2
rm -rf /usr/share/doc/python-3.13.7
EOF

# ============================================================================
# §8.56-8.63 módulos Python (flit-core, packaging, wheel, setuptools, ninja,
# meson, markupsafe, jinja2) — cada uno explícito, extrae su tarball
# ============================================================================
pipmod() {
    # pipmod <dir-tarball> <nombre-pip>: extrae, wheela e instala
    local dir=$1 mod=$2
    pkg "pip-$mod" <<EOF
set -euo pipefail
cd /sources
rm -rf "$dir"
tar -xpf "$dir".tar.gz
cd "$dir"
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps \$PWD
pip3 install --no-index --find-links dist $mod
cd /sources
rm -rf "$dir" dist
EOF
}

# flit_core: tarball flit_core-3.12.0 (con guión bajo en el dir)
pkg pip-flit-core <<'EOF'
set -euo pipefail
cd /sources
rm -rf flit_core-3.12.0
tar -xpf flit_core-3.12.0.tar.gz
cd flit_core-3.12.0
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist flit_core
cd /sources
rm -rf flit_core-3.12.0
EOF

pipmod packaging-25.0 packaging
pipmod wheel-0.46.1 wheel
pipmod setuptools-80.9.0 setuptools

pkg ninja <<'EOF'
set -euo pipefail
cd /sources
rm -rf ninja-1.13.1
tar -xpf ninja-1.13.1.tar.gz
cd ninja-1.13.1
python3 configure.py --bootstrap --verbose
install -vm755 ninja /usr/bin/
rm -rf /usr/share/bash-completion /usr/share/zsh
EOF

pkg meson <<'EOF'
set -euo pipefail
cd /sources
rm -rf meson-1.8.3
tar -xpf meson-1.8.3.tar.gz
cd meson-1.8.3
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist meson
cd /sources
rm -rf meson-1.8.3
EOF

pipmod markupsafe-3.0.2 markupsafe
pipmod jinja2-3.1.6 jinja2

# ============================================================================
# §8.64 Kmod
# ============================================================================
pkg kmod <<'EOF'
set -euo pipefail
cd /sources
rm -rf kmod-34.2
tar -xpf kmod-34.2.tar.xz
cd kmod-34.2
mkdir -p build
cd       build
meson setup --prefix=/usr ..    \
            --buildtype=release \
            -D manpages=false
ninja
ninja install
# symlinks del libro para compatibilidad
for target in depmod insmod modinfo modprobe rmmod; do
  ln -sfv ../bin/kmod /usr/sbin/$target
done
EOF

# ============================================================================
# §8.65-8.75 Coreutils → sysklogd (sin grub, sin udev, sin sysvinit)
# ============================================================================
pkg coreutils-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf coreutils-9.7
tar -xpf coreutils-9.7.tar.xz
cd coreutils-9.7
patch -Np1 -i ../coreutils-9.7-upstream_fix-1.patch
patch -Np1 -i ../coreutils-9.7-i18n-1.patch
autoreconf -fv
automake -af
FORCE_UNSAFE_CONFIGURE=1 ./configure \
            --prefix=/usr            \
            --enable-no-install-program=kill,uptime
make
make install
mv -v /usr/bin/chroot /usr/sbin
mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8
rm -rf /usr/share/info/coreutils*
EOF

pkg diffutils-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf diffutils-3.12
tar -xpf diffutils-3.12.tar.xz
cd diffutils-3.12
./configure --prefix=/usr
make
make install
EOF

pkg gawk-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf gawk-5.3.2
tar -xpf gawk-5.3.2.tar.xz
cd gawk-5.3.2
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr
make
rm -f /usr/bin/gawk-5.3.2
make install
ln -sv gawk.1 /usr/share/man/man1/awk.1
rm -rf /usr/share/doc/gawk-5.3.2
EOF

pkg findutils-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf findutils-4.10.0
tar -xpf findutils-4.10.0.tar.xz
cd findutils-4.10.0
./configure --prefix=/usr --localstatedir=/var/lib/locate
make
make install
EOF

pkg groff <<'EOF'
set -euo pipefail
cd /sources
rm -rf groff-1.23.0
tar -xpf groff-1.23.0.tar.gz
cd groff-1.23.0
PAGE=letter ./configure --prefix=/usr
make
make install
rm -rf /usr/share/doc/groff-1.23.0
EOF

pkg gzip-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf gzip-1.14
tar -xpf gzip-1.14.tar.xz
cd gzip-1.14
./configure --prefix=/usr
make
make install
EOF

pkg iproute2 <<'EOF'
set -euo pipefail
cd /sources
rm -rf iproute2-6.16.0
tar -xpf iproute2-6.16.0.tar.xz
cd iproute2-6.16.0
sed -i /ARPD/d Makefile
rm -fv man/man8/arpd.8
make NETNS_RUN_DIR=/run/netns
make SBINDIR=/usr/sbin install
rm -rf /usr/share/doc/iproute2-6.16.0
EOF

pkg kbd <<'EOF'
set -euo pipefail
cd /sources
rm -rf kbd-2.8.0
tar -xpf kbd-2.8.0.tar.xz
cd kbd-2.8.0
patch -Np1 -i ../kbd-2.8.0-backspace-1.patch
sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure
sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
./configure --prefix=/usr --disable-vlock
make
make install
rm -rf /usr/share/doc/kbd-2.8.0
# PLAN: keymap us (variable editable)
cat > /etc/vconsole.conf << VC
KEYMAP=us
FONT=
VC
rm -rf /usr/share/kbd/keymaps/amiga /usr/share/kbd/keymaps/atari /usr/share/kbd/keymaps/mac /usr/share/kbd/keymaps/sun
EOF

pkg libpipeline <<'EOF'
set -euo pipefail
cd /sources
rm -rf libpipeline-1.5.8
tar -xpf libpipeline-1.5.8.tar.gz
cd libpipeline-1.5.8
./configure --prefix=/usr
make
make install
EOF

pkg make-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf make-4.4.1
tar -xpf make-4.4.1.tar.gz
cd make-4.4.1
./configure --prefix=/usr
make
make install
EOF

pkg patch-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf patch-2.8
tar -xpf patch-2.8.tar.xz
cd patch-2.8
./configure --prefix=/usr
make
make install
EOF

pkg tar-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf tar-1.35
tar -xpf tar-1.35.tar.xz
cd tar-1.35
FORCE_UNSAFE_CONFIGURE=1  \
./configure --prefix=/usr
make
make install
rm -rf /usr/share/doc/tar-1.35
make -C doc install-html docdir=/usr/share/doc/tar-1.35 >/dev/null 2>&1 || true
rm -rf /usr/share/doc/tar-1.35
EOF

pkg texinfo-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf texinfo-7.2
tar -xpf texinfo-7.2.tar.xz
cd texinfo-7.2
sed 's/! $output_file eq/$output_file ne/' -i tp/Texinfo/Convert/*.pm
./configure --prefix=/usr
make
make install
rm -rf /usr/share/doc/texinfo-7.2 /usr/share/info
EOF

pkg vim <<'EOF'
set -euo pipefail
cd /sources
rm -rf vim-9.1.1629
tar -xpf vim-9.1.1629.tar.gz
cd vim-9.1.1629
echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
./configure --prefix=/usr
make
make install
ln -sv vim /usr/bin/vi
for L in  /usr/share/man/{,*/}man1/vim.1; do
    ln -sv vim.1 $(dirname $L)/vi.1
done
ln -sv ../vim/vim91/doc /usr/share/doc/vim-9.1.1629 2>/dev/null || true
# vimrc del libro (§8.73)
cat > /etc/vimrc << "EOF2"
" Begin /etc/vimrc

" Ensure extensions are loaded
set nocompatible

" Do not backup
set nobackup
set noswapfile

" Use UTF-8
set encoding=utf-8

" Keep cursor centered
set scrolloff=5

" Settings for X based files
set backspace=indent,eol,start
set mouse=
set spelllang=en

" Do not use octal numbers when using <C-a> or <C-x>
set nrformats-=octal

" When editing a file, always jump to the last cursor position
autocmd BufReadPost *
  \ if line("'\"") > 1 && line("'\"") <= line("$") |
  \   exe "normal! g`\"" |
  \ endif

" End /etc/vimrc
EOF2
rm -rf /usr/share/vim/vim91/doc 2>/dev/null || true
EOF

# NOTA: udev del libro OMITIDO — el PLAN usa eudev (bloque de extras abajo).

pkg man-db <<'EOF'
set -euo pipefail
cd /sources
rm -rf man-db-2.13.1
tar -xpf man-db-2.13.1.tar.xz
cd man-db-2.13.1
./configure --prefix=/usr                         \
            --docdir=/usr/share/doc/man-db-2.13.1 \
            --sysconfdir=/etc                     \
            --disable-setuid                      \
            --enable-cache-owner=bin              \
            --with-browser=/usr/bin/lynx          \
            --with-vgrind=/usr/bin/vgrind         \
            --with-grap=/usr/bin/grap             \
            --with-systemdtmpfilesdir=            \
            --with-systemdsystemunitdir=
make
make install
rm -rf /usr/share/doc/man-db-2.13.1
EOF

pkg procps <<'EOF'
set -euo pipefail
cd /sources
rm -rf procps-ng-4.0.5
tar -xpf procps-ng-4.0.5.tar.xz
cd procps-ng-4.0.5
./configure --prefix=/usr                           \
            --docdir=/usr/share/doc/procps-ng-4.0.5 \
            --disable-static                        \
            --disable-kill                          \
            --enable-watch8bit
make
make install
rm -rf /usr/share/doc/procps-ng-4.0.5
EOF

pkg util-linux-final <<'EOF'
set -euo pipefail
cd /sources
rm -rf util-linux-2.41.1
tar -xpf util-linux-2.41.1.tar.xz
cd util-linux-2.41.1
./configure --bindir=/usr/bin     \
            --libdir=/usr/lib     \
            --runstatedir=/run    \
            --sbindir=/usr/sbin   \
            --disable-chfn-chsh   \
            --disable-login       \
            --disable-nologin     \
            --disable-su          \
            --disable-setpriv     \
            --disable-runuser     \
            --disable-pylibmount  \
            --disable-liblastlog2 \
            --disable-static      \
            --without-python      \
            --without-systemd      \
            --without-systemdsystemunitdir        \
            ADJTIME_PATH=/var/lib/hwclock/adjtime \
            --docdir=/usr/share/doc/util-linux-2.41.1
make
make install
rm -rf /usr/share/doc/util-linux-2.41.1
EOF

pkg e2fsprogs <<'EOF'
set -euo pipefail
cd /sources
rm -rf e2fsprogs-1.47.3
tar -xpf e2fsprogs-1.47.3.tar.gz
cd e2fsprogs-1.47.3
mkdir -v build
cd       build
../configure --prefix=/usr       \
             --sysconfdir=/etc   \
             --enable-elf-shlibs \
             --disable-libblkid  \
             --disable-libuuid   \
             --disable-uuidd     \
             --disable-fsck
make
make install
rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
gunzip -v /usr/share/info/libext2fs.info.gz
install-info --dir-file=/usr/share/info/dir /usr/share/info/libext2fs.info
rm -rf /usr/share/info
EOF

pkg sysklogd <<'EOF'
set -euo pipefail
cd /sources
rm -rf sysklogd-2.7.2
tar -xpf sysklogd-2.7.2.tar.gz
cd sysklogd-2.7.2
./configure --prefix=/usr      \
            --sysconfdir=/etc  \
            --runstatedir=/run \
            --without-logger   \
            --disable-static   \
            --docdir=/usr/share/doc/sysklogd-2.7.2
make
make install
rm -rf /usr/share/doc/sysklogd-2.7.2
# syslog.conf del libro (§9.2.1)
cat > /etc/syslog.conf << "EOF2"
auth,authpriv.* -/var/log/auth.log
*.*;auth,authpriv.none -/var/log/sys.log
daemon.* -/var/log/daemon.log
kern.* -/var/log/kern.log
mail.* -/var/log/mail.log
user.* -/var/log/user.log
*.emerg *
EOF2
EOF

# ============================================================================
# ADICIONES DEL PLAN — Linux-PAM primero, luego shadow con PAM (BLFS 12.4).
# El libro (§8.32) remite a BLFS cuando hay PAM: esta es esa secuencia.
# ============================================================================
pkg linux-pam <<'EOF'
set -euo pipefail
cd /sources
rm -rf Linux-PAM-1.7.1
tar -xpf Linux-PAM-1.7.1.tar.xz
cd Linux-PAM-1.7.1
mkdir build
cd    build
meson setup ..        \
  --prefix=/usr       \
  --buildtype=release \
  -D docdir=/usr/share/doc/Linux-PAM-1.7.1
ninja
install -v -m755 -d /etc/pam.d
cat > /etc/pam.d/other << "EOF2"
auth     required       pam_deny.so
account  required       pam_deny.so
password required       pam_deny.so
session  required       pam_deny.so
EOF2
ninja install
chmod -v 4755 /usr/sbin/unix_chkpwd
rm -rf /usr/lib/systemd
rm -rf /usr/share/doc/Linux-PAM-1.7.1
EOF

pkg shadow-pam <<'EOF'
set -euo pipefail
cd /sources
rm -rf shadow-4.18.0
tar -xpf shadow-4.18.0.tar.xz
cd shadow-4.18.0
sed -i 's/groups$(EXEEXT) //' src/Makefile.in
find man -name Makefile.in -exec sed -i 's/groups\.1 / /'   {} \;
find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;
sed -e 's@#ENCRYPT_METHOD DES@ENCRYPT_METHOD YESCRYPT@' \
    -e 's@/var/spool/mail@/var/mail@'                   \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                  \
    -i etc/login.defs
./configure --sysconfdir=/etc   \
            --disable-static    \
            --without-libbsd    \
            --with-{b,yes}crypt
make
make exec_prefix=/usr pamddir= install
# login.defs: desactivar lo que ahora maneja PAM (BLFS)
install -v -m644 /etc/login.defs /etc/login.defs.orig
for FUNCTION in FAIL_DELAY               \
                FAILLOG_ENAB             \
                LASTLOG_ENAB             \
                MAIL_CHECK_ENAB          \
                OBSCURE_CHECKS_ENAB      \
                PORTTIME_CHECKS_ENAB     \
                QUOTAS_ENAB              \
                CONSOLE MOTD_FILE        \
                FTMP_FILE NOLOGINS_FILE  \
                ENV_HZ PASS_MIN_LEN      \
                SU_WHEEL_ONLY            \
                PASS_CHANGE_TRIES        \
                PASS_ALWAYS_WARN         \
                CHFN_AUTH ENCRYPT_METHOD \
                ENVIRON_FILE
do
    sed -i "s/^${FUNCTION}/# &/" /etc/login.defs
done
EOF

pkg pam-config <<'EOF'
set -euo pipefail
# Pilas PAM genéricas de BLFS (§Linux-PAM, configuración)
install -vdm755 /etc/pam.d
cat > /etc/pam.d/system-account << "EOF2"
# Begin /etc/pam.d/system-account

account   required    pam_unix.so

# End /etc/pam.d/system-account
EOF2

cat > /etc/pam.d/system-auth << "EOF2"
# Begin /etc/pam.d/system-auth

auth      required    pam_unix.so

# End /etc/pam.d/system-auth
EOF2

cat > /etc/pam.d/system-session << "EOF2"
# Begin /etc/pam.d/system-session

session   required    pam_unix.so

# End /etc/pam.d/system-session
EOF2

cat > /etc/pam.d/system-password << "EOF2"
# Begin /etc/pam.d/system-password

# use yescrypt hash for encryption, use shadow, and try to use any
# previously defined authentication token (chosen password) set by any
# prior module.
password  required    pam_unix.so       yescrypt shadow try_first_pass

# End /etc/pam.d/system-password
EOF2

cat > /etc/pam.d/other << "EOF2"
# Begin /etc/pam.d/other

auth        required        pam_warn.so
auth        required        pam_deny.so
account     required        pam_warn.so
account     required        pam_deny.so
password    required        pam_warn.so
password    required        pam_deny.so
session     required        pam_warn.so
session     required        pam_deny.so

# End /etc/pam.d/other
EOF2

cat > /etc/pam.d/login << "EOF2"
# Begin /etc/pam.d/login

# Set failure delay before next prompt to 3 seconds
auth      optional    pam_faildelay.so  delay=3000000

# Check to make sure that the user is allowed to login
auth      requisite   pam_nologin.so

# include system auth settings
auth      include     system-auth

# check access for the user
account   required    pam_access.so

# include system account settings
account   include     system-account

# Set default environment variables for the user
session   required    pam_env.so

# Set resource limits for the user
session   required    pam_limits.so

# include system session and password settings
session   include     system-session
password  include     system-password

# End /etc/pam.d/login
EOF2

cat > /etc/pam.d/passwd << "EOF2"
# Begin /etc/pam.d/passwd

password  include     system-password

# End /etc/pam.d/passwd
EOF2

cat > /etc/pam.d/su << "EOF2"
# Begin /etc/pam.d/su

# always allow root
auth      sufficient  pam_rootok.so

# include system auth settings
auth      include     system-auth

# include system account settings
account   include     system-account

# Set default environment variables for the service user
session   required    pam_env.so

# include system session settings
session   include     system-session

# End /etc/pam.d/su
EOF2

cat > /etc/pam.d/chpasswd << "EOF2"
# Begin /etc/pam.d/chpasswd

# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account
password  include     system-password

# End /etc/pam.d/chpasswd
EOF2

sed -e s/chpasswd/newusers/ /etc/pam.d/chpasswd >/etc/pam.d/newusers

cat > /etc/pam.d/chage << "EOF2"
# Begin /etc/pam.d/chage

# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account

# End /etc/pam.d/chage
EOF2

for PROGRAM in chfn chgpasswd chsh groupadd groupdel \
               groupmems groupmod useradd userdel usermod
do
    install -v -m644 /etc/pam.d/chage /etc/pam.d/${PROGRAM}
    sed -i "s/chage/$PROGRAM/" /etc/pam.d/${PROGRAM}
done

if [ -f /etc/login.access ]; then mv -v /etc/login.access{,.NOUSE}; fi
if [ -f /etc/limits ]; then mv -v /etc/limits{,.NOUSE}; fi
EOF

# ============================================================================
# EXTRAS DEL PLAN — eudev (sustituye udev de systemd), curl, ca-certificates,
# openssh (--with-pam), opendoas, dhcpcd, chrony, acpid, dracut
# ============================================================================
pkg eudev <<'EOF'
set -euo pipefail
cd /sources
rm -rf eudev-3.2.15
tar -xpf eudev-3.2.15.tar.gz
cd eudev-3.2.15
# Configuración de Void Linux (runit, sin systemd): blkid de util-linux
./configure --prefix=/usr           \
            --sysconfdir=/etc      \
            --sbindir=/usr/sbin    \
            --libdir=/usr/lib      \
            --with-rootprefix=     \
            --with-rootlibdir=/usr/lib \
            --enable-kmod           \
            --enable-blkid
make
make install
# hwdb binaria
/usr/bin/udevadm hwdb --update
rm -rf /usr/share/doc/eudev* /usr/share/gtk-doc
EOF

pkg curl <<'EOF'
set -euo pipefail
cd /sources
rm -rf curl-8.15.0
tar -xpf curl-8.15.0.tar.xz
cd curl-8.15.0
./configure --prefix=/usr    \
            --disable-static \
            --with-openssl   \
            --with-ca-path=/etc/ssl/certs
make
make install
rm -rf /usr/share/doc/curl-8.15.0
EOF

pkg ca-certificates <<'EOF'
set -euo pipefail
# Extracto oficial Mozilla (mantenido por curl.se)
install -vdm755 /etc/ssl/certs
cp -v /sources/cacert-2026-09-25.pem /etc/ssl/certs/ca-certificates.crt
chmod 644 /etc/ssl/certs/ca-certificates.crt
# hash links para herramientas que buscan por hash
cd /etc/ssl/certs
for f in ca-certificates.crt; do :; done
# generar hashes con openssl (equivalente a c_rehash)
rm -f *.0
ln -sf ca-certificates.crt $(openssl x509 -hash -noout -in ca-certificates.crt).0 2>/dev/null || true
EOF

pkg openssh <<'EOF'
set -euo pipefail
install -v -g sys -m700 -d /var/lib/sshd
groupadd -g 50 sshd        &&
useradd  -c 'sshd PrivSep' \
         -d /var/lib/sshd  \
         -g sshd           \
         -s /bin/false     \
         -u 50 sshd
cd /sources
rm -rf openssh-10.0p1
tar -xpf openssh-10.0p1.tar.gz
cd openssh-10.0p1
# PLAN: openssh CON PAM
./configure --prefix=/usr                            \
            --sysconfdir=/etc/ssh                    \
            --with-privsep-path=/var/lib/sshd        \
            --with-default-path=/usr/bin             \
            --with-superuser-path=/usr/sbin:/usr/bin \
            --with-pid-dir=/run                      \
            --with-pam
make
make install
install -v -m755 contrib/ssh-copy-id /usr/bin
# PAM stack para sshd (BLFS) y UsePAM
sed 's@d/login@d/sshd@g' /etc/pam.d/login > /etc/pam.d/sshd
chmod 644 /etc/pam.d/sshd
echo "UsePAM yes" >> /etc/ssh/sshd_config
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
rm -rf /usr/share/doc/openssh-10.0p1
EOF

pkg opendoas <<'EOF'
set -euo pipefail
cd /sources
rm -rf OpenDoas-6.8.2
tar -xpf OpenDoas-6.8.2.tar.gz
cd OpenDoas-6.8.2
# PLAN: doas permite poweroff sin contraseña al usuario del sistema.
# Configuración igual a la de Void (configure, con PAM)
./configure --prefix=/usr --with-pam
make
make install
# /etc/doas.conf: poweroff sin password para el usuario mikuri (variable editable)
cat > /etc/doas.conf << "EOF2"
# permit root para el grupo wheel, con password
permit persist :wheel
# poweroff/reboot sin password para cualquier usuario (PLAN)
permit nopass :wheel cmd /sbin/poweroff
permit nopass :wheel cmd /sbin/reboot
EOF2
chmod 0400 /etc/doas.conf
EOF

pkg dhcpcd <<'EOF'
set -euo pipefail
cd /sources
rm -rf dhcpcd-10.2.4
tar -xpf dhcpcd-10.2.4.tar.xz
cd dhcpcd-10.2.4
# BLFS: sin privilege separation (más simple, para un desktop)
./configure --prefix=/usr                \
            --sysconfdir=/etc            \
            --libexecdir=/usr/lib/dhcpcd \
            --dbdir=/var/lib/dhcpcd      \
            --runstatedir=/run           \
            --disable-privsep
make
make install
# hooks: resolv.conf vía dhcpcd (PLAN: dhcpcd servicio y resolv.conf)
EOF

pkg chrony <<'EOF'
set -euo pipefail
cd /sources
rm -rf chrony-4.5
tar -xpf chrony-4.5.tar.gz
cd chrony-4.5
# Upstream INSTALL: ./configure; sin readline (opcional), con editline off
./configure --prefix=/usr
# chrony usa make con --sbindir; default: /usr/sbin
make
make install
mkdir -p /var/lib/chrony
# chrony.conf mínimo: servidores de NTP de Guatemala/CentAm y pool global
cat > /etc/chrony.conf << "EOF2"
# Servidores NTP (editables)
pool 0.pool.ntp.org iburst
pool 1.pool.ntp.org iburst
pool 2.pool.ntp.org iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF2
rm -rf /usr/share/doc/chrony*
EOF

pkg acpid <<'EOF'
set -euo pipefail
cd /sources
rm -rf acpid-2.0.34
tar -xpf acpid-2.0.34.tar.xz
cd acpid-2.0.34
./configure --prefix=/usr \
            --docdir=/usr/share/doc/acpid-2.0.34
make
make install
# PLAN: acpid SOLO para el botón de apagado
install -v -m755 -d /etc/acpi/events
cat > /etc/acpi/events/powerbtn << "EOF2"
event=button/power
action=/etc/acpi/powerbtn.sh
EOF2
cat > /etc/acpi/powerbtn.sh << "EOF2"
#!/bin/sh
# Botón de apagado: poweroff limpio vía runit
/usr/sbin/poweroff
EOF2
chmod 755 /etc/acpi/powerbtn.sh
rm -rf /usr/share/doc/acpid-2.0.34
EOF

pkg dracut <<'EOF'
set -euo pipefail
cd /sources
rm -rf dracut-112
tar -xpf dracut-112.tar.gz
cd dracut-112
# dracut-ng: ./configure + make install
./configure --prefix=/usr --sysconfdir=/etc
make -j1
make install
rm -rf /usr/share/doc/dracut* /usr/lib/dracut/test
EOF

# ============================================================================
# §8.77 Stripping (transcripción del libro, con las libs que existen aquí)
# ============================================================================
pkg stripping <<'EOF'
set -euo pipefail
save_usrlib="$(cd /usr/lib; ls ld-linux*[^g])
             libc.so.6
             libthread_db.so.1
             libquadmath.so.0.0.0
             libstdc++.so.6.0.34
             libitm.so.1.0.0
             libatomic.so.1.2.0"

cd /usr/lib

for LIB in $save_usrlib; do
    objcopy --only-keep-debug --compress-debug-sections=zstd $LIB $LIB.dbg
    cp $LIB /tmp/$LIB
    strip --strip-debug /tmp/$LIB
    objcopy --add-gnu-debuglink=$LIB.dbg /tmp/$LIB
    install -vm755 /tmp/$LIB /usr/lib
    rm /tmp/$LIB
done

online_usrbin="bash find strip"
online_usrlib="libbfd-2.45.so
               libsframe.so.2.0.0
               libhistory.so.8.3
               libncursesw.so.6.5
               libm.so.6
               libreadline.so.8.3
               libz.so.1.3.1
               libzstd.so.1.5.7
               $(cd /usr/lib; find libnss*.so* -type f)"

for BIN in $online_usrbin; do
    cp /usr/bin/$BIN /tmp/$BIN
    strip --strip-debug /tmp/$BIN
    install -vm755 /tmp/$BIN /usr/bin
    rm /tmp/$BIN
done

for LIB in $online_usrlib; do
    cp /usr/lib/$LIB /tmp/$LIB
    strip --strip-debug /tmp/$LIB
    install -vm755 /tmp/$LIB /usr/lib
    rm /tmp/$LIB
done

for i in $(find /usr/lib -type f -name \*.so* ! -name \*dbg) \
         $(find /usr/lib -type f -name \*.a)                 \
         $(find /usr/{bin,sbin,libexec} -type f); do
    case "$online_usrbin $online_usrlib $save_usrlib" in
        *$(basename $i)* )
            ;;
        * ) strip --strip-debug $i
            ;;
    esac
done

unset BIN LIB save_usrlib online_usrbin online_usrlib
EOF

# ============================================================================
# §8.78 Cleanup final del libro + /etc/os-release + usuario normal (PLAN)
# ============================================================================
pkg cleanup-final <<'EOF'
set -euo pipefail
rm -rf /tmp/{*,.*} 2>/dev/null || true
find /usr/lib /usr/libexec -name \*.la -delete
find /usr -depth -name $(uname -m)-lfs-linux-gnu\* | xargs rm -rf
userdel -r tester 2>/dev/null || true
groupdel dummy 2>/dev/null || true
# PLAN: /etc/os-release
cat > /etc/os-release << "EOF2"
NAME="mylfs"
PRETTY_NAME="mylfs 1.0 (LFS 12.4)"
ID=mylfs
VERSION_ID="1.0"
VERSION="1.0 (LFS 12.4, kernel 7.1.5-mikuri)"
HOME_URL="https://github.com/mikuri12/mylfs"
EOF2
# hostname (PLAN, variable editable)
echo "optiplex-mikuri" > /etc/hostname
cat > /etc/hosts << "EOF2"
127.0.0.1  localhost optiplex-mikuri
::1        localhost
EOF2
EOF

# ---------------------------------------------------------------------------
# Verificación de salida de la etapa (fuera del chroot)
# ---------------------------------------------------------------------------
step "verificación rápida del resultado"
test -x "$LFS/usr/bin/gcc"      || { echo "FALTA gcc final"; exit 1; }
test -x "$LFS/usr/bin/bash"     || { echo "FALTA bash"; exit 1; }
test -e "$LFS/usr/lib/libc.so.6" || { echo "FALTA glibc final"; exit 1; }
test -x "$LFS/usr/bin/udevadm"   || { echo "FALTA eudev"; exit 1; }
test -e "$LFS/usr/lib/libpam.so" || { echo "FALTA Linux-PAM"; exit 1; }
test -x "$LFS/usr/bin/doas"      || { echo "FALTA opendoas"; exit 1; }
test -x "$LFS/usr/bin/ssh"       || { echo "FALTA openssh"; exit 1; }
test -e "$LFS/etc/pam.d/login"   || { echo "FALTA pam.d/login"; exit 1; }
test -x "$LFS/usr/bin/dhcpcd"    || { echo "FALTA dhcpcd"; exit 1; }
test -x "$LFS/usr/sbin/chronyd"  || { echo "FALTA chrony"; exit 1; }
test -x "$LFS/usr/sbin/acpid"    || { echo "FALTA acpid"; exit 1; }
test -e "$LFS/etc/ssl/certs/ca-certificates.crt" || { echo "FALTA ca-certs"; exit 1; }
test -x "$LFS/usr/bin/dracut"    || { echo "FALTA dracut"; exit 1; }
test -x "$LFS/usr/bin/ls"        || { echo "FALTA coreutils"; exit 1; }
test ! -e "$LFS/tools"           || { echo "/tools sigue presente"; exit 1; }
df -h "$LFS"
du -sh "$LFS/usr" "$LFS/lib" || true
echo "==> ETAPA 3 COMPLETA (t=$(( (SECONDS-T0)/60 ))min)"
