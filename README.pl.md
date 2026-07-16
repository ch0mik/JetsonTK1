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
Kernel mainline zawiera moduły AX.25 dla packet radio, w tym KISS, 6PACK i BPQ
Ethernet. Zawiera też firmware i sterowniki popularnych kart Wi-Fi Realtek,
pamięci masowej USB, kart dźwiękowych USB, adapterów szeregowych USB oraz
tunerów RTL2832U używanych jako RTL-SDR.

Dla sieci HAMNET kernel mainline obsługuje natywny mesh Wi-Fi 802.11s,
BATMAN-adv (BATMAN IV/V, BLA, DAT i optymalizację multicastu) oraz VLAN 802.1Q.
W obrazie znajduje się też `batctl`. Przed budową węzła sprawdź, czy karta
udostępnia tryb `mesh point`:

```bash
iw list
```

Przykładowe utworzenie interfejsu (częstotliwość i szerokość kanału dobierz
zgodnie z pozwoleniem, bandplanem i konfiguracją lokalnej sieci HAMNET):

```bash
frequency_mhz=2412  # zmień zgodnie z lokalnym bandplanem HAMNET
sudo iw phy phy0 interface add mesh0 type mp
sudo ip link set mesh0 up
sudo iw dev mesh0 mesh join HAMNET freq "$frequency_mhz" HT20
sudo modprobe batman-adv
sudo batctl meshif bat0 interface add mesh0
sudo ip link set bat0 up
```

Nie każdy układ Realtek i nie każdy jego firmware wspiera tryb mesh lub
jednoczesną pracę interfejsów station/mesh; wynik `iw list` jest rozstrzygający.

### Znak wywoławczy

Domyślny znak AX.25 to neutralny `N0CALL`. Jest zapisany w
`/etc/default/tk1-hamradio` oraz jako znak portu `radio` w
`/etc/ax25/axports`. Aby zmienić go po instalacji, uruchom na Jetsonie:

```bash
new_callsign=SQ7MRU  # tutaj wpisz swój znak zamiast N0CALL
sudo tk1-set-callsign "$new_callsign"
cat /etc/default/tk1-hamradio
cat /etc/ax25/axports
```

Dozwolony jest znak bazowy do sześciu znaków oraz opcjonalny SSID od `-0` do
`-15`, na przykład `SQ7MRU-7`. Po zmianie ponownie podłącz port KISS albo
zrestartuj usługi AX.25. `MESH_ID=HAMNET` pozostaje wspólne dla wszystkich
węzłów mesh i nie powinno być zastępowane indywidualnym znakiem.

Tuner RTL2832U może działać jako urządzenie DVB-T sterowane przez kernel albo
bezpośrednio przez `librtlsdr`, ale nie w obu trybach jednocześnie. Domyślnie
aktywny jest DVB-T. Tryb można przełączyć poleceniami:

```bash
sudo tk1-rtl2832-mode sdr  # rtl_test, rtl_fm, rtl_tcp itd.
sudo tk1-rtl2832-mode dvb  # powrót do kernelowego DVB-T
tk1-rtl2832-mode status
```

Tryb SDR tworzy blacklistę dla `dvb_usb_rtl28xxu`, `rtl2832_sdr`, `rtl2832` i
`rtl2830`. Po przełączeniu odłącz i ponownie podłącz tuner. Konstrukcja
`sudo echo ... > /etc/modprobe.d/...` jest niepoprawna, ponieważ przekierowanie
nie działa z uprawnieniami `sudo`; przy ręcznej konfiguracji użyj `sudo tee`.

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
jetson-tk1-<variant>-debian12-pxe.tar.xz
jetson-tk1-<variant>-debian12-manifest.txt
SHA256SUMS
```

### Co zrobić z wygenerowanymi plikami

Do normalnej dystrybucji pozostaw te pliki jako zasoby GitHub Release. Artefakt
workflow jest kopią tymczasową, używaną między jobami oraz wtedy, gdy publikacja
Release jest wyłączona. GitHub Packages nie jest tu używane, ponieważ obsługuje
formaty menedżerów pakietów oraz obrazy Docker/OCI, a nie surowe obrazy dysków
lub systemów plików.

Po pobraniu z zakładki **Actions** najpierw rozpakuj ZIP artefaktu. Przy
pobieraniu z **Releases** umieść wszystkie pliki danego wydania w jednym
katalogu. Przed zapisem na jakikolwiek nośnik sprawdź ich integralność:

```bash
sha256sum -c SHA256SUMS
```

Obraz głównego systemu plików jest obowiązkowy. Następnie wybierz dokładnie
jedną z czterech metod instalacji plików boot:

| Wygenerowany plik | Przeznaczenie i następny krok |
| --- | --- |
| `*-rootfs.ext4.xz` | Wymagany: zapisz na partycji `/dev/sda1` dysku SATA. |
| `*-boot-sd.img.xz` | Najprostsza opcja dla dedykowanej karty SD: zapisz na całym urządzeniu. |
| `*-boot.ext2.xz` | Zapisz na istniejącej dedykowanej partycji boot; jej zawartość zostanie zastąpiona. |
| `*-boot-files.tar.xz` | Alternatywa bez formatowania: rozpakuj pliki na przygotowanej partycji boot. |
| `*-pxe.tar.xz` | Drzewo TFTP z osobnym menu zwykłego startu i instalacji rootfs na SATA. |
| `*-manifest.txt` | Metadane buildu do identyfikacji i diagnostyki; tego pliku się nie flashuje. |
| `SHA256SUMS` | Sumy kontrolne wszystkich wygenerowanych plików. |

Nie wdrażaj wszystkich czterech wariantów boot. Wybierz jeden pasujący do układu
nośnika, a potem wykonaj instrukcje **Przygotowanie rootfs SATA** i
**Przygotowanie nośnika boot** poniżej.

### Budowanie lokalne

Ten sam zestaw artefaktów można zbudować lokalnie na 64-bitowym Debianie lub
Ubuntu. Skrypt sprawdza wymagane pakiety, doinstalowuje braki przez `apt`,
włącza emulację ARM QEMU, buduje rootfs i kernel oraz weryfikuje wynik tak jak
workflow GitHub Actions. Wymagane są `sudo`, dostęp do Internetu, obsługa
mountów loop i około 25 GiB wolnego miejsca.

```bash
# Linux 6.12.95 + Nouveau
bash ./scripts/build-local.sh mainline

# NVIDIA L4T 21.8 + CUDA 6.5
bash ./scripts/build-local.sh nvidia
```

Wyniki trafiają odpowiednio do `release/mainline/` lub `release/nvidia/`.
Parametry można zmienić, na przykład:

```bash
bash ./scripts/build-local.sh mainline \
  --kernel-version 6.12.95 \
  --rootfs-size-mib 14336 \
  --jobs 8 \
  --keep-work
```

Pełną listę opcji pokazuje `bash ./scripts/build-local.sh --help`. Nie uruchamiaj
skryptu z Git Bash ani bezpośrednio z Windows; użyj natywnego Linuxa lub maszyny
wirtualnej z dostępem do loop mountów. WSL może działać tylko wtedy, gdy jego
środowisko pozwala na `binfmt_misc`, chroot i montowanie urządzeń loop.

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

Ten krok jest wymagany dla startu z SD/eMMC. Rootfs można zapisać ręcznie
zgodnie z instrukcją poniżej albo użyć osobnej pozycji instalacyjnej w menu PXE
opisanej w sekcji **Bootowanie sieciowe PXE/TFTP + instalacja rootfs**. Pobierz
`*-rootfs.ext4.xz` i `SHA256SUMS` z tego samego Release.

Dla SSD 128 GB zalecany układ to duża partycja root `/dev/sda1` oraz partycja
swap 2 GiB jako `/dev/sda2`. Swap jest przydatny przy 2 GB RAM w TK1, zwłaszcza
z Dockerem. Obraz ustawia `vm.swappiness=10`, więc system preferuje RAM i
ogranicza zbędne zapisy na SSD. Utwórz partycje na komputerze z Linuxem
(zastąp `/dev/sdX` dopiero po sprawdzeniu urządzenia):

```bash
disk=/dev/sdX
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$disk"

# Przerwij, jeśli którakolwiek partycja docelowa jest zamontowana.
if findmnt -rn -S "${disk}1" >/dev/null || \
   findmnt -rn -S "${disk}2" >/dev/null; then
  echo "docelowy SSD jest zamontowany; odmontuj go przed kontynuacją" >&2
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

Jeżeli SSD ma już odpowiednio dużą partycję `/dev/sda1` i opcjonalną
`/dev/sda2`, nie twórz ponownie tablicy partycji. W systemie ratunkowym Jetsona
umieść pobrane pliki na innym systemie plików i wykonaj:

```bash
grep 'rootfs\.ext4\.xz$' SHA256SUMS | sha256sum -c -
if findmnt -rn -S /dev/sda1 >/dev/null; then
  echo "/dev/sda1 jest zamontowane; zapis został przerwany" >&2
  exit 1
fi
xzcat jetson-tk1-mainline-debian12-rootfs.ext4.xz | \
  sudo dd of=/dev/sda1 bs=4M iflag=fullblock oflag=direct status=progress
sudo e2fsck -f /dev/sda1
sudo mkswap -L swap /dev/sda2  # pomiń, jeśli nie ma partycji swap
sync
```

`*-rootfs.ext4.xz` jest obrazem systemu plików, a nie całego dysku. Zawsze
zapisuj go na `/dev/sda1` (lub `${disk}1` na komputerze przygotowującym),
**nigdy na `/dev/sda` ani `${disk}`**. Po tym kroku PXE może pobrać pliki boot
przez TFTP, a Linux zamontuje przygotowany SSD jako główny system plików.

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

## Bootowanie sieciowe PXE/TFTP + instalacja rootfs

Pakiet opublikowany jako GitHub Release udostępnia trzy pozycje menu PXE:

- **Boot Debian 12 from existing SATA `/dev/sda1`** — zwykły i domyślny start;
- **INSTALL rootfs from GitHub HTTPS (DESTRUCTIVE)** — pobiera obraz bezpośrednio
  z tego samego GitHub Release;
- **INSTALL rootfs from local HTTP (DESTRUCTIVE)** — pobiera obraz z lokalnego
  serwera `${serverip}:8080`.

Kernel, initramfs, DTB i menu są pobierane przez TFTP. Duży
`rootfs.ext4.xz` może być pobrany alternatywnie przez HTTPS z GitHuba albo HTTP
z serwera lokalnego. W obu przypadkach jest przesyłany strumieniowo do
`xz | dd`, z obsługą błędów, ponawiania i SHA-256. TFTP nadal obsługuje cały
etap startowy. Build bez publikacji Release zawiera tylko wariant lokalny,
ponieważ zasób GitHub jeszcze nie istnieje.

Poniższy przykład zakłada wydzieloną sieć instalacyjną, adres serwera
`192.168.50.1` i interfejs `enp3s0`. Zmień je zgodnie ze swoim serwerem. Nie
uruchamiaj drugiego serwera DHCP w zwykłej sieci domowej.

### Krok 1: przygotuj pliki

Zawsze pobierz archiwum PXE i `SHA256SUMS` z tego samego Release, sprawdź
archiwum i rozpakuj je:

```bash
grep -- '-pxe\.tar\.xz$' SHA256SUMS | sha256sum -c -
sudo install -d -m 0755 /srv/tftp
sudo tar -xJf jetson-tk1-mainline-debian12-pxe.tar.xz -C /srv/tftp
find /srv/tftp -maxdepth 3 -type f -print
```

Tylko dla lokalnego HTTP pobierz również rootfs, sprawdź go i skopiuj:

```bash
grep -- '-rootfs\.ext4\.xz$' SHA256SUMS | sha256sum -c -
sudo install -m 0644 jetson-tk1-mainline-debian12-rootfs.ext4.xz /srv/tftp/
```

Użyj nazw `nvidia` zamiast `mainline`, jeżeli instalujesz wariant NVIDIA.
Powstanie wspólny katalog udostępniany przez TFTP i HTTP:

```text
/srv/tftp/
├── pxelinux.cfg/default
├── README-PXE.txt
├── pxe
├── jetson-tk1-mainline-debian12-rootfs.ext4.xz  # tylko lokalny HTTP
└── jetson-tk1-mainline-debian12/
    ├── zImage
    ├── initrd.img
    ├── tegra124-jetson-tk1.dtb
    ├── manifest.txt
    └── rootfs.sha256
```

### Krok 2: uruchom DHCP i TFTP

Jetson musi mieć U-Boot z Ethernetem, DHCP, TFTP oraz poleceniem `pxe`.
Najprostszy serwer dla wydzielonego interfejsu zapewnia `dnsmasq`:

```bash
sudo apt-get install dnsmasq python3
sudo ip address add 192.168.50.1/24 dev enp3s0
sudo ip link set enp3s0 up
```

Utwórz `/etc/dnsmasq.d/jetson-tk1-pxe.conf`:

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

Pusta opcja `dhcp-option=3` nie ogłasza bramy w izolowanej sieci, dlatego ten
wariant nadaje się do instalacji z lokalnego HTTP. Pobieranie z GitHuba wymaga
DHCP przekazującego działającą bramę i DNS oraz dostępu do Internetu. Jeżeli masz
już DHCP, zamiast uruchamiać drugi ustaw w nim adres `next-server`/option 66 na
adres TFTP i nazwę pliku startowego/option 67 na `pxe`.

```bash
sudo dnsmasq --test
sudo systemctl restart dnsmasq
sudo journalctl -u dnsmasq -f
```

### Krok 3: wybierz źródło obrazu

**GitHub HTTPS:** nie uruchamiaj lokalnego HTTP. Upewnij się, że Release jest
publiczny, a Jetson otrzymuje z DHCP bramę i DNS oraz może łączyć się z
`github.com`. W menu wybierzesz **INSTALL rootfs from GitHub HTTPS**. Adres
konkretnego tagu i pliku jest automatycznie osadzany w artefakcie PXE przez
GitHub Actions. Zegar RTC Jetsona musi wskazywać poprawną datę, inaczej
weryfikacja certyfikatu HTTPS zostanie zatrzymana; w takim przypadku popraw
czas albo wybierz lokalny HTTP.

**Lokalny HTTP:** działa również bez Internetu. Zalecany serwer jest zdefiniowany
w `docker/pxe-http/Dockerfile`, a `compose.pxe-http.yml` montuje `/srv/tftp`
tylko do odczytu. Z katalogu głównego repozytorium wykonaj:

```text
host: ${PXE_FILES_DIR:-/srv/tftp}  ->  kontener: /srv/files (read-only)
```

Nie używamy instrukcji Dockerfile `ADD` ani `COPY` dla artefaktów. Skopiowałaby
ona wielogigabajtowy rootfs do warstwy obrazu i wymagałaby ponownego builda po
każdej zmianie pliku. Bind mount udostępnia aktualną zawartość katalogu hosta.

```bash
PXE_FILES_DIR=/srv/tftp PXE_HTTP_BIND=192.168.50.1 \
  docker compose -f compose.pxe-http.yml up --build -d
docker compose -f compose.pxe-http.yml ps
curl --fail http://192.168.50.1:8080/healthz
curl --fail --head \
  http://192.168.50.1:8080/jetson-tk1-mainline-debian12-rootfs.ext4.xz
```

W menu wybierz **INSTALL rootfs from local HTTP**. Ten prosty serwer nie
zapewnia uwierzytelniania ani szyfrowania; używaj go tylko w zaufanej,
wydzielonej sieci i zatrzymaj po instalacji. Port TCP 8080 musi być
dostępny z Jetsona. Logi i zatrzymanie kontenera:

```bash
docker compose -f compose.pxe-http.yml logs -f pxe-http
docker compose -f compose.pxe-http.yml down
```

Bez Compose można zbudować i uruchomić ten sam Dockerfile bezpośrednio:

```bash
docker build -t jetson-tk1-pxe-http:local docker/pxe-http
docker run --rm --name jetson-tk1-pxe-http \
  --read-only --tmpfs /tmp:size=16m,mode=1777 \
  --cap-drop ALL --security-opt no-new-privileges \
  -p 192.168.50.1:8080:8080 \
  -v /srv/tftp:/srv/files:ro \
  jetson-tk1-pxe-http:local
```

Awaryjnie, bez Dockera, nadal można użyć
`cd /srv/tftp && python3 -m http.server 8080 --bind 192.168.50.1`.

### Krok 4: otwórz menu PXE przez konsolę szeregową

Podłącz konsolę 115200 8N1, zatrzymaj automatyczny start U-Boot i wykonaj:

```text
=> help pxe
=> printenv pxefile_addr_r kernel_addr_r ramdisk_addr_r fdt_addr_r
=> setenv autoload no
=> dhcp
=> setenv bootfile pxe
=> pxe get
=> pxe boot
```

Po wyświetleniu menu wybierz strzałkami instalację z **GitHub HTTPS** albo
**local HTTP**. Obie pozycje zapisują `/dev/sda1`. Timeout uruchamia zwykły
boot, a nie instalator.
Jeśli brakuje `help pxe` albo którejś zmiennej adresowej, zaktualizuj U-Boot.
Niektóre wersje distro-boot pozwalają też użyć `run bootcmd_pxe`. Szczegóły:
[dokumentacja formatu i poleceń PXE U-Boot](https://docs.u-boot.org/en/stable/usage/pxe.html).

### Krok 5: potwierdź zapis SSD

Instalator kolejno:

1. pobiera obraz bez zapisywania i porównuje jego SHA-256 z sumą osadzoną w
   menu PXE;
2. pokazuje wykryty `/dev/sda` i pozwala zachować istniejącą tablicę partycji
   albo — po wpisaniu `ERASE-SDA` — utworzyć GPT z rootfs i swap 2 GiB;
3. sprawdza, czy `/dev/sda1` istnieje, nie jest zamontowane i mieści obraz;
4. wymaga wpisania `WRITE-SDA1`, ponownie pobiera obraz i strumieniowo zapisuje
   go na partycji, jednocześnie ponownie sprawdzając SHA-256 transferu;
5. wykonuje `e2fsck`, inicjuje opcjonalne `/dev/sda2` jako swap i proponuje
   restart.

Przerwanie zasilania lub sieci podczas zapisu pozostawi niekompletny rootfs.
W takim przypadku uruchom instalator ponownie. Tryb `ERASE-SDA` usuwa całą
zawartość `/dev/sda`; zwykły tryb nadpisuje całą zawartość `/dev/sda1`.

### Krok 6: uruchom zainstalowany system

Po restarcie ponownie wykonaj `pxe get` i `pxe boot` albo skonfiguruj
`boot_targets`. Pozostaw domyślną pozycję **Boot Debian 12 from existing SATA
`/dev/sda1`**. TFTP dostarczy kernel, initramfs i DTB, a Linux zamontuje nowy
rootfs z SSD. HTTP nie jest już potrzebny do zwykłego startu.

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
