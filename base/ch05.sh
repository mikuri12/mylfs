#!/bin/bash
# base/ch05.sh — Etapa 1: toolchain temporal (LFS 12.4 SysV, capítulos 5 y 6).
#
# FUENTE: LFS-BOOK-12.4 (https://www.linuxfromscratch.org/lfs/downloads/12.4/)
#   §5.2 Binutils-P1, §5.3 GCC-P1, §5.4 Linux headers, §5.5 Glibc,
#   §5.6 Libstdc++, §6.1-6.20 utilidades (m4…xz), §6.21 Binutils-P2, §6.22 GCC-P2.
# Los comandos de cada paquete son transcripción literal del libro.
#
# DISEÑO CI: el libro construye caps. 5-6 como usuario 'lfs' con entorno limpio
# (§4.4: env -i + set +h + umask 022). Aquí cada paquete se ejecuta como lfs
# vía `runuser ... env -i ... bash -s` leyendo un heredoc por stdin, con el
# mismo PATH de §4.4 ($LFS/tools/bin delante). No hay chroot en esta etapa.
#
# PLAN: set -euo pipefail, MAKEFLAGS=-j$(nproc), RUN_TESTS=0 (en cap. 5-6 el
# libro no corre test suites de todos modos), sin -O3/LTO en toolchain.

set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/make.conf.sh"

T0=$SECONDS
step() { printf '\n==> [stage1] %s (t+%dm%ss)\n' "$*" $(( (SECONDS-T0)/60 )) $(( (SECONDS-T0)%60 )); }

# Ejecuta un bloque de comandos (heredoc por stdin) como usuario lfs,
# con entorno limpio equivalente al .bashrc del libro (§4.4).
# El preámbulo fija umask 022 y set +h (§4.4/§2.6) — umask es builtin,
# no variable de entorno, así que se inyecta al inicio del script.
pkg() {
    local name=$1
    step "$name"
    { echo 'umask 022; set +h'; cat; } | \
    runuser -u lfs -- env -i \
        HOME=/home/lfs TERM=dumb PS1='\u:\w\$ ' \
        LFS="$LFS" LFS_TGT="$LFS_TGT" LC_ALL=POSIX \
        PATH="$LFS/tools/bin:/usr/bin:/bin" \
        CONFIG_SITE="$LFS/usr/share/config.site" \
        MAKEFLAGS="$MAKEFLAGS" TESTSUITEFLAGS="$TESTSUITEFLAGS" \
        bash -s
    step "$name OK"
}

# ============================================================================
# §5.2 Binutils-2.45 - Pass 1
# ============================================================================
pkg binutils-pass1 <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf binutils-2.45
tar -xpf binutils-2.45.tar.xz
cd binutils-2.45
mkdir -v build
cd       build
../configure --prefix="$LFS/tools" \
             --with-sysroot="$LFS" \
             --target="$LFS_TGT" \
             --disable-nls \
             --enable-gprofng=no \
             --disable-werror \
             --enable-new-dtags \
             --enable-default-hash-style=gnu
make
make install
EOF

# ============================================================================
# §5.3 GCC-15.2.0 - Pass 1
# ============================================================================
pkg gcc-pass1 <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf gcc-15.2.0
tar -xpf gcc-15.2.0.tar.xz
cd gcc-15.2.0
tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir -v build
cd       build
../configure --target="$LFS_TGT" \
             --prefix="$LFS/tools" \
             --with-glibc-version=2.42 \
             --with-sysroot="$LFS" \
             --with-newlib \
             --without-headers \
             --enable-default-pie \
             --enable-default-ssp \
             --disable-nls \
             --disable-shared \
             --disable-multilib \
             --disable-threads \
             --disable-libatomic \
             --disable-libgomp \
             --disable-libquadmath \
             --disable-libssp \
             --disable-libvtv \
             --disable-libstdcxx \
             --enable-languages=c,c++
make
make install
cd ..
cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
  "$(dirname "$($LFS_TGT-gcc -print-libgcc-file-name)")/include/limits.h"
EOF

# ============================================================================
# §5.4 Linux-6.16.1 API Headers
# ============================================================================
pkg linux-headers <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf linux-6.16.1
tar -xpf linux-6.16.1.tar.xz
cd linux-6.16.1
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include "$LFS/usr"
EOF

# ============================================================================
# §5.5 Glibc-2.42 (con enlaces ld-lsb, parche FHS y verificaciones del libro)
# ============================================================================
pkg glibc <<'EOF'
set +h
set -euo pipefail
ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64"
ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3"
cd "$LFS/sources"
rm -rf glibc-2.42
tar -xpf glibc-2.42.tar.xz
cd glibc-2.42
patch -Np1 -i ../glibc-2.42-fhs-1.patch
mkdir -v build
cd       build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr \
      --host="$LFS_TGT" \
      --build="$(../scripts/config.guess)" \
      --disable-nscd \
      libc_cv_slibdir=/usr/lib \
      --enable-kernel=5.4
make
make DESTDIR="$LFS" install
sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"
# --- Verificaciones de sanidad del toolchain (§5.5) ---
echo 'int main(){}' | "$LFS_TGT-gcc" -x c - -v -Wl,--verbose &> dummy.log
readelf -l a.out | grep ': /lib'
grep -E -o "$LFS/lib.*/S?crt[1in].*succeeded" dummy.log
grep -B3 "^ $LFS/usr/include" dummy.log
grep 'SEARCH.*/usr/lib' dummy.log | sed 's|; |\n|g'
grep "/lib.*/libc.so.6 " dummy.log
grep found dummy.log
rm -v a.out dummy.log
EOF

# ============================================================================
# §5.6 Libstdc++ from GCC-15.2.0
# ============================================================================
pkg libstdcpp <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources/gcc-15.2.0"
rm -rf build
mkdir -v build
cd       build
../libstdc++-v3/configure --host="$LFS_TGT" \
    --build="$(../config.guess)" \
    --prefix=/usr \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/15.2.0
make
make DESTDIR="$LFS" install
rm -v "$LFS"/usr/lib/lib{stdc++{,exp,fs},supc++}.la
EOF

# ============================================================================
# §6.2 M4-1.4.20
# ============================================================================
pkg m4 <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf m4-1.4.20
tar -xpf m4-1.4.20.tar.xz
cd m4-1.4.20
./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.3 Ncurses-6.5-20250809 (tic nativo primero, luego cross)
# ============================================================================
pkg ncurses <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf ncurses-6.5-20250809
tar -xpf ncurses-6.5-20250809.tgz
cd ncurses-6.5-20250809
mkdir build
pushd build
  ../configure --prefix="$LFS/tools" AWK=gawk
  make -C include
  make -C progs tic
  install progs/tic "$LFS/tools/bin"
popd
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(./config.guess)" \
            --mandir=/usr/share/man \
            --with-manpage-format=normal \
            --with-shared \
            --without-normal \
            --with-cxx-shared \
            --without-debug \
            --without-ada \
            --disable-stripping \
            AWK=gawk
make
make DESTDIR="$LFS" install
ln -sv libncursesw.so "$LFS/usr/lib/libncurses.so"
sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$LFS/usr/include/curses.h"
EOF

# ============================================================================
# §6.4 Bash-5.3
# ============================================================================
pkg bash <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf bash-5.3
tar -xpf bash-5.3.tar.gz
cd bash-5.3
./configure --prefix=/usr \
            --build="$(sh support/config.guess)" \
            --host="$LFS_TGT" \
            --without-bash-malloc
make
make DESTDIR="$LFS" install
ln -sv bash "$LFS/bin/sh"
EOF

# ============================================================================
# §6.5 Coreutils-9.7
# ============================================================================
pkg coreutils <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf coreutils-9.7
tar -xpf coreutils-9.7.tar.xz
cd coreutils-9.7
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)" \
            --enable-install-program=hostname \
            --enable-no-install-program=kill,uptime
make
make DESTDIR="$LFS" install
mv -v "$LFS/usr/bin/chroot" "$LFS/usr/sbin"
mkdir -pv "$LFS/usr/share/man/man8"
mv -v "$LFS/usr/share/man/man1/chroot.1" "$LFS/usr/share/man/man8/chroot.8"
sed -i 's/"1"/"8"/' "$LFS/usr/share/man/man8/chroot.8"
EOF

# ============================================================================
# §6.6 Diffutils-3.12
# ============================================================================
pkg diffutils <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf diffutils-3.12
tar -xpf diffutils-3.12.tar.xz
cd diffutils-3.12
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            gl_cv_func_strcasecmp_works=y \
            --build="$(./build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.7 File-5.46 (build nativo para FILE_COMPILE, luego cross)
# ============================================================================
pkg file <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf file-5.46
tar -xpf file-5.46.tar.gz
cd file-5.46
mkdir build
pushd build
  ../configure --disable-bzlib \
               --disable-libseccomp \
               --disable-xzlib \
               --disable-zlib
  make
popd
./configure --prefix=/usr --host="$LFS_TGT" --build="$(./config.guess)"
make FILE_COMPILE="$(pwd)/build/src/file"
make DESTDIR="$LFS" install
rm -v "$LFS/usr/lib/libmagic.la"
EOF

# ============================================================================
# §6.8 Findutils-4.10.0
# ============================================================================
pkg findutils <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf findutils-4.10.0
tar -xpf findutils-4.10.0.tar.xz
cd findutils-4.10.0
./configure --prefix=/usr \
            --localstatedir=/var/lib/locate \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.9 Gawk-5.3.2
# ============================================================================
pkg gawk <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf gawk-5.3.2
tar -xpf gawk-5.3.2.tar.xz
cd gawk-5.3.2
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.10 Grep-3.12
# ============================================================================
pkg grep <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf grep-3.12
tar -xpf grep-3.12.tar.xz
cd grep-3.12
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(./build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.11 Gzip-1.14
# ============================================================================
pkg gzip <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf gzip-1.14
tar -xpf gzip-1.14.tar.xz
cd gzip-1.14
./configure --prefix=/usr --host="$LFS_TGT"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.12 Make-4.4.1
# ============================================================================
pkg make <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf make-4.4.1
tar -xpf make-4.4.1.tar.gz
cd make-4.4.1
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.13 Patch-2.8
# ============================================================================
pkg patch <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf patch-2.8
tar -xpf patch-2.8.tar.xz
cd patch-2.8
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.14 Sed-4.9
# ============================================================================
pkg sed <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf sed-4.9
tar -xpf sed-4.9.tar.xz
cd sed-4.9
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(./build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.15 Tar-1.35
# ============================================================================
pkg tar <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf tar-1.35
tar -xpf tar-1.35.tar.xz
cd tar-1.35
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)"
make
make DESTDIR="$LFS" install
EOF

# ============================================================================
# §6.16 Xz-5.8.1
# ============================================================================
pkg xz <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf xz-5.8.1
tar -xpf xz-5.8.1.tar.xz
cd xz-5.8.1
./configure --prefix=/usr \
            --host="$LFS_TGT" \
            --build="$(build-aux/config.guess)" \
            --disable-static \
            --docdir=/usr/share/doc/xz-5.8.1
make
make DESTDIR="$LFS" install
rm -v "$LFS/usr/lib/liblzma.la"
EOF

# ============================================================================
# §6.17 Binutils-2.45 - Pass 2
# ============================================================================
pkg binutils-pass2 <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf binutils-2.45
tar -xpf binutils-2.45.tar.xz
cd binutils-2.45
sed '6031s/$add_dir//' -i ltmain.sh
mkdir -v build
cd       build
../configure --prefix=/usr \
    --build="$(../config.guess)" \
    --host="$LFS_TGT" \
    --disable-nls \
    --enable-shared \
    --enable-gprofng=no \
    --disable-werror \
    --enable-64-bit-bfd \
    --enable-new-dtags \
    --enable-default-hash-style=gnu
make
make DESTDIR="$LFS" install
rm -v "$LFS"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
EOF

# ============================================================================
# §6.18 GCC-15.2.0 - Pass 2
# ============================================================================
pkg gcc-pass2 <<'EOF'
set +h
set -euo pipefail
cd "$LFS/sources"
rm -rf gcc-15.2.0
tar -xpf gcc-15.2.0.tar.xz
cd gcc-15.2.0
tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
sed '/thread_header =/s/@.*@/gthr-posix.h/' \
    -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
mkdir -v build
cd       build
../configure --build="$(../config.guess)" \
    --host="$LFS_TGT" \
    --target="$LFS_TGT" \
    --prefix=/usr \
    --with-build-sysroot="$LFS" \
    --enable-default-pie \
    --enable-default-ssp \
    --disable-nls \
    --disable-multilib \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libsanitizer \
    --disable-libssp \
    --disable-libvtv \
    --enable-languages=c,c++ \
    LDFLAGS_FOR_TARGET="-L$PWD/$LFS_TGT/libgcc"
make
make DESTDIR="$LFS" install
ln -sv gcc "$LFS/usr/bin/cc"
EOF

# ============================================================================
# Resumen de la etapa (equivalente al backup lfs-temp-tools del libro §7.12)
# El tarball final lo arma el job de Actions, no este script.
# ============================================================================
step "verificación rápida del resultado"
test -x "$LFS/tools/bin/$LFS_TGT-gcc"   || { echo "FALTA $LFS/tools/bin/$LFS_TGT-gcc"; exit 1; }
test -x "$LFS/usr/bin/$LFS_TGT-gcc"     || { echo "FALTA gcc-pass2"; exit 1; }
test -e "$LFS/usr/lib/libc.so.6"        || { echo "FALTA glibc"; exit 1; }
test -L "$LFS/usr/bin/cc"               || { echo "FALTA symlink cc"; exit 1; }
test -x "$LFS/usr/bin/bash"             || { echo "FALTA bash"; exit 1; }
df -h "$LFS" || true
du -sh "$LFS/tools" "$LFS/usr"
echo "==> ETAPA 1 COMPLETA (t=$(( (SECONDS-T0)/60 ))min)"
