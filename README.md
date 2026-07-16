# Jetson TK1 OS Factory

**English** | [Polski](README.pl.md)

This repository builds two experimental Debian 12 (`armhf`) systems for the
NVIDIA Jetson TK1. Each factory runs on GitHub-hosted Ubuntu runners and
publishes separate boot media and SATA rootfs images. The kernel boots from SD
or an existing eMMC boot partition; Debian mounts the SSD at `/dev/sda1` as `/`.

## Available variants

| Variant | Kernel and graphics | Compute support | Notes |
| --- | --- | --- | --- |
| **NVIDIA** | L4T 21.8 kernel 3.10.40 and proprietary Tegra driver | CUDA 6.5; no OpenCL | Full legacy GPU stack; old, unsupported kernel |
| **Mainline** | Linux 6.12 LTS, Nouveau and Mesa | No CUDA or OpenCL | Modern kernel and lower GPU performance |

Both variants contain Debian 12, SSH, DHCP networking, a serial console and
Docker CE. Docker uses `vfs` on the NVIDIA kernel for compatibility and
`overlay2` on mainline.

> [!WARNING]
> These hybrid images are not official NVIDIA or Debian releases. In
> particular, NVIDIA's Ubuntu 14.04-era graphics userspace and current Debian
> packages may have ABI incompatibilities. Treat a successful workflow as a
> build validation, not proof that graphics, CUDA or Docker work on hardware.

## Running a factory

Open **Actions** and select one of the manually dispatched workflows:

- **Jetson TK1 OS Factory - NVIDIA L4T** builds L4T 21.8 and CUDA 6.5.
- **Jetson TK1 OS Factory - Mainline** builds the selected 6.12.x kernel; the
  default is `6.12.95`.

The inputs control initial root filesystem size, optional Release tag and whether a
GitHub Release is created. With release publishing disabled, results remain
available as a workflow artifact for 14 days. A normal build produces:

```text
jetson-tk1-<variant>-debian12-boot-sd.img.xz
jetson-tk1-<variant>-debian12-boot.ext2.xz
jetson-tk1-<variant>-debian12-rootfs.ext4.xz
jetson-tk1-<variant>-debian12-boot-files.tar.xz
jetson-tk1-<variant>-debian12-manifest.txt
SHA256SUMS
```

The boot files archive contains `boot/zImage`, initramfs,
`tegra124-jetson-tk1.dtb` and `boot/extlinux/extlinux.conf`. L4T's board-specific
`tegra124-jetson_tk1-pm375-000-c00-00.dtb` is published under that common DTB
name. The configuration uses `root=/dev/sda1 rootwait`; the NVIDIA variant also
retains L4T's required Tegra memory and board arguments. Source downloads are
checksum-checked; the L4T value comes from NVIDIA's official R21.8 release hash
list.

## Bootloader requirement

The image intentionally does **not** overwrite the Jetson bootloader. The TK1
must already have U-Boot capable of reading an ext2 boot partition and an
extlinux configuration from SD. The approach follows the board assumptions in
[RobertCNelson/netinstall](https://github.com/RobertCNelson/netinstall/blob/master/hwpack/tegra124-jetson-tk1.conf),
which expects the bootloader in onboard flash. If the board only boots the
factory NVIDIA installation, install a suitable TK1 U-Boot first, for example
with NVIDIA's
[tegra-uboot-flasher-scripts](https://github.com/NVIDIA/tegra-uboot-flasher-scripts).
The newer U-Boot installed with the procedure in
[SQ7MRU's Jetson TK1 guide](https://sq7mru.blogspot.com/2017/04/u-boot-kompilacja-i-instalowanie.html)
uses that flasher and is suitable for these images. The boot artifact contains
both `/boot/extlinux/extlinux.conf` and `/extlinux/extlinux.conf`, so it covers
the standard U-Boot distro-boot search prefixes.

Before the first boot, use the serial console (115200 8N1) to verify that the
SD interface is present in `mmc list` and included in `printenv boot_targets`.
U-Boot only reads the kernel, initramfs and DTB from SD/eMMC; it does not need
to understand the SATA filesystem. Linux mounts the SSD later as `/dev/sda1`.

## Preparing the SATA rootfs

For a 128 GB SSD, the recommended layout is a large `/dev/sda1` root partition
and a 2 GiB `/dev/sda2` swap partition. Swap is useful on the TK1's 2 GB RAM,
especially with Docker. The image sets `vm.swappiness=10`, so normal operation
prefers RAM and limits unnecessary SSD writes. Create the layout on a Linux
host (replace `/dev/sdX` only after verifying the target disk):

```bash
disk=/dev/sdX
end_mib=$(( $(sudo blockdev --getsize64 "$disk") / 1024 / 1024 ))
swap_start_mib=$(( end_mib - 2048 ))
sudo parted --script "$disk" mklabel gpt
sudo parted --script "$disk" unit MiB \
  mkpart rootfs ext4 1 "$swap_start_mib" \
  mkpart swap linux-swap "$swap_start_mib" 100%
sudo partprobe "$disk"

sha256sum -c SHA256SUMS
xzcat jetson-tk1-mainline-debian12-rootfs.ext4.xz | \
sudo dd of="${disk}1" bs=4M iflag=fullblock oflag=direct status=progress
sudo e2fsck -f "${disk}1"
sudo mkswap -L swap "${disk}2"
sync
```

The root filesystem is labelled `rootfs`, but the kernel command line
intentionally selects it as `/dev/sda1`. Swap is found by the `swap` label and
is optional, so the system still boots without it. Partitioning and writing the
image destroy all existing data on the target SSD. The generated rootfs is at
least 14 GiB. On first boot, `tk1-grow-rootfs.service` expands its ext4
filesystem to fill `/dev/sda1`; it does not alter the partition table. A weekly
`fstrim.timer` is enabled for SSD maintenance.

## Preparing boot media

For a dedicated SD card, write the complete boot-only image to the whole card:

```bash
xzcat jetson-tk1-mainline-debian12-boot-sd.img.xz | \
  sudo dd of=/dev/mmcblkX bs=4M iflag=fullblock oflag=direct status=progress
sync
```

This creates an MBR and a 128 MiB ext2 partition labelled `BOOT`. For an
existing SD/eMMC layout, do **not** overwrite the whole device. Write
`boot.ext2.xz` only to a suitably sized boot partition, or extract
`boot-files.tar.xz` into its mounted filesystem:

```bash
sudo mount /dev/mmcblkXp1 /mnt/boot
sudo tar -xJf jetson-tk1-mainline-debian12-boot-files.tar.xz -C /mnt/boot
sync
sudo umount /mnt/boot
```

Double-check every device path. `dd` against the wrong SSD, SD card or eMMC
partition destroys its existing contents.

The initial console account is `debian` with password `debian`. Login over the
115200 baud serial console; the image forces a password change immediately.
SSH host keys are generated on first boot. Change credentials before exposing
the board to an untrusted network.

## Hardware acceptance checks

After first boot, check the common platform services:

```bash
systemctl --failed
ip address
swapon --show
cat /proc/sys/vm/swappiness
findmnt /
systemctl status tk1-grow-rootfs.service
docker run --rm hello-world
```

For NVIDIA, additionally run `nvcc --version`, a CUDA sample and an OpenGL/EGL
test. NVIDIA never shipped supported GPU OpenCL for Jetson TK1; installing a
generic ICD loader would not add an OpenCL implementation. For mainline,
inspect `dmesg` for Nouveau firmware errors and run `glxinfo -B`. Mainline
requires firmware from Debian's `non-free-firmware` component.

## Repository layout and local validation

The two factories live in `.github/workflows/`. Reusable rootfs, NVIDIA and
image-building logic is in `scripts/`; the mainline Docker/Nouveau kernel
fragment is in `scripts/config/`.

Before pushing workflow changes, run:

```bash
actionlint .github/workflows/*.yml
shellcheck scripts/*.sh
git diff --check
```

Full builds need Linux, root privileges, QEMU user emulation, loop mounts,
network access and several gigabytes of free disk space, so GitHub Actions is
the supported build environment.

## Security and support status

The NVIDIA image deliberately combines an obsolete kernel and archived CUDA
packages with a modern userspace. It receives no current kernel security fixes,
and its CUDA repository no longer provides a modern trust chain. Do not use it
for an internet-facing production system. Review NVIDIA's L4T/CUDA license
terms before redistributing public Release artifacts.
