#!/bin/bash

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

EXTRA_USERS=()
EFI=""
ROOT=""
DE_CHOICE=""
SHELL_BIN=""

die() {
    echo -e "${RED}FATAL: $1${RST}" >&2
    cleanup
    echo -e "${RED}Dropping to shell for inspection.${RST}"
    bash
    exit 1
}

step() { echo -e "${CYN}${BLD}=> $1${RST}"; }
ok()   { echo -e "${GRN}OK: $1${RST}"; }

banner() {
    clear
    echo -e "${CYN}${BLD}"
    cat <<'ART'
  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/
ART
    echo -e "${RST}"
}

ask() {
    local prompt="$1" var="$2" default="$3"
    while true; do
        echo -ne "${CYN}${prompt}${RST}"
        [ -n "$default" ] && echo -ne " [${default}]"
        echo -ne ": "
        read -r input
        input="${input:-$default}"
        [ -n "$input" ] && { printf -v "$var" '%s' "$input"; return; }
        echo -e "${RED}Cannot be empty.${RST}"
    done
}

ask_pass() {
    local prompt="$1" var="$2"
    while true; do
        echo -ne "${CYN}${prompt}${RST} (doesn't echo): "
        read -rs p1; echo
        echo -ne "${CYN}Confirm ${prompt}${RST} (doesn't echo): "
        read -rs p2; echo
        if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then
            printf -v "$var" '%s' "$p1"
            return
        fi
        echo -e "${RED}Passwords do not match or are empty.${RST}"
    done
}

menu() {
    local title="$1"; shift
    local options=("$@")
    echo -e "${BLD}${title}${RST}"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    while true; do
        echo -ne "${CYN}Choice${RST}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            MENU_RESULT="${options[$((choice-1))]}"
            return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

confirm() {
    echo -ne "${CYN}$1 [y/N]${RST}: "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

check_root() {
    [ "$EUID" -eq 0 ] || die "Must run as root."
}

check_assets() {
    [ -f /opt/borealOS/rootfs.tar.gz ]    || die "/opt/borealOS/rootfs.tar.gz missing."
    [ -f /opt/borealOS/background_2.png ] || die "Wallpaper assets missing."
    [ -f /opt/borealOS/de ]               || die "/opt/borealOS/de missing."
    [ -f /opt/borealOS/shell ]            || die "/opt/borealOS/shell missing."
    DE_CHOICE=$(cat /opt/borealOS/de)
    SHELL_BIN=$(cat /opt/borealOS/shell)
}

select_disk() {
    banner
    echo -e "${BLD}Available disks:${RST}"
    echo
    lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|sr0"
    echo
    ask "Target disk (e.g. /dev/sda)" DISK
    [ -b "$DISK" ] || die "$DISK is not a block device."
    echo -e "${RED}${BLD}WARNING: All data on $DISK will be destroyed.${RST}"
    confirm "Continue?" || die "Aborted."
}

partition_disk() {
    step "Partitioning $DISK..."
    parted -s "$DISK" mklabel gpt                      || die "mklabel failed"
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB     || die "EFI partition failed"
    parted -s "$DISK" set 1 esp on                     || die "esp flag failed"
    parted -s "$DISK" mkpart primary ext4 513MiB 100%  || die "root partition failed"
    if [[ "$DISK" == *nvme* ]]; then
        EFI="${DISK}p1"; ROOT="${DISK}p2"
    else
        EFI="${DISK}1";  ROOT="${DISK}2"
    fi
    mkfs.fat -F32 -n EFI "$EFI"      || die "mkfs.fat failed"
    mkfs.ext4 -F -L borealOS "$ROOT" || die "mkfs.ext4 failed"
    ok "Partitioned."
}

mount_target() {
    step "Mounting..."
    mount "$ROOT" /mnt              || die "mount root failed"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi     || die "mount EFI failed"
    ok "Mounted."
}

install_rootfs() {
    step "Extracting base system..."
    tar -xzf /opt/borealOS/rootfs.tar.gz -C /mnt || die "rootfs extraction failed"
    ok "Base system extracted."
}

install_wallpapers() {
    step "Installing wallpapers..."
    mkdir -p /mnt/usr/share/wallpapers/BorealOS
    cp /opt/borealOS/background_2.png   /mnt/usr/share/wallpapers/BorealOS/default.png || die "wallpaper copy failed"
    cp /opt/borealOS/background_one.png /mnt/usr/share/wallpapers/BorealOS/waves.png   || die "wallpaper copy failed"
    mkdir -p /mnt/usr/share/pixmaps
    cp /opt/borealOS/logo.png /mnt/usr/share/pixmaps/borealOS-logo.png                 || die "logo copy failed"
    ok "Wallpapers installed."
}

select_timezone() {
    banner
    echo -e "${BLD}Timezone selection${RST}"
    echo "Type part of a timezone to filter. Leave blank for all."
    echo
    echo -ne "${CYN}Filter${RST}: "
    read -r tz_filter
    mapfile -t tz_list < <(find /usr/share/zoneinfo -type f -o -type l 2>/dev/null | \
        sed 's|/usr/share/zoneinfo/||' | \
        grep -v "^posix\|^right\|\.tab$\|^leap\|\.list$\|^tzdata" | \
        sort | grep -i "${tz_filter}")
    if [ ${#tz_list[@]} -eq 0 ]; then
        echo -e "${RED}No matches.${RST}"
        ask "Timezone" TIMEZONE "UTC"
        return
    fi
    if [ ${#tz_list[@]} -gt 40 ]; then
        echo -e "${RED}${#tz_list[@]} results, refine filter.${RST}"
        select_timezone; return
    fi
    for i in "${!tz_list[@]}"; do echo "  $((i+1))) ${tz_list[$i]}"; done
    echo
    while true; do
        echo -ne "${CYN}Choice (0=manual)${RST}: "
        read -r choice
        [ "$choice" = "0" ] && { ask "Timezone" TIMEZONE "UTC"; return; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tz_list[@]} )); then
            TIMEZONE="${tz_list[$((choice-1))]}"; return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

get_user_info() {
    banner
    ask "Hostname" HOSTNAME "borealOS"
    ask_pass "Root password" ROOT_PASS
    ask "Locale (e.g. en_US.UTF-8)" LOCALE "en_US.UTF-8"
    select_timezone
}

get_extra_users() {
    banner
    echo -e "${BLD}Extra user accounts${RST}"
    echo "Leave username blank to stop."
    echo
    while true; do
        echo -ne "${CYN}Username (blank to stop)${RST}: "
        read -r uname
        [ -z "$uname" ] && break
        ask_pass "Password for $uname" upass
        EXTRA_USERS+=("${uname}|${upass}")
        ok "Added: $uname"
    done
}

configure_network() {
    banner
    menu "Network:" "DHCP (automatic)" "Static IP" "Skip"
    NET_TYPE="$MENU_RESULT"
    [ "$NET_TYPE" = "Skip" ] && return
    echo
    echo -e "${BLD}Interfaces:${RST}"
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print "  "$2}' | grep -v lo
    echo
    ask "Interface" NET_IF "eth0"
    if [ "$NET_TYPE" = "Static IP" ]; then
        ask "IP/prefix (e.g. 192.168.1.100/24)" NET_IP
        ask "Gateway" NET_GW
        ask "DNS" NET_DNS "1.1.1.1"
    fi
}

copy_tools() {
    step "Copying required tools into target..."

    for d in dev proc sys run; do
        mount --bind /$d /mnt/$d || die "Failed to bind mount /$d"
    done

    cp /usr/sbin/locale-gen             /mnt/usr/sbin/locale-gen             2>/dev/null || true
    cp /usr/bin/localedef               /mnt/usr/bin/localedef               2>/dev/null || true
    cp -r /usr/share/i18n               /mnt/usr/share/i18n                  2>/dev/null || true
    cp /usr/share/locale/locale.alias   /mnt/usr/share/locale/locale.alias   2>/dev/null || true

    VMLINUZ=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    INITRD=$(ls /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
    [ -f "$VMLINUZ" ] && cp "$VMLINUZ" /mnt/boot/ || die "No kernel found in live env"
    [ -f "$INITRD"  ] && cp "$INITRD"  /mnt/boot/ || die "No initrd found in live env"

    for bin in grub-install grub-mkconfig update-grub; do
        src=$(command -v $bin 2>/dev/null)
        [ -n "$src" ] && cp "$src" /mnt/usr/sbin/$bin 2>/dev/null || true
    done
    [ -d /usr/lib/grub ]    && cp -r /usr/lib/grub    /mnt/usr/lib/grub    2>/dev/null || true
    [ -d /usr/share/grub ]  && cp -r /usr/share/grub  /mnt/usr/share/grub  2>/dev/null || true

    for lib in libdevmapper libefivar libefiboot; do
        find /usr/lib /lib -name "${lib}*.so*" 2>/dev/null | while read -r f; do
            dest="/mnt$(dirname "$f")"
            mkdir -p "$dest"
            cp "$f" "$dest/" 2>/dev/null || true
        done
    done

    if [ "$SHELL_BIN" = "/usr/bin/fish" ]; then
        fish_bin=$(command -v fish 2>/dev/null)
        [ -n "$fish_bin" ] || die "fish not found in live env"
        cp "$fish_bin" /mnt/usr/bin/fish
        [ -d /usr/share/fish ] && cp -r /usr/share/fish /mnt/usr/share/fish 2>/dev/null || true
        ldd "$fish_bin" 2>/dev/null | awk '{print $3}' | grep "^/" | while read -r lib; do
            dest="/mnt$(dirname "$lib")"
            mkdir -p "$dest"
            cp "$lib" "$dest/" 2>/dev/null || true
        done
    fi

    grep -q 'netdev' /mnt/etc/group || echo 'netdev:x:999:' >> /mnt/etc/group

    ok "Tools copied."
}

configure_system() {
    step "Configuring system..."

    ROOT_HASH=$(openssl passwd -6 "$ROOT_PASS") || die "openssl passwd failed"

    USERS_SCRIPT=""
    for entry in "${EXTRA_USERS[@]}"; do
        uname="${entry%%|*}"
        upass="${entry##*|}"
        uhash=$(openssl passwd -6 "$upass") || die "openssl passwd failed for $uname"
        USERS_SCRIPT+="useradd -m -G sudo,audio,video,netdev -s ${SHELL_BIN} ${uname} || true"$'\n'
        USERS_SCRIPT+="sed -i \"s|^${uname}:[^:]*:|${uname}:${uhash}:|\" /etc/shadow"$'\n'
    done

    NET_SCRIPT=""
    if [ "$NET_TYPE" = "DHCP (automatic)" ] || [ "$NET_TYPE" = "Static IP" ]; then
        mkdir -p /mnt/etc/NetworkManager/system-connections
        NMFILE="/mnt/etc/NetworkManager/system-connections/${NET_IF}.nmconnection"
        if [ "$NET_TYPE" = "DHCP (automatic)" ]; then
            cat > "$NMFILE" <<NMC
[connection]
id=${NET_IF}
type=ethernet
interface-name=${NET_IF}
[ipv4]
method=auto
[ipv6]
method=auto
NMC
        else
            cat > "$NMFILE" <<NMC
[connection]
id=${NET_IF}
type=ethernet
interface-name=${NET_IF}
[ipv4]
method=manual
addresses=${NET_IP}
gateway=${NET_GW}
dns=${NET_DNS}
[ipv6]
method=auto
NMC
        fi
        chmod 600 "$NMFILE"
    fi

    chroot /mnt /bin/bash <<CHROOT || die "System configuration in chroot failed"
set -e

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
HOSTS

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
echo "$TIMEZONE" > /etc/timezone

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

cat > /etc/os-release <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS 1.0"
ID=borealos
ID_LIKE=
VERSION="1.0"
VERSION_ID="1.0"
HOME_URL="https://borealos.org"
OS

cat > /etc/lsb-release <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS 1.0"
LSB

echo "BorealOS"     > /etc/issue
echo "BorealOS 1.0" > /etc/issue.net
echo "BorealOS"     > /etc/debian_version

sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" /etc/shadow
$USERS_SCRIPT

mkdir -p /etc/runlevels/default
ln -sf /etc/init.d/NetworkManager /etc/runlevels/default/NetworkManager 2>/dev/null || true

case "$DE_CHOICE" in
    "KDE Plasma")
        ln -sf /etc/init.d/sddm /etc/runlevels/default/sddm 2>/dev/null || true
        mkdir -p /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/wallpapers/BorealOS/default.png
SDDM
        ;;
    "XFCE")
        ln -sf /etc/init.d/lightdm /etc/runlevels/default/lightdm 2>/dev/null || true
        mkdir -p /etc/lightdm
        cat >> /etc/lightdm/lightdm-gtk-greeter.conf <<LDM
[greeter]
background=/usr/share/wallpapers/BorealOS/default.png
LDM
        mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
        cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<XFCE
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/wallpapers/BorealOS/default.png"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XFCE
        ;;
    "Sway")
        mkdir -p /etc/sway
        cat > /etc/sway/config <<SWAY
set \$mod Mod4
font pango:monospace 10
output * bg /usr/share/wallpapers/BorealOS/default.png fill
input type:keyboard { xkb_layout us }
bindsym \$mod+Return exec foot
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+e exec swaymsg exit
bar {
    statusbar_command while date +'%Y-%m-%d %H:%M'; do sleep 1; done
    colors {
        background #0d1b2a
        statusline #4dffd2
        focused_workspace #4dffd2 #0d1b2a #ffffff
    }
}
SWAY
        ;;
esac

cat > /etc/default/grub <<GRUBCFG
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=BorealOS
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUBCFG

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS || die "grub-install failed"

update-grub || grub-mkconfig -o /boot/grub/grub.cfg || true

mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/BorealOS/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || \
cp /usr/lib/grub/x86_64-efi/grub.efi  /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
CHROOT

    ok "System configured."
}

cleanup() {
    umount -R /mnt 2>/dev/null || true
}

finish() {
    banner
    ok "Installation complete."
    echo
    echo "  Disk:        $DISK"
    echo "  DE/WM:       $DE_CHOICE"
    echo "  Shell:       $SHELL_BIN"
    echo "  Host:        $HOSTNAME"
    echo "  Timezone:    $TIMEZONE"
    echo "  Network:     $NET_TYPE"
    echo "  Extra users: ${#EXTRA_USERS[@]}"
    echo
    menu "What now?" "Reboot" "Drop to shell"
    case "$MENU_RESULT" in
        "Reboot") reboot ;;
        "Drop to shell") echo -e "${CYN}Type 'reboot' when done.${RST}"; bash ;;
    esac
}

main() {
    check_root
    check_assets
    banner
    echo -e "${BLD}Welcome to the BorealOS Installer${RST}"
    echo -e "DE: ${DE_CHOICE}  |  Shell: ${SHELL_BIN}"
    echo
    confirm "Begin?" || die "Aborted."

    select_disk
    get_user_info
    get_extra_users
    configure_network

    banner
    echo -e "${BLD}Summary:${RST}"
    echo "  Disk:         $DISK"
    echo "  Hostname:     $HOSTNAME"
    echo "  Timezone:     $TIMEZONE"
    echo "  DE/WM:        $DE_CHOICE"
    echo "  Shell:        $SHELL_BIN"
    echo "  Network:      $NET_TYPE"
    echo "  Extra users:  ${#EXTRA_USERS[@]}"
    echo
    confirm "Proceed?" || die "Aborted."

    partition_disk
    mount_target
    install_rootfs
    install_wallpapers
    copy_tools
    configure_system
    cleanup
    finish
}

trap cleanup EXIT
main
