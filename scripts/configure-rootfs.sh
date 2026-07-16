#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
variant=${TK1_VARIANT:?TK1_VARIANT must be nvidia or mainline}

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
  e2fsprogs util-linux rsync xz-utils less vim-tiny \
  alsa-utils ax25-apps ax25-tools batctl iw rtl-sdr wireless-regdb wpasupplicant

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
