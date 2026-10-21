# mylfs-live v1

ISO live de prueba construida desde el rootfs validado `rootfs-base-v1`
(LFS 12.4 + kernel 7.1.5-mikuri CachyOS+BORE, runit, eudev, PAM…).

**NO es un instalador**: arranca por USB en tu PC sin tocar el disco
(squashfs zstd + overlayfs en RAM, todo en memoria).

## Usuario de prueba

- usuario: `live`
- contraseña: `mylfs`
- (root también con `mylfs` — para probar, cambia todo en tu PC real)

## Arrancar

- **USB**: `dd if=mylfs-live.iso of=/dev/sdX bs=4M status=progress` —
  la ISO es híbrida (BIOS legacy + UEFI x86_64).
- **QEMU**: `qemu-system-x86_64 -machine q35 -m 4096 -bios /usr/share/OVMF/OVMF.fd -cdrom mylfs-live.iso`
  (con display gráfico; la ISO manda consola a tty0 Y ttyS0).

## Qué probar (checklist del PLAN)

- [ ] GRUB aparece con entrada "mylfs live"
- [ ] El kernel mikuri arranca con dmesg limpio
- [ ] dracut monta el LiveOS (squashfs.img) y hace switch_root
- [ ] runit llega al login (stage 1 → 2)
- [ ] Login con live/mylfs funciona
- [ ] `doas poweroff` apaga sin pedir contraseña
- [ ] (En tu PC) ethernet I219-LM con dhcpcd
- [ ] (En tu PC) teclado/consola OK

Si algo falla, saca foto del error y mándamela: el dmesg completo va
en consola serial con `console=ttyS0` también.
