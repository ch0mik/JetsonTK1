#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
variant=${TK1_VARIANT:?TK1_VARIANT must be nvidia or mainline}

# systemd-resolved replaces resolv.conf while it is inactive in the build
# chroot. Preserve the resolver supplied by run-in-rootfs.sh for later steps.
install -m 0644 /etc/resolv.conf /tmp/resolv.conf.build

cat > /etc/apt/sources.list <<'EOF'
deb https://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb https://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 /usr/sbin/policy-rc.d

apt-get update
apt-get install -y --no-install-recommends \
  systemd-sysv systemd-resolved dbus initramfs-tools sudo openssh-server ca-certificates curl gnupg \
  locales tzdata kmod iproute2 iptables nftables net-tools ethtool pciutils usbutils \
  busybox-static e2fsprogs parted util-linux rsync xz-utils less vim-tiny \
  alsa-utils ax25-apps ax25-tools batctl iw rtl-sdr wireless-regdb wpasupplicant

rm -f /etc/resolv.conf
install -m 0644 /tmp/resolv.conf.build /etc/resolv.conf
rm -f /tmp/resolv.conf.build

/bin/busybox --list | grep -Fx udhcpc >/dev/null

install -d -m 0755 \
  /etc/initramfs-tools/hooks \
  /etc/initramfs-tools/scripts/init-premount
cat > /etc/initramfs-tools/hooks/tk1-network-installer <<'EOF'
#!/bin/sh
set -e

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions

for command_name in \
  awk blockdev curl dd e2fsck ip lsblk mkswap parted partprobe sha256sum xz; do
  command_path=$(command -v "$command_name")
  copy_exec "$command_path"
done

copy_exec /bin/busybox /bin/busybox
copy_file config /etc/ssl/certs/ca-certificates.crt
mkdir -p "$DESTDIR/bin"
for applet in awk cat date grep mkfifo reboot rm sha256sum sleep sync tee udhcpc; do
  ln -sf busybox "$DESTDIR/bin/$applet"
done
cat > "$DESTDIR/bin/tk1-udhcpc" <<'UDHCPC'
#!/bin/sh
case "$1" in
  deconfig)
    ip address flush dev "$interface"
    ;;
  bound|renew)
    ip address flush dev "$interface"
    prefix=24
    if [ -n "${subnet:-}" ]; then
      prefix=0
      old_ifs=$IFS
      IFS=.
      set -- $subnet
      IFS=$old_ifs
      for octet in "$@"; do
        case "$octet" in
          255) prefix=$((prefix + 8)) ;;
          254) prefix=$((prefix + 7)) ;;
          252) prefix=$((prefix + 6)) ;;
          248) prefix=$((prefix + 5)) ;;
          240) prefix=$((prefix + 4)) ;;
          224) prefix=$((prefix + 3)) ;;
          192) prefix=$((prefix + 2)) ;;
          128) prefix=$((prefix + 1)) ;;
        esac
      done
    fi
    ip address add "$ip/$prefix" dev "$interface"
    ip link set "$interface" up
    if [ -n "${router:-}" ]; then
      ip route replace default via ${router%% *} dev "$interface"
    fi
    if [ -n "${dns:-}" ]; then
      rm -f /etc/resolv.conf
      : > /etc/resolv.conf
      for dns_server in $dns; do
        echo "nameserver $dns_server" >> /etc/resolv.conf
      done
    fi
    ;;
esac
exit 0
UDHCPC
chmod 0755 "$DESTDIR/bin/tk1-udhcpc"
for module_name in r8169 ahci ahci_tegra libahci sd_mod; do
  manual_add_modules "$module_name" || true
done
EOF
chmod 0755 /etc/initramfs-tools/hooks/tk1-network-installer

cat > /etc/initramfs-tools/scripts/init-premount/tk1-network-installer <<'EOF'
#!/bin/sh

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

case " $(cat /proc/cmdline) " in
  *" tk1_installer=1 "*) ;;
  *) exit 0 ;;
esac

exec </dev/console >/dev/console 2>&1
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -u
set -o pipefail

rescue_shell() {
  echo
  echo "INSTALLER ERROR: $*" >&2
  echo "A rescue shell is starting. Run 'reboot -f' when finished." >&2
  exec sh
}

installer_url=
installer_sha256=
installer_min_sectors=
for parameter in $(cat /proc/cmdline); do
  case "$parameter" in
    tk1_installer_url=*) installer_url=${parameter#*=} ;;
    tk1_installer_sha256=*) installer_sha256=${parameter#*=} ;;
    tk1_installer_min_sectors=*) installer_min_sectors=${parameter#*=} ;;
  esac
done

[ -n "$installer_url" ] || rescue_shell "missing tk1_installer_url"
[ -n "$installer_sha256" ] || rescue_shell "missing tk1_installer_sha256"
[ -n "$installer_min_sectors" ] || rescue_shell "missing tk1_installer_min_sectors"
echo "$installer_sha256" | grep -Eq '^[0-9a-f]{64}$' || \
  rescue_shell "invalid installer SHA256"
case "$installer_min_sectors" in
  *[!0-9]*|'') rescue_shell "invalid rootfs size" ;;
esac

echo "Jetson TK1 network rootfs installer"
echo "Source: $installer_url"
echo "Target: /dev/sda1"
echo

case "$installer_url" in
  https://*)
    current_year=$(date +%Y)
    [ "$current_year" -ge 2024 ] || \
      rescue_shell "system clock is invalid for HTTPS; correct RTC/time or use local HTTP"
    ;;
esac

modprobe r8169 2>/dev/null || true
network_ready=false
for interface_path in /sys/class/net/*; do
  interface=${interface_path##*/}
  [ "$interface" = lo ] && continue
  ip link set "$interface" up 2>/dev/null || continue
  echo "Requesting DHCP lease on $interface..."
  if udhcpc -q -n -t 5 -T 3 -s /bin/tk1-udhcpc -i "$interface"; then
    network_ready=true
    break
  fi
done
[ "$network_ready" = true ] || rescue_shell "DHCP failed on every interface"

echo "Verifying the compressed rootfs before changing the SSD..."
actual_sha256=$(
  curl --fail --location --retry 5 --connect-timeout 15 "$installer_url" |
    sha256sum | awk '{print $1}'
) || rescue_shell "rootfs download failed during verification"
[ "$actual_sha256" = "$installer_sha256" ] || \
  rescue_shell "SHA256 mismatch: expected $installer_sha256, got $actual_sha256"
echo "SHA256 verified: $actual_sha256"

modprobe ahci_tegra 2>/dev/null || true
modprobe tegra_ahci 2>/dev/null || true
modprobe ahci 2>/dev/null || true
modprobe sd_mod 2>/dev/null || true
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ -b /dev/sda ] && break
  sleep 1
done
[ -b /dev/sda ] || rescue_shell "SATA disk /dev/sda was not detected"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL /dev/sda || true

echo
echo "Choose the target layout:"
echo "  1 - keep the partition table and overwrite existing /dev/sda1"
echo "  2 - ERASE /dev/sda and create rootfs plus a 2 GiB swap partition"
printf "Selection [1/2]: "
read -r layout_choice

case "$layout_choice" in
  1)
    [ -b /dev/sda1 ] || rescue_shell "/dev/sda1 does not exist"
    ;;
  2)
    printf "Type ERASE-SDA to destroy the complete /dev/sda disk: "
    read -r erase_confirmation
    [ "$erase_confirmation" = ERASE-SDA ] || rescue_shell "disk erase not confirmed"
    disk_bytes=$(blockdev --getsize64 /dev/sda) || \
      rescue_shell "cannot determine /dev/sda size"
    disk_mib=$((disk_bytes / 1024 / 1024))
    required_mib=$(((installer_min_sectors + 2047) / 2048))
    [ "$disk_mib" -gt $((required_mib + 2048)) ] || \
      rescue_shell "SSD is too small for rootfs plus 2 GiB swap"
    swap_start_mib=$((disk_mib - 2048))
    parted --script /dev/sda mklabel gpt || rescue_shell "cannot create GPT"
    parted --script /dev/sda unit MiB \
      mkpart rootfs ext4 1 "$swap_start_mib" \
      mkpart swap linux-swap "$swap_start_mib" 100% || \
      rescue_shell "cannot create SSD partitions"
    partprobe /dev/sda || true
    udevadm settle 2>/dev/null || sleep 2
    [ -b /dev/sda1 ] || rescue_shell "/dev/sda1 did not appear"
    ;;
  *)
    rescue_shell "invalid layout selection"
    ;;
esac

if grep -qE '^/dev/sda1[[:space:]]' /proc/mounts; then
  rescue_shell "/dev/sda1 is mounted"
fi
partition_sectors=$(blockdev --getsz /dev/sda1) || \
  rescue_shell "cannot determine /dev/sda1 size"
[ "$partition_sectors" -ge "$installer_min_sectors" ] || \
  rescue_shell "/dev/sda1 is smaller than the generated rootfs image"

echo
echo "WARNING: the next operation overwrites /dev/sda1."
printf "Type WRITE-SDA1 to download and install the verified image: "
read -r write_confirmation
[ "$write_confirmation" = WRITE-SDA1 ] || rescue_shell "rootfs write not confirmed"

echo "Writing rootfs to /dev/sda1..."
hash_fifo=/tmp/tk1-rootfs-hash-input
hash_result=/tmp/tk1-rootfs-hash-result
rm -f "$hash_fifo" "$hash_result"
mkfifo "$hash_fifo" || rescue_shell "cannot create checksum pipe"
sha256sum < "$hash_fifo" > "$hash_result" &
hash_pid=$!
write_status=0
curl --fail --location --retry 5 --connect-timeout 15 "$installer_url" |
  tee "$hash_fifo" |
  xz -dc |
  dd of=/dev/sda1 bs=4M iflag=fullblock oflag=direct status=progress || \
  write_status=$?
wait "$hash_pid" || rescue_shell "cannot checksum the installation stream"
rm -f "$hash_fifo"
if [ "$write_status" -ne 0 ]; then
  rescue_shell "download, decompression or SSD write failed"
fi
sync
written_sha256=$(awk '{print $1}' "$hash_result") || \
  rescue_shell "cannot read the installation checksum"
rm -f "$hash_result"
[ "$written_sha256" = "$installer_sha256" ] || \
  rescue_shell "installation stream SHA256 mismatch"
echo "Installation stream SHA256 verified: $written_sha256"

e2fsck -f -y /dev/sda1
e2fsck_status=$?
if [ "$e2fsck_status" -gt 1 ]; then
  rescue_shell "e2fsck failed with status $e2fsck_status"
fi
if [ -b /dev/sda2 ]; then
  mkswap -L swap /dev/sda2 || rescue_shell "cannot initialize /dev/sda2 swap"
fi
sync

echo
echo "Rootfs installation completed successfully."
echo "The default PXE entry will boot Debian from /dev/sda1."
printf "Press Enter to reboot: "
read -r _unused
reboot -f
sleep 3600
EOF
chmod 0755 /etc/initramfs-tools/scripts/init-premount/tk1-network-installer

echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/default/locale
ln -snf /usr/share/zoneinfo/UTC /etc/localtime
echo UTC > /etc/timezone

echo jetson-tk1 > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 jetson-tk1
::1 localhost ip6-localhost ip6-loopback
EOF

if ! id debian >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo debian
fi
for group in audio dialout plugdev; do
  getent group "$group" >/dev/null || groupadd --system "$group"
  usermod --append --groups "$group" debian
done
echo 'debian:debian' | chpasswd
chage -d 0 debian

cat > /etc/fstab <<'EOF'
LABEL=rootfs / ext4 defaults,noatime 0 1
LABEL=BOOT /boot/uboot ext2 defaults,noatime,nofail,x-systemd.device-timeout=5s 0 2
LABEL=swap none swap sw,nofail,x-systemd.device-timeout=5s 0 0
EOF
mkdir -p /boot/uboot

cat > /etc/sysctl.d/90-jetson-tk1-swap.conf <<'EOF'
# Prefer RAM; use the SSD swap only under memory pressure.
vm.swappiness=10
EOF

cat > /usr/local/sbin/tk1-grow-rootfs <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=/var/lib/tk1-grow-rootfs
root_source=$(findmnt --noheadings --output SOURCE /)
root_device=$(readlink -f "$root_source")

if [[ "$root_device" != /dev/sda1 ]]; then
  echo "Root filesystem is $root_device, expected /dev/sda1; skipping resize" >&2
  exit 0
fi

resize2fs "$root_device"
install -d -m 0755 "$state_dir"
touch "$state_dir/done"
EOF
chmod 0755 /usr/local/sbin/tk1-grow-rootfs

cat > /etc/systemd/system/tk1-grow-rootfs.service <<'EOF'
[Unit]
Description=Grow the Jetson TK1 root filesystem to fill /dev/sda1
After=local-fs.target
ConditionPathExists=!/var/lib/tk1-grow-rootfs/done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tk1-grow-rootfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/tk1-rtl2832-mode <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

config=/etc/modprobe.d/tk1-rtl2832-sdr.conf
mode=${1:-status}

case "$mode" in
  sdr)
    ((EUID == 0)) || { echo "run as root: sudo tk1-rtl2832-mode sdr" >&2; exit 1; }
    cat > "$config" <<'BLACKLIST'
# Reserve RTL2832U devices for librtlsdr instead of the kernel DVB stack.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832_sdr
blacklist rtl2832
blacklist rtl2830
BLACKLIST
    if ! modprobe --remove rtl2832_sdr dvb_usb_rtl28xxu rtl2832 rtl2830 2>/dev/null; then
      rm -f "$config"
      echo "stop DVB applications, unplug the tuner and run this command again" >&2
      exit 1
    fi
    echo "RTL2832U mode: SDR (librtlsdr); reconnect the tuner, then run rtl_test"
    ;;
  dvb)
    ((EUID == 0)) || { echo "run as root: sudo tk1-rtl2832-mode dvb" >&2; exit 1; }
    rm -f "$config"
    modprobe dvb_usb_rtl28xxu
    echo "RTL2832U mode: kernel DVB-T; reconnect the tuner if necessary"
    ;;
  status)
    if [[ -e "$config" ]]; then
      echo "configured mode: SDR (librtlsdr)"
    else
      echo "configured mode: kernel DVB-T"
    fi
    lsmod | grep -E 'dvb_usb_rtl28xxu|rtl283[02](_sdr)?' || true
    ;;
  *)
    echo "usage: tk1-rtl2832-mode sdr|dvb|status" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 /usr/local/sbin/tk1-rtl2832-mode

cat > /usr/local/sbin/tk1-set-callsign <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

((EUID == 0)) || { echo "run as root: sudo tk1-set-callsign CALLSIGN" >&2; exit 1; }
callsign=${1:?usage: tk1-set-callsign CALLSIGN}
callsign=$(printf '%s' "$callsign" | tr '[:lower:]' '[:upper:]')
if [[ ! "$callsign" =~ ^[A-Z0-9]{1,6}(-([0-9]|1[0-5]))?$ ]]; then
  echo "invalid AX.25 callsign: $callsign (expected CALL or CALL-0..15)" >&2
  exit 2
fi

cat > /etc/default/tk1-hamradio <<CONFIG
CALLSIGN=$callsign
MESH_ID=HAMNET
CONFIG
install -d -m 0755 /etc/ax25
cat > /etc/ax25/axports <<CONFIG
# name  callsign  speed  paclen  window  description
radio   $callsign  9600   255     2       Jetson TK1 AX.25 port
CONFIG

echo "AX.25 callsign set to $callsign"
echo "reattach the KISS port or restart AX.25 services to apply it"
EOF
chmod 0755 /usr/local/sbin/tk1-set-callsign
/usr/local/sbin/tk1-set-callsign N0CALL

mkdir -p /etc/systemd/network /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
cat > /etc/systemd/network/25-wireless.network <<'EOF'
[Match]
Name=wl*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' 115200,57600,38400,9600 - $TERM
EOF

install -d -m 0755 /etc/apt/keyrings
curl --fail --silent --show-error --location \
  --retry 5 --retry-all-errors --connect-timeout 30 \
  https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: bookworm
Components: stable
Architectures: armhf
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

install -d -m 0755 /etc/docker
if [[ "$variant" == nvidia ]]; then
  apt-get install -y --no-install-recommends xserver-xorg-core xinit
  cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "vfs",
  "log-driver": "local"
}
EOF
else
  apt-get install -y --no-install-recommends \
    firmware-misc-nonfree firmware-realtek libdrm-tegra0 libgl1-mesa-dri \
    mesa-utils xserver-xorg-core xserver-xorg-video-nouveau xinit
  cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "local"
}
EOF
  cat > /etc/modules-load.d/jetson-tk1.conf <<'EOF'
tegra124-cpufreq
br_netfilter
overlay
EOF
fi

test -f /lib/systemd/system/systemd-resolved.service
systemctl enable systemd-networkd.service systemd-resolved.service
systemctl enable ssh.service docker.service serial-getty@ttyS0.service
systemctl enable fstrim.timer tk1-grow-rootfs.service
systemctl set-default multi-user.target

rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
