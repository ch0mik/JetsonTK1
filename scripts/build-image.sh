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
rootfs_size_mib=${ROOTFS_SIZE_MIB:-4096}
boot_size_mib=${BOOT_SIZE_MIB:-128}
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

mkdir -p "$output" "$boot_mount" "$root_mount" "$work/boot/extlinux"
required_mib=$(du -sm "$rootfs" | awk '{print $1}')
if (( required_mib + 256 > rootfs_size_mib )); then
  echo "rootfs needs ${required_mib} MiB; ROOTFS_SIZE_MIB=${rootfs_size_mib} is too small" >&2
  exit 1
fi

install -m 0644 "$zimage" "$work/boot/zImage"
install -m 0644 "$dtb" "$work/boot/tegra124-jetson-tk1.dtb"
install -m 0644 "$rootfs/boot/initrd.img-$kernel_version" "$work/boot/initrd.img"
cat > "$work/boot/extlinux/extlinux.conf" <<EOF
DEFAULT primary
TIMEOUT 30
MENU TITLE Jetson TK1 ${variant}

LABEL primary
  MENU LABEL Debian 12 (${variant}, ${kernel_version})
  LINUX /zImage
  INITRD /initrd.img
  FDT /tegra124-jetson-tk1.dtb
  APPEND console=ttyS0,115200n8 console=tty0 root=LABEL=rootfs rootwait rw
EOF

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

disk_size_mib=$((1 + boot_size_mib + rootfs_size_mib + 1))
root_start_mib=$((1 + boot_size_mib))
disk_image="$work/$base.img"
truncate -s "${disk_size_mib}M" "$disk_image"
parted -s "$disk_image" mklabel msdos
parted -s "$disk_image" mkpart primary ext2 1MiB "${root_start_mib}MiB"
parted -s "$disk_image" set 1 boot on
parted -s "$disk_image" mkpart primary ext4 "${root_start_mib}MiB" 100%
dd if="$boot_image" of="$disk_image" bs=1M seek=1 conv=notrunc status=none
dd if="$root_image" of="$disk_image" bs=1M seek="$root_start_mib" conv=notrunc status=none
parted -s "$disk_image" unit MiB print

manifest="$work/manifest.txt"
cat > "$manifest" <<EOF
board=tegra124-jetson-tk1
variant=$variant
debian=12-bookworm-armhf
kernel=$kernel_version
rootfs_size_mib=$rootfs_size_mib
boot_size_mib=$boot_size_mib
source_revision=${GITHUB_SHA:-local}
build_run=${GITHUB_RUN_ID:-local}
EOF

components="$work/components"
mkdir -p "$components/boot"
cp "$root_image" "$components/rootfs.ext4"
cp -a "$work/boot/." "$components/boot/"
cp "$manifest" "$components/manifest.txt"

tar --sparse -C "$components" -cJf "$output/$base-components.tar.xz" .
xz -T0 -3 -c "$disk_image" > "$output/$base.img.xz"
cp "$manifest" "$output/$base-manifest.txt"
(cd "$output" && sha256sum "$base-components.tar.xz" "$base.img.xz" "$base-manifest.txt" > SHA256SUMS)
