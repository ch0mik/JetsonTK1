#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "finalize-rootfs.sh must run as root" >&2
  exit 1
fi

rootfs=$(readlink -f "${1:?usage: finalize-rootfs.sh ROOTFS KERNEL_VERSION}")
kernel_version=${2:?usage: finalize-rootfs.sh ROOTFS KERNEL_VERSION}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

test -d "$rootfs/lib/modules/$kernel_version"
kernel_config="$rootfs/boot/config-$kernel_version"
if [[ ! -s "$kernel_config" ]]; then
  echo "missing kernel configuration required by initramfs-tools: $kernel_config" >&2
  exit 1
fi
grep -qx 'CONFIG_BLK_DEV_INITRD=y' "$kernel_config" || {
  echo "$kernel_config does not enable CONFIG_BLK_DEV_INITRD" >&2
  exit 1
}
# Bookworm's udev initramfs hook searches this directory unconditionally, but
# a minimal rootfs without systemd-networkd does not create it.
bash "$script_dir/run-in-rootfs.sh" "$rootfs" \
  install -d -m 0755 /lib/systemd/network
if ! bash "$script_dir/run-in-rootfs.sh" "$rootfs" \
  update-initramfs -v -c -k "$kernel_version"; then
  echo "update-initramfs failed; udev path diagnostics:" >&2
  bash "$script_dir/run-in-rootfs.sh" "$rootfs" /bin/bash -c '
    for path in \
      /bin /bin/udevadm /usr/bin/udevadm \
      /lib/systemd/systemd-udevd /etc/udev/udev.conf \
      /lib/udev/ata_id /lib/udev/scsi_id /sbin/blkid; do
      ls -ld "$path" 2>&1 || true
      if [ -L "$path" ]; then
        readlink "$path" 2>&1 || true
      fi
    done
    /bin/udevadm --version 2>&1 || true
    ldd /bin/udevadm 2>&1 || true
  ' >&2 || true
  exit 1
fi
bash "$script_dir/run-in-rootfs.sh" "$rootfs" /bin/bash -c \
  'lsinitramfs "$1" | grep -F "scripts/init-premount/tk1-network-installer" >/dev/null' \
  _ "/boot/initrd.img-$kernel_version"

rm -f "$rootfs/usr/bin/qemu-arm-static"
rm -f "$rootfs/etc/ssh/ssh_host_"*
rm -f "$rootfs/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
: > "$rootfs/etc/machine-id"
rm -f "$rootfs/var/lib/dbus/machine-id"
rm -rf "$rootfs/var/lib/apt/lists/"* "$rootfs/var/cache/apt/archives/"*.deb

test -s "$rootfs/boot/initrd.img-$kernel_version"
test -x "$rootfs/usr/bin/docker"
