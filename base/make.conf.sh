#!/bin/bash
# base/make.conf.sh — flags globales de compilación (PLAN: make.conf.sh único).
# Cargado por base/env.sh y por las recetas de mymypkgs.
# REGLA DEL PLAN: NUNCA -march=native. Sin LTO ni -O3 en glibc, gcc ni binutils.
# CFLAGS/CXXFLAGS: optimización para Skylake (i3-6100, x86-64-v3).
# LDFLAGS/RUSTFLAGS: los fija el PLAN.

export CFLAGS="-march=skylake -mtune=skylake -O2 -pipe -fno-plt"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-O1,--as-needed,--sort-common"
export RUSTFLAGS="-C target-cpu=skylake"

# Tests de paquetes desactivados por defecto (PLAN: RUN_TESTS=0).
export RUN_TESTS=${RUN_TESTS:-0}
