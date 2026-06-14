#!/bin/bash

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

EXTRA_USERS=()
EFI=""
ROOT=""

die() {
    echo -e "${RED}FATAL: $1${RST}" >&2
    cleanup
    echo -e "${RED}Installation failed. Dropping to shell for inspection.${RST}"
    bash
    exit 1
}

step() { echo -e "${CYN}${BLD}=> $1${RST}"; }
ok()   { echo -e "${GRN}OK: $1${RST}"; }

run() {
    "$@" || die "Command failed: $*"
}

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
    [ -f /opt/borealOS/rootfs.tar.gz ] || die "/opt/borealOS/rootfs.tar.gz missing."
    [ -f /opt/borealOS/background_2.png ] || die "Wallpaper assets missing."
    [ -f /opt/borealOS/de ] || die "/opt/borealOS/de missing."
    [ -f /opt/borealOS/shell ] || die "/opt/borealOS/shell missing."
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
    confirm "Continue?" || die "Aborted by user."
}

partition_disk() {
    step "Partitioning $DISK..."
    run parted -s "$DISK" mklabel gpt
    run parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    run parted -s "$DISK" set 1 esp on
    run parted -s "$DISK" mkpart primary ext4 513MiB 100%

    if [[ "$DISK" == *nvme* ]]; then
        EFI="${DISK}p1"; ROOT="${DISK}p2"
    else
        EFI="${DISK}1"; ROOT="${DISK}2"
    fi

    run mkfs.fat -F32 -n EFI "$EFI"
    run mkfs.ext4 -L borealOS "$ROOT"
    ok "Partitioned."
}

mount_target() {
    step "Mounting..."
    run mount "$ROOT" /mnt
    mkdir -p /mnt/boot/efi
    run mount "$EFI" /mnt/boot/efi
    ok "Mounted."
}

install_rootfs() {
    step "Extracting base system..."
    run tar -xzf /opt/borealOS/rootfs.tar.gz -C /mnt
    ok "Base system extracted."
}

install_wallpapers() {
    step "Installing wallpapers..."
    mkdir -p /mnt/usr/share/wallpapers/BorealOS
    run cp /opt/borealOS/background_2.png   /mnt/usr/share/wallpapers/BorealOS/default.png
    run cp /opt/borealOS/background_one.png /mnt/usr/share/wallpapers/BorealOS/waves.png
    mkdir -p /mnt/usr/share/pixmaps
    run cp /opt/borealOS/logo.png /mnt/usr/share/pixmaps/borealOS-logo.png
    ok "Wallpapers installed."
}

select_timezone() {
    banner
    echo -e "${BLD}Timezone selection${RST}"
    echo "Type part of a timezone to filter (e.g. 'Europe', 'Berlin'). Leave blank for all."
    echo
    echo -ne "${CYN}Filter${RST}: "
    read -r tz_filter

    mapfile -t tz_list < <(find /usr/share/zoneinfo -type f -o -type l | sed 's|/usr/share/zoneinfo/||' | grep -v "^posix\|^right\|\.tab$\|^leap\|\.list$" | sort | grep -i "${tz_filter}")

    if [ ${#tz_list[@]} -eq 0 ]; then
        echo -e "${RED}No matches.${RST}"
        ask "Enter timezone manually" TIMEZONE "UTC"
        return
    fi

    if [ ${#tz_list[@]} -gt 40 ]; then
        echo -e "${RED}${#tz_list[@]} results, refine your filter.${RST}"
        select_timezone
        return
    fi

    for i in "${!tz_list[@]}"; do
        echo "  $((i+1))) ${tz_list[$i]}"
    done
    echo
    while true; do
        echo -ne "${CYN}Choice (0 = enter manually)${RST}: "
        read -r choice
        if [ "$choice" = "0" ]; then
            ask "Timezone" TIMEZONE "UTC"
            return
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tz_list[@]} )); then
            TIMEZONE="${tz_list[$((choice-1))]}"
            return
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
    menu "Network configuration:" "DHCP on eth0" "Static IP" "Skip"
    NET_TYPE="$MENU_RESULT"

    if [ "$NET_TYPE" = "Skip" ]; then
        NET_IF=""
        return
    fi

    echo
    echo -e "${BLD}Available interfaces:${RST}"
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print "  "$2}' | grep -v lo
    echo
    ask "Network interface" NET_IF "eth0"

    if [ "$NET_TYPE" = "Static IP" ]; then
        ask "IP/prefix (e.g. 192.168.1.100/24)" NET_IP
        ask "Gateway" NET_GW
        ask "DNS" NET_DNS "1.1.1.1"
    fi
}

configure_system() {
    step "Configuring system..."

    for d in dev proc sys run; do
        mount --bind /$d /mnt/$d || die "Failed to bind mount /$d"
    done

    USERS_SCRIPT=""
    for entry in "${EXTRA_USERS[@]}"; do
        uname="${entry%%|*}"
        upass="${entry##*|}"
        USERS_SCRIPT+="useradd -m -G sudo,audio,video,netdev -s ${SHELL_BIN} ${uname} || true"$'\n'
        USERS_SCRIPT+="echo '${uname}:${upass}' | chpasswd || die 'Failed to set password for ${uname}'"$'\n'
    done

    NET_SCRIPT=""
    if [ "$NET_TYPE" = "DHCP on eth0" ] || [ "$NET_TYPE" = "Static IP" ]; then
        NET_SCRIPT="mkdir -p /etc/NetworkManager/system-connections"$'\n'
        if [ "$NET_TYPE" = "DHCP on eth0" ]; then
            NET_SCRIPT+="cat > /etc/NetworkManager/system-connections/${NET_IF}.nmconnection <<NMC
[connection]
id=${NET_IF}
type=ethernet
interface-name=${NET_IF}
[ipv4]
method=auto
[ipv6]
method=auto
NMC
chmod 600 /etc/NetworkManager/system-connections/${NET_IF}.nmconnection"
        else
            NET_SCRIPT+="cat > /etc/NetworkManager/system-connections/${NET_IF}.nmconnection <<NMC
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
chmod 600 /etc/NetworkManager/system-connections/${NET_IF}.nmconnection"
        fi
    fi

    cp /usr/sbin/locale-gen /mnt/usr/sbin/locale-gen 2>/dev/null || true
    cp -r /usr/share/i18n /mnt/usr/share/i18n 2>/dev/null || true
    cp /usr/bin/localedef /mnt/usr/bin/localedef 2>/dev/null || true

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


echo "root:$ROOT_PASS" | chpasswd
$USERS_SCRIPT
$NET_SCRIPT

update-rc.d NetworkManager defaults 2>/dev/null || \
    ln -sf /etc/init.d/NetworkManager /etc/rc2.d/S99NetworkManager || true

case "$DE_CHOICE" in
    "KDE Plasma")
        update-rc.d sddm defaults 2>/dev/null || \
            ln -sf /etc/init.d/sddm /etc/rc2.d/S99sddm || true
        mkdir -p /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/wallpapers/BorealOS/default.png
SDDM
        ;;
    "XFCE")
        update-rc.d lightdm defaults 2>/dev/null || \
            ln -sf /etc/init.d/lightdm /etc/rc2.d/S99lightdm || true
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

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="BorealOS"/' /etc/default/grub
update-grub
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
        "Drop to shell")
            echo -e "${CYN}Type 'reboot' when done.${RST}"
            bash
            ;;
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
    configure_system
    cleanup
    finish
}

trap cleanup EXIT
main
