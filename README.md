# Jetson TK1 Hybrid OS Factory

This repository builds a **hybrid Linux OS** for NVIDIA Jetson TK1:

- Kernel, DTB and GPU drivers from **NVIDIA L4T 21.8** (Tegra K1, CUDA 6.5 era)
- Userspace based on **Debian 12 (bookworm, armhf)**
- **CUDA 6.5** libraries copied from L4T
- **Docker CE** for ARM32
- Automatically generated **SD/eMMC disk image** with boot + rootfs
- Published as a **GitHub Release** artifact

The result is a modern Debian userspace on top of the legacy Tegra kernel stack, with working GPU, OpenCL, CUDA 6.5 and Docker.

---

## Requirements

You only need:

- A GitHub repository with:
  - `.github/workflows/tk1-os-factory.yml` (this workflow)
  - This `README.md`
- A Jetson TK1 board (for flashing and testing)
- A machine that can write images to SD/eMMC (Linux, macOS, or Windows with appropriate tools)

The workflow runs on `ubuntu-latest` GitHub-hosted runners.

---

## How it works

1. **build-rootfs job**
   - Downloads NVIDIA L4T 21.8 BSP and sample rootfs.
   - Runs `apply_binaries.sh` to get a complete L4T rootfs.
   - Creates a fresh Debian 12 armhf rootfs via `debootstrap`.
   - Configures basic packages (SSH, locales, OpenCL ICD, etc.).
   - Installs Docker CE for armhf.
   - Copies Tegra GPU libraries, firmware, kernel modules and CUDA 6.5 from L4T into the Debian rootfs.
   - Packs the Debian rootfs into `rootfs.ext4`.

2. **build-image job**
   - Creates a FAT32 boot partition image (`boot.vfat`) with:
     - `zImage` (kernel)
     - `tegra124-jetson-tk1.dtb` (device tree)
     - `extlinux.conf` boot configuration
   - Creates a full disk image `jetson-tk1.img`:
     - Partition 1: FAT32 boot (1 MiB–129 MiB)
     - Partition 2: ext4 rootfs (Debian 12)
   - Writes `boot.vfat` and `rootfs.ext4` into the respective partitions.

3. **release job**
   - Downloads `jetson-tk1.img` artifact.
   - Creates a GitHub Release with tag `tk1-l4t21.8-debian12`.
   - Attaches `jetson-tk1.img` to the release.

---

## Running the build

1. Push the workflow file and README to your GitHub repository.
2. Go to **Actions** tab.
3. Select **Jetson TK1 OS Factory** workflow.
4. Click **Run workflow**.

After the run completes:

- Go to **Releases**.
- Download `jetson-tk1.img`.

---

## Flashing the image to SD/eMMC

> **Warning:** This will overwrite the target device. Double-check the device path.

On a Linux host:

```bash
sudo dd if=jetson-tk1.img of=/dev/sdX bs=4M status=progress
sync
