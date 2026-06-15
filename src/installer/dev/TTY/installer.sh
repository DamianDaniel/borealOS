#!/bin/bash

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

EXTRA_USERS=()
EFI="" ROOT="" DISK=""
DE_CHOICE="" SHELL_BIN=""
NET_TYPE="" NET_IF="" NET_IP="" NET_GW="" NET_DNS=""
HOSTNAME="" LOCALE="" TIMEZONE=""
ROOT_PASS=""

die() {
    echo -e "\n${RED}${BLD}FATAL: $1${RST}" >&2
    echo -e "${RED}Dropping to shell. Type 'exit' to quit.${RST}"
    cleanup
    bash
    exit 1
}
step() { echo -e "\n${CYN}${BLD}=> $1${RST}"; }
ok()   { echo -e "${GRN}OK: $1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

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
            printf -v "$var" '%s' "$p1"; return
        fi
        echo -e "${RED}Passwords do not match or are empty.${RST}"
    done
}

menu() {
    local title="$1"; shift
    local options=("$@")
    echo -e "${BLD}${title}${RST}"
    for i in "${!options[@]}"; do echo "  $((i+1))) ${options[$i]}"; done
    while true; do
        echo -ne "${CYN}Choice${RST}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            MENU_RESULT="${options[$((choice-1))]}"; return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

confirm() {
    echo -ne "${CYN}$1 [y/N]${RST}: "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

check_root() { [ "$EUID" -eq 0 ] || die "Must run as root."; }

check_assets() {
    [ -f /opt/borealOS/rootfs.tar.gz ]    || die "/opt/borealOS/rootfs.tar.gz missing."
    [ -f /opt/borealOS/background_2.png ] || die "Wallpaper missing."
    [ -f /opt/borealOS/de ]               || die "/opt/borealOS/de missing."
    [ -f /opt/borealOS/shell ]            || die "/opt/borealOS/shell missing."
    command -v rsync >/dev/null            || die "rsync not found in live env."
    command -v openssl >/dev/null          || die "openssl not found in live env."
    DE_CHOICE=$(cat /opt/borealOS/de)
    SHELL_BIN=$(cat /opt/borealOS/shell)
}

select_disk() {
    banner
    echo -e "${BLD}Available disks:${RST}\n"
    lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|sr0"
    echo
    ask "Target disk (e.g. /dev/sda)" DISK
    [ -b "$DISK" ] || die "$DISK is not a block device."
    echo -e "\n${RED}${BLD}WARNING: All data on $DISK will be erased.${RST}"
    confirm "Continue?" || die "Aborted."
}

partition_disk() {
    step "Partitioning $DISK..."
    parted -s "$DISK" mklabel gpt                     || die "mklabel failed"
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB    || die "EFI partition failed"
    parted -s "$DISK" set 1 esp on                    || die "esp flag failed"
    parted -s "$DISK" mkpart primary ext4 513MiB 100% || die "root partition failed"
    partprobe "$DISK" 2>/dev/null; sleep 1
    if [[ "$DISK" == *nvme* ]]; then
        EFI="${DISK}p1"; ROOT="${DISK}p2"
    else
        EFI="${DISK}1";  ROOT="${DISK}2"
    fi
    [ -b "$EFI"  ] || die "EFI partition $EFI not found after partitioning."
    [ -b "$ROOT" ] || die "Root partition $ROOT not found after partitioning."
    mkfs.fat -F32 -n EFI "$EFI"      || die "mkfs.fat failed"
    mkfs.ext4 -F -L borealOS "$ROOT" || die "mkfs.ext4 failed"
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT") || die "Could not read root UUID"
    EFI_UUID=$(blkid -s UUID -o value "$EFI")   || die "Could not read EFI UUID"
    [ -n "$ROOT_UUID" ] || die "Root UUID is empty"
    [ -n "$EFI_UUID"  ] || die "EFI UUID is empty"
    ok "Partitioned. Root UUID: $ROOT_UUID"
}

mount_target() {
    step "Mounting..."
    mount "$ROOT" /mnt              || die "mount root failed"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi     || die "mount EFI failed"
    ok "Mounted."
}

rsync_system() {
    step "Copying live system to disk (this takes a while)..."
    rsync -aAX \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/live \
        --exclude=/mnt \
        --exclude=/media \
        --exclude=/tmp \
        --exclude=/opt/borealOS \
        --exclude=/usr/local/bin/borealOS-install \
        --exclude=/etc/profile.d/live-welcome.sh \
        / /mnt/ || die "rsync failed"
    mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp
    chmod 1777 /mnt/tmp
    ok "System copied."
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

write_fstab() {
    step "Writing /etc/fstab..."
    cat > /mnt/etc/fstab <<FSTAB
UUID=${ROOT_UUID}  /         ext4  errors=remount-ro  0  1
UUID=${EFI_UUID}   /boot/efi vfat  umask=0077         0  2
FSTAB
    ok "fstab written."
}

write_network() {
    [ "$NET_TYPE" = "Skip" ] && return
    step "Writing network config..."
    mkdir -p /mnt/etc/NetworkManager/system-connections
    local NMFILE="/mnt/etc/NetworkManager/system-connections/${NET_IF}.nmconnection"
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
    ok "Network config written."
}

bind_mounts() {
    for d in dev proc sys run; do
        mount --bind /$d /mnt/$d || die "bind mount /$d failed"
    done
}

unbind_mounts() {
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    umount -R /mnt/run  2>/dev/null || true
}

select_timezone() {
    banner
    echo -e "${BLD}Timezone selection${RST}"
    echo "Type part of a timezone to filter (e.g. 'Europe', 'Berlin'). Leave blank for all."
    echo
    echo -ne "${CYN}Filter${RST}: "
    read -r tz_filter
    mapfile -t tz_list < <(find /usr/share/zoneinfo -type f -o -type l 2>/dev/null | \
        sed 's|/usr/share/zoneinfo/||' | \
        grep -v "^posix\|^right\|\.tab$\|^leap\|\.list$\|^tzdata\|^iso3166" | \
        sort | grep -i "${tz_filter}")
    if [ ${#tz_list[@]} -eq 0 ]; then
        echo -e "${RED}No matches.${RST}"
        ask "Timezone" TIMEZONE "UTC"; return
    fi
    if [ ${#tz_list[@]} -gt 40 ]; then
        echo -e "${RED}${#tz_list[@]} results — refine your filter.${RST}"
        select_timezone; return
    fi
    for i in "${!tz_list[@]}"; do echo "  $((i+1))) ${tz_list[$i]}"; done
    echo
    while true; do
        echo -ne "${CYN}Choice (0=enter manually)${RST}: "
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

configure_system() {
    step "Configuring base system..."
    chroot /mnt /bin/bash <<CHROOT || die "Base configuration failed"
set -e
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
HOSTS
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
grep -q "^${LOCALE}" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen 2>/dev/null || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
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
CHROOT
    ok "Base configured."
}

set_passwords() {
    step "Setting passwords..."
    printf 'root:%s\n' "$ROOT_PASS" | chroot /mnt chpasswd || die "Failed to set root password"
    for entry in "${EXTRA_USERS[@]}"; do
        local uname="${entry%%|*}"
        local upass="${entry##*|}"
        chroot /mnt useradd -m -G sudo,audio,video,netdev -s "$SHELL_BIN" "$uname" 2>/dev/null || \
        chroot /mnt useradd -m -G sudo,audio,video -s "$SHELL_BIN" "$uname" || \
        die "useradd failed for $uname"
        printf '%s:%s\n' "$uname" "$upass" | chroot /mnt chpasswd || die "Failed to set password for $uname"
    done
    ok "Passwords set."
}

remove_live_boot() {
    step "Removing live-boot from installed system..."
    chroot /mnt dpkg -r live-boot live-boot-initramfs-tools 2>/dev/null || true
    chroot /mnt dpkg -r live-config live-config-systemd 2>/dev/null || true
    rm -f /mnt/etc/initramfs-tools/scripts/live* 2>/dev/null || true
    rm -f /mnt/etc/initramfs-tools/hooks/live* 2>/dev/null || true
    step "Rebuilding initramfs..."
    chroot /mnt update-initramfs -u -k all || die "update-initramfs failed"
    ok "live-boot removed, initramfs rebuilt."
}

restore_inittab() {
    step "Restoring inittab..."
    cat > /mnt/etc/inittab <<'INITTAB'
id:2:initdefault:
si::sysinit:/etc/init.d/rcS
~~:S:wait:/sbin/sulogin --force
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
z6:6:respawn:/sbin/sulogin --force
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
pf::powerwait:/etc/init.d/powerfail start
pn::powerfailnow:/etc/init.d/powerfail now
po::powerokwait:/etc/init.d/powerfail stop
1:2345:respawn:/sbin/getty --noclear 38400 tty1
2:23:respawn:/sbin/getty 38400 tty2
3:23:respawn:/sbin/getty 38400 tty3
INITTAB
    ok "inittab restored."
}

setup_de() {
    step "Configuring DE/WM: $DE_CHOICE..."
    mkdir -p /mnt/etc/runlevels/default
    case "$DE_CHOICE" in
        "KDE Plasma")
            ln -sf /etc/init.d/sddm    /mnt/etc/runlevels/default/sddm    2>/dev/null || true
            ln -sf /etc/init.d/NetworkManager /mnt/etc/runlevels/default/NetworkManager 2>/dev/null || true
            mkdir -p /mnt/etc/sddm.conf.d
            cat > /mnt/etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/wallpapers/BorealOS/default.png
SDDM
            ;;
        "XFCE")
            ln -sf /etc/init.d/lightdm /mnt/etc/runlevels/default/lightdm 2>/dev/null || true
            ln -sf /etc/init.d/NetworkManager /mnt/etc/runlevels/default/NetworkManager 2>/dev/null || true
            mkdir -p /mnt/etc/lightdm
            cat > /mnt/etc/lightdm/lightdm-gtk-greeter.conf <<LDM
[greeter]
background=/usr/share/wallpapers/BorealOS/default.png
LDM
            mkdir -p /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
            cat > /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<XFCE
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
            ln -sf /etc/init.d/NetworkManager /mnt/etc/runlevels/default/NetworkManager 2>/dev/null || true
            mkdir -p /mnt/etc/sway
            cat > /mnt/etc/sway/config <<SWAY
set \$mod Mod4
output * bg /usr/share/wallpapers/BorealOS/default.png fill
input type:keyboard { xkb_layout us }
bindsym \$mod+Return exec foot
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+e exec swaymsg exit
bar {
    statusbar_command while date +'%Y-%m-%d %H:%M'; do sleep 1; done
    colors { background #0d1b2a; statusline #4dffd2 }
}
SWAY
            ;;
        *)
            ln -sf /etc/init.d/NetworkManager /mnt/etc/runlevels/default/NetworkManager 2>/dev/null || true
            ;;
    esac
    ok "DE configured."
}

install_grub() {
    step "Installing GRUB..."
    cat > /mnt/etc/default/grub <<GRUBCFG
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=BorealOS
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUBCFG

    chroot /mnt grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=BorealOS \
        --recheck \
        || die "grub-install failed"

    chroot /mnt update-grub || chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed"

    mkdir -p /mnt/boot/efi/EFI/BOOT
    if [ ! -f /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
        find /mnt/boot/efi/EFI -name "grubx64.efi" | head -1 | \
            xargs -I{} cp {} /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
    fi
    ok "GRUB installed."
}

verify() {
    step "Verifying installation..."
    local fail=0
    [ -f /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI ] || { warn "BOOTX64.EFI missing!"; fail=1; }
    [ -f /mnt/boot/grub/grub.cfg ]             || { warn "grub.cfg missing!"; fail=1; }
    [ -f /mnt/etc/fstab ]                      || { warn "fstab missing!"; fail=1; }
    ls /mnt/boot/vmlinuz-* >/dev/null 2>&1     || { warn "No kernel in /boot!"; fail=1; }
    ls /mnt/boot/initrd.img-* >/dev/null 2>&1  || { warn "No initrd in /boot!"; fail=1; }
    [ "$fail" = "1" ] && die "Verification failed — see warnings above."
    ok "All checks passed."
}

cleanup() { umount -R /mnt 2>/dev/null || true; }

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
    echo -e "  DE: ${DE_CHOICE}  |  Shell: ${SHELL_BIN}"
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
    rsync_system
    install_wallpapers
    write_fstab
    write_network
    bind_mounts
    configure_system
    set_passwords
    remove_live_boot
    restore_inittab
    setup_de
    install_grub
    unbind_mounts
    verify
    cleanup
    finish
}

trap 'unbind_mounts; cleanup' EXIT
main
