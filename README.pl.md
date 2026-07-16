# Fabryka systemów dla Jetson TK1

[English](README.md) | **Polski**

Repozytorium buduje dwa eksperymentalne systemy Debian 12 (`armhf`) dla
NVIDIA Jetson TK1. Fabryki działają na runnerach GitHub Actions i publikują
oddzielne obrazy nośnika startowego oraz rootfs dla dysku SATA. Kernel jest
uruchamiany z karty SD lub istniejącej partycji boot eMMC, a Debian montuje SSD
`/dev/sda1` jako `/`.

## Dostępne warianty

| Wariant | Kernel i grafika | Obliczenia GPU | Uwagi |
| --- | --- | --- | --- |
| **NVIDIA** | L4T 21.8, kernel 3.10.40 i własnościowy sterownik Tegra | CUDA 6.5; bez OpenCL | Pełny, historyczny stos GPU; stary i niewspierany kernel |
| **Mainline** | Linux 6.12 LTS, Nouveau i Mesa | Bez CUDA i OpenCL | Nowoczesny kernel, niższa wydajność GPU |

Oba warianty zawierają Debian 12, SSH, sieć DHCP, konsolę szeregową i Docker
CE. Docker używa sterownika `vfs` z kernelem NVIDIA oraz `overlay2` z mainline.

> [!WARNING]
> Obrazy hybrydowe nie są oficjalnymi wydaniami NVIDIA ani Debiana. Stos
> graficzny NVIDIA z epoki Ubuntu 14.04 może być niezgodny ABI ze współczesnymi
> pakietami Debiana. Udany workflow potwierdza budowę, ale nie działanie
> grafiki, CUDA lub Dockera na urządzeniu.

## Uruchamianie fabryki

W zakładce **Actions** wybierz ręcznie uruchamiany workflow:

- **Jetson TK1 OS Factory - NVIDIA L4T** — L4T 21.8 i CUDA 6.5.
- **Jetson TK1 OS Factory - Mainline** — wybrany kernel 6.12.x; domyślnie
  `6.12.95`.

Parametry określają początkowy rozmiar systemu plików root, opcjonalny tag Release i publikację
GitHub Release. Bez publikacji wyniki są dostępne jako artefakt workflow przez
14 dni. Standardowa budowa tworzy:

```text
jetson-tk1-<variant>-debian12-boot-sd.img.xz
jetson-tk1-<variant>-debian12-boot.ext2.xz
jetson-tk1-<variant>-debian12-rootfs.ext4.xz
jetson-tk1-<variant>-debian12-boot-files.tar.xz
jetson-tk1-<variant>-debian12-manifest.txt
SHA256SUMS
```

Archiwum boot zawiera `boot/zImage`, initramfs,
`tegra124-jetson-tk1.dtb` i `boot/extlinux/extlinux.conf`. Plik L4T
`tegra124-jetson_tk1-pm375-000-c00-00.dtb` jest publikowany pod wspólną nazwą
DTB. Konfiguracja używa `root=/dev/sda1 rootwait`; wariant NVIDIA zachowuje też
wymagane parametry pamięci i płyty Tegra. Pobierane źródła są weryfikowane
sumami kontrolnymi.

## Wymagania bootloadera

Obraz celowo **nie nadpisuje** bootloadera Jetsona. TK1 musi mieć U-Boot, który
odczytuje partycję ext2 oraz konfigurację extlinux z SD. Jest to zgodne z
założeniami [RobertCNelson/netinstall](https://github.com/RobertCNelson/netinstall/blob/master/hwpack/tegra124-jetson-tk1.conf),
gdzie bootloader znajduje się w pamięci urządzenia. Odpowiedni U-Boot można
zainstalować przez
[tegra-uboot-flasher-scripts](https://github.com/NVIDIA/tegra-uboot-flasher-scripts).
Nowszy U-Boot z
[instrukcji SQ7MRU](https://sq7mru.blogspot.com/2017/04/u-boot-kompilacja-i-instalowanie.html)
korzysta z tego flashera i jest zgodny z obrazami. Artefakt zawiera zarówno
`/boot/extlinux/extlinux.conf`, jak i `/extlinux/extlinux.conf`.

Przed pierwszym startem sprawdź przez konsolę szeregową 115200 8N1, czy karta
SD jest widoczna w `mmc list` i uwzględniona w `printenv boot_targets`. U-Boot
czyta z SD/eMMC tylko kernel, initramfs i DTB. Rootfs SATA jest montowany później
przez Linux jako `/dev/sda1`.

## Przygotowanie rootfs SATA

Dla SSD 128 GB zalecany układ to duża partycja root `/dev/sda1` oraz partycja
swap 2 GiB jako `/dev/sda2`. Swap jest przydatny przy 2 GB RAM w TK1, zwłaszcza
z Dockerem. Obraz ustawia `vm.swappiness=10`, więc system preferuje RAM i
ogranicza zbędne zapisy na SSD. Utwórz partycje na komputerze z Linuxem
(zastąp `/dev/sdX` dopiero po sprawdzeniu urządzenia):

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

System plików root ma etykietę `rootfs`, ale kernel celowo wybiera `/dev/sda1`.
Swap jest odnajdywany po etykiecie `swap` i jest opcjonalny, więc system
uruchomi się również bez niego. Partycjonowanie i zapis obrazu usuwają całą
dotychczasową zawartość SSD. Wygenerowany rootfs ma co najmniej 14 GiB. Podczas
pierwszego startu `tk1-grow-rootfs.service` rozszerza ext4 do pełnego rozmiaru
`/dev/sda1`; usługa nie zmienia tablicy partycji. Do obsługi SSD włączony jest
cotygodniowy `fstrim.timer`.

## Przygotowanie nośnika boot

Dla dedykowanej karty SD zapisz kompletny obraz boot na całym urządzeniu:

```bash
xzcat jetson-tk1-mainline-debian12-boot-sd.img.xz | \
  sudo dd of=/dev/mmcblkX bs=4M iflag=fullblock oflag=direct status=progress
sync
```

Powstanie MBR i partycja ext2 128 MiB z etykietą `BOOT`. Dla istniejącego
układu SD/eMMC **nie nadpisuj całego urządzenia**. Zapisz `boot.ext2.xz` na
odpowiedniej partycji boot albo rozpakuj `boot-files.tar.xz`:

```bash
sudo mount /dev/mmcblkXp1 /mnt/boot
sudo tar -xJf jetson-tk1-mainline-debian12-boot-files.tar.xz -C /mnt/boot
sync
sudo umount /mnt/boot
```

Dokładnie sprawdź ścieżki urządzeń. `dd` uruchomione dla błędnego SSD, SD lub
eMMC zniszczy znajdujące się tam dane.

Początkowe konto konsoli to `debian`, hasło `debian`. Przy pierwszym logowaniu
przez konsolę szeregową wymagana jest zmiana hasła. Klucze hosta SSH są
generowane podczas pierwszego uruchomienia. Zmień dane logowania przed
podłączeniem urządzenia do niezaufanej sieci.

## Testy na urządzeniu

Po pierwszym starcie sprawdź podstawowe usługi:

```bash
systemctl --failed
ip address
swapon --show
cat /proc/sys/vm/swappiness
findmnt /
systemctl status tk1-grow-rootfs.service
docker run --rm hello-world
```

Dla NVIDIA uruchom też `nvcc --version`, przykład CUDA oraz test OpenGL/EGL.
NVIDIA nie udostępniła obsługiwanej implementacji GPU OpenCL dla Jetson TK1;
sam loader ICD jej nie zapewni. Dla mainline sprawdź błędy firmware Nouveau w
`dmesg` i uruchom `glxinfo -B`. Mainline wymaga firmware z komponentu Debiana
`non-free-firmware`.

## Struktura repozytorium i walidacja

Fabryki znajdują się w `.github/workflows/`. Wspólna logika rootfs, NVIDIA i
budowy obrazów jest w `scripts/`, a fragment konfiguracji kernela Docker/Nouveau
w `scripts/config/`.

Przed wysłaniem zmian uruchom:

```bash
actionlint .github/workflows/*.yml
shellcheck scripts/*.sh
git diff --check
```

Pełna budowa wymaga Linuxa, uprawnień root, emulacji QEMU, montowania loop,
dostępu do sieci i kilku gigabajtów miejsca. Wspieranym środowiskiem budowy jest
GitHub Actions.

## Bezpieczeństwo i status wsparcia

Wariant NVIDIA celowo łączy przestarzały kernel, archiwalne CUDA i nowoczesny
userspace. Nie otrzymuje aktualnych poprawek bezpieczeństwa kernela, a
repozytorium CUDA nie ma współczesnego łańcucha zaufania. Nie używaj go jako
systemu produkcyjnego wystawionego do Internetu. Przed publiczną dystrybucją
artefaktów Release sprawdź licencje NVIDIA L4T/CUDA.
