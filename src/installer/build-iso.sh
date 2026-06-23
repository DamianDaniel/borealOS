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
BRANDING_ZIP="./borealOS-branding.zip"
RICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../rice"

RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
die()  { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }
ok()   { echo -e "${GRN}$1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

for f in "$ROOTFS_TAR" "$INSTALLER_SH" "$WALLPAPER_DEFAULT" "$WALLPAPER_ALT" "$LOGO" "$BANNER"; do
    [ -f "$f" ] || die "Missing: $f"
done
[ "$EUID" -eq 0 ] || die "Run as root."

command -v xorriso       >/dev/null || apt-get install -y xorriso        || die "Failed to install xorriso"
command -v convert       >/dev/null || apt-get install -y imagemagick    || die "Failed to install imagemagick"
command -v grub-mkrescue >/dev/null || apt-get install -y grub-efi-amd64-bin grub-pc-bin mtools || die "Failed to install grub"
command -v mksquashfs    >/dev/null || apt-get install -y squashfs-tools  || die "Failed to install squashfs-tools"
command -v unzip         >/dev/null || apt-get install -y unzip           || die "Failed to install unzip"

echo ""
echo -e "${BLD}Select DE/WM to include in ISO:${RST}"
echo "  1) KDE Plasma"
echo "  2) XFCE"
echo "  3) Sway (Wayland)"
echo "  4) Hyprland (Wayland)"
echo "  5) Niri (Wayland, built from source)"
echo "  6) None (TTY only)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r de_choice
    case "$de_choice" in
        1) DE_PKGS="kde-plasma-desktop"; DM_PKGS="sddm"; DE_NAME="KDE Plasma"; DE_START="startplasma-x11"; break ;;
        2) DE_PKGS="xfce4 xfce4-goodies"; DM_PKGS="lightdm lightdm-gtk-greeter"; DE_NAME="XFCE"; DE_START="startxfce4"; break ;;
        3) DE_PKGS="sway swaybg swaylock waybar foot wofi"; DM_PKGS=""; DE_NAME="Sway"; DE_START="sway"; break ;;
        4) DE_PKGS="hyprland waybar foot wofi"; DM_PKGS=""; DE_NAME="Hyprland"; DE_START="Hyprland"; break ;;
        5) DE_PKGS="foot"; DM_PKGS=""; DE_NAME="Niri"; DE_START="niri-session"; break ;;
        6) DE_PKGS=""; DM_PKGS=""; DE_NAME="None"; DE_START=""; break ;;
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
echo -e "${BLD}Building ISO: DE=${DE_NAME}, Shell=${SHELL_NAME}${RST}"
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
cp "$INSTALLER_SH"      "$WORK/squashfs-root/usr/local/bin/borealOS-install"
chmod +x                "$WORK/squashfs-root/usr/local/bin/borealOS-install"
echo "$DE_NAME"   > "$WORK/squashfs-root/opt/borealOS/de"
mkdir -p "$WORK/squashfs-root/opt/borealOS/lightdm"
if [ -d "$RICE_DIR/lightdm" ]; then
    cp -r "$RICE_DIR/lightdm/." "$WORK/squashfs-root/opt/borealOS/lightdm/"
    ok "Copied lightdm rice configs"
else
    warn "No rice/lightdm/ found - using defaults"
fi
echo "$DE_START"  > "$WORK/squashfs-root/opt/borealOS/de-start"
echo "$SHELL_BIN" > "$WORK/squashfs-root/opt/borealOS/shell"

echo "==> Setting up BorealOS artwork..."
mkdir -p "$WORK/squashfs-root/usr/share/boreal-artwork"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-default.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-waves.png"
cp "$LOGO"              "$WORK/squashfs-root/usr/share/boreal-artwork/logo.png"
cp "$BANNER"            "$WORK/squashfs-root/usr/share/boreal-artwork/banner.png"

echo "==> Creating GRUB theme..."
mkdir -p "$WORK/squashfs-root/usr/share/grub/themes/boreal"
convert "$WALLPAPER_DEFAULT" -resize 1920x1080! \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/background.png" 2>/dev/null || \
    cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/grub/themes/boreal/background.png"
# Resize banner preserving aspect ratio: fit within 400px wide, height auto-scales.
# logo.png is 3310x1254 (~2.64:1), so 400wide -> ~152px tall. Never use ! (force-stretch).
convert "$BANNER" -trim -resize 400x -background none \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/title.png" 2>/dev/null || \
    cp "$BANNER" "$WORK/squashfs-root/usr/share/grub/themes/boreal/title.png"
convert -size 760x44 xc:none \
    -fill "#0d3333cc" -draw "roundrectangle 2,2 757,41 6,6" \
    -fill none -stroke "#4dffd2" -strokewidth 2 -draw "roundrectangle 2,2 757,41 6,6" \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/select_c.png" 2>/dev/null || true
convert -size 4x44 xc:"#4dffd2" \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/select_w.png" 2>/dev/null || true
convert -size 4x44 xc:"#4dffd2" \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/select_e.png" 2>/dev/null || true

if [ -f "$RICE_DIR/grub/grub-theme.txt" ]; then
    cp "$RICE_DIR/grub/grub-theme.txt" "$WORK/squashfs-root/usr/share/grub/themes/boreal/theme.txt"
    # Remove any hardcoded height from the title image block so it can't warp.
    # GRUB scales correctly when only width is specified.
    sed -i '/^\s*height\s*=\s*[0-9]/d' \
        "$WORK/squashfs-root/usr/share/grub/themes/boreal/theme.txt"
    ok "Rice grub theme applied (height constraint removed to prevent logo warp)"
else
    cat > "$WORK/squashfs-root/usr/share/grub/themes/boreal/theme.txt" <<'THEME'
desktop-image: "background.png"
desktop-color: "#0d1b2a"
title-text: ""

+ image {
    top = 18%
    left = 50%-200
    width = 400
    # No height: GRUB scales to match the image's natural height at this width.
    # Setting both width AND height to non-matching values causes the egg warp.
    file = "title.png"
}

+ boot_menu {
    top = 53%
    left = 20%
    width = 60%
    height = 36%
    item_color = "#7fffff"
    selected_item_color = "#ffffff"
    selected_item_pixmap_style = "select_*.png"
    item_height = 44
    item_padding = 18
    item_spacing = 6
    scrollbar = false
}

+ label {
    top = 92%
    left = 0
    width = 100%
    align = "center"
    color = "#4dffd2"
    text = "↑ ↓ navigate    Enter boot    e edit    c console"
}
THEME
fi

echo "==> Writing xorg config..."
mkdir -p "$WORK/squashfs-root/etc/X11/xorg.conf.d"

# Let Xorg + libinput handle device enumeration via udev (the modern way).
# DO NOT set AutoAddDevices=false here — that was blocking keyboard/mouse in live env.
# We only force libinput as the catch-all input driver and set a sane keyboard layout.
cat > "$WORK/squashfs-root/etc/X11/xorg.conf.d/00-boreal-input.conf" <<'XORGCONF'
Section "InputClass"
    Identifier "libinput catch-all"
    MatchIsPointer "on"
    Driver "libinput"
    Option "NaturalScrolling" "false"
EndSection

Section "InputClass"
    Identifier "libinput keyboard catch-all"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbLayout" "us"
EndSection
XORGCONF

# Remove any leftover static xorg.conf that might have AutoAddDevices=false
rm -f "$WORK/squashfs-root/etc/X11/xorg.conf"

echo "==> Copying rice configs to skel..."
SKEL="$WORK/squashfs-root/etc/skel"
copy_rice() {
    local src="$RICE_DIR/$1" dst="$SKEL/$2"
    mkdir -p "$(dirname "$dst")"
    [ -f "$src" ] && cp "$src" "$dst" && echo "  copied: $2" || warn "  missing: $1"
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

echo "==> Writing live TTY menu..."
cat > "$WORK/squashfs-root/etc/profile.d/boreal-live.sh" <<'LIVEMENU'
#!/bin/bash
[ "$(tty)" = "/dev/tty1" ] || exit 0
[ "$(id -u)" = "0" ]       || exit 0
grep -q "boot=live" /proc/cmdline 2>/dev/null || exit 0

DE=$(cat /opt/borealOS/de 2>/dev/null || echo "None")
DE_START=$(cat /opt/borealOS/de-start 2>/dev/null || echo "")

while true; do
    clear
    printf '\033[0;36m\033[1m'
    cat <<'BANNER'
  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/
BANNER
    printf '\033[0m'
    echo ""
    echo "  BorealOS 1.0 Live  |  DE: $DE"
    echo ""
    echo "  1) Terminal Installer"
    echo "  2) Graphical Live Environment"
    echo "  3) Shell"
    echo ""
    echo -n "  Choice: "
    read -r choice
    case "$choice" in
        1)
            clear
            borealOS-install
            break
            ;;
        2)
            if [ -z "$DE_START" ] || [ "$DE" = "None" ]; then
                echo "No graphical DE in this ISO."
                sleep 2
            else
                clear
                /usr/local/bin/boreal-start-graphical
                break
            fi
            ;;
        3)
            clear
            break
            ;;
    esac
done
LIVEMENU
chmod +x "$WORK/squashfs-root/etc/profile.d/boreal-live.sh"

cat > "$WORK/squashfs-root/usr/local/bin/boreal-start-graphical" <<'GRAPHICAL'
#!/bin/bash
# boreal-start-graphical: launches a minimal XFCE installer session.
#
# WHY XFCE ALWAYS:
#   Calamares is a Qt/X11 application. It requires a running X server, a D-Bus
#   session, and a composited or at least functional WM. Wayland compositors
#   (Sway, Hyprland, Niri) do not expose DISPLAY, so Qt6/X11 Calamares can't
#   connect. Bare WMs without a session manager miss the D-Bus plumbing Calamares
#   needs. XFCE is the lightest DE that provides all of this reliably.
#
#   The user's chosen DE (KDE, Sway, etc.) is still installed into the *target*
#   system by installer.sh — this session is only for the live install environment.

DE=$(cat /opt/borealOS/de 2>/dev/null || echo "None")

if [ "$DE" = "None" ]; then
    echo "This ISO was built without a graphical environment (TTY-only mode)."
    echo "Use option 1 (Terminal Installer) instead."
    echo "Press Enter to return."
    read -r; exit 0
fi

# Check XFCE is available (it's always installed as the installer host DE)
if ! command -v startxfce4 >/dev/null 2>&1; then
    echo "ERROR: XFCE installer environment not found."
    echo "The ISO may need to be rebuilt. Press Enter to return."
    read -r; exit 0
fi

echo "Starting BorealOS graphical installer (XFCE host session)..."
echo "Your chosen DE ($DE) will be installed to the target disk."
sleep 1

cat > /root/.xinitrc <<'XINITRC'
#!/bin/bash
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE

# Start a D-Bus session if one isn't running
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval "$(dbus-launch --sh-syntax --exit-with-session)"
fi

# Set wallpaper once XFCE desktop is up
(sleep 6
 WP=/usr/share/boreal-artwork/wallpaper-default.png
 for screen in screen0; do
   for mon in VGA-1 VGA1 HDMI-1 HDMI1 Virtual-1 Virtual1 DP-1 DP1 \
               eDP-1 eDP1 DVI-1 DVI1 monitor0; do
     xfconf-query -c xfce4-desktop \
       -p "/backdrop/$screen/$mon/workspace0/last-image" -s "$WP" 2>/dev/null || true
     xfconf-query -c xfce4-desktop \
       -p "/backdrop/$screen/$mon/workspace0/image-style" -t int -s 5 2>/dev/null || true
   done
 done
 xfdesktop --reload 2>/dev/null || true
) &

# Launch Calamares installer after desktop has settled.
# Loop so it restarts if the user closes and re-opens it.
(sleep 10
 while true; do
   DISPLAY=:0 calamares 2>/tmp/calamares.log
   RET=$?
   # Exit code 0 = finished successfully; don't restart
   [ "$RET" -eq 0 ] && break
   sleep 3
 done
) &

exec startxfce4
XINITRC

chmod +x /root/.xinitrc
# -nolisten tcp: no remote X connections; good practice in a live env
startx -- -nolisten tcp 2>/tmp/xorg.log
GRAPHICAL
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-start-graphical"

echo "==> Installing packages..."
mount --bind /dev  "$WORK/squashfs-root/dev"
mount --bind /proc "$WORK/squashfs-root/proc"
mount --bind /sys  "$WORK/squashfs-root/sys"
cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"

chroot "$WORK/squashfs-root" /bin/bash <<CHROOT || die "Package installation failed"
set -e
apt-get update -qq

apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    grub-efi-amd64 grub-efi-amd64-bin grub-pc-bin grub-common \
    efibootmgr \
    live-boot live-boot-initramfs-tools \
    openrc \
    network-manager ifupdown dhcpcd5 \
    parted dosfstools e2fsprogs \
    passwd sudo \
    bash bash-completion \
    iproute2 iputils-ping net-tools \
    curl wget nano less \
    tzdata locales \
    openssl libdevmapper1.02.1 libefivar1 libefiboot1 \
    os-prober python3 rsync \
    fonts-dejavu-core \
    wpasupplicant \
    $SHELL_PKG

apt-get install -y \
    xserver-xorg xserver-xorg-core \
    xserver-xorg-input-all \
    xserver-xorg-input-libinput \
    xserver-xorg-input-evdev \
    xserver-xorg-input-mouse \
    xserver-xorg-input-kbd \
    xserver-xorg-video-all xserver-xorg-video-vesa xserver-xorg-video-fbdev \
    xinit xauth x11-xserver-utils x11-utils xterm xwayland \
    libinput-tools \
    libgl1-mesa-dri libgl1 mesa-utils \
    dbus dbus-x11 at-spi2-core \
    libinput10 libinput-dev \
    udev

for pkg in virtualbox-guest-x11 virtualbox-guest-utils xf86-video-vmware; do
    apt-get install -y "$pkg" 2>/dev/null || echo "SKIP: $pkg"
done

# Always install XFCE as the live installer host environment.
# Calamares requires X11 + D-Bus + a session manager — XFCE is the lightest DE
# that provides all of this. Wayland compositors (Sway, Hyprland, Niri) and
# bare WMs cannot host Calamares reliably in a live session.
# The user's chosen DE ($DE_PKGS) is also installed so the live env can demo it,
# but the GUI installer always launches inside XFCE regardless.
apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal xfwm4 xfdesktop4 xfconf \
    lightdm lightdm-gtk-greeter \
    || echo "WARN: XFCE installer host DE install incomplete"

if [ -n "$DE_PKGS" ] && [ "$DE_PKGS" != "xfce4 xfce4-goodies" ]; then
    apt-get install -y --no-install-recommends $DE_PKGS || echo "WARN: some DE packages failed"
elif [ -n "$DE_PKGS" ]; then
    # User chose XFCE — install the goodies too
    apt-get install -y --no-install-recommends $DE_PKGS || echo "WARN: some DE packages failed"
fi

for pkg in fastfetch kitty calamares calamares-qt6; do
    apt-get install -y "$pkg" 2>/dev/null || echo "SKIP: $pkg"
done

mkdir -p /opt/borealOS/debs
if [ -n "$DM_PKGS" ]; then
    apt-get install -y --download-only $DM_PKGS 2>/dev/null || true
fi
cp /var/cache/apt/archives/*.deb /opt/borealOS/debs/ 2>/dev/null || true
echo "$(ls /opt/borealOS/debs/*.deb 2>/dev/null | wc -l) debs cached"

echo 'root:borealOS' | chpasswd

echo "==> Ensuring no display manager auto-starts in live env..."
apt-get remove --purge -y lightdm sddm gdm3 xdm wdm nodm 2>/dev/null || true
for dm in lightdm sddm gdm3 xdm wdm; do
    find /etc/rc*.d -name "*${dm}*" -delete 2>/dev/null || true
    rm -f /etc/runlevels/default/${dm} 2>/dev/null || true
    rm -f /etc/runlevels/boot/${dm} 2>/dev/null || true
    if [ -f /etc/init.d/${dm} ]; then
        printf '#!/bin/sh\nexit 0\n' > /etc/init.d/${dm}
    fi
done

rm -f /etc/X11/default-display-manager 2>/dev/null || true
CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
ok "==> Packages installed."

echo "==> Setting up Calamares branding..."
if [ -f "$BRANDING_ZIP" ]; then
    mkdir -p "$WORK/squashfs-root/usr/share/calamares/branding"
    unzip -o "$BRANDING_ZIP" -d /tmp/calamares-branding/ 2>/dev/null || true
    if [ -d /tmp/calamares-branding/branding/default ]; then
        cp -r /tmp/calamares-branding/branding/default \
            "$WORK/squashfs-root/usr/share/calamares/branding/boreal"
        ok "Calamares branding installed."
    fi
    rm -rf /tmp/calamares-branding
else
    warn "borealOS-branding.zip not found — Calamares will use default branding"
fi

mkdir -p "$WORK/squashfs-root/etc/calamares"
cat > "$WORK/squashfs-root/etc/calamares/settings.conf" <<'CALSETTINGS'
---
modules-search: [ local, /usr/lib/calamares/modules ]
sequence:
  - show:
    - welcome
    - locale
    - keyboard
    - partition
    - users
    - summary
  - exec:
    - partition
    - mount
    - unpackfs
    - fstab
    - locale
    - keyboard
    - users
    - bootloader
    - unmount
  - show:
    - finished
branding: boreal
prompt-install: true
dont-chroot: false
CALSETTINGS

echo "==> Removing Debian artwork (after package install)..."
find "$WORK/squashfs-root/usr/share" \
    \( -name "*debian*" -not -path "*/dpkg/*" -not -path "*/apt/*" \
       -not -path "*/plymouth/themes/debian-logo*" \) \
    -delete 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/desktop-base" 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/vendor-logos" 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/backgrounds" -maxdepth 2 -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/pixmaps" -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/icons" -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/boot/grub" -name "*debian*" -delete 2>/dev/null || true

if [ "$DE_NAME" = "Niri" ]; then
    echo "==> Building niri from source (10-20 minutes)..."
    mount --bind /dev  "$WORK/squashfs-root/dev"
    mount --bind /proc "$WORK/squashfs-root/proc"
    mount --bind /sys  "$WORK/squashfs-root/sys"
    cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"
    chroot "$WORK/squashfs-root" /bin/bash <<NIRICHROOT || die "niri build failed"
set -e
apt-get install -y --no-install-recommends \
    build-essential git cmake pkg-config meson ninja-build \
    rustc cargo clang libclang-dev \
    libwayland-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libxcb1-dev libxcb-xkb-dev libxcb-composite0-dev libxcb-present-dev libxcb-xfixes0-dev \
    libinput-dev libseat-dev libpam0g-dev \
    libdrm-dev libpixman-1-dev libgbm-dev \
    libudev-dev libdbus-1-dev libsystemd-dev \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev libglib2.0-dev \
    libffi-dev libexpat1-dev libcap-dev libxrandr-dev \
    xwayland wayland-protocols

for optpkg in libwayland-egl1 libegl-dev libegl1-mesa-dev libgles-dev libgles2-mesa-dev \
    libgtk-3-dev libpulse-dev libpcre2-dev wayland-utils swaybg waybar wlr-randr grim slurp; do
    apt-get install -y --no-install-recommends "$optpkg" 2>/dev/null || echo "SKIP: $optpkg"
done

LATEST_TAG=$(git ls-remote --tags https://github.com/YaLTeR/niri.git 2>/dev/null | \
    grep -oP 'refs/tags/v[0-9.]+$' | sort -V | tail -1 | sed 's|refs/tags/||')
echo "Cloning niri $LATEST_TAG..."
cd /tmp && git clone --depth 1 --branch "$LATEST_TAG" https://github.com/YaLTeR/niri.git niri-src
cd niri-src && cargo build --release
install -Dm755 target/release/niri /usr/local/bin/niri
if [ -f resources/niri-session ]; then
    install -Dm755 resources/niri-session /usr/local/bin/niri-session
else
    printf '#!/bin/sh\nexport XDG_SESSION_TYPE=wayland\nexport XDG_CURRENT_DESKTOP=niri\nexec niri --session\n' > /usr/local/bin/niri-session
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
cd / && rm -rf /tmp/niri-src
apt-get remove -y --purge rustc cargo git cmake meson ninja-build build-essential libclang-dev clang 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
NIRICHROOT
    umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
    ok "niri built."
fi

echo "==> Enabling udev in OpenRC for live env..."
ln -sf /etc/init.d/udev "$WORK/squashfs-root/etc/runlevels/sysinit/udev" 2>/dev/null || true
ln -sf /etc/init.d/udev-trigger "$WORK/squashfs-root/etc/runlevels/sysinit/udev-trigger" 2>/dev/null || true

echo "==> Setting up auto-login for live env..."
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
[ -f "$VMLINUZ" ] || die "No kernel found."
[ -f "$INITRD"  ] || die "No initrd found."
cp "$VMLINUZ" "$WORK/iso/boot/vmlinuz"
cp "$INITRD"  "$WORK/iso/boot/initrd.img"

echo "==> Writing GRUB config..."
mkdir -p "$WORK/iso/boot/grub/themes/boreal"
cp -r "$WORK/squashfs-root/usr/share/grub/themes/boreal/." "$WORK/iso/boot/grub/themes/boreal/"

cat > "$WORK/iso/boot/grub/grub.cfg" <<'GRUB'
insmod all_video
insmod gfxterm
insmod png
set gfxmode=1024x768,auto
set gfxpayload=keep
terminal_output gfxterm
set timeout_style=menu
set timeout=10
set default=0
set theme=/boot/grub/themes/boreal/theme.txt

menuentry "BorealOS Live" {
    linux /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}

menuentry "BorealOS Live (safe mode)" {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUB

echo "==> Building ISO..."
grub-mkrescue -o "$OUTPUT" "$WORK/iso" \
    --modules="normal iso9660 linux ext2 fat search search_label all_video gfxterm png" \
    2>/dev/null || die "grub-mkrescue failed"

ok "==> Done: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
