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
  e2fsprogs util-linux rsync xz-utils less vim-tiny

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

mkdir -p /etc/systemd/network /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

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
curl -fsSL https://download.docker.com/linux/debian/gpg \
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
