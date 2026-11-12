# mylfs-live v2

ISO live de prueba construida desde el rootfs validado `rootfs-base-v1`
(LFS 12.4 + kernel 7.1.5-mikuri CachyOS+BORE, runit, eudev, PAM) **más todos
los paquetes del Release `packages` de mymypkgs** (sesión: seatd, turnstile,
dbus, greetd + noctalia-greeter; gráficos: libdrm/wayland/mesa iris+vulkan
intel; audio: alsa/pipewire/wireplumber; escritorio: Halley + Noctalia v5 +
xwayland-satellite + xdg-desktop-portal + fuzzel/foot; firmware i915 Skylake;
mymy).

**NO es un instalador**: arranca por USB en tu PC sin tocar el disco
(squashfs zstd + overlayfs en RAM, todo en memoria).

## Usuario de prueba

- usuario: `live`
- contraseña: `mylfs`
- (root también con `mylfs` — para probar, cambia todo en tu PC real)
- consola serial ttyS0 hace **autologin** como `live` (para el test CI con QEMU)

## Arrancar

- **USB**: `dd if=mylfs-live.iso of=/dev/sdX bs=4M status=progress` —
  la ISO es híbrida (BIOS legacy + UEFI x86_64). Si pasa de 1.9 GB está
  partida en `mylfs-live.iso.partNN` (reconstruir: `cat mylfs-live.iso.part* > mylfs-live.iso`,
  verificar con `mylfs-live.iso.sha256`).
- **QEMU**: `qemu-system-x86_64 -machine q35 -m 4096 -bios /usr/share/OVMF/OVMF.fd -cdrom mylfs-live.iso`

## Qué probar (checklist del PLAN, FASE 3)

- [ ] GRUB aparece con entrada "mylfs live v2"
- [ ] El kernel mikuri arranca (i915 carga, firmware skl_dmc/skl_guc/skl_huc presentes)
- [ ] dracut monta el LiveOS (squashfs.img) y hace switch_root
- [ ] runit stage 2 levanta seatd, turnstiled, dbus y **greetd**
- [ ] **greetd muestra el greeter de Noctalia** en tty1 (HD 530 con mesa iris)
- [ ] Login desde el greeter arranca la sesión **Halley** (xwayland-satellite)
- [ ] **Noctalia v5** corre (barra/paneles) dentro de Halley
- [ ] Sonido: pipewire/wireplumber como servicios de usuario de turnstile
- [ ] `doas poweroff` apaga sin pedir contraseña
- [ ] (En tu PC) ethernet I219-LM con dhcpcd

## Verificación automática en CI

El workflow `live` corre QEMU+OVMF con la ISO y exige en la consola serial:
`MYLFS_LIVE_READY` (autologin) y `MYLFS_SVC greetd: run:` (greetd arriba).
El greeter en sí necesita GPU real (en QEMU no hay DRM virtio-gpu en el
kernel mikuri), así que el renderizado del greeter se prueba en hardware real.

Si algo falla, saca foto del error y mándamela: el dmesg completo va
en consola serial con `console=ttyS0` también.
