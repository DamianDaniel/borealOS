#!/bin/bash
set -e

WORK="$(pwd)/iso-work"
OUTPUT="borealOS.iso"
ROOTFS_TAR="./borealOS-rootfs.tar.gz"
INSTALLER_SH="./installer.sh"
WALLPAPER_DEFAULT="./background_2.png"
WALLPAPER_ALT="./background_one.png"
LOGO="./logo.png"
BANNER="./borealOS-text-and-logo-transparent.png"
RICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../rice"

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

die() { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }
ok()  { echo -e "${GRN}$1${RST}"; }

for f in "$ROOTFS_TAR" "$INSTALLER_SH" "$WALLPAPER_DEFAULT" "$WALLPAPER_ALT" "$LOGO" "$BANNER"; do
    [ -f "$f" ] || die "Missing: $f"
done
[ "$EUID" -eq 0 ] || die "Run as root."

command -v xorriso       >/dev/null || apt-get install -y xorriso       || die "Failed to install xorriso"
command -v convert        >/dev/null || apt-get install -y imagemagick    || die "Failed to install imagemagick"
command -v grub-mkrescue >/dev/null || apt-get install -y grub-efi-amd64-bin grub-pc-bin mtools || die "Failed to install grub tools"
command -v mksquashfs    >/dev/null || apt-get install -y squashfs-tools || die "Failed to install squashfs-tools"

echo ""
echo -e "${BLD}Select DE/WM to include in ISO:${RST}"
echo "  1) KDE Plasma"
echo "  2) XFCE"
echo "  3) Sway (Wayland)"
echo "  4) Hyprland (Wayland)"
echo "  5) Niri (Wayland)"
echo "  6) None (TTY only)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r de_choice
    case "$de_choice" in
        1) DE_PKGS="kde-plasma-desktop sddm"; DE_NAME="KDE Plasma"; break ;;
        2) DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"; DE_NAME="XFCE"; break ;;
        3) DE_PKGS="sway swaybg swaylock waybar foot wofi"; DE_NAME="Sway"; break ;;
        4) DE_PKGS="hyprland waybar foot wofi"; DE_NAME="Hyprland"; break ;;
        5) DE_PKGS="foot"; DE_NAME="Niri"; echo -e "${RED}NOTE: niri has no Debian package. It will be built from source.${RST}"; break ;;
        6) DE_PKGS=""; DE_NAME="None"; break ;;
        *) echo -e "${RED}Invalid.${RST}" ;;
    esac
done

echo ""
echo -e "${BLD}Select shell to include:${RST}"
echo "  1) bash"
echo "  2) fish"
echo "  3) sh (already present)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r sh_choice
    case "$sh_choice" in
        1) SHELL_PKG="bash"; SHELL_BIN="/bin/bash"; SHELL_NAME="bash"; break ;;
        2) SHELL_PKG="fish"; SHELL_BIN="/usr/bin/fish"; SHELL_NAME="fish"; break ;;
        3) SHELL_PKG=""; SHELL_BIN="/bin/sh"; SHELL_NAME="sh"; break ;;
        *) echo -e "${RED}Invalid.${RST}" ;;
    esac
done

echo ""
echo -e "${BLD}Building ISO with: DE=${DE_NAME}, Shell=${SHELL_NAME}${RST}"
echo ""

echo "==> Cleaning work directory..."
rm -rf "$WORK"
mkdir -p "$WORK"/{iso/{boot/grub,live},squashfs-root}

echo "==> Extracting rootfs..."
tar -xzf "$ROOTFS_TAR" -C "$WORK/squashfs-root" || die "Failed to extract rootfs"

echo "==> Injecting installer and assets..."
mkdir -p "$WORK/squashfs-root/opt/borealOS"
cp "$ROOTFS_TAR"        "$WORK/squashfs-root/opt/borealOS/rootfs.tar.gz" || die "Failed to copy rootfs"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/opt/borealOS/background_2.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/opt/borealOS/background_one.png"
cp "$LOGO"              "$WORK/squashfs-root/opt/borealOS/logo.png"
mkdir -p "$WORK/squashfs-root/usr/share/boreal-artwork"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-default.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-waves.png"
cp "$LOGO"              "$WORK/squashfs-root/usr/share/boreal-artwork/logo.png"
cp "$BANNER"            "$WORK/squashfs-root/usr/share/boreal-artwork/banner.png"

echo "==> Removing Debian artwork..."
find "$WORK/squashfs-root/usr/share" -name "*debian*" -not -path "*/dpkg/*" -not -path "*/apt/*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/pixmaps" -name "*debian*" -delete 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/desktop-base" 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/vendor-logos" 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/backgrounds" -name "*debian*" -delete 2>/dev/null || true

echo "==> Creating GRUB theme..."
mkdir -p "$WORK/squashfs-root/usr/share/grub/themes/boreal"
convert "$WALLPAPER_DEFAULT" -resize 1920x1080!     "$WORK/squashfs-root/usr/share/grub/themes/boreal/background.png" 2>/dev/null ||     cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/grub/themes/boreal/background.png"
convert "$BANNER" -resize 800x200 -background none     "$WORK/squashfs-root/usr/share/grub/themes/boreal/title.png" 2>/dev/null ||     cp "$BANNER" "$WORK/squashfs-root/usr/share/grub/themes/boreal/title.png"
cp "$RICE_DIR/grub/grub-theme.txt" "$WORK/squashfs-root/usr/share/grub/themes/boreal/theme.txt" || die "Missing rice/grub/grub-theme.txt"

echo "==> Creating Plymouth theme..."
mkdir -p "$WORK/squashfs-root/usr/share/plymouth/themes/boreal"
convert "$WALLPAPER_DEFAULT" -resize 1920x1080!     -fill "#0d1b2a" -colorize 55     "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/background.png" 2>/dev/null ||     cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/background.png"
convert "$BANNER" -resize 600x150 -background none     "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/logo.png" 2>/dev/null ||     cp "$BANNER" "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/logo.png"
convert -size 12x12 xc:none -fill "#4dffd2" -draw "circle 5,5 5,0"     "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/dot.png"
convert -size 12x12 xc:none -fill "#4dffd23c" -draw "circle 5,5 5,0"     "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/dot-dim.png"
cp "$RICE_DIR/plymouth/boreal.script"   "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/boreal.script"   || die "Missing rice/plymouth/boreal.script"
cp "$RICE_DIR/plymouth/boreal.plymouth" "$WORK/squashfs-root/usr/share/plymouth/themes/boreal/boreal.plymouth" || die "Missing rice/plymouth/boreal.plymouth"
cp "$INSTALLER_SH"      "$WORK/squashfs-root/usr/local/bin/borealOS-install"
chmod +x                "$WORK/squashfs-root/usr/local/bin/borealOS-install"

echo "$DE_NAME"   > "$WORK/squashfs-root/opt/borealOS/de"
echo "$SHELL_BIN" > "$WORK/squashfs-root/opt/borealOS/shell"

echo "==> Copying rice configs to skel..."
SKEL="$WORK/squashfs-root/etc/skel"
copy_rice() {
    local src="$RICE_DIR/$1" dst="$SKEL/$2"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$src" ]; then
        cp "$src" "$dst" && echo "  copied: $2"
    else
        warn "  missing rice config: $1"
    fi
}
copy_rice "fastfetch/config.jsonc" ".config/fastfetch/config.jsonc"
copy_rice "kitty/kitty.conf"       ".config/kitty/kitty.conf"
copy_rice "kitty/dark.conf"        ".config/kitty/dark.conf"
copy_rice "kitty/light.conf"       ".config/kitty/light.conf"
copy_rice "niri/config.kdl"        ".config/niri/config.kdl"
copy_rice "sway/config"            ".config/sway/config"


echo "==> Applying branding..."
cat > "$WORK/squashfs-root/etc/os-release" <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS 1.0"
ID=borealos
ID_LIKE=
VERSION="1.0"
VERSION_ID="1.0"
HOME_URL="https://borealos.org"
SUPPORT_URL="https://borealos.org"
BUG_REPORT_URL="https://borealos.org"
OS

cat > "$WORK/squashfs-root/etc/lsb-release" <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS 1.0"
LSB

echo "BorealOS"      > "$WORK/squashfs-root/etc/issue"
echo "BorealOS 1.0"  > "$WORK/squashfs-root/etc/issue.net"
echo "BorealOS"      > "$WORK/squashfs-root/etc/debian_version"
echo "borealOS-live" > "$WORK/squashfs-root/etc/hostname"



cat > "$WORK/squashfs-root/etc/profile.d/live-welcome.sh" <<'WELCOME'
if [ "$(tty)" = "/dev/tty1" ] && [ "$(id -u)" = "0" ]; then
    clear
    cat <<'BANNER'

  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/

  Welcome to BorealOS Live
  Run: borealOS-install   to install

BANNER
    borealOS-install
fi
WELCOME

echo "==> Installing packages into squashfs (this takes a while)..."
mount --bind /dev  "$WORK/squashfs-root/dev"
mount --bind /proc "$WORK/squashfs-root/proc"
mount --bind /sys  "$WORK/squashfs-root/sys"
cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"

chroot "$WORK/squashfs-root" /bin/bash <<CHROOT || die "Package installation in chroot failed"
set -e
apt-get update -qq

apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    grub-efi-amd64 \
    grub-efi-amd64-bin \
    grub-pc-bin \
    grub-common \
    efibootmgr \
    live-boot \
    live-boot-initramfs-tools \
    openrc \
    network-manager \
    ifupdown \
    parted \
    dosfstools \
    e2fsprogs \
    passwd \
    sudo \
    bash \
    bash-completion \
    iproute2 \
    iputils-ping \
    net-tools \
    curl \
    wget \
    nano \
    less \
    tzdata \
    locales \
    wpasupplicant \
    openssl \
    libdevmapper1.02.1 \
    libefivar1 \
    libefiboot1 \
    os-prober \
    python3 \
    rsync \
    $SHELL_PKG

apt-get install -y \
    xserver-xorg \
    xserver-xorg-core \
    xserver-xorg-input-all \
    xserver-xorg-video-all \
    xinit \
    xauth \
    x11-xserver-utils \
    xterm \
    xwayland

if [ -n "$DE_PKGS" ]; then
    apt-get install -y $DE_PKGS || die "Failed to install DE packages: $DE_PKGS"
fi

for pkg in fastfetch kitty; do
    apt-get install -y "$pkg" 2>/dev/null || echo "WARN: $pkg not available, skipping"
    dpkg --configure -a 2>/dev/null || true
done

echo 'root:borealOS' | chpasswd

CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
ok "==> Packages installed."

if [ "$DE_NAME" = "Niri" ]; then
    echo "==> Building niri from source (this will take 10-20 minutes)..."
    mount --bind /dev  "$WORK/squashfs-root/dev"
    mount --bind /proc "$WORK/squashfs-root/proc"
    mount --bind /sys  "$WORK/squashfs-root/sys"
    cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"

    chroot "$WORK/squashfs-root" /bin/bash <<NIRICHROOT || die "niri build failed"
set -e
apt-get update -qq
apt-get install -y --no-install-recommends     rustc cargo     git cmake build-essential pkg-config meson ninja-build     libwayland-dev libwayland-egl1     libegl1-mesa-dev libgles2-mesa-dev     libxcb-composite0-dev libxcb-present-dev libxcb-xfixes0-dev libxcb1-dev     libinput-dev     libxkbcommon-dev libxkbcommon-x11-dev libxcb-xkb-dev     libseat-dev libpam0g-dev libelogind-dev     libdrm-dev libpixman-1-dev libgbm-dev     libxrandr-dev libpcre3-dev libcap-dev     libgtk-3-dev libglib2.0-dev     libpulse-dev libffi-dev libexpat1-dev     libdbus-1-dev     xwayland wayland-protocols wayland-utils     swaybg waybar wlr-randr grim slurp     libudev-dev libsystemd-dev     libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev     libclang-dev clang

LATEST_TAG=$(git ls-remote --tags https://github.com/YaLTeR/niri.git 2>/dev/null |     grep -oP 'refs/tags/v[0-9.]+$' | sort -V | tail -1 | sed 's|refs/tags/||')
echo "==> Cloning niri ${LATEST_TAG}..."
cd /tmp
git clone --depth 1 --branch "$LATEST_TAG" https://github.com/YaLTeR/niri.git niri-src
cd niri-src

echo "==> Compiling niri (this takes a while)..."
cargo build --release

install -Dm755 target/release/niri /usr/local/bin/niri

if [ -f resources/niri-session ]; then
    install -Dm755 resources/niri-session /usr/local/bin/niri-session
else
    cat > /usr/local/bin/niri-session <<SESSION
#!/bin/sh
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=niri
export XDG_CURRENT_DESKTOP=niri
exec niri --session
SESSION
    chmod +x /usr/local/bin/niri-session
fi

mkdir -p /usr/local/share/wayland-sessions
cat > /usr/local/share/wayland-sessions/niri.desktop <<DESK
[Desktop Entry]
Name=Niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
DESK

cd /
rm -rf /tmp/niri-src

apt-get remove -y --purge     rustc cargo git cmake meson ninja-build build-essential     libclang-dev clang 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
NIRICHROOT

    umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
    ok "niri built and installed."
fi

echo "==> Disabling display managers in live env..."
for dm in lightdm sddm gdm3 xdm; do
    find "$WORK/squashfs-root/etc" -name "*${dm}*" -path "*/rc*.d/*" -delete 2>/dev/null || true
    rm -f "$WORK/squashfs-root/etc/runlevels/default/${dm}"
    rm -f "$WORK/squashfs-root/etc/runlevels/boot/${dm}"
done

tar -xOf "$ROOTFS_TAR" ./etc/inittab > "$WORK/squashfs-root/etc/inittab" 2>/dev/null || true
sed -i 's|^\(1:[0-9]*:respawn:.*getty\)|\1 --autologin root|' "$WORK/squashfs-root/etc/inittab"
if ! grep -q "autologin" "$WORK/squashfs-root/etc/inittab"; then
    sed -i '/^1:/d' "$WORK/squashfs-root/etc/inittab"
    echo "1:2345:respawn:/sbin/agetty --autologin root --noclear 38400 tty1" >> "$WORK/squashfs-root/etc/inittab"
fi

echo "==> Building SquashFS..."
mksquashfs "$WORK/squashfs-root" "$WORK/iso/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -noappend -quiet || die "mksquashfs failed"

echo "==> Copying kernel and initrd..."
VMLINUZ=$(ls "$WORK/squashfs-root/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls  "$WORK/squashfs-root/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)
[ -f "$VMLINUZ" ] || die "No kernel found after package install."
[ -f "$INITRD"  ] || die "No initrd found after package install."
cp "$VMLINUZ" "$WORK/iso/boot/vmlinuz"
cp "$INITRD"  "$WORK/iso/boot/initrd.img"

echo "==> Writing GRUB config..."
mkdir -p "$WORK/iso/boot/grub/themes/boreal"
cp -r "$WORK/squashfs-root/usr/share/grub/themes/boreal/." "$WORK/iso/boot/grub/themes/boreal/"

cat > "$WORK/iso/boot/grub/grub.cfg" <<'GRUB'
set timeout_style=menu
set timeout=10
set default=0
set theme=/boot/grub/themes/boreal/theme.txt

menuentry "BorealOS Live Installer" {
    linux /boot/vmlinuz boot=live quiet splash plymouth.ignore-serial-consoles
    initrd /boot/initrd.img
}

menuentry "BorealOS Live (safe mode)" {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUB

echo "==> Building ISO..."
grub-mkrescue -o "$OUTPUT" "$WORK/iso" \
    --modules="normal iso9660 linux ext2 fat search search_label" \
    2>/dev/null || die "grub-mkrescue failed"

ok "==> Done: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
