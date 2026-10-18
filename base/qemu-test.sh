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
ROOT_UUID_EMBED=$(sudo blkid -s UUID -o value ${LOOP}p2)
sudo mkdir -p /mnt/root-part/boot/efi/EFI/BOOT
cat > /tmp/embed.cfg <<EMBED
# GRUB debe hablar por serial: la VM corre headless (-display none) y sin
# esto TODOS los errores de GRUB van a la VGA invisible.
insmod serial
serial --unit=0 --speed=115200
terminal_input --append serial
terminal_output --append serial
set timeout=0
set default=0
search.fs_uuid ${ROOT_UUID_EMBED} root
menuentry "mylfs 1.0 (7.1.5-mikuri)" {
    linux /boot/vmlinuz-7.1.5-mikuri root=UUID=${ROOT_UUID_EMBED} ro mitigations=off console=ttyS0,115200 console=tty0
    initrd /boot/initramfs-7.1.5-mikuri.img
}
EMBED
# Binario principal: grub-mkstandalone (config embebida completa)
sudo grub-mkstandalone --format=x86_64-efi \
    --output=/mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI \
    --modules="part_gpt part_msdos ext2 fat linux normal search search_fs_uuid echo test boot serial terminal" \
    "boot/grub/grub.cfg=/tmp/embed.cfg"
# Binario alternativo: grub-mkimage puro con config temprana embebida
# (--config). El memdisk NO va como argumento posicional (lo trataría como
# módulo .mod). La early-config ejecuta el menú directamente al arrancar.
sudo grub-mkimage --format=x86_64-efi \
    --output=/tmp/BOOTX64-alt.efi \
    --prefix='(hd0,gpt2)/boot/grub' \
    --config=/tmp/embed.cfg \
    part_gpt ext2 fat linux normal search search_fs_uuid echo test boot serial terminal
sudo cp /tmp/BOOTX64-alt.efi /mnt/root-part/boot/efi/EFI/mylfs-alt.efi
ls -la /mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI /mnt/root-part/boot/efi/EFI/mylfs-alt.efi

step "desmontar y liberar loop (antes de arrancar)"
sudo umount /mnt/root-part/boot/efi
sudo umount /mnt/root-part
sudo losetup -d "$LOOP"

run_qemu_boot() {
    # $1 = ruta al EFI a bootear (se copia a EFI/BOOT/BOOTX64.EFI antes)
    QEMU_OK=0
    QEMU_FAIL=""
    sudo mount ${LOOP}p1 /mnt/root-part/boot/efi 2>/dev/null || true
    sudo cp "$1" /mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI
    sudo umount /mnt/root-part/boot/efi 2>/dev/null || true
    rm -f "$LOG"
    sudo qemu-system-x86_64 \
        -machine q35 -m 2048 -smp 2 \
        -drive file=$DISK,format=raw,if=none,id=disk0,index=0,media=disk \
        -device ahci,id=ahci0 \
        -device ide-hd,drive=disk0,bus=ahci0.0 \
        -net none \
        $OVMF_ARGS \
        -serial file:$LOG \
        -display none \
        -no-reboot &
    local pid=$!
    for i in $(seq 1 150); do
        if sudo grep -q "login:" "$LOG" 2>/dev/null; then QEMU_OK=1; break; fi
        if ! kill -0 $pid 2>/dev/null; then QEMU_FAIL="QEMU murió"; break; fi
        if sudo grep -q "^grub> " "$LOG" 2>/dev/null; then QEMU_FAIL="GRUB cayó a grub>"; break; fi
        if sudo grep -q "Shell>" "$LOG" 2>/dev/null; then QEMU_FAIL="UEFI shell"; break; fi
        sleep 2
    done
    sudo kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    echo "boot intento terminado: ok=$QEMU_OK fail=$QEMU_FAIL"
}

step "arrancar QEMU con OVMF, esperar login (timeout 300s)"
# OVMF con pflash: CODE + VARS separados (modo canónico).
OVMF_CODE=""
OVMF_VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/ovmf/OVMF_CODE.cc.fd; do
    [ -f "$c" ] && OVMF_CODE="$c" && break
done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/ovmf/OVMF_VARS.cc.fd; do
    [ -f "$v" ] && OVMF_VARS="$v" && break
done
if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    sudo cp "$OVMF_VARS" /tmp/OVMF_VARS.fd
    OVMF_ARGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
               -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd"
    echo "OVMF pflash: code=$OVMF_CODE vars=$OVMF_VARS"
else
    OVMF=""
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
        [ -f "$cand" ] && OVMF="$cand" && break
    done
    [ -n "$OVMF" ] || { echo "no se encontró firmware OVMF"; exit 1; }
    OVMF_ARGS="-bios $OVMF"
    echo "OVMF combinado: $OVMF"
fi

LOG=/mnt/work/qemu-boot.log

# Volver a attachear el loop (lo liberamos antes de arrancar)
sudo losetup -fP "$DISK"
LOOP=$(losetup -j "$DISK" | head -1 | cut -d: -f1)

# Intento 1: binario grub-mkstandalone. Si mata la VM (o cae a grub>/shell),
# Intento 2: binario grub-mkimage puro con memdisk.
RESULT_FILE=/tmp/qemu-result.txt
run_qemu_boot /mnt/root-part/boot/efi/EFI/BOOT/BOOTX64.EFI > /dev/null 2>&1 || true
ok=$QEMU_OK
failreason=$QEMU_FAIL
if [ $ok -ne 1 ]; then
    echo "== intento 1 (mkstandalone) falló: $failreason — probando mkimage =="
    run_qemu_boot /mnt/root-part/boot/efi/EFI/mylfs-alt.efi > /dev/null 2>&1 || true
    ok=$QEMU_OK
    failreason=$QEMU_FAIL
fi

echo "== serial completo (head 30) =="
sudo head -30 "$LOG" 2>/dev/null || echo "(serial vacío)"
if [ "$ok" = "1" ]; then
    echo "== QEMU ARRANCÓ HASTA LOGIN =="
    sudo grep -E "runit|stage|Welcome|login:|Linux" "$LOG" > /tmp/qemu-grep.txt || true
    sudo tail -20 /tmp/qemu-grep.txt
    exit 0
else
    echo "== QEMU NO LLEGÓ A LOGIN ($failreason) — últimos 40 líneas del serial =="
    sudo tail -40 "$LOG" 2>/dev/null || echo "(log serial vacío — no arrancó ni el firmware)"
    exit 1
fi
