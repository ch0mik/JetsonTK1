#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "install-nvidia-userspace.sh must run as root" >&2
  exit 1
fi

rootfs=$(readlink -f "${1:?usage: install-nvidia-userspace.sh ROOTFS L4T_DIR}")
l4t_dir=$(readlink -f "${2:?usage: install-nvidia-userspace.sh ROOTFS L4T_DIR}")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

rm -rf "$l4t_dir/rootfs"
ln -s "$rootfs" "$l4t_dir/rootfs"
(cd "$l4t_dir" && ./apply_binaries.sh)

# L4T R21.8 predates merged-/usr. Its apply_binaries.sh can remove the
# top-level ARMHF interpreter link from a modern Debian rootfs, after which
# binfmt/QEMU cannot start even /bin/sh and only reports exit status 255.
armhf_loader=arm-linux-gnueabihf/ld-linux-armhf.so.3
loader_link="$rootfs/lib/ld-linux-armhf.so.3"
if [[ -e "$rootfs/lib/$armhf_loader" ]]; then
  loader_target=$armhf_loader
elif [[ -e "$rootfs/usr/lib/$armhf_loader" ]]; then
  if [[ -L "$rootfs/lib" ]]; then
    loader_target=$armhf_loader
  else
    loader_target="../usr/lib/$armhf_loader"
  fi
else
  echo "ARMHF dynamic loader is missing after apply_binaries.sh:" >&2
  find "$rootfs/lib" "$rootfs/usr/lib" -maxdepth 3 \
    -name 'ld-linux-armhf.so*' -print >&2 || true
  exit 1
fi

rm -f "$loader_link"
ln -s "$loader_target" "$loader_link"
if [[ ! -e "$loader_link" ]]; then
  echo "repaired ARMHF loader link is broken: $loader_link -> $loader_target" >&2
  exit 1
fi
echo "ARMHF loader: /lib/ld-linux-armhf.so.3 -> $loader_target"

test -x "$rootfs/usr/bin/qemu-arm-static"
bash "$script_dir/run-in-rootfs.sh" "$rootfs" /bin/true

# initramfs-tools reads /boot/config-<release> to choose a compression format.
# The L4T installer supplies the binary kernel and headers but omits that file.
kernel_dir=$(find "$rootfs/lib/modules" -mindepth 1 -maxdepth 1 \
  -type d -name '3.10*' -print -quit)
if [[ -z "$kernel_dir" ]]; then
  echo "L4T kernel modules were not installed under $rootfs/lib/modules" >&2
  exit 1
fi
kernel_release=${kernel_dir##*/}
kernel_config="$rootfs/boot/config-$kernel_release"
header_config=$(find "$rootfs/usr/src" -maxdepth 4 -type f \
  -path "*$kernel_release*" -name .config -print -quit 2>/dev/null || true)

if [[ -n "$header_config" ]]; then
  install -m 0644 "$header_config" "$kernel_config"
  echo "Installed L4T kernel config from ${header_config#"$rootfs"}"
else
  # R21.8's stock zImage uses an initial ramdisk compressed with gzip. These
  # entries provide the metadata required by modern initramfs-tools when the
  # legacy headers archive does not contain its original .config.
  cat > "$kernel_config" <<EOF
# Compatibility metadata for NVIDIA L4T R21.8 ${kernel_release}
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
EOF
  echo "L4T headers contain no .config; installed gzip initramfs metadata"
fi

for required_option in CONFIG_BLK_DEV_INITRD CONFIG_RD_GZIP; do
  if ! grep -qx "${required_option}=y" "$kernel_config"; then
    echo "$kernel_config does not enable $required_option" >&2
    exit 1
  fi
done
install -d -m 0755 "$rootfs/etc/initramfs-tools/conf.d"
cat > "$rootfs/etc/initramfs-tools/conf.d/tk1-nvidia-compression" <<'EOF'
COMPRESS=gzip
EOF

cat > "$rootfs/tmp/install-cuda.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

cat > /etc/apt/sources.list.d/cuda-6-5.list <<'LIST'
deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1404/armhf /
LIST
apt-get update \
  -o Acquire::AllowInsecureRepositories=true \
  -o Acquire::AllowWeakRepositories=true \
  -o Acquire::Check-Valid-Until=false
apt-get install -y --no-install-recommends --allow-unauthenticated \
  cuda-core-6-5 cuda-command-line-tools-6-5 \
  cuda-cudart-6-5 cuda-cudart-dev-6-5 \
  cuda-cublas-6-5 cuda-cublas-dev-6-5 \
  cuda-cufft-6-5 cuda-cufft-dev-6-5 \
  cuda-curand-6-5 cuda-curand-dev-6-5 \
  cuda-cusparse-6-5 cuda-cusparse-dev-6-5 \
  cuda-npp-6-5 cuda-npp-dev-6-5 cuda-misc-headers-6-5 cuda-license-6-5
rm -f /etc/apt/sources.list.d/cuda-6-5.list

cat > /etc/ld.so.conf.d/cuda-6-5.conf <<'CONF'
/usr/local/cuda-6.5/lib
CONF
cat > /etc/profile.d/cuda-6-5.sh <<'PROFILE'
export CUDA_HOME=/usr/local/cuda-6.5
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
PROFILE

install -d -m 0755 /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-nvidia.conf <<'XORG'
Section "Device"
  Identifier "Tegra K1"
  Driver "nvidia"
EndSection
XORG

ldconfig
test -x /usr/local/cuda-6.5/bin/nvcc
ldconfig -p | grep 'libcuda\.so' >/dev/null
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF
chmod 0755 "$rootfs/tmp/install-cuda.sh"
bash "$script_dir/run-in-rootfs.sh" "$rootfs" /bin/bash /tmp/install-cuda.sh
rm -f "$rootfs/tmp/install-cuda.sh"
