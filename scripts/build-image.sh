#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "build-image.sh must run as root" >&2
  exit 1
fi

rootfs=$(readlink -f "${1:?usage: build-image.sh ROOTFS VARIANT ZIMAGE DTB KERNEL_VERSION OUTPUT}")
variant=${2:?}
zimage=$(readlink -f "${3:?}")
dtb=$(readlink -f "${4:?}")
kernel_version=${5:?}
output=$(readlink -m "${6:?}")
rootfs_size_mib=${ROOTFS_SIZE_MIB:-14336}
boot_size_mib=${BOOT_SIZE_MIB:-128}
[[ "$rootfs_size_mib" =~ ^[0-9]+$ ]] || { echo "ROOTFS_SIZE_MIB must be numeric" >&2; exit 1; }
[[ "$boot_size_mib" =~ ^[0-9]+$ ]] || { echo "BOOT_SIZE_MIB must be numeric" >&2; exit 1; }
(( rootfs_size_mib >= 14336 )) || { echo "ROOTFS_SIZE_MIB must be at least 14336" >&2; exit 1; }
(( boot_size_mib >= 64 )) || { echo "BOOT_SIZE_MIB must be at least 64" >&2; exit 1; }
base="jetson-tk1-${variant}-debian12"
work=$(mktemp -d)
boot_mount="$work/boot-mount"
root_mount="$work/root-mount"

cleanup() {
  mountpoint -q "$boot_mount" && umount "$boot_mount" || true
  mountpoint -q "$root_mount" && umount "$root_mount" || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$output" "$boot_mount" "$root_mount" \
  "$work/boot/boot/extlinux" "$work/boot/extlinux"
required_mib=$(du -sm "$rootfs" | awk '{print $1}')
if (( required_mib + 256 > rootfs_size_mib )); then
  echo "rootfs needs ${required_mib} MiB; ROOTFS_SIZE_MIB=${rootfs_size_mib} is too small" >&2
  exit 1
fi

install -m 0644 "$zimage" "$work/boot/boot/zImage"
install -m 0644 "$dtb" "$work/boot/boot/tegra124-jetson-tk1.dtb"
install -m 0644 "$rootfs/boot/initrd.img-$kernel_version" "$work/boot/boot/initrd.img"

if [[ "$variant" == nvidia ]]; then
  kernel_args='console=ttyS0,115200n8 console=tty1 no_console_suspend=1 lp0_vec=2064@0xf46ff000 mem=2015M@2048M memtype=255 ddr_die=2048M@2048M section=256M pmuboard=0x0177:0x0000:0x02:0x43:0x00 tsec=32M@3913M otf_key=c75e5bb91eb3bd947560357b64422f85 usbcore.old_scheme_first=1 core_edp_mv=1150 core_edp_ma=4000 tegraid=40.1.1.0.0 debug_uartport=lsport,3 power_supply=Adapter audio_codec=rt5640 modem_id=0 android.kerneltype=normal fbcon=map:1 commchip_id=0 usb_port_owner_info=0 lane_owner_info=6 emc_max_dvfs=0 touch_id=0@0 board_info=0x0177:0x0000:0x02:0x43:0x00 net.ifnames=0 root=/dev/sda1 rootwait rw'
else
  kernel_args='console=ttyS0,115200n8 console=tty0 root=/dev/sda1 rootwait rw'
fi

cat > "$work/boot/boot/extlinux/extlinux.conf" <<EOF
DEFAULT primary
TIMEOUT 30
MENU TITLE Jetson TK1 ${variant}

LABEL primary
  MENU LABEL Debian 12 (${variant}, ${kernel_version})
  LINUX /boot/zImage
  INITRD /boot/initrd.img
  FDT /boot/tegra124-jetson-tk1.dtb
  APPEND ${kernel_args}
EOF
cp "$work/boot/boot/extlinux/extlinux.conf" "$work/boot/extlinux/extlinux.conf"

boot_image="$work/boot.ext2"
root_image="$work/rootfs.ext4"
truncate -s "${boot_size_mib}M" "$boot_image"
mkfs.ext2 -F -L BOOT -m 0 "$boot_image"
mount -o loop "$boot_image" "$boot_mount"
cp -a "$work/boot/." "$boot_mount/"
sync
umount "$boot_mount"

truncate -s "${rootfs_size_mib}M" "$root_image"
mkfs.ext4 -F -L rootfs -m 0 "$root_image"
mount -o loop "$root_image" "$root_mount"
rsync -aHAX --numeric-ids "$rootfs/" "$root_mount/"
sync
umount "$root_mount"
e2fsck -fn "$boot_image"
e2fsck -fn "$root_image"

boot_disk_size_mib=$((1 + boot_size_mib + 1))
boot_disk_image="$work/$base-boot-sd.img"
truncate -s "${boot_disk_size_mib}M" "$boot_disk_image"
parted -s "$boot_disk_image" mklabel msdos
parted -s "$boot_disk_image" mkpart primary ext2 1MiB "$((1 + boot_size_mib))MiB"
parted -s "$boot_disk_image" set 1 boot on
dd if="$boot_image" of="$boot_disk_image" bs=1M seek=1 conv=notrunc status=none
parted -s "$boot_disk_image" unit MiB print

manifest="$work/manifest.txt"
cat > "$manifest" <<EOF
board=tegra124-jetson-tk1
variant=$variant
debian=12-bookworm-armhf
kernel=$kernel_version
rootfs_size_mib=$rootfs_size_mib
boot_size_mib=$boot_size_mib
root_device=/dev/sda1
source_revision=${GITHUB_SHA:-local}
build_run=${GITHUB_RUN_ID:-local}
EOF

cp "$manifest" "$work/boot/manifest.txt"
tar -C "$work/boot" -cJf "$output/$base-boot-files.tar.xz" .
xz -T0 -3 -c "$boot_disk_image" > "$output/$base-boot-sd.img.xz"
xz -T0 -3 -c "$boot_image" > "$output/$base-boot.ext2.xz"
xz -T0 -3 -c "$root_image" > "$output/$base-rootfs.ext4.xz"
cp "$manifest" "$output/$base-manifest.txt"
(cd "$output" && sha256sum \
  "$base-boot-files.tar.xz" \
  "$base-boot-sd.img.xz" \
  "$base-boot.ext2.xz" \
  "$base-rootfs.ext4.xz" \
  "$base-manifest.txt" > SHA256SUMS)
