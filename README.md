# Jetson TK1 OS Factory

This repository builds two experimental Debian 12 (`armhf`) images for the
NVIDIA Jetson TK1. Each factory runs on GitHub-hosted Ubuntu runners and
publishes a flashable SD image plus an archive of the individual boot and
rootfs components.

## Available variants

| Variant | Kernel and graphics | Compute support | Notes |
| --- | --- | --- | --- |
| **NVIDIA** | L4T 21.8 kernel 3.10.40 and proprietary Tegra driver | CUDA 6.5 and OpenCL | Full legacy GPU stack; old, unsupported kernel |
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

- **Jetson TK1 OS Factory - NVIDIA L4T** builds L4T 21.8, CUDA 6.5 and OpenCL.
- **Jetson TK1 OS Factory - Mainline** builds the selected 6.12.x kernel; the
  default is `6.12.95`.

The inputs control root partition size, optional Release tag and whether a
GitHub Release is created. With release publishing disabled, results remain
available as a workflow artifact for 14 days. A normal build produces:

```text
jetson-tk1-<variant>-debian12.img.xz
jetson-tk1-<variant>-debian12-components.tar.xz
jetson-tk1-<variant>-debian12-manifest.txt
SHA256SUMS
```

The components archive contains `rootfs.ext4`, `zImage`, initramfs, the TK1
device tree and `extlinux/extlinux.conf`. Source downloads are checksum-checked;
the L4T value comes from NVIDIA's official R21.8 release hash list.

## Bootloader requirement

The image intentionally does **not** overwrite the Jetson bootloader. The TK1
must already have U-Boot capable of reading an ext2 boot partition and an
extlinux configuration from SD. The approach follows the board assumptions in
[RobertCNelson/netinstall](https://github.com/RobertCNelson/netinstall/blob/master/hwpack/tegra124-jetson-tk1.conf),
which expects the bootloader in onboard flash. If the board only boots the
factory NVIDIA installation, install a suitable TK1 U-Boot first, for example
with NVIDIA's
[tegra-uboot-flasher-scripts](https://github.com/NVIDIA/tegra-uboot-flasher-scripts).

## Verifying and flashing

On a Linux host, verify the downloaded files and write the decompressed image
directly to an SD card:

```bash
sha256sum -c SHA256SUMS
xzcat jetson-tk1-mainline-debian12.img.xz | \
  sudo dd of=/dev/sdX bs=4M iflag=fullblock oflag=direct status=progress
sync
```

Replace `/dev/sdX` with the whole target device, not a partition. This command
destroys all existing data on that device. The image contains a 128 MiB ext2
boot partition and a configurable ext4 root partition labelled `rootfs`.

The initial console account is `debian` with password `debian`. Login over the
115200 baud serial console; the image forces a password change immediately.
SSH host keys are generated on first boot. Change credentials before exposing
the board to an untrusted network.

## Hardware acceptance checks

After first boot, check the common platform services:

```bash
systemctl --failed
ip address
docker run --rm hello-world
```

For NVIDIA, additionally run `clinfo`, `nvcc --version`, a CUDA sample and an
OpenGL/EGL test. For mainline, inspect `dmesg` for Nouveau firmware errors and
run `glxinfo -B`. Mainline requires firmware from Debian's
`non-free-firmware` component.

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
