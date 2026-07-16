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
The mainline kernel includes AX.25 packet-radio modules, including KISS, 6PACK
and BPQ Ethernet support. It also includes firmware and drivers for common
Realtek Wi-Fi adapters, USB storage, USB audio, USB serial adapters and RTL2832U
devices used as RTL-SDR receivers.

For HAMNET networks, the mainline kernel supports native 802.11s Wi-Fi mesh,
BATMAN-adv (BATMAN IV/V, BLA, DAT and multicast optimisation), and 802.1Q VLANs.
The image also includes `batctl`. Check that the adapter advertises `mesh point`
mode before building a node:

```bash
iw list
```

Example setup (select frequency and channel width according to your licence,
band plan, and local HAMNET configuration):

```bash
frequency_mhz=2412  # replace according to the local HAMNET band plan
sudo iw phy phy0 interface add mesh0 type mp
sudo ip link set mesh0 up
sudo iw dev mesh0 mesh join HAMNET freq "$frequency_mhz" HT20
sudo modprobe batman-adv
sudo batctl meshif bat0 interface add mesh0
sudo ip link set bat0 up
```

Not every Realtek chipset and firmware supports mesh mode or concurrent
station/mesh interfaces; the capabilities reported by `iw list` are decisive.

### Callsign

The default AX.25 callsign is the neutral `N0CALL`. It is stored in
`/etc/default/tk1-hamradio` and as the `radio` port callsign in
`/etc/ax25/axports`. To change it after installation, run on the Jetson:

```bash
new_callsign=SQ7MRU  # enter your callsign here instead of N0CALL
sudo tk1-set-callsign "$new_callsign"
cat /etc/default/tk1-hamradio
cat /etc/ax25/axports
```

The base callsign may contain up to six characters, with an optional SSID from
`-0` to `-15`, for example `SQ7MRU-7`. Reattach the KISS port or restart AX.25
services after changing it. `MESH_ID=HAMNET` remains common to all mesh nodes
and should not be replaced with an individual callsign.

An RTL2832U tuner can be controlled by the kernel DVB-T stack or directly by
`librtlsdr`, but not by both at once. Kernel DVB-T is the default. Switch modes
with:

```bash
sudo tk1-rtl2832-mode sdr  # rtl_test, rtl_fm, rtl_tcp, etc.
sudo tk1-rtl2832-mode dvb  # restore kernel DVB-T
tk1-rtl2832-mode status
```

SDR mode blacklists `dvb_usb_rtl28xxu`, `rtl2832_sdr`, `rtl2832` and `rtl2830`.
Reconnect the tuner after switching. The construction
`sudo echo ... > /etc/modprobe.d/...` is incorrect because the redirection does
not run under `sudo`; use `sudo tee` when configuring this manually.

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
jetson-tk1-<variant>-debian12-pxe.tar.xz
jetson-tk1-<variant>-debian12-manifest.txt
SHA256SUMS
```

### Using the generated files

For normal distribution, keep these files as GitHub Release assets. A workflow
artifact is the temporary copy used between jobs and for builds where Release
publishing is disabled. GitHub Packages is not used because it accepts package
manager formats and Docker/OCI images, not raw disk or filesystem images.

If downloaded from **Actions**, extract the artifact ZIP first. If downloaded
from **Releases**, put all files from one release in the same directory. Then
verify them before writing anything to removable media:

```bash
sha256sum -c SHA256SUMS
```

The root filesystem image is required, followed by exactly one of the four
boot deployment methods:

| Generated file | Purpose and next step |
| --- | --- |
| `*-rootfs.ext4.xz` | Required: write it to the SATA SSD partition `/dev/sda1`. |
| `*-boot-sd.img.xz` | Easiest option for a dedicated SD card: write it to the whole card. |
| `*-boot.ext2.xz` | Write it to an existing dedicated boot partition; it replaces that partition. |
| `*-boot-files.tar.xz` | Non-destructive alternative: extract the boot files onto an already formatted boot partition. |
| `*-pxe.tar.xz` | TFTP tree with separate normal-boot and SATA rootfs installer menu entries. |
| `*-manifest.txt` | Build metadata for identification and troubleshooting; do not flash it. |
| `SHA256SUMS` | Checksums for verifying every generated file. |

Do not deploy all four boot variants. Choose the one matching the existing
boot-media layout, then follow **Preparing the SATA rootfs** and **Preparing
boot media** below.

### Building locally

The same artifacts can be built on a 64-bit Debian or Ubuntu host. The script
checks required packages, installs missing ones with `apt`, enables ARM QEMU
emulation, builds the rootfs and kernel, and verifies the result like the
GitHub Actions workflows. It needs `sudo`, internet access, loop mounts and
about 25 GiB of free space.

```bash
# Linux 6.12.95 + Nouveau
bash ./scripts/build-local.sh mainline

# NVIDIA L4T 21.8 + CUDA 6.5
bash ./scripts/build-local.sh nvidia
```

Results are written to `release/mainline/` or `release/nvidia/`. Options can be
overridden, for example:

```bash
bash ./scripts/build-local.sh mainline \
  --kernel-version 6.12.95 \
  --rootfs-size-mib 14336 \
  --jobs 8 \
  --keep-work
```

Run `bash ./scripts/build-local.sh --help` for all options. Do not run it from Git
Bash or directly on Windows; use native Linux or a virtual machine with loop
mount support. WSL can work only when its environment permits `binfmt_misc`,
chroot and loop-device mounts.

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

This step is required for SD/eMMC boot. Write the rootfs manually as described
below, or use the separate PXE installer entry documented under **PXE/TFTP
network boot and rootfs installation**. Download `*-rootfs.ext4.xz` and
`SHA256SUMS` from the same Release.

For a 128 GB SSD, the recommended layout is a large `/dev/sda1` root partition
and a 2 GiB `/dev/sda2` swap partition. Swap is useful on the TK1's 2 GB RAM,
especially with Docker. The image sets `vm.swappiness=10`, so normal operation
prefers RAM and limits unnecessary SSD writes. Create the layout on a Linux
host (replace `/dev/sdX` only after verifying the target disk):

```bash
disk=/dev/sdX
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$disk"

# Stop if either target partition is mounted.
if findmnt -rn -S "${disk}1" >/dev/null || \
   findmnt -rn -S "${disk}2" >/dev/null; then
  echo "target SSD is mounted; unmount it before continuing" >&2
  exit 1
fi

end_mib=$(( $(sudo blockdev --getsize64 "$disk") / 1024 / 1024 ))
swap_start_mib=$(( end_mib - 2048 ))
sudo parted --script "$disk" mklabel gpt
sudo parted --script "$disk" unit MiB \
  mkpart rootfs ext4 1 "$swap_start_mib" \
  mkpart swap linux-swap "$swap_start_mib" 100%
sudo partprobe "$disk"

grep 'rootfs\.ext4\.xz$' SHA256SUMS | sha256sum -c -
xzcat jetson-tk1-mainline-debian12-rootfs.ext4.xz | \
sudo dd of="${disk}1" bs=4M iflag=fullblock oflag=direct status=progress
sudo e2fsck -f "${disk}1"
sudo mkswap -L swap "${disk}2"
sync
```

If the SSD already has a sufficiently large `/dev/sda1` and optional
`/dev/sda2`, do not recreate its partition table. On the Jetson rescue system,
place the downloaded files on another filesystem and use:

```bash
grep 'rootfs\.ext4\.xz$' SHA256SUMS | sha256sum -c -
if findmnt -rn -S /dev/sda1 >/dev/null; then
  echo "/dev/sda1 is mounted; refusing to overwrite it" >&2
  exit 1
fi
xzcat jetson-tk1-mainline-debian12-rootfs.ext4.xz | \
  sudo dd of=/dev/sda1 bs=4M iflag=fullblock oflag=direct status=progress
sudo e2fsck -f /dev/sda1
sudo mkswap -L swap /dev/sda2  # omit when there is no swap partition
sync
```

`*-rootfs.ext4.xz` is a filesystem image, not a whole-disk image. Always write
it to `/dev/sda1` (or `${disk}1` on the preparation host), **never to
`/dev/sda` or `${disk}`**. After this step, PXE can load the boot files over
TFTP and Linux will mount the prepared SSD as its root filesystem.

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

## PXE/TFTP network boot and rootfs installation

An artifact published as a GitHub Release provides three PXE menu entries:

- **Boot Debian 12 from existing SATA `/dev/sda1`** — normal default boot;
- **INSTALL rootfs from GitHub HTTPS (DESTRUCTIVE)** — downloads directly from
  the matching GitHub Release;
- **INSTALL rootfs from local HTTP (DESTRUCTIVE)** — downloads from the local
  `${serverip}:8080` server.

TFTP delivers the kernel, initramfs, DTB and menu. The large
`rootfs.ext4.xz` can come from GitHub HTTPS or local HTTP and is streamed
through `xz | dd` with retries and SHA-256 checking. A build without Release
publishing only includes the local entry because no GitHub asset exists yet.

The example below uses an isolated provisioning network, server address
`192.168.50.1` and interface `enp3s0`. Adjust them for the server. Never start
a second DHCP service on a normal home or office network.

### Step 1: prepare the files

Always download the PXE archive and `SHA256SUMS` from the same Release, verify
the archive and extract it:

```bash
grep -- '-pxe\.tar\.xz$' SHA256SUMS | sha256sum -c -
sudo install -d -m 0755 /srv/tftp
sudo tar -xJf jetson-tk1-mainline-debian12-pxe.tar.xz -C /srv/tftp
find /srv/tftp -maxdepth 3 -type f -print
```

For local HTTP only, also download, verify and copy the rootfs:

```bash
grep -- '-rootfs\.ext4\.xz$' SHA256SUMS | sha256sum -c -
sudo install -m 0644 jetson-tk1-mainline-debian12-rootfs.ext4.xz /srv/tftp/
```

Use `nvidia` instead of `mainline` for the NVIDIA variant. The same directory
is served through TFTP and HTTP:

```text
/srv/tftp/
├── pxelinux.cfg/default
├── README-PXE.txt
├── pxe
├── jetson-tk1-mainline-debian12-rootfs.ext4.xz  # local HTTP only
└── jetson-tk1-mainline-debian12/
    ├── zImage
    ├── initrd.img
    ├── tegra124-jetson-tk1.dtb
    ├── manifest.txt
    └── rootfs.sha256
```

### Step 2: start DHCP and TFTP

The Jetson needs U-Boot with Ethernet, DHCP, TFTP and the `pxe` command.
`dnsmasq` provides a simple server for a dedicated interface:

```bash
sudo apt-get install dnsmasq python3
sudo ip address add 192.168.50.1/24 dev enp3s0
sudo ip link set enp3s0 up
```

Create `/etc/dnsmasq.d/jetson-tk1-pxe.conf`:

```ini
interface=enp3s0
bind-interfaces
dhcp-range=192.168.50.20,192.168.50.50,255.255.255.0,1h
dhcp-option=3
enable-tftp
tftp-root=/srv/tftp
dhcp-boot=pxe
log-dhcp
```

The empty `dhcp-option=3` avoids advertising a gateway on the isolated link, so
this configuration is intended for local HTTP installation. GitHub download
requires DHCP to provide a working gateway and DNS plus Internet access. If
DHCP already exists, do not start another server: configure its next-server or
option 66 for TFTP and boot filename or option 67 as `pxe`.

```bash
sudo dnsmasq --test
sudo systemctl restart dnsmasq
sudo journalctl -u dnsmasq -f
```

### Step 3: select the image source

**GitHub HTTPS:** do not start local HTTP. Ensure the Release is public and the
Jetson receives a gateway and DNS from DHCP and can reach `github.com`. Select
**INSTALL rootfs from GitHub HTTPS** in the menu. GitHub Actions embeds the
exact Release tag and asset URL in the PXE artifact. The Jetson RTC must hold a
valid date for TLS certificate verification; correct it or use local HTTP if
the installer reports an invalid clock.

**Local HTTP:** this also works without Internet. The recommended server is
defined by `docker/pxe-http/Dockerfile`; `compose.pxe-http.yml` mounts
`/srv/tftp` read-only. From the repository root, run:

```text
host: ${PXE_FILES_DIR:-/srv/tftp}  ->  container: /srv/files (read-only)
```

Dockerfile `ADD` or `COPY` is intentionally not used for artifacts: it would
bake the multi-gigabyte rootfs into an image layer and require rebuilding the
image after every file change. The bind mount exposes the host directory's
current contents.

```bash
PXE_FILES_DIR=/srv/tftp PXE_HTTP_BIND=192.168.50.1 \
  docker compose -f compose.pxe-http.yml up --build -d
docker compose -f compose.pxe-http.yml ps
curl --fail http://192.168.50.1:8080/healthz
curl --fail --head \
  http://192.168.50.1:8080/jetson-tk1-mainline-debian12-rootfs.ext4.xz
```

Select **INSTALL rootfs from local HTTP** in the menu. This simple server has
no authentication or encryption. Use it only on a trusted isolated network
and stop it after installation. TCP port 8080 must be reachable from the
Jetson. To follow logs and stop the container:

```bash
docker compose -f compose.pxe-http.yml logs -f pxe-http
docker compose -f compose.pxe-http.yml down
```

Without Compose, build and run the same Dockerfile directly:

```bash
docker build -t jetson-tk1-pxe-http:local docker/pxe-http
docker run --rm --name jetson-tk1-pxe-http \
  --read-only --tmpfs /tmp:size=16m,mode=1777 \
  --cap-drop ALL --security-opt no-new-privileges \
  -p 192.168.50.1:8080:8080 \
  -v /srv/tftp:/srv/files:ro \
  jetson-tk1-pxe-http:local
```

As a no-Docker fallback, use
`cd /srv/tftp && python3 -m http.server 8080 --bind 192.168.50.1`.

### Step 4: open the PXE menu on the serial console

Connect at 115200 8N1, interrupt U-Boot autoboot and run:

```text
=> help pxe
=> printenv pxefile_addr_r kernel_addr_r ramdisk_addr_r fdt_addr_r
=> setenv autoload no
=> dhcp
=> setenv bootfile pxe
=> pxe get
=> pxe boot
```

Select either **GitHub HTTPS** or **local HTTP** installation with the menu
keys. Both entries write `/dev/sda1`. The timeout starts normal boot, never the
installer. If `help pxe` or a load address is missing, update U-Boot. Some
distro-boot versions can also use `run bootcmd_pxe`. See the U-Boot
[PXE format and command documentation](https://docs.u-boot.org/en/stable/usage/pxe.html).

### Step 5: confirm the SSD write

The installer performs these operations in order:

1. downloads without writing and compares SHA-256 with the value embedded in
   the PXE menu;
2. displays `/dev/sda` and either preserves its partition table or, after the
   exact `ERASE-SDA` confirmation, creates GPT rootfs plus 2 GiB swap;
3. checks that `/dev/sda1` exists, is not mounted and is large enough;
4. requires `WRITE-SDA1`, downloads again and streams the image to the
   partition while also checking the second transfer's SHA-256;
5. runs `e2fsck`, initializes optional `/dev/sda2` swap and offers to reboot.

Power or network loss during the write leaves an incomplete rootfs; start the
installer again. `ERASE-SDA` destroys all of `/dev/sda`, while normal mode
overwrites all of `/dev/sda1`.

### Step 6: boot the installed system

After reboot, run `pxe get` and `pxe boot` again or configure `boot_targets`.
Leave **Boot Debian 12 from existing SATA `/dev/sda1`** selected. TFTP supplies
the boot files and Linux mounts the new SSD rootfs. HTTP is not needed for
normal boot.

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
