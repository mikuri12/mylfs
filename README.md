# mylfs

Linux From Scratch personal para el Dell OptiPlex 7050 (i3-6100, Skylake, HD 530,
8 GB RAM, UEFI). Construido en GitHub Actions sobre el libro **LFS 12.4 SysV**,
con init **runit** y optimización `-march=skylake`.

## Estructura

- `base/` — scripts del rootfs: `env.sh` (entorno), `make.conf.sh` (flags),
  `setup-user.sh` (usuario lfs + layout §4.3-5.1), `version-check.sh` (§2.2),
  `download-sources.sh` (manifiesto sha256 + mirrors), `ch05.sh` (etapa 1: caps. 5-6).
- `kernel/` — `KERNEL_TAG`: release precompilado de [mikuri-kernel](https://github.com/mikuri12/mikuri-kernel)
  que se integra en la etapa 4 (kernel 7.1.5 CachyOS+BORE). No se compila aquí.
- `live/` — (fase 3) scripts de la ISO live.
- `.github/workflows/base.yml` — pipeline: etapa 1 → etapa 2 → … (una por job).

## Versiones fijadas

| Qué | Valor | Fuente |
|---|---|---|
| Libro | LFS 12.4 SysV (última estable SysV) | lfs.org/lfs/downloads/12.4 |
| Kernel | 7.1.5-mikuri (CachyOS + BORE, precompilado) | release v7.1.5-mikuri |
| CFLAGS | `-march=skylake -mtune=skylake -O2 -pipe -fno-plt` | PLAN (make.conf.sh) |

## Releases

- `rootfs-base-vN` — rootfs base arrancable (fase 1 completa).
- `live-vN` — ISO live (fase 3).

Los paquetes de escritorio viven en el repo hermano [mymypkgs](https://github.com/mikuri12/mymypkgs).
