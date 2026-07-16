#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "build-rootfs.sh must run as root" >&2
  exit 1
fi

rootfs=${1:?usage: build-rootfs.sh ROOTFS nvidia|mainline}
variant=${2:?usage: build-rootfs.sh ROOTFS nvidia|mainline}
case "$variant" in
  nvidia|mainline) ;;
  *) echo "unknown variant: $variant" >&2; exit 1 ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rm -rf "$rootfs"
mkdir -p "$rootfs"

debootstrap --arch=armhf --foreign --variant=minbase \
  bookworm "$rootfs" https://deb.debian.org/debian
install -m 0755 /usr/bin/qemu-arm-static "$rootfs/usr/bin/qemu-arm-static"
bash "$script_dir/run-in-rootfs.sh" "$rootfs" /debootstrap/debootstrap --second-stage

install -m 0755 "$script_dir/configure-rootfs.sh" "$rootfs/tmp/configure-rootfs.sh"
bash "$script_dir/run-in-rootfs.sh" "$rootfs" \
  /usr/bin/env TK1_VARIANT="$variant" /bin/bash /tmp/configure-rootfs.sh
rm -f "$rootfs/tmp/configure-rootfs.sh"
