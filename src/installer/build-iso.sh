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
WALLPAPER_BG2="$SCRIPT_DIR/background_2.png"
LOGO="$SCRIPT_DIR/logo.png"
GHOST_LOGO="$SCRIPT_DIR/borealos-ghost-logo.png"
BANNER="$SCRIPT_DIR/borealOS-text-and-logo-transparent.png"
BRANDING_ZIP="$SCRIPT_DIR/borealOS-branding.zip"
RICE_DIR="$SCRIPT_DIR/../rice"

RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
die()  { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }
ok()   { echo -e "${GRN}$1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

for f in "$ROOTFS_TAR" "$INSTALLER_SH" "$WALLPAPER_DEFAULT" "$WALLPAPER_BG2" "$LOGO" "$BANNER"; do
    [ -f "$f" ] || die "Missing: $f"
done
[ "$EUID" -eq 0 ] || die "Run as root."

command -v xorriso       >/dev/null || apt-get install -y xorriso        || die "Failed to install xorriso"
command -v convert       >/dev/null || apt-get install -y imagemagick    || die "Failed to install imagemagick"
dpkg -s grub-efi-amd64-bin >/dev/null 2>&1 || apt-get install -y grub-efi-amd64-bin || die "Failed to install grub-efi-amd64-bin"
dpkg -s grub-pc-bin        >/dev/null 2>&1 || apt-get install -y grub-pc-bin        || die "Failed to install grub-pc-bin"
dpkg -s mtools             >/dev/null 2>&1 || apt-get install -y mtools             || die "Failed to install mtools"
command -v grub-mkrescue >/dev/null || apt-get install -y grub2-common || die "Failed to install grub2-common"
command -v mksquashfs    >/dev/null || apt-get install -y squashfs-tools  || die "Failed to install squashfs-tools"
command -v unzip         >/dev/null || apt-get install -y unzip           || die "Failed to install unzip"

EFI_PLATFORM_DIR="$(find /usr/lib/grub -maxdepth 1 -type d -name 'x86_64-efi' 2>/dev/null | head -1)"
[ -n "$EFI_PLATFORM_DIR" ] || die "grub x86_64-efi platform directory not found - grub-efi-amd64-bin did not install correctly, EFI ISO cannot be built"

echo ""
echo -e "${BLD}Select DE/WM to include in ISO:${RST}"
echo "  1) KDE Plasma"
echo "  2) XFCE"
echo "  3) Niri (Wayland, built from source)"
echo "  4) None (TTY only)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r de_choice
    case "$de_choice" in
        1) DE_PKGS="kde-plasma-desktop"; DM_PKGS="sddm"; DE_NAME="KDE Plasma"; DE_START="startplasma-x11"; break ;;
        2) DE_PKGS="xfce4 xfce4-goodies gvfs gvfs-backends tumbler tumbler-plugins-extra"; DE_EXTRA_PKGS="fonts-ibm-plex papirus-icon-theme materia-gtk-theme"; DM_PKGS="lightdm lightdm-gtk-greeter"; DE_NAME="XFCE"; DE_START="startxfce4"; break ;;
        3) DE_PKGS="foot"; DM_PKGS=""; DE_NAME="Niri"; DE_START="niri-session"; break ;;
        4) DE_PKGS=""; DM_PKGS=""; DE_NAME="None"; DE_START=""; break ;;
        *) echo -e "${RED}Invalid.${RST}" ;;
    esac
done

echo ""
echo -e "${BLD}Select kernel:${RST}"
echo "  1) linux-image-amd64 from trixie-backports (current, 7.0.x)"
echo "  2) linux-image-6.18-amd64 from trixie-backports (LTS 6.18.x)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r kern_choice
    case "$kern_choice" in
        1) KERNEL_PKG="linux-image-amd64"; KERNEL_NAME="7.0 current (trixie-backports)"; break ;;
        2) KERNEL_PKG="linux-image-6.18-amd64"; KERNEL_NAME="6.18 LTS (trixie-backports)"; break ;;
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
cp "$WALLPAPER_BG2"     "$WORK/squashfs-root/opt/borealOS/background_2.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/opt/borealOS/background_one.png"
cp "$LOGO"              "$WORK/squashfs-root/opt/borealOS/logo.png"
[ -f "$GHOST_LOGO" ] && cp "$GHOST_LOGO" "$WORK/squashfs-root/opt/borealOS/logo-ghost.png"
cp "$BANNER"            "$WORK/squashfs-root/opt/borealOS/banner.png"
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
cp "$WP_MAIN"           "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-default.png"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-waves.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-alt.png"


# Set it as the xfdesktop default via the defaults config
mkdir -p "$WORK/squashfs-root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
{
echo '<?xml version="1.0" encoding="UTF-8"?>'
echo '<channel name="xfce4-desktop" version="1.0">'
echo '  <property name="backdrop" type="empty">'
echo '    <property name="screen0" type="empty">'
echo '      <property name="monitor0" type="empty">'
echo '        <property name="workspace0" type="empty">'
echo '          <property name="last-image" type="string" value="/usr/share/xfce4/backdrops/BorealOS.png"/>'
echo '          <property name="image-style" type="int" value="5"/>'
echo '        </property>'
echo '      </property>'
for mon in Virtual-1 Virtual-0 VGA-1 VGA-0 HDMI-1 HDMI-0 DP-1 DP-0 eDP-1 eDP-0 DVI-I-1 DVI-D-1; do
    echo "      <property name=\"${mon}\" type=\"empty\">"
    echo '        <property name="workspace0" type="empty">'
    echo '          <property name="last-image" type="string" value="/usr/share/xfce4/backdrops/BorealOS.png"/>'
    echo '          <property name="image-style" type="int" value="5"/>'
    echo '        </property>'
    echo '      </property>'
done
echo '    </property>'
echo '  </property>'
echo '</channel>'
} > "$WORK/squashfs-root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
cp "$LOGO"              "$WORK/squashfs-root/usr/share/boreal-artwork/logo.png"
[ -f "$GHOST_LOGO" ] && cp "$GHOST_LOGO" "$WORK/squashfs-root/usr/share/boreal-artwork/logo-ghost.png"
cp "$BANNER"            "$WORK/squashfs-root/usr/share/boreal-artwork/banner.png"
chmod 755 "$WORK/squashfs-root/usr/share/boreal-artwork"
chmod 644 "$WORK/squashfs-root/usr/share/boreal-artwork/"*.png

echo "==> Creating GRUB theme..."
GRUB_THEME_DIR="$WORK/squashfs-root/usr/share/grub/themes/boreal"
mkdir -p "$GRUB_THEME_DIR"
convert "$WALLPAPER_DEFAULT" -resize 1920x1080! \
    "$GRUB_THEME_DIR/background.png" 2>/dev/null || \
    cp "$WALLPAPER_DEFAULT" "$GRUB_THEME_DIR/background.png"
convert "$BANNER" -trim -resize 520x -background none \
    "$GRUB_THEME_DIR/title.png" 2>/dev/null || \
    cp "$BANNER" "$GRUB_THEME_DIR/title.png"

# Selection-highlight bar. GRUB's pixmap_style only requires the "_c" (center)
# slice to be present — missing edge slices are silently skipped, so a single
# flat image is a stable, supported highlight box (not a 9-slice gimmick).
SELECT_IMG="$SCRIPT_DIR/select.png"
if [ -f "$SELECT_IMG" ]; then
    cp "$SELECT_IMG" "$GRUB_THEME_DIR/select_c.png"
fi

# Compute the actual rendered height of title.png so the theme never has to
# guess at an aspect ratio (this was the source of the previous oval/egg warp).
TITLE_H=$(identify -format "%h" "$GRUB_THEME_DIR/title.png" 2>/dev/null || echo 197)

cat > "$GRUB_THEME_DIR/theme.txt" <<THEME
desktop-image: "background.png"
desktop-color: "#51b2bb"
title-text: ""
message-font: "DejaVu Sans Regular 14"
message-color: "#4dffd2"
terminal-width: "80%"
terminal-height: "70%"
terminal-left: "10%"
terminal-top: "15%"

+ image {
    top = 6%
    left = 50%-260
    width = 520
    height = ${TITLE_H}
    file = "title.png"
}

+ boot_menu {
    top = 46%
    left = 50%-200
    width = 400
    height = 36%
    item_font = "DejaVu Sans Bold 16"
    item_color = "#d0f5f0"
    selected_item_color = "#0d1f2d"
    item_height = 42
    item_padding = 14
    item_spacing = 4
    icon_width = 0
    icon_height = 0
    scrollbar = false
THEME
if [ -f "$GRUB_THEME_DIR/select_c.png" ]; then
    cat >> "$GRUB_THEME_DIR/theme.txt" <<THEME
    selected_item_pixmap_style = "select_*.png"
THEME
fi
cat >> "$GRUB_THEME_DIR/theme.txt" <<THEME
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
ok "GRUB theme generated (stable, single source of truth, no regex patching)."

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
if [ "$DE_NAME" != "None" ]; then
    copy_rice "fastfetch/config.jsonc" ".config/fastfetch/config.jsonc"
    copy_rice "kitty/kitty.conf"       ".config/kitty/kitty.conf"
    copy_rice "kitty/dark.conf"        ".config/kitty/dark.conf"
    copy_rice "kitty/light.conf"       ".config/kitty/light.conf"
fi
if [ "$DE_NAME" = "Niri" ]; then
    copy_rice "niri/config.kdl"        ".config/niri/config.kdl"
fi

if [ "$DE_NAME" = "XFCE" ]; then
echo "==> Copying XFCE rice configs..."
XFCE_RICE="$RICE_DIR/xfce4"

xfce_copy_to() {
    local DEST="$1"

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
fi

echo "==> Applying BorealOS XFCE branding..."
# Copy logo to pixmaps
mkdir -p "$WORK/squashfs-root/usr/share/pixmaps"
cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo.png"
if [ -f "$GHOST_LOGO" ]; then
    cp "$GHOST_LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-ghost.png"
else
    cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-ghost.png"
fi
convert "$LOGO" -resize 24x24 -background none     "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-24.png" 2>/dev/null || true
convert "$LOGO" -resize 48x48 -background none     "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-48.png" 2>/dev/null || true

# Replace the xfce4 logo used by the apps-menu panel button with our logo.
# xfce4-panel's applicationsmenu plugin uses "org.xfce.panel" or "xfce4-logo" icon.
# We overwrite those in hicolor so our logo appears without any xfconf needed.
for size in 16 24 32 48 64 96 128; do
    dir="$WORK/squashfs-root/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    convert "$LOGO" -resize ${size}x${size} -background none         "$dir/xfce4-logo.png" 2>/dev/null || true
    cp "$dir/xfce4-logo.png" "$dir/org.xfce.panel.png" 2>/dev/null || true
    cp "$dir/xfce4-logo.png" "$dir/xfce-logo.png" 2>/dev/null || true
done

mkdir -p "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<'XSETTINGS'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Materia-dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
    <property name="DoubleClickTime" type="int" value="400"/>
    <property name="DoubleClickDistance" type="int" value="5"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="FontName" type="string" value="IBM Plex Sans 10"/>
    <property name="MonospaceFontName" type="string" value="IBM Plex Mono 10"/>
  </property>
</channel>
XSETTINGS

mkdir -p "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<'XFWM4'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Materia-dark"/>
    <property name="title_font" type="string" value="IBM Plex Sans Bold 10"/>
    <property name="double_click_action" type="string" value="maximize"/>
    <property name="double_click_time" type="int" value="400"/>
    <property name="double_click_distance" type="int" value="5"/>
    <property name="click_to_focus" type="bool" value="true"/>
    <property name="wrap_workspaces" type="bool" value="true"/>
    <property name="box_move" type="bool" value="false"/>
    <property name="box_resize" type="bool" value="false"/>
  </property>
</channel>
XFWM4

cat > "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml" <<'XFSESSION'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="SaveOnExit" type="bool" value="false"/>
    <property name="LockScreen" type="string" value="xflock4"/>
  </property>
  <property name="shutdown" type="empty">
    <property name="ShowOnLogout" type="bool" value="true"/>
  </property>
</channel>
XFSESSION

# xfce4-desktop channel: wallpaper for all common monitor connectors + no system icons
# xfdesktop4 stores wallpaper under the raw connector name (e.g. "Virtual-1"),
# NOT prefixed with "monitor". Cover every common name so it works everywhere.
WP=/usr/share/boreal-artwork/wallpaper-default.png
{
cat << XFDESKTOP_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
XFDESKTOP_HEAD
for mon in Virtual-1 Virtual-0 VGA-1 VGA-0 HDMI-1 HDMI-0            DP-1 DP-0 eDP-1 eDP-0 DVI-I-1 DVI-D-1; do
cat << MONBLOCK
      <property name="${mon}" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image"  type="string" value="${WP}"/>
          <property name="image-style" type="int"    value="5"/>
          <property name="color-style" type="int"    value="0"/>
        </property>
      </property>
MONBLOCK
done
cat << XFDESKTOP_FOOT
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style"             type="int"  value="2"/>
    <property name="file-icons" type="empty">
      <property name="show-home"       type="bool" value="false"/>
      <property name="show-filesystem" type="bool" value="false"/>
      <property name="show-removable"  type="bool" value="false"/>
      <property name="show-trash"      type="bool" value="false"/>
    </property>
  </property>
</channel>
XFDESKTOP_FOOT
} > "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
# Copy to skel too
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"    "$WORK/squashfs-root/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" 2>/dev/null || true

# TTY install wrapper — runs the terminal installer
cat > "$WORK/squashfs-root/usr/local/bin/boreal-tty-install" <<'TTYINSTALL'
#!/bin/bash
if command -v borealOS-install >/dev/null 2>&1; then
    borealOS-install
else
    echo "ERROR: borealOS-install not found"
    read -r
fi
TTYINSTALL
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-tty-install"

# Terminal launcher: tries kitty (with rice config) → xfce4-terminal → xterm
# Terminal launcher helper, used by tty install command if run manually
cat > "$WORK/squashfs-root/usr/local/bin/boreal-open-terminal" <<'TERMLAUNCH'
#!/bin/bash
# Usage: boreal-open-terminal <command>
CMD="$1"
KITTY_CONF=/root/.config/kitty/kitty.conf
if command -v kitty >/dev/null 2>&1; then
    if [ -f "$KITTY_CONF" ]; then
        kitty --config "$KITTY_CONF" bash -c "$CMD; bash"
    else
        kitty bash -c "$CMD; bash"
    fi
elif command -v xfce4-terminal >/dev/null 2>&1; then
    xfce4-terminal --hold -e "bash -c '$CMD; bash'"
else
    xterm -hold -e "bash -c '$CMD; bash'"
fi
TERMLAUNCH
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-open-terminal"

# Copy kitty rice configs to live root so the TTY install terminal looks riced
if [ -d "$RICE_DIR/kitty" ]; then
    mkdir -p "$WORK/squashfs-root/root/.config/kitty"
    cp -r "$RICE_DIR/kitty/." "$WORK/squashfs-root/root/.config/kitty/"
    echo "  kitty rice copied to live root"
fi

# Patch the rice panel config to set the logo icon on applicationsmenu.
# We do NOT rewrite the whole panel XML — the rice config worked, we just need to:
#   1. Set the app menu button icon to the BorealOS logo
#   2. Remove power-manager-plugin if the rice included it (it's not installed)
PANEL_XML="$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
SKEL_PANEL_XML="$WORK/squashfs-root/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"

# Remove power-manager-plugin from panel XML using grep/awk — no Python quoting issues.
# Strategy: skip any line containing power-manager-plugin AND the next closing </property>
# if it immediately follows (for multi-line blocks).
# Remove power-manager-plugin from panel XML entirely using awk.
# awk handles multi-line blocks and the orphaned array entry in one pass.
patch_panel_xml_simple() {
    local f="$1"
    [ -f "$f" ] || return 0

    # Step 1: collect plugin IDs that are power-manager-plugin using grep + sed
    # (POSIX-compatible, no gawk needed)
    local bad_ids
    bad_ids=$(grep 'value="power-manager-plugin"' "$f" | \
              sed 's/.*name="plugin-\([0-9]*\)".*/\1/' | \
              grep '^[0-9]*$' || true)

    # Step 2: remove the power-manager-plugin property block (self-closing form)
    sed -i '/value="power-manager-plugin"/d' "$f"

    # Step 3: remove orphaned <value type="int" value="N"/> for each bad ID
    for pid in $bad_ids; do
        sed -i "/type=\"int\" value=\"${pid}\"/d" "$f"
    done

    echo "  patched: $f (removed plugin IDs: ${bad_ids:-none})"
}

patch_panel_xml_simple "$PANEL_XML"
patch_panel_xml_simple "$SKEL_PANEL_XML"
ok "Panel XML patched (power-manager removed)"

# Reliable taskbar/menu-button icon fix. The previous approach overwrote
# generic icon-theme filenames (xfce4-logo.png etc.) guessing what icon name
# the applicationsmenu plugin requests — that name differs across Xfce
# versions (4.16 uses "xfce4-logo", 4.18 often defaults to
# "org.xfce.panel.applicationsmenu" or a generic "start-here" fallback), so
# the guess silently misses depending on which Xfce is actually installed.
# Set it explicitly via xfconf instead, which works regardless of version.
cat > "$WORK/squashfs-root/usr/local/bin/boreal-panel-icon.sh" <<'PANELICON'
#!/bin/bash
for i in 1 2 3 4 5 6; do
    command -v xfconf-query >/dev/null 2>&1 && xfconf-query -c xfce4-panel -p /plugins -l >/dev/null 2>&1 && break
    sleep 2
done
IDS=$(xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null | grep -oE 'plugin-[0-9]+' | sort -u)
for id in $IDS; do
    val=$(xfconf-query -c xfce4-panel -p "/plugins/$id" 2>/dev/null)
    if [ "$val" = "applicationsmenu" ] || [ "$val" = "whiskermenu" ]; then
        xfconf-query -c xfce4-panel -p "/plugins/${id}/button-icon" -n -t string -s /usr/share/pixmaps/boreal-logo-ghost.png 2>/dev/null || \
        xfconf-query -c xfce4-panel -p "/plugins/${id}/button-icon" -t string -s /usr/share/pixmaps/boreal-logo-ghost.png 2>/dev/null
    fi
done
PANELICON
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-panel-icon.sh"

mkdir -p "$WORK/squashfs-root/root/.config/autostart"
cat > "$WORK/squashfs-root/root/.config/autostart/boreal-panel-icon.desktop" <<'PANELAUTOSTART'
[Desktop Entry]
Type=Application
Name=BorealOS Panel Icon
Exec=/usr/local/bin/boreal-panel-icon.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
PANELAUTOSTART
mkdir -p "$WORK/squashfs-root/etc/skel/.config/autostart"
cp "$WORK/squashfs-root/root/.config/autostart/boreal-panel-icon.desktop" \
   "$WORK/squashfs-root/etc/skel/.config/autostart/boreal-panel-icon.desktop"

# Create a .desktop for the installer launcher on the panel
mkdir -p "$WORK/squashfs-root/usr/share/applications"
cat > "$WORK/squashfs-root/usr/share/applications/boreal-installer.desktop" <<'DESKTOP'
[Desktop Entry]
Name=BorealOS Installer
Comment=Install BorealOS
Exec=/usr/local/bin/boreal-installer
Icon=/usr/share/pixmaps/boreal-logo.png
StartupWMClass=boreal-installer
Type=Application
Categories=System;
DESKTOP

# Copy the same xfconf XMLs to /etc/skel so installed users get them too
SKEL_XFCONF="$WORK/squashfs-root/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$SKEL_XFCONF"
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"  "$SKEL_XFCONF/" 2>/dev/null || true
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"      "$SKEL_XFCONF/" 2>/dev/null || true
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"          "$SKEL_XFCONF/" 2>/dev/null || true
cp "$WORK/squashfs-root/root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml"  "$SKEL_XFCONF/" 2>/dev/null || true
# Don't copy panel.xml to skel — installed users can have their own panel layout
ok "BorealOS XFCE branding applied."

echo "==> Applying branding..."
cat > "$WORK/squashfs-root/etc/os-release" <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS alpha"
ID=borealos
ID_LIKE=
VERSION="1.0"
VERSION_ID="1.0"
HOME_URL="https://borealos.org"
OS
cat > "$WORK/squashfs-root/etc/lsb-release" <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=alpha
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS alpha"
LSB
echo "BorealOS"      > "$WORK/squashfs-root/etc/issue"
echo "BorealOS alpha"  > "$WORK/squashfs-root/etc/issue.net"
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
    echo "  BorealOS alpha Live  |  DE: $DE"
    echo ""
    echo "  1) Graphical Install"
    echo "  2) Terminal Installer"
    echo "  3) Shell"
    echo ""
    echo -n "  Choice: "
    read -r choice
    case "$choice" in
        1)
            if [ ! -x /usr/local/bin/boreal-installer ]; then
                echo "Graphical installer not found in this ISO."
                sleep 2
            else
                clear
                /usr/local/bin/boreal-start-graphical
                break
            fi
            ;;
        2)
            clear
            borealOS-install
            break
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
# Runs the BorealOS graphical installer directly on a bare X server.
# No window manager, no desktop session - just our installer as the sole
# X client, drawn fullscreen. The user's chosen DE is installed separately
# onto the target disk by the installer itself; this session only hosts
# the installer program.

if [ ! -x /usr/local/bin/boreal-installer ]; then
    echo "ERROR: boreal-installer not found. Rebuild the ISO."
    echo "Press Enter to return."
    read -r; exit 0
fi

echo "Starting BorealOS graphical installer..."

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
command -v xinit >/dev/null || { echo "ERROR: xinit not found"; read -r; exit 1; }
echo "  xinit: OK"

VT=7
for v in 7 8 2 3 4 5 6; do
    fgconsole 2>/dev/null | grep -q "^${v}$" || { VT=$v; break; }
done
echo "  Using VT: $VT"

mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

cat > /root/.xinitrc <<'XINITRC'
#!/bin/bash
export DISPLAY=:0
eval "$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true
xsetroot -cursor_name left_ptr 2>/dev/null || true
exec /usr/local/bin/boreal-installer
XINITRC
chmod +x /root/.xinitrc

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

udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true
udevadm settle --timeout=3 2>/dev/null || true
chmod a+rw /dev/input/event* /dev/input/mice /dev/input/mouse* 2>/dev/null || true
usermod -aG input,plugdev root 2>/dev/null || true

echo "  Input devices: $(ls /dev/input/event* 2>/dev/null | wc -l) event nodes found"

echo "==> Starting X on display :0 VT${VT}..."
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
echo "--- boreal-installer log ---"
cat /tmp/boreal-installer.log 2>/dev/null | tail -20 || true
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
echo "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" > /etc/apt/sources.list
PYVER=\$(ls /usr/lib/ | grep -oP '^python3\.[0-9]+\$' | sort -V | tail -1)
if [ -n "\$PYVER" ]; then
    mkdir -p /usr/share/python3
    if [ ! -s /usr/share/python3/debian_defaults ]; then
        cat > /usr/share/python3/debian_defaults <<PYDEFAULTS
[DEFAULT]
default-version = \${PYVER}
supported-versions = \${PYVER}
unsupported-versions =
requested-versions = \${PYVER#python}
PYDEFAULTS
    fi
fi
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall python3-minimal || true
dpkg --configure -a || true
apt-get update -qq

echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list
apt-get update -qq

apt-get install -y --no-install-recommends -t trixie-backports ${KERNEL_PKG}

apt-get install -y --no-install-recommends \
    grub-efi-amd64 grub-efi-amd64-bin grub-pc-bin grub-common \
    efibootmgr \
    live-boot live-boot-initramfs-tools \
    openrc \
    network-manager ifupdown dhcpcd5 \
    parted dosfstools e2fsprogs \
    cryptsetup cryptsetup-initramfs lvm2 \
    btrfs-progs xfsprogs \
    passwd sudo \
    bash bash-completion \
    iproute2 iputils-ping net-tools \
    curl wget nano less \
    tzdata locales console-setup \
    openssl libdevmapper1.02.1 libefivar1 libefiboot1 \
    os-prober python3 rsync \
    fonts-dejavu-core \
    wpasupplicant \
    elogind libpam-elogind polkitd pkexec \
    chrony \
    $SHELL_PKG

if [ "$DE_NAME" != "None" ]; then
apt-get install -y --no-install-recommends \
    xserver-xorg xserver-xorg-core xserver-xorg-legacy \
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
    adwaita-icon-theme gnome-themes-extra \
    libinput10 libinput-dev \
    udev

# This live/installed environment has no systemd-logind/elogind seat manager,
# so Xorg needs the classic setuid wrapper to be allowed to open /dev/tty*
# and the DRM/input devices for a non-root user (otherwise: "parse_vt_settings:
# Cannot open /dev/tty0 (Permission denied)" when running startx/startxfce4).
mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config <<'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP
for xorgbin in /usr/lib/xorg/Xorg /usr/lib/xorg/Xorg.wrap; do
    [ -f "$xorgbin" ] && chmod u+s "$xorgbin"
done

for pkg in virtualbox-guest-x11 virtualbox-guest-utils xf86-video-vmware; do
    apt-get install -y "$pkg" 2>/dev/null || echo "SKIP: $pkg"
done
fi

# Install the user's chosen DE
if [ -n "$DE_PKGS" ]; then
    apt-get install -y --no-install-recommends $DE_PKGS || { echo "FATAL: DE package install failed ($DE_PKGS), see error above"; exit 1; }
    if [ -n "$DM_PKGS" ]; then
        apt-get install -y --no-install-recommends $DM_PKGS || { echo "FATAL: DM package install failed ($DM_PKGS), see error above"; exit 1; }
    fi
    if [ -n "$DE_EXTRA_PKGS" ]; then
        apt-get install -y --no-install-recommends $DE_EXTRA_PKGS || echo "WARN: theming packages failed ($DE_EXTRA_PKGS) - desktop will use default theme/icons/fonts"
    fi
fi

if [ "$DE_NAME" != "None" ]; then
    apt-get install -y --no-install-recommends fastfetch || echo "FAILED: fastfetch install, see error above"
    apt-get install -y --no-install-recommends kitty || { echo "FATAL: kitty install failed, see error above"; exit 1; }
    command -v kitty >/dev/null 2>&1 || { echo "FATAL: kitty binary missing after install"; exit 1; }

    if command -v kitty >/dev/null 2>&1; then
        update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/kitty 50 2>/dev/null || true
        update-alternatives --set x-terminal-emulator /usr/bin/kitty 2>/dev/null || true
        mkdir -p /etc/xdg/xfce4
        cat > /etc/xdg/xfce4/helpers.rc <<HELPERSRC
TerminalEmulator=kitty
HELPERSRC
    fi
fi

if [ "$DE_NAME" != "None" ]; then
    apt-get install -y --no-install-recommends gcc make pkg-config libgtk-3-dev libgtk-3-0 \
        || echo "WARN: GTK3 build deps failed"
fi

# lightdm is now installed normally above (with $DE_PKGS), so it gets
# properly configured with full dependency resolution and rides along
# to the target via the rsync copy of the live system - no more fragile
# separate offline-cache/dpkg-i dance for the DM itself.
mkdir -p /opt/borealOS/debs

echo 'root:borealOS' | /usr/sbin/chpasswd

# ── Disable (not uninstall) any display manager in the live env ────────────
# lightdm's own postinst auto-enables it via rc-update, which would make the
# live boot media show a login screen instead of going straight to the
# installer. We want the package itself to stay installed (so it rsyncs
# onto the target intact), just not auto-started here in the live env -
# the installer re-enables it for the target specifically later.
echo "==> Disabling (not removing) any display manager for the live boot..."
for dm in lightdm sddm gdm gdm3 xdm wdm slim nodm; do
    rc-update del ${dm} default 2>/dev/null || true
    rc-update del ${dm} boot 2>/dev/null || true
    rm -f /etc/runlevels/default/${dm} \
          /etc/runlevels/boot/${dm} \
          /etc/runlevels/sysinit/${dm} 2>/dev/null || true
    find /etc/rc*.d -name "*${dm}*" -delete 2>/dev/null || true
done

# Remove the file that tells Xorg/PAM which DM to use
rm -f /etc/X11/default-display-manager 2>/dev/null || true

echo "==> Configuring UTC hwclock + chrony..."
cat > /etc/adjtime <<'ADJTIME'
0.0 0 0.0
0
UTC
ADJTIME
hwclock --systohc --utc 2>/dev/null || true
cat >> /etc/chrony/chrony.conf <<'CHRONYCONF'

makestep 1.0 3
CHRONYCONF
rc-update add chronyd default 2>/dev/null || rc-update add chrony default 2>/dev/null || true
rc-update add hwclock boot 2>/dev/null || true

rc-update add elogind boot 2>/dev/null || rc-update add elogind default 2>/dev/null || true
rc-update add dbus boot 2>/dev/null || rc-update add dbus default 2>/dev/null || true

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-boreal-power.rules <<'POLKITRULES'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id == "org.freedesktop.login1.suspend" ||
         action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
         action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions") &&
        subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
POLKITRULES
CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
ok "==> Packages installed."

# Bundle any custom .deb packages for fully offline install on the target.
# Drop them in <repo>/packages/ (i.e. ../../packages relative to this
# script) and they're copied alongside the DM debs, so the installer's
# offline dpkg -i step on the target picks them up automatically.
CUSTOM_PKG_DIR="$SCRIPT_DIR/../../packages"
if [ -d "$CUSTOM_PKG_DIR" ]; then
    count=$(find "$CUSTOM_PKG_DIR" -maxdepth 1 -name '*.deb' | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "==> Bundling $count custom package(s) from $CUSTOM_PKG_DIR"
        mkdir -p "$WORK/squashfs-root/opt/borealOS/debs"
        cp "$CUSTOM_PKG_DIR"/*.deb "$WORK/squashfs-root/opt/borealOS/debs/"
    fi
fi

if [ "$DE_NAME" != "None" ]; then
echo "==> Building and installing BorealOS graphical installer..."
GUI_SRC="$SCRIPT_DIR/gui-installer"
if [ ! -f "$GUI_SRC/boreal-installer.c" ]; then
    die "Missing $GUI_SRC/boreal-installer.c - graphical installer source not found"
fi
mkdir -p "$WORK/squashfs-root/usr/share/boreal-installer"
cp "$GUI_SRC/boreal-installer.c" "$WORK/squashfs-root/tmp/boreal-installer.c"
cp "$GUI_SRC/style.css" "$WORK/squashfs-root/usr/share/boreal-installer/style.css"

chroot "$WORK/squashfs-root" /bin/bash <<GUIBUILD || die "boreal-installer build failed"
set -e
gcc \$(pkg-config --cflags gtk+-3.0) -O2 -o /usr/local/bin/boreal-installer /tmp/boreal-installer.c \$(pkg-config --libs gtk+-3.0) -lpthread
chmod +x /usr/local/bin/boreal-installer
rm -f /tmp/boreal-installer.c
GUIBUILD
ok "boreal-installer built."
fi

echo "==> Finalizing system..."
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
    curl clang libclang-dev \
    libwayland-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libxcb1-dev libxcb-xkb-dev libxcb-composite0-dev libxcb-present-dev libxcb-xfixes0-dev \
    libinput-dev libseat-dev libpam0g-dev \
    libdrm-dev libpixman-1-dev libgbm-dev \
    libudev-dev libdbus-1-dev libsystemd-dev \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev libglib2.0-dev \
    libffi-dev libexpat1-dev libcap-dev libxrandr-dev \
    libpipewire-0.3-dev libspa-0.2-dev \
    xwayland wayland-protocols

# Debian stable's apt rustc/cargo are frequently older than niri's MSRV, which
# is the usual reason this build silently fails. Install rust via rustup
# instead so we always get a current stable toolchain.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
source "$HOME/.cargo/env"

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
rustup self uninstall -y 2>/dev/null || rm -rf "$HOME/.cargo" "$HOME/.rustup"
apt-get remove -y --purge cmake meson ninja-build build-essential libclang-dev clang 2>/dev/null || true
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

echo "==> Forcing BorealOS wallpaper over any package-installed defaults..."
mkdir -p "$WORK/squashfs-root/usr/share/xfce4/backdrops"
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/xfce4/backdrops/BorealOS.png"
find "$WORK/squashfs-root/usr/share/xfce4/backdrops"     -not -name "BorealOS.png" -type f -delete 2>/dev/null || true

for dir in \
    "$WORK/squashfs-root/usr/share/backgrounds" \
    "$WORK/squashfs-root/usr/share/wallpapers" \
    "$WORK/squashfs-root/usr/share/pixmaps/backgrounds"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -print0 2>/dev/null | \
        while IFS= read -r -d '' f; do cp "$WP_MAIN" "$f" 2>/dev/null || true; done
done
mkdir -p "$WORK/squashfs-root/usr/share/backgrounds/xfce"
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/backgrounds/xfce/xfce-shapes.png" 2>/dev/null || true
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/backgrounds/xfce/xfce-verticals.png" 2>/dev/null || true
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/backgrounds/xfce/xfce-stripes.png" 2>/dev/null || true

echo "==> Slimming down image (apt cache, docs, man pages)..."
chroot "$WORK/squashfs-root" apt-get clean 2>/dev/null || true
rm -rf "$WORK/squashfs-root/var/lib/apt/lists/"* 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/doc/"* 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/man/"* 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/info/"* 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/lintian/"* 2>/dev/null || true
find "$WORK/squashfs-root/var/log" -type f -delete 2>/dev/null || true
find "$WORK/squashfs-root/var/cache" -maxdepth 1 -type d -not -name apt -exec rm -rf {} + 2>/dev/null || true

echo "==> Building SquashFS..."
mksquashfs "$WORK/squashfs-root" "$WORK/iso/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -noappend -xattrs -quiet || die "mksquashfs failed"

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
GRUB_MKRESCUE_LOG="$WORK/grub-mkrescue.log"
grub-mkrescue -o "$OUTPUT" "$WORK/iso" \
    --modules="normal iso9660 linux ext2 fat search search_label part_gpt part_msdos all_video gfxterm png" \
    2>&1 | tee "$GRUB_MKRESCUE_LOG"
[ ${PIPESTATUS[0]} -eq 0 ] || die "grub-mkrescue failed (see $GRUB_MKRESCUE_LOG)"
if grep -qi "No EFI boot images\|efi.img.*not found\|cannot find efi" "$GRUB_MKRESCUE_LOG"; then
    die "grub-mkrescue built a BIOS-only ISO (no EFI El Torito image) - see $GRUB_MKRESCUE_LOG. Re-check grub-efi-amd64-bin installation."
fi

if command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$OUTPUT" -report_el_torito plain 2>/dev/null | grep -qi "El Torito boot img.*UEFI" \
        || warn "Could not confirm an EFI El Torito entry on $OUTPUT - verify UEFI boot manually before shipping this ISO."
fi

ok "==> Done: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
