#!/bin/bash
set -e

# Always resolve paths relative to the script's own directory,
# not cwd. Prevents stale iso-work folders from accumulating when run as
# e.g. "sudo bash src/installer/build-iso.sh" from the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$SCRIPT_DIR/iso-work"
OUTPUT="$SCRIPT_DIR/borealOS.iso"
ROOTFS_TAR="$SCRIPT_DIR/borealOS-rootfs.tar.gz"
INSTALLER_SH="$SCRIPT_DIR/installer.sh"
WALLPAPER_DEFAULT="$SCRIPT_DIR/background_main.png"
WALLPAPER_ALT="$SCRIPT_DIR/background_one.png"
WALLPAPER_MAIN="$SCRIPT_DIR/background_main.png"
LOGO="$SCRIPT_DIR/logo.png"
BANNER="$SCRIPT_DIR/borealOS-text-and-logo-transparent.png"
BRANDING_ZIP="$SCRIPT_DIR/borealOS-branding.zip"
RICE_DIR="$SCRIPT_DIR/../rice"

RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
die()  { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }
ok()   { echo -e "${GRN}$1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

for f in "$ROOTFS_TAR" "$INSTALLER_SH" "$WALLPAPER_DEFAULT" "$LOGO" "$BANNER"; do
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
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/opt/borealOS/background_main.png"
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
# background_main.png is the primary wallpaper for installed system + live XFCE session
WP_MAIN="${WALLPAPER_MAIN:-$WALLPAPER_DEFAULT}"
cp "$WP_MAIN"         "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-default.png"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-waves.png"
cp "$WALLPAPER_ALT"   "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-alt.png"
cp "$LOGO"              "$WORK/squashfs-root/usr/share/boreal-artwork/logo.png"
cp "$BANNER"            "$WORK/squashfs-root/usr/share/boreal-artwork/banner.png"

echo "==> Creating GRUB theme..."
mkdir -p "$WORK/squashfs-root/usr/share/grub/themes/boreal"
convert "$WALLPAPER_DEFAULT" -resize 1920x1080! \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/background.png" 2>/dev/null || \
    cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/grub/themes/boreal/background.png"
# Banner PNG (logo+text combined, 3310x1254 = 2.638:1).
# Resize to 520px wide — height auto-scales to ~197px. NO height in theme.txt.
convert "$BANNER" -trim -resize 520x -background none \
    "$WORK/squashfs-root/usr/share/grub/themes/boreal/title.png" 2>/dev/null || \
    cp "$BANNER" "$WORK/squashfs-root/usr/share/grub/themes/boreal/title.png"

# Generate GRUB 9-slice rounded-corner selection highlight pixmaps.
# GRUB tiles these to draw the selected item box with rounded corners.
GRUB_THEME_DIR="$WORK/squashfs-root/usr/share/grub/themes/boreal"
GRUB_PIXMAP_DIR="$GRUB_THEME_DIR" python3 << 'GENPIXMAP'
import sys, struct, zlib, os

def make_png_rgba(w, h, pixels):
    def chunk(name, data):
        c = name + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = b""
    for y in range(h):
        raw += b"\x00"
        for x in range(w):
            raw += bytes(pixels[y*w+x])
    png  = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">II", w, h) + bytes([8, 6, 0, 0, 0]))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    return png

outdir = os.environ.get("GRUB_PIXMAP_DIR", "/usr/share/grub/themes/boreal")
BG   = (13,  51,  77, 200)
EDGE = (61, 255, 210, 220)
TRAN = (0,   0,   0,   0)
R = 8

def tile(w, h, tl=False, tr=False, bl=False, br=False):
    pix = []
    for y in range(h):
        for x in range(w):
            cut = (
                (tl and x<R   and y<R   and (x-R+1)**2+(y-R+1)**2 > R**2) or
                (tr and x>=w-R and y<R   and (x-w+R)**2+(y-R+1)**2 > R**2) or
                (bl and x<R   and y>=h-R and (x-R+1)**2+(y-h+R)**2 > R**2) or
                (br and x>=w-R and y>=h-R and (x-w+R)**2+(y-h+R)**2 > R**2)
            )
            if cut:
                pix.append(TRAN)
            elif x==0 or x==w-1 or y==0 or y==h-1:
                pix.append(EDGE)
            else:
                pix.append(BG)
    return pix

C=R; E=4
for name,w,h,args in [
    ("select_nw",C,C,dict(tl=True)),  ("select_n",E,C,{}),  ("select_ne",C,C,dict(tr=True)),
    ("select_w", C,E,{}),             ("select_c",E,E,{}),  ("select_e", C,E,{}),
    ("select_sw",C,C,dict(bl=True)),  ("select_s",E,C,{}),  ("select_se",C,C,dict(br=True)),
]:
    with open(f"{outdir}/{name}.png","wb") as f:
        f.write(make_png_rgba(w,h,tile(w,h,**args)))
    print(f"  {name}.png")
GENPIXMAP

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
    # Enforce width=520 (must match the resized title.png) and strip any height.
    # If theme width != actual image width, GRUB stretches to fill → egg/oval warp.
    python3 -c "
import re, sys
t = open(sys.argv[1]).read()
# Strip height= only from inside + image { } blocks (not boot_menu height which is valid)
t = re.sub(r'(\+\s*image\s*\{[^}]*)height\s*=\s*[^\n]+\n', r'\1', t, flags=re.DOTALL)
# Enforce width=520 inside + image { } blocks to match the resized banner PNG
t = re.sub(r'(\+\s*image\s*\{[^}]*)width\s*=\s*\d+', r'\g<1>width = 520', t, flags=re.DOTALL)
open(sys.argv[1], 'w').write(t)
" "$WORK/squashfs-root/usr/share/grub/themes/boreal/theme.txt"
    ok "Rice grub theme applied (image block: width=520, height stripped)"
else
    cat > "$WORK/squashfs-root/usr/share/grub/themes/boreal/theme.txt" <<'THEME'
desktop-image: "background.png"
desktop-color: "#51b2bb"
title-text: ""
message-font: "DejaVu Sans Regular 14"
message-color: "#4dffd2"
terminal-width: "80%"
terminal-height: "70%"
terminal-left: "10%"
terminal-top: "15%"

# Banner PNG (logo+text, 3310x1254 = 2.638:1 ratio).
# width=520 → natural height ~197px. NO height field — GRUB auto-scales correctly.
+ image {
    top = 6%
    left = 50%-280
    width = 520
    file = "title.png"
}

+ boot_menu {
    top = 46%
    left = 50%-200
    width = 400
    height = 36%
    item_font = "DejaVu Sans Bold 16"
    item_color = "#d0f5f0"
    selected_item_color = "#ffffff"
    selected_item_pixmap_style = "select_*.png"
    item_height = 42
    item_padding = 14
    item_spacing = 4
    scrollbar = false
}

+ label {
    top = 91%
    left = 0
    width = 100%
    align = "center"
    font = "DejaVu Sans Regular 13"
    color = "#4dffd2"
    text = "up/down: navigate    enter: boot    e: edit    c: console"
}
THEME
fi

echo "==> Writing xorg config..."
mkdir -p "$WORK/squashfs-root/etc/X11/xorg.conf.d"

# Input config: let libinput handle all devices via udev (modern approach).
cat > "$WORK/squashfs-root/etc/X11/xorg.conf.d/00-boreal-input.conf" <<'XORGCONF'
Section "InputClass"
    Identifier "libinput pointer"
    MatchIsPointer "on"
    Driver "libinput"
    Option "NaturalScrolling" "false"
EndSection

Section "InputClass"
    Identifier "libinput keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbLayout" "us"
EndSection
XORGCONF

# Video config: use fbdev as primary driver.
# - modesetting requires /dev/dri/card0 (KMS) — not always present in VMs → "no screens found"
# - vmware_drv segfaults in some VMware guest configs
# - fbdev works on any framebuffer device (/dev/fb0) including VMware, VirtualBox, QEMU, bare metal
# - vesa is the absolute last resort (no KMS, no fb required)
cat > "$WORK/squashfs-root/etc/X11/xorg.conf.d/10-boreal-video.conf" <<'XORGVIDEO'
Section "Device"
    Identifier "BorealOS Video"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
XORGVIDEO

# Blacklist vmware_drv via Xorg so it is never auto-loaded by the server
mkdir -p "$WORK/squashfs-root/usr/share/X11/xorg.conf.d"
cat > "$WORK/squashfs-root/usr/share/X11/xorg.conf.d/99-boreal-novm.conf" <<'XORGNVM'
Section "Module"
    Disable "vmware"
EndSection
XORGNVM

# Also make the start-graphical script try fbdev → vesa → modesetting in order
# by passing -config to Xorg so we always get a screen even on unusual hardware

rm -f "$WORK/squashfs-root/etc/X11/xorg.conf"

# udev rule: make all input devices readable by everyone in the live env.
# Normally input group handles this but in a minimal live env the group
# membership doesn't take effect until next login — chmod is instant.
mkdir -p "$WORK/squashfs-root/etc/udev/rules.d"
cat > "$WORK/squashfs-root/etc/udev/rules.d/99-boreal-input.rules" <<'UDVRULES'
# BorealOS live: make input devices world-accessible so X11 libinput works
# without needing proper group membership in the live session.
KERNEL=="event*", SUBSYSTEM=="input", MODE="0666"
KERNEL=="mice",   SUBSYSTEM=="input", MODE="0666"
KERNEL=="mouse*", SUBSYSTEM=="input", MODE="0666"
UDVRULES

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

echo "==> Copying XFCE rice configs..."
XFCE_RICE="$RICE_DIR/xfce4"

xfce_copy_to() {
    # xfce_copy_to <destination_skel_root>
    # Copies the rice into any given skel/home root.
    local DEST="$1"

    # Exact folder names from src/rice/xfce4/:
    #   desktop/  panel/  xfce4-screenshooter/  xfconf/

    # desktop/ → .config/xfce4/desktop/
    if [ -d "$XFCE_RICE/desktop" ]; then
        mkdir -p "$DEST/.config/xfce4/desktop"
        cp -r "$XFCE_RICE/desktop/." "$DEST/.config/xfce4/desktop/"
        echo "  xfce rice: desktop → .config/xfce4/desktop"
    fi

    # panel/ → .config/xfce4/panel/
    if [ -d "$XFCE_RICE/panel" ]; then
        mkdir -p "$DEST/.config/xfce4/panel"
        cp -r "$XFCE_RICE/panel/." "$DEST/.config/xfce4/panel/"
        echo "  xfce rice: panel → .config/xfce4/panel"
    fi

    # xfce4-screenshooter/ → .config/xfce4-screenshooter/
    if [ -d "$XFCE_RICE/xfce4-screenshooter" ]; then
        mkdir -p "$DEST/.config/xfce4-screenshooter"
        cp -r "$XFCE_RICE/xfce4-screenshooter/." "$DEST/.config/xfce4-screenshooter/"
        echo "  xfce rice: xfce4-screenshooter → .config/xfce4-screenshooter"
    fi

    # xfconf/ → .config/xfce4/xfconf/
    # This is the XFCE settings store — most important for theming/panel layout
    if [ -d "$XFCE_RICE/xfconf" ]; then
        mkdir -p "$DEST/.config/xfce4/xfconf"
        cp -r "$XFCE_RICE/xfconf/." "$DEST/.config/xfce4/xfconf/"
        echo "  xfce rice: xfconf → .config/xfce4/xfconf"
    fi
}

# 1. Apply to /etc/skel so every new user on the installed system gets the rice
xfce_copy_to "$SKEL"
ok "XFCE rice applied to skel."

# 2. Apply to live ISO root's home so the installer session itself looks riced.
# The live session runs as root, so target /root directly.
LIVE_ROOT="$WORK/squashfs-root/root"
mkdir -p "$LIVE_ROOT"
xfce_copy_to "$LIVE_ROOT"
ok "XFCE rice applied to live ISO root home."

echo "==> Applying BorealOS XFCE branding..."
# Copy logo to a standard icon path so the panel can reference it
mkdir -p "$WORK/squashfs-root/usr/share/pixmaps"
cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo.png"
convert "$LOGO" -resize 24x24 -background none     "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-24.png" 2>/dev/null || true

# Write a xfconf xsettings channel to set GTK theme and icon theme
mkdir -p "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<'XSETTINGS'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="hicolor"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="CursorThemeName" type="string" value="Adwaita"/>
  </property>
</channel>
XSETTINGS

# xfce4-desktop channel: set background_main.png as wallpaper for all monitors
cat > "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<'XFDESKTOP'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorVGA-1"  type="empty"><property name="workspace0" type="empty">
        <property name="last-image"   type="string"  value="/usr/share/boreal-artwork/wallpaper-waves.png"/>
        <property name="image-style"  type="int"     value="5"/>
        <property name="color-style"  type="int"     value="0"/>
      </property></property>
      <property name="monitorHDMI-1" type="empty"><property name="workspace0" type="empty">
        <property name="last-image"   type="string"  value="/usr/share/boreal-artwork/wallpaper-waves.png"/>
        <property name="image-style"  type="int"     value="5"/>
        <property name="color-style"  type="int"     value="0"/>
      </property></property>
      <property name="monitorVirtual-1" type="empty"><property name="workspace0" type="empty">
        <property name="last-image"   type="string"  value="/usr/share/boreal-artwork/wallpaper-waves.png"/>
        <property name="image-style"  type="int"     value="5"/>
        <property name="color-style"  type="int"     value="0"/>
      </property></property>
      <property name="monitoreDP-1"  type="empty"><property name="workspace0" type="empty">
        <property name="last-image"   type="string"  value="/usr/share/boreal-artwork/wallpaper-waves.png"/>
        <property name="image-style"  type="int"     value="5"/>
        <property name="color-style"  type="int"     value="0"/>
      </property></property>
    </property>
  </property>
</channel>
XFDESKTOP

# Patch the rice panel config to set the logo icon on applicationsmenu.
# We do NOT rewrite the whole panel XML — the rice config worked, we just need to:
#   1. Set the app menu button icon to the BorealOS logo
#   2. Remove power-manager-plugin if the rice included it (it's not installed)
PANEL_XML="$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
if [ -f "$PANEL_XML" ]; then
    # Remove any power-manager-plugin entry from plugin-ids array and plugin definitions
    python3 -c "
import re, sys
t = open(sys.argv[1]).read()
# Remove the plugin entry for power-manager-plugin
t = re.sub(r'<property name="plugin-\d+" type="string" value="power-manager-plugin"[^/]*/>', '', t)
t = re.sub(r'<property name="plugin-\d+" type="string" value="power-manager-plugin">.*?</property>', '', t, flags=re.DOTALL)
# Set the button-icon for applicationsmenu to the boreal logo
t = re.sub(
    r'(<property name="plugin-\d+" type="string" value="applicationsmenu">)(.*?)(</property>)',
    lambda m: m.group(1) + re.sub(r'(<property name="button-icon"[^/]*/>|<property name="button-icon"[^>]*>.*?</property>)', '', m.group(2), flags=re.DOTALL) + '  <property name="button-icon" type="string" value="/usr/share/pixmaps/boreal-logo-24.png"/>
  ' + m.group(3),
    t, flags=re.DOTALL
)
open(sys.argv[1], 'w').write(t)
" "$PANEL_XML" 2>/dev/null || true
    ok "Panel XML patched (power-manager removed, logo set)"
else
    warn "No rice panel XML found — XFCE will use defaults (that's fine)"
fi

# Create a .desktop for the installer launcher on the panel
mkdir -p "$WORK/squashfs-root/usr/share/applications"
cat > "$WORK/squashfs-root/usr/share/applications/boreal-installer.desktop" <<'DESKTOP'
[Desktop Entry]
Name=BorealOS Installer
Comment=Install BorealOS
Exec=calamares
Icon=/usr/share/pixmaps/boreal-logo.png
Type=Application
Categories=System;
DESKTOP

# Copy the same xfconf XMLs to /etc/skel so installed users get them too
SKEL_XFCONF="$WORK/squashfs-root/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$SKEL_XFCONF"
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"    "$SKEL_XFCONF/" 2>/dev/null || true
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"    "$SKEL_XFCONF/" 2>/dev/null || true
# Don't copy panel.xml to skel — installed users can have their own panel layout
ok "BorealOS XFCE branding applied."

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

# Diagnose common X startup failures before attempting
echo "==> Pre-flight checks..."
XORG_BIN=""
for p in /usr/lib/xorg/Xorg /usr/bin/Xorg /usr/bin/X; do
    [ -x "$p" ] && XORG_BIN="$p" && break
done
if [ -z "$XORG_BIN" ]; then
    echo "ERROR: Xorg binary not found. Check that xserver-xorg-core is installed."
    echo "Press Enter to return."; read -r; exit 1
fi
echo "  Xorg: $XORG_BIN"
command -v xinit    >/dev/null || { echo "ERROR: xinit not found"; read -r; exit 1; }
command -v startxfce4 >/dev/null || { echo "ERROR: startxfce4 not found"; read -r; exit 1; }
echo "  xinit, startxfce4: OK"

# Find a free VT. Live systems boot on tty1; we want to open X on the next free one.
VT=7
for v in 7 8 2 3 4 5 6; do
    fgconsole 2>/dev/null | grep -q "^${v}$" || { VT=$v; break; }
done
echo "  Using VT: $VT"

mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

cat > /root/.xinitrc <<'XINITRC'
#!/bin/bash
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export DISPLAY=:0

# D-Bus session
eval "$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true

# Wallpaper after desktop settles
(sleep 8
 WP=/usr/share/boreal-artwork/wallpaper-default.png
 [ -f "$WP" ] || WP=/usr/share/pixmaps/xfce4-logo.png
 for screen in screen0; do
   for mon in VGA-1 VGA1 HDMI-1 HDMI1 Virtual-1 Virtual1 DP-1 DP1                eDP-1 eDP1 DVI-1 DVI1 monitor0; do
     xfconf-query -c xfce4-desktop        -p "/backdrop/$screen/$mon/workspace0/last-image" -s "$WP" 2>/dev/null || true
     xfconf-query -c xfce4-desktop        -p "/backdrop/$screen/$mon/workspace0/image-style" -t int -s 5 2>/dev/null || true
   done
 done
 xfdesktop --reload 2>/dev/null || true
) &

# Launch Calamares after desktop is fully ready.
# Must use dbus-run-session or inherit the session bus; DISPLAY must be set.
# Restart on crash (non-zero exit); stop cleanly on success (exit 0).
(sleep 14
 while true; do
   DISPLAY=:0 dbus-run-session -- calamares 2>/tmp/calamares.log      || DISPLAY=:0 calamares 2>/tmp/calamares.log
   [ "$?" -eq 0 ] && break
   sleep 4
 done
) &

exec startxfce4
XINITRC
chmod +x /root/.xinitrc

# ── Input device setup ────────────────────────────────────────────────────────
# In the live env, udev may be running but the `input` group owns /dev/input/*.
# Root should always have access, but we chmod anyway as belt-and-suspenders.
# The real issue on many live systems: udevd is running but hasn't processed
# all add events yet, so libinput can't see the devices.

# 1. Start udevd if not already running
if ! pgrep -x udevd >/dev/null 2>&1 && ! pgrep -x systemd-udevd >/dev/null 2>&1; then
    echo "==> Starting udev..."
    if [ -x /sbin/udevd ]; then
        /sbin/udevd --daemon
    elif [ -x /usr/sbin/udevd ]; then
        /usr/sbin/udevd --daemon
    elif [ -x /lib/systemd/systemd-udevd ]; then
        /lib/systemd/systemd-udevd --daemon
    fi
    sleep 1
fi

# 2. Re-trigger all input device add events so libinput gets notified
udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true
udevadm settle --timeout=3 2>/dev/null || true

# 3. Direct chmod on all input nodes — works even if udev rules are wrong
chmod a+rw /dev/input/event* /dev/input/mice /dev/input/mouse* 2>/dev/null || true

# 4. Add root to input and plugdev groups (needed on some Debian live configs)
usermod -aG input,plugdev root 2>/dev/null || true

echo "  Input devices: $(ls /dev/input/event* 2>/dev/null | wc -l) event nodes found"

echo "==> Starting X on display :0 VT${VT}..."
# Try fbdev first; if Xorg still can't find a screen, retry with vesa
xinit /root/.xinitrc -- "$XORG_BIN" :0 vt${VT} -nolisten tcp     > /tmp/xorg.log 2>&1
XRET=$?
if [ "$XRET" -ne 0 ] && grep -q "no screens found" /tmp/xorg.log 2>/dev/null; then
    echo "fbdev failed — retrying with vesa driver..."
    cat > /etc/X11/xorg.conf.d/10-boreal-video.conf <<VESACFG
Section "Device"
    Identifier "BorealOS Video Vesa"
    Driver "vesa"
EndSection
VESACFG
    xinit /root/.xinitrc -- "$XORG_BIN" :0 vt${VT} -nolisten tcp         > /tmp/xorg.log 2>&1
    XRET=$?
fi
echo ""
if [ "$XRET" -ne 0 ]; then
    echo "X server exited with code $XRET."
fi
echo "--- Xorg log (last 30 lines) ---"
tail -30 /tmp/xorg.log
echo "--- XFCE session log ---"
cat /tmp/xfce4-session.log 2>/dev/null | tail -20 || true
echo "--- Calamares log ---"
cat /tmp/calamares.log 2>/dev/null | tail -10 || true
echo ""
echo "Press Enter to return to the menu."
read -r
GRAPHICAL
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-start-graphical"

echo "==> Installing packages..."
mount --bind /dev  "$WORK/squashfs-root/dev"
mount --bind /proc "$WORK/squashfs-root/proc"
mount --bind /sys  "$WORK/squashfs-root/sys"
cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"

# policy-rc.d: tells dpkg/invoke-rc.d to refuse ALL service start/restart
# actions during the chroot install. This is the standard Debian mechanism —
# without it, any package whose postinst calls `service X start` or
# `invoke-rc.d X start` will actually try to start the service inside the
# chroot, and for DMs that means registering runlevel symlinks.
cat > "$WORK/squashfs-root/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
# Deny all service actions during chroot build
exit 101
POLICY
chmod +x "$WORK/squashfs-root/usr/sbin/policy-rc.d"

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

# ── XFCE installer host DE ────────────────────────────────────────────────────
# Install XFCE with --no-install-recommends to prevent apt from pulling in
# lightdm/sddm as a recommended dep (xfce4 recommends a DM).
# We intentionally keep the live env DM-free: the TTY autologin → boreal-live.sh
# menu → boreal-start-graphical script calls startx directly. Any DM present
# at boot will register an OpenRC init script and hijack the TTY autologin.
apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal xfwm4 xfdesktop4 xfconf \
    xfce4-session xfce4-panel xfce4-settings \
    || echo "WARN: XFCE installer host install incomplete"

# Install the user's chosen DE (also --no-install-recommends to stay safe)
if [ -n "$DE_PKGS" ] && [ "$DE_PKGS" != "xfce4 xfce4-goodies" ]; then
    apt-get install -y --no-install-recommends $DE_PKGS || echo "WARN: some DE packages failed"
elif [ -n "$DE_PKGS" ]; then
    apt-get install -y --no-install-recommends $DE_PKGS || echo "WARN: some DE packages failed"
fi

for pkg in fastfetch kitty calamares calamares-qt6; do
    apt-get install -y "$pkg" 2>/dev/null || echo "SKIP: $pkg"
done

# lightdm is installed by installer.sh directly into the target, not the live env

# Also cache the user's chosen DM debs (sddm for KDE etc.) if different
mkdir -p /opt/borealOS/debs
if [ -n "$DM_PKGS" ]; then
    apt-get install -y --download-only $DM_PKGS 2>/dev/null || true
fi
cp /var/cache/apt/archives/*.deb /opt/borealOS/debs/ 2>/dev/null || true

echo 'root:borealOS' | chpasswd

# ── Nuclear DM purge ──────────────────────────────────────────────────────────
# Belt-and-suspenders: purge every known DM even if none were installed.
# Then delete every hook that could auto-start one on boot.
echo "==> Purging all display managers from live env..."
apt-get remove --purge -y \
    lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings \
    sddm gdm3 gdm xdm wdm nodm slim \
    2>/dev/null || true
apt-get autoremove --purge -y 2>/dev/null || true

# Remove every OpenRC/SysV runlevel symlink for any DM
for dm in lightdm sddm gdm gdm3 xdm wdm slim nodm; do
    rm -f /etc/runlevels/default/${dm} \
          /etc/runlevels/boot/${dm} \
          /etc/runlevels/sysinit/${dm} 2>/dev/null || true
    find /etc/rc*.d -name "*${dm}*" -delete 2>/dev/null || true
    # Stub out any surviving init.d script so it can't start anything
    if [ -f /etc/init.d/${dm} ]; then
        printf '#!/bin/sh\nexit 0\n' > /etc/init.d/${dm}
        chmod +x /etc/init.d/${dm}
    fi
done

# Remove the file that tells Xorg/PAM which DM to use
rm -f /etc/X11/default-display-manager 2>/dev/null || true
CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
ok "==> Packages installed."

echo "==> Setting up Calamares branding..."
BRAND_DEST="$WORK/squashfs-root/usr/share/calamares/branding/boreal"
mkdir -p "$BRAND_DEST"

if [ -f "$BRANDING_ZIP" ]; then
    rm -rf /tmp/calamares-branding
    unzip -o "$BRANDING_ZIP" -d /tmp/calamares-branding/ 2>/dev/null || true
    # Copy the base files (install.png, languages.png etc) from zip as fallback
    if [ -d /tmp/calamares-branding/branding/default ]; then
        cp /tmp/calamares-branding/branding/default/*.png "$BRAND_DEST/" 2>/dev/null || true
        cp /tmp/calamares-branding/branding/default/lang "$BRAND_DEST/" -r 2>/dev/null || true
    fi
    rm -rf /tmp/calamares-branding
fi

# --- branding.desc: fully updated for BorealOS ---
cat > "$BRAND_DEST/branding.desc" << 'BRANDDESC'
# BorealOS Calamares Branding
# SPDX-License-Identifier: CC0-1.0
---
componentName:  boreal

welcomeStyleCalamares:   false
welcomeExpandingLogo:    true

windowExpanding:    normal
windowSize:         900px,600px
windowPlacement:    center

sidebar:    widget
navigation: widget

strings:
    productName:         "BorealOS"
    shortProductName:    "Boreal"
    version:             "Alpha"
    shortVersion:        "alpha"
    versionedName:       "BorealOS Alpha"
    shortVersionedName:  "BorealOS Alpha"
    bootloaderEntryName: "BorealOS"
    productUrl:          "https://github.com/DamianDaniel/borealOS"
    supportUrl:          "https://github.com/DamianDaniel/borealOS/issues"

images:
    productBanner:       "banner.png"
    productIcon:         "logo.png"
    productLogo:         "logo.png"
    productWallpaper:    "wallpaper.png"
    productWelcome:      "welcome.png"

style:
    SidebarBackground:        "#0d1f2d"
    SidebarText:              "#b2f0e8"
    SidebarTextCurrent:       "#0d1f2d"
    SidebarBackgroundCurrent: "#3dffd2"

slideshow:      [ "install.png" ]
slideshowAPI:   1

uploadServer:
    type:      "none"
    url:       ""
    sizeLimit: -1
BRANDDESC

# --- stylesheet.qss: BorealOS teal/dark-navy palette ---
cat > "$BRAND_DEST/stylesheet.qss" << 'QSS'
#mainApp, QDialog {
    background-color: #0d1f2d;
    color: #e0f7f4;
    font-family: "Inter", "Noto Sans", sans-serif;
    font-size: 11pt;
}
#sidebarApp { background-color: #0d1f2d; color: #b2f0e8; }
#sidebarMenuApp { background-color: #0d1f2d; }
QPushButton {
    background-color: #163a4a; color: #3dffd2;
    border: 1px solid #3dffd2; border-radius: 4px; padding: 6px 16px;
}
QPushButton:hover { background-color: #1e5060; color: #ffffff; }
QPushButton:pressed { background-color: #3dffd2; color: #0d1f2d; }
QPushButton:disabled { background-color: #0d2535; color: #4a7a7a; border-color: #2a5555; }
QPushButton#pushButtonNext, QPushButton#pushButtonInstall {
    background-color: #3dffd2; color: #0d1f2d; font-weight: bold; border: none;
}
QPushButton#pushButtonNext:hover, QPushButton#pushButtonInstall:hover {
    background-color: #7fffd4;
}
QProgressBar {
    background-color: #163a4a; border: 1px solid #3dffd2;
    border-radius: 4px; text-align: center; color: #e0f7f4; height: 18px;
}
QProgressBar::chunk {
    background-color: qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 #3dffd2,stop:1 #5fffaa);
    border-radius: 3px;
}
QLineEdit, QComboBox, QSpinBox {
    background-color: #163a4a; color: #e0f7f4;
    border: 1px solid #2a6060; border-radius: 4px; padding: 4px 8px;
    selection-background-color: #3dffd2; selection-color: #0d1f2d;
}
QLineEdit:focus, QComboBox:focus { border-color: #3dffd2; }
QComboBox QAbstractItemView {
    background-color: #163a4a; color: #e0f7f4;
    selection-background-color: #3dffd2; selection-color: #0d1f2d;
    border: 1px solid #3dffd2;
}
QListView, QTreeView, QTableView {
    background-color: #0f2535; color: #e0f7f4;
    border: 1px solid #2a6060; alternate-background-color: #163a4a;
}
QListView::item:selected, QTreeView::item:selected {
    background-color: #3dffd2; color: #0d1f2d;
}
QScrollBar:vertical { background: #0d1f2d; width: 8px; border-radius: 4px; }
QScrollBar::handle:vertical { background: #3dffd2; border-radius: 4px; min-height: 20px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar:horizontal { background: #0d1f2d; height: 8px; border-radius: 4px; }
QScrollBar::handle:horizontal { background: #3dffd2; border-radius: 4px; min-width: 20px; }
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }
QLabel { color: #e0f7f4; }
QLabel#labelWelcome, QLabel#labelSubtitle { color: #3dffd2; font-size: 14pt; font-weight: bold; }
QCheckBox, QRadioButton { color: #e0f7f4; spacing: 6px; }
QCheckBox::indicator, QRadioButton::indicator {
    width: 14px; height: 14px; border: 1px solid #3dffd2;
    background: #163a4a; border-radius: 3px;
}
QCheckBox::indicator:checked { background-color: #3dffd2; }
QRadioButton::indicator { border-radius: 7px; }
QRadioButton::indicator:checked { background-color: #3dffd2; }
QGroupBox {
    border: 1px solid #2a6060; border-radius: 6px;
    margin-top: 8px; padding-top: 8px; color: #3dffd2; font-weight: bold;
}
QGroupBox::title { subcontrol-origin: margin; left: 12px; padding: 0 4px; }
QTabBar::tab {
    background: #163a4a; color: #b2f0e8; border: 1px solid #2a6060;
    border-bottom: none; padding: 6px 14px;
    border-top-left-radius: 4px; border-top-right-radius: 4px;
}
QTabBar::tab:selected { background: #0d1f2d; color: #3dffd2; border-bottom: 2px solid #3dffd2; }
QTabWidget::pane { border: 1px solid #2a6060; }
QSS

# --- Convert borealOS images to correct Calamares slot sizes ---
# banner.png  : top-of-welcome wide banner, max 460x64px
convert "$BANNER" -trim -resize 460x64 -background none -gravity center \
    -extent 460x64 "$BRAND_DEST/banner.png" 2>/dev/null || \
    cp "$BANNER" "$BRAND_DEST/banner.png"

# logo.png    : sidebar step indicator + window icon, 80x80px square
convert "$LOGO" -resize 80x80 -background none -gravity center \
    -extent 80x80 "$BRAND_DEST/logo.png" 2>/dev/null || \
    cp "$LOGO" "$BRAND_DEST/logo.png"

# welcome.png : center of welcome page, 320x150px (fits the window well)
convert "$LOGO" -resize 320x320 -background none -gravity center \
    "$BRAND_DEST/welcome.png" 2>/dev/null || \
    cp "$LOGO" "$BRAND_DEST/welcome.png"

# wallpaper.png : Calamares window background 900x600
WP_MAIN="${WALLPAPER_MAIN:-$WALLPAPER_DEFAULT}"
convert "$WP_MAIN" -resize 900x600 -background black -gravity center -extent 900x600 \
    "$BRAND_DEST/wallpaper.png" 2>/dev/null || \
    cp "$WP_MAIN" "$BRAND_DEST/wallpaper.png"

ok "Calamares branding installed (BorealOS assets + theme)."

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

# Remove plymouth entirely from the live env — not used, and its initramfs hook
# adds boot delay and can conflict with simple console boot.
find "$WORK/squashfs-root/usr/share/plymouth"      "$WORK/squashfs-root/etc/plymouth"      -delete 2>/dev/null || true
rm -f "$WORK/squashfs-root/usr/share/initramfs-tools/hooks/plymouth"       "$WORK/squashfs-root/etc/initramfs-tools/conf.d/plymouth" 2>/dev/null || true

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
