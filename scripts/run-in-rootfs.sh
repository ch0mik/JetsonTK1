#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "run-in-rootfs.sh must run as root" >&2
  exit 1
fi

rootfs=${1:?usage: run-in-rootfs.sh ROOTFS COMMAND [ARG...]}
shift
rootfs=$(readlink -f "$rootfs")

cleanup() {
  mountpoint -q "$rootfs/dev" && umount -R "$rootfs/dev" || true
  mountpoint -q "$rootfs/sys" && umount -R "$rootfs/sys" || true
  mountpoint -q "$rootfs/proc" && umount "$rootfs/proc" || true
}
trap cleanup EXIT

mount -t proc proc "$rootfs/proc"
mount --rbind /sys "$rootfs/sys"
mount --make-rslave "$rootfs/sys"
mount --rbind /dev "$rootfs/dev"
mount --make-rslave "$rootfs/dev"
rm -f "$rootfs/etc/resolv.conf"
cp --dereference /etc/resolv.conf "$rootfs/etc/resolv.conf"

chroot "$rootfs" "$@"
