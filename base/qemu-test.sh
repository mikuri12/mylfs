#!/bin/bash
# base/qemu-test.sh — Prueba de arranque: disco GPT + kernel mikuri + OVMF UEFI,
# hasta el prompt de login de agetty por consola serial (PLAN fase 1).
# Requiere en el runner: qemu-system-x86_64, ovmf, sgdisk, mtools (se instalan aquí).
set -euo pipefail
. "$(dirname "$0")/env.sh"

T0=$SECONDS
step() { printf '\n==> [qemu] %s (t+%dm)\n' "$*" $(( (SECONDS-T0)/60 )); }

step "dependencias QEMU/OVMF en el runner"
sudo apt-get update -q
sudo apt-get install -y -q qemu-system-x86 ovmf gdisk mtools >/dev/null

step "crear disco de prueba (12G, GPT: 512M EFI + root ext4)"
DISK=/mnt/work/mylfs-test.img
mkdir -p /mnt/work
rm -f "$DISK"
truncate -s 12G "$DISK"
sudo sgdisk --zap-all "$DISK"
sudo sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sudo sgdisk -n 2:0:0 -t 2:8300 "$DISK"
sudo losetup -fP "$DISK"
LOOP=$(losetup -j "$DISK" | head -1 | cut -d: -f1)
echo "loop: $LOOP"
sudo partprobe "$LOOP" 2>/dev/null || true
# esperar nodos de partición
for i in $(seq 1 10); do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && break
    sleep 1
done
[ -b "${LOOP}p2" ] || { echo "no apareció ${LOOP}p2"; exit 1; }
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.ext4 -q -L root ${LOOP}p2

step "montar, poblar rootfs y configurar (TODO en un montaje)"
sudo mkdir -p /mnt/root-part
sudo mount ${LOOP}p2 /mnt/root-part
sudo mkdir -p /mnt/root-part/boot/efi
sudo mount ${LOOP}p1 /mnt/root-part/boot/efi
# el tarball lleva prefijo lfs/ (creado con -C /mnt lfs): strip 1 nivel
sudo tar --zstd -xpf "$1" -C /mnt/root-part --numeric-owner --keep-directory-symlink --strip-components=1

# UUID reales para fstab y grub
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
echo "root uuid: $ROOT_UUID / efi uuid: $EFI_UUID"
sudo sed -i "s/UUID=00000000-0000-0000-0000-000000000000/UUID=$ROOT_UUID/" /mnt/root-part/etc/fstab
sudo sed -i "s/UUID=0000-0000/UUID=$EFI_UUID/" /mnt/root-part/etc/fstab
sudo sed -i "s/ROOTUUID/$ROOT_UUID/g" /mnt/root-part/boot/grub/grub.cfg
# consola serial para el test (getty serial + cmdline)
sudo ln -sf /etc/sv/agetty-ttyS0 /mnt/root-part/etc/runit/runsvdir/default/
sudo sed -i 's/ ro mitigations=off/ ro mitigations=off console=ttyS0,115200 console=tty0/' /mnt/root-part/boot/grub/grub.cfg

step "GRUB UEFI en el disco (binario determinista con mkstandalone)"
# El grub-install de Ubuntu embebe un prefijo que no resuelve nuestra
# partición (caía a grub>). Vía determinista: grub-mkstandalone con config
# embebida que busca el ext4 por UUID (lo conocemos) y carga su grub.cfg.
ROOT_UUID_EMBED=$(sudo blkid -s UUID -o value ${LOOP}p2)
cat > /tmp/embed.cfg <<EMBED
search.fs_uuid ${ROOT_UUID_EMBED} root
set prefix=(\$root)/boot/grub
insmod ext2
configfile \${prefix}/grub.cfg
EMBED
sudo grub-mkstandalone --format=x86_64-efi \
    --output=/mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI \
    --modules="part_gpt ext2 search_fs_uuid fat" \
    "boot/grub/grub.cfg=/tmp/embed.cfg"
# EFI/mylfs también (por si el firmware prefiere el bootloader-id)
sudo mkdir -p /mnt/root-part/boot/efi/EFI/mylfs
sudo cp /mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI \
        /mnt/root-part/boot/efi/EFI/mylfs/grubx64.efi
ls -la /mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI

step "desmontar y liberar loop (antes de arrancar)"
sudo umount /mnt/root-part/boot/efi
sudo umount /mnt/root-part
sudo losetup -d "$LOOP"

step "arrancar QEMU con OVMF, esperar login (timeout 300s)"
# OVMF con pflash: CODE + VARS separados (modo canónico). Con --no-nvram
# en grub-install, OVMF usa su ruta de fallback EFI/BOOT/BOOTX64.EFI.
OVMF_CODE=""
OVMF_VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/ovmf/OVMF_CODE.cc.fd; do
    [ -f "$c" ] && OVMF_CODE="$c" && break
done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/ovmf/OVMF_VARS.cc.fd; do
    [ -f "$v" ] && OVMF_VARS="$v" && break
done
if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    # copia editable de VARS (pflash la modifica)
    sudo cp "$OVMF_VARS" /tmp/OVMF_VARS.fd
    OVMF_ARGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
               -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd"
    echo "OVMF pflash: code=$OVMF_CODE vars=$OVMF_VARS"
else
    # fallback: imagen combinada con -bios
    OVMF=""
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
        [ -f "$cand" ] && OVMF="$cand" && break
    done
    [ -n "$OVMF" ] || { echo "no se encontró firmware OVMF"; exit 1; }
    OVMF_ARGS="-bios $OVMF"
    echo "OVMF combinado: $OVMF"
fi

LOG=/mnt/work/qemu-boot.log
rm -f "$LOG"
sudo qemu-system-x86_64 \
    -machine q35 -m 2048 -smp 2 \
    -drive file=$DISK,format=raw,if=virtio \
    -net none \
    $OVMF_ARGS \
    -serial file:$LOG \
    -display none \
    -no-reboot &
QEMU_PID=$!

# Esperar el prompt de login en el log serial
ok=0
for i in $(seq 1 150); do
    if sudo grep -q "login:" "$LOG" 2>/dev/null; then
        ok=1
        break
    fi
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo "QEMU terminó antes del login"
        break
    fi
    sleep 2
done
sudo kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

if [ $ok -eq 1 ]; then
    echo "== QEMU ARRANCÓ HASTA LOGIN =="
    sudo grep -E "runit|stage|Welcome|login:|Linux" "$LOG" > /tmp/qemu-grep.txt || true
    sudo tail -20 /tmp/qemu-grep.txt
    exit 0
else
    echo "== QEMU NO LLEGÓ A LOGIN — últimos 40 líneas del serial =="
    sudo tail -40 "$LOG" 2>/dev/null || echo "(log serial vacío — no arrancó ni el firmware)"
    exit 1
fi
