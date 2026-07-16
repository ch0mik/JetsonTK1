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

cat > "$rootfs/tmp/install-cuda.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

cat > /etc/apt/sources.list.d/cuda-6-5.list <<'LIST'
deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1404/armhf /
LIST
apt-get update -o Acquire::AllowInsecureRepositories=true
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
ldconfig -p | grep -q 'libcuda\.so'
ldconfig -p | grep -q 'libOpenCL\.so'
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF
chmod 0755 "$rootfs/tmp/install-cuda.sh"
bash "$script_dir/run-in-rootfs.sh" "$rootfs" /bin/bash /tmp/install-cuda.sh
rm -f "$rootfs/tmp/install-cuda.sh"
