#!/bin/sh
# base/env.sh — entorno global del build, compartido por todas las etapas.
# Fuente del layout y variables: LFS 12.4 §4.4 (Setting Up the Environment).
# Cargado con: . base/env.sh
# Reglas del PLAN (make.conf.sh único): CFLAGS etc. se definen en make.conf.sh.

LFS=/mnt/lfs
LFS_TGT=x86_64-lfs-linux-gnu
LC_ALL=POSIX
CONFIG_SITE="$LFS/usr/share/config.site"

# En CI el host es el runner de GitHub; las herramientas del libro corren directo.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MAKEFLAGS="-j$(nproc)"
TESTSUITEFLAGS="-j$(nproc)"

# Variables de trabajo
RUN_TESTS=0        # tests de paquetes desactivados por defecto (PLAN)
SOURCES=$LFS/sources
LOGDIR=/mnt/lfs-logs

export LFS LFS_TGT LC_ALL CONFIG_SITE PATH MAKEFLAGS TESTSUITEFLAGS RUN_TESTS SOURCES LOGDIR
