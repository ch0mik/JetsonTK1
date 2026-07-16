#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Build the same Jetson TK1 artifacts locally as GitHub Actions.

Usage:
  bash ./scripts/build-local.sh mainline [options]
  bash ./scripts/build-local.sh nvidia [options]

Options:
  --kernel-version VERSION  Mainline kernel version (default: 6.12.95)
  --rootfs-size-mib SIZE     Rootfs image size in MiB (default: 14336)
  --jobs COUNT               Parallel kernel build jobs (default: nproc)
  --output DIRECTORY         Artifact directory (default: release/VARIANT)
  --work-dir DIRECTORY       Temporary build directory (default: .local-build/VARIANT)
  --keep-work                Keep intermediate files after a successful build
  --help                     Show this help

Missing Debian/Ubuntu packages are installed automatically with apt.
The build needs sudo/root, network access, loop mounts, QEMU binfmt and about
25 GiB of free disk space. Failed builds keep their working directory.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

on_error() {
  local status=$?
  echo "error: local build failed at line $1 (exit $status)" >&2
  echo "intermediate files were kept in: $work_dir" >&2
  exit "$status"
}

trap 'on_error $LINENO' ERR

variant=${1:-}
if [[ "$variant" == --help || "$variant" == -h ]]; then
  usage
  exit 0
fi
case "$variant" in
  mainline|nvidia) shift ;;
  *) usage >&2; die "first argument must be mainline or nvidia" ;;
esac

kernel_version=6.12.95
rootfs_size_mib=14336
jobs=$(nproc 2>/dev/null || echo 1)
output=
work_dir=
keep_work=false

while (($#)); do
  case "$1" in
    --kernel-version) kernel_version=${2:?missing value for --kernel-version}; shift 2 ;;
    --rootfs-size-mib) rootfs_size_mib=${2:?missing value for --rootfs-size-mib}; shift 2 ;;
    --jobs) jobs=${2:?missing value for --jobs}; shift 2 ;;
    --output) output=${2:?missing value for --output}; shift 2 ;;
    --work-dir) work_dir=${2:?missing value for --work-dir}; shift 2 ;;
    --keep-work) keep_work=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$rootfs_size_mib" =~ ^[0-9]+$ ]] || die "rootfs size must be numeric"
((rootfs_size_mib >= 14336)) || die "rootfs size must be at least 14336 MiB"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "jobs must be a positive integer"
if [[ "$variant" == mainline && ! "$kernel_version" =~ ^6\.12\.[0-9]+$ ]]; then
  die "mainline kernel version must be a 6.12.x release"
fi

[[ $(uname -s) == Linux ]] || die "this build must run on Linux"
[[ $(uname -m) == x86_64 ]] || die "this build currently supports an x86_64 host"
command -v apt-get >/dev/null || die "apt-get is required (use Debian or Ubuntu)"
command -v dpkg-query >/dev/null || die "dpkg-query is required"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
output=$(realpath -m "${output:-$repo_dir/release/$variant}")
work_dir=$(realpath -m "${work_dir:-$repo_dir/.local-build/$variant}")

[[ "$work_dir" != / && "$work_dir" != "$repo_dir" ]] || die "unsafe work directory: $work_dir"
case "$output/" in
  "$work_dir/"*) die "output directory must not be inside the temporary work directory" ;;
esac

if ((EUID == 0)); then
  root=()
  owner_uid=${SUDO_UID:-0}
  owner_gid=${SUDO_GID:-0}
else
  command -v sudo >/dev/null || die "sudo is required to install packages and create images"
  sudo -v
  root=(sudo)
  owner_uid=$(id -u)
  owner_gid=$(id -g)
fi

common_packages=(
  binfmt-support qemu-user-static debootstrap ca-certificates curl
  bzip2 rsync e2fsprogs parted xz-utils tar util-linux
)
mainline_packages=(
  gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf bc bison
  build-essential flex libssl-dev libelf-dev device-tree-compiler
)
packages=("${common_packages[@]}")
if [[ "$variant" == mainline ]]; then
  packages+=("${mainline_packages[@]}")
fi

missing_packages=()
for package in "${packages[@]}"; do
  if ! dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii '; then
    missing_packages+=("$package")
  fi
done

if ((${#missing_packages[@]})); then
  log "Installing missing host packages: ${missing_packages[*]}"
  "${root[@]}" apt-get update
  "${root[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
else
  log "All required host packages are installed"
fi

required_commands=(curl debootstrap qemu-arm-static mount umount mountpoint chroot)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null || die "required command is unavailable: $command_name"
done
if [[ "$variant" == mainline ]]; then
  for command_name in arm-linux-gnueabihf-gcc make; do
    command -v "$command_name" >/dev/null || die "required command is unavailable: $command_name"
  done
fi

if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
  log "Enabling ARM QEMU binfmt support"
  "${root[@]}" systemctl restart systemd-binfmt.service 2>/dev/null || true
  "${root[@]}" update-binfmts --enable qemu-arm 2>/dev/null || true
fi
[[ -e /proc/sys/fs/binfmt_misc/qemu-arm ]] || \
  die "qemu-arm binfmt is not active; enable binfmt_misc and retry"

available_kib=$(df -Pk "$repo_dir" | awk 'NR == 2 {print $4}')
required_kib=$((25 * 1024 * 1024))
((available_kib >= required_kib)) || \
  die "at least 25 GiB free is required; only $((available_kib / 1024 / 1024)) GiB is available"

log "Preparing local build directory"
"${root[@]}" rm -rf -- "$work_dir"
mkdir -p "$work_dir" "$output"
"${root[@]}" chown "$owner_uid:$owner_gid" "$work_dir" "$output"
base="jetson-tk1-${variant}-debian12"
rm -f -- \
  "$output/$base-boot-files.tar.xz" \
  "$output/$base-pxe.tar.xz" \
  "$output/$base-boot-sd.img.xz" \
  "$output/$base-boot.ext2.xz" \
  "$output/$base-rootfs.ext4.xz" \
  "$output/$base-manifest.txt" \
  "$output/SHA256SUMS"

source_revision=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo local)
cd "$work_dir"

log "Building Debian 12 armhf rootfs ($variant)"
"${root[@]}" bash "$script_dir/build-rootfs.sh" rootfs "$variant"

if [[ "$variant" == mainline ]]; then
  log "Downloading and verifying Linux $kernel_version"
  base_url=https://cdn.kernel.org/pub/linux/kernel/v6.x
  archive="linux-${kernel_version}.tar.xz"
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
    --remote-name "$base_url/$archive"
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
    --output sha256sums.asc "$base_url/sha256sums.asc"
  grep "  $archive$" sha256sums.asc | sha256sum --check --strict
  tar -xf "$archive"

  log "Configuring and building Linux $kernel_version"
  cd "linux-${kernel_version}"
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- tegra_defconfig
  scripts/kconfig/merge_config.sh -m .config "$script_dir/config/kernel-docker.fragment"
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig

  for option in \
    CONFIG_CGROUPS CONFIG_NAMESPACES CONFIG_NET_NS CONFIG_SECCOMP \
    CONFIG_EXT4_FS CONFIG_SCSI CONFIG_BLK_DEV_SD CONFIG_ATA \
    CONFIG_SATA_AHCI CONFIG_AHCI_TEGRA CONFIG_R8169 CONFIG_DRM_TEGRA \
    CONFIG_DRM_TEGRA_STAGING CONFIG_NOUVEAU_PLATFORM_DRIVER \
    CONFIG_FW_LOADER CONFIG_HAMRADIO CONFIG_AX25_DAMA_SLAVE \
    CONFIG_WLAN CONFIG_WLAN_VENDOR_REALTEK CONFIG_MAC80211_MESH \
    CONFIG_BATMAN_ADV_BATMAN_V CONFIG_BATMAN_ADV_BLA \
    CONFIG_BATMAN_ADV_DAT CONFIG_BATMAN_ADV_MCAST \
    CONFIG_USB_SERIAL_GENERIC CONFIG_SOUND CONFIG_SND CONFIG_SND_USB; do
    grep -q "^${option}=y$" .config
  done
  for option in \
    CONFIG_OVERLAY_FS CONFIG_BRIDGE CONFIG_VETH CONFIG_DRM_NOUVEAU \
    CONFIG_AX25 CONFIG_MKISS CONFIG_6PACK CONFIG_BPQETHER \
    CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_BATMAN_ADV \
    CONFIG_VLAN_8021Q CONFIG_RTL8187 CONFIG_RTL8XXXU \
    CONFIG_RTW88_8822BU CONFIG_RTW88_8822CU CONFIG_RTW88_8723DU \
    CONFIG_RTW88_8821CU CONFIG_VFAT_FS CONFIG_EXFAT_FS \
    CONFIG_NTFS3_FS CONFIG_FUSE_FS CONFIG_USB_STORAGE \
    CONFIG_USB_STORAGE_REALTEK CONFIG_USB_UAS \
    CONFIG_USB_ACM CONFIG_USB_SERIAL CONFIG_USB_SERIAL_FTDI_SIO \
    CONFIG_USB_SERIAL_PL2303 CONFIG_USB_SERIAL_CP210X \
    CONFIG_USB_SERIAL_CH341 CONFIG_SND_USB_AUDIO \
    CONFIG_MEDIA_SUPPORT CONFIG_VIDEO_DEV CONFIG_DVB_CORE \
    CONFIG_DVB_USB_RTL28XXU CONFIG_DVB_RTL2832_SDR; do
    grep -Eq "^${option}=(y|m)$" .config
  done

  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j"$jobs" zImage dtbs modules
  kernel_release=$(make -s ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- kernelrelease)
  "${root[@]}" make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
    INSTALL_MOD_PATH="$work_dir/rootfs" INSTALL_MOD_STRIP=1 modules_install
  "${root[@]}" install -m 0644 .config "$work_dir/rootfs/boot/config-$kernel_release"
  "${root[@]}" install -m 0644 System.map "$work_dir/rootfs/boot/System.map-$kernel_release"

  dtb=$(find arch/arm/boot/dts -type f -name tegra124-jetson-tk1.dtb -print -quit)
  [[ -n "$dtb" ]] || die "the Jetson TK1 DTB was not built"
  mkdir -p "$work_dir/kernel-out"
  cp arch/arm/boot/zImage "$work_dir/kernel-out/zImage"
  cp "$dtb" "$work_dir/kernel-out/tegra124-jetson-tk1.dtb"
  cd "$work_dir"
else
  l4t_version=R21.8
  l4t_archive=Tegra124_Linux_R21.8.0_armhf.tbz2
  l4t_sha1=5a1ebb2cc1f851ef36baa19736500588efeb9756
  l4t_url="https://developer.download.nvidia.com/embedded/L4T/r21_Release_v8.0/release_files/$l4t_archive"

  log "Downloading and verifying NVIDIA L4T $l4t_version"
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
    --output "$l4t_archive" "$l4t_url"
  echo "$l4t_sha1  $l4t_archive" | sha1sum --check --strict
  tar -xjf "$l4t_archive"

  log "Installing NVIDIA drivers and CUDA 6.5"
  "${root[@]}" bash "$script_dir/install-nvidia-userspace.sh" rootfs Linux_for_Tegra
  zimage=Linux_for_Tegra/kernel/zImage
  dtb=Linux_for_Tegra/kernel/dtb/tegra124-jetson_tk1-pm375-000-c00-00.dtb
  [[ -s "$zimage" && -s "$dtb" ]] || die "the L4T kernel or DTB is missing"
  mkdir -p kernel-out
  cp "$zimage" kernel-out/zImage
  cp "$dtb" kernel-out/tegra124-jetson-tk1.dtb
  kernel_dir=$(find rootfs/lib/modules -mindepth 1 -maxdepth 1 -type d -name '3.10*' -print -quit)
  [[ -n "$kernel_dir" ]] || die "the installed L4T kernel modules are missing"
  kernel_release=${kernel_dir##*/}
fi

log "Finalizing rootfs and creating release images"
"${root[@]}" bash "$script_dir/finalize-rootfs.sh" rootfs "$kernel_release"
"${root[@]}" env \
  GITHUB_SHA="$source_revision" GITHUB_RUN_ID=local ROOTFS_SIZE_MIB="$rootfs_size_mib" \
  bash "$script_dir/build-image.sh" \
    rootfs "$variant" kernel-out/zImage kernel-out/tegra124-jetson-tk1.dtb \
    "$kernel_release" "$output"
"${root[@]}" chown -R "$owner_uid:$owner_gid" "$output"

log "Verifying release payload"
cd "$output"
sha256sum --check SHA256SUMS
for artifact in \
  "$base-boot-files.tar.xz" "$base-pxe.tar.xz" "$base-boot-sd.img.xz" \
  "$base-boot.ext2.xz" "$base-rootfs.ext4.xz" "$base-manifest.txt"; do
  [[ -s "$artifact" ]] || die "missing or empty artifact: $artifact"
done
tar -xOf "$base-boot-files.tar.xz" ./boot/extlinux/extlinux.conf | \
  grep -F 'root=/dev/sda1' >/dev/null
tar -xOf "$base-pxe.tar.xz" ./pxelinux.cfg/default | \
  grep -F 'root=/dev/sda1' >/dev/null
for path in \
  ./pxe ./pxelinux.cfg/default "./$base/zImage" "./$base/initrd.img" \
  "./$base/tegra124-jetson-tk1.dtb" "./$base/manifest.txt" \
  "./$base/rootfs.sha256"; do
  tar -tf "$base-pxe.tar.xz" | grep -Fx "$path" >/dev/null
done
pxe_config=$(tar -xOf "$base-pxe.tar.xz" ./pxelinux.cfg/default)
grep -F 'LABEL install-rootfs-local' <<<"$pxe_config" >/dev/null
grep -F 'tk1_installer=1' <<<"$pxe_config" >/dev/null
grep -F 'tk1_installer_url=http://${serverip}:8080/' <<<"$pxe_config" >/dev/null
grep -Eq 'tk1_installer_sha256=[0-9a-f]{64}' <<<"$pxe_config"
rootfs_sha256=$(sha256sum "$base-rootfs.ext4.xz" | awk '{print $1}')
grep -F "tk1_installer_sha256=$rootfs_sha256" <<<"$pxe_config" >/dev/null
test "$(tar -xOf "$base-pxe.tar.xz" "./$base/rootfs.sha256" | awk '{print $1}')" = \
  "$rootfs_sha256"
if [[ "$variant" == nvidia ]]; then
  tar -xOf "$base-boot-files.tar.xz" ./boot/extlinux/extlinux.conf | \
    grep -F 'mem=2015M@2048M' >/dev/null
  tar -xOf "$base-pxe.tar.xz" ./pxelinux.cfg/default | \
    grep -F 'mem=2015M@2048M' >/dev/null
fi

if [[ "$keep_work" == false ]]; then
  log "Removing successful build intermediates"
  cd "$repo_dir"
  "${root[@]}" rm -rf -- "$work_dir"
fi

trap - ERR
printf '\nBuild completed successfully. Artifacts:\n'
find "$output" -maxdepth 1 -type f -printf '  %f\n' | sort
printf 'Output directory: %s\n' "$output"
