#!/bin/bash

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

EXTRA_USERS=()
EFI="" ROOT="" DISK="" BIOS=""
DE_CHOICE="" SHELL_BIN=""
NET_TYPE="" NET_IF="" NET_IP="" NET_GW="" NET_DNS=""
HOSTNAME="" LOCALE="" TIMEZONE=""
ROOT_PASS="" ROOT_UUID="" EFI_UUID=""

die() {
    echo -e "\n${RED}${BLD}FATAL: $1${RST}" >&2
    cleanup
    echo -e "${RED}Dropping to shell.${RST}"
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
    echo -ne "${CYN}$1 [Y/n]${RST}: "
    read -r ans
    [[ "$ans" =~ ^[Nn]$ ]] && return 1
    return 0
}

check_root() { [ "$EUID" -eq 0 ] || die "Must run as root."; }

check_assets() {
    [ -f /opt/borealOS/rootfs.tar.gz ]    || die "/opt/borealOS/rootfs.tar.gz missing."
    [ -f /opt/borealOS/background_2.png ] || die "Wallpaper missing."
    [ -f /opt/borealOS/de ]               || die "/opt/borealOS/de missing."
    [ -f /opt/borealOS/shell ]            || die "/opt/borealOS/shell missing."
    command -v rsync        >/dev/null     || die "rsync not in live env."
    command -v grub-install >/dev/null     || die "grub-install not in live env."
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

select_partitioning() {
    banner
    echo -e "${BLD}Partitioning${RST}"
    EFI_SIZE=512
    SWAP_SIZE=0
    if confirm "Advanced partitioning (custom EFI/swap size)?"; then
        while true; do
            ask "EFI size in MiB" EFI_SIZE
            [[ "$EFI_SIZE" =~ ^[0-9]+$ ]] && [ "$EFI_SIZE" -ge 100 ] && break
            echo -e "${RED}Enter a number >= 100.${RST}"
        done
        while true; do
            ask "Swap size in MiB (0 for none)" SWAP_SIZE
            [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] && break
            echo -e "${RED}Enter a number >= 0.${RST}"
        done
    fi

    USE_LVM="n"
    USE_LUKS="n"
    LUKS_PASS=""
    if confirm "Use LVM?"; then USE_LVM="y"; fi
    if confirm "Encrypt root with LUKS?"; then
        USE_LUKS="y"
        while true; do
            echo -ne "${CYN}Encryption passphrase${RST}: "
            read -rs LUKS_PASS; echo
            echo -ne "${CYN}Confirm passphrase${RST}: "
            read -rs LUKS_PASS2; echo
            [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
            echo -e "${RED}Passphrases empty or don't match.${RST}"
        done
    fi
}

select_timezone() {
    banner
    echo -e "${BLD}Timezone${RST} - type to filter (e.g. Europe, Berlin)"
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
        echo -e "${RED}${#tz_list[@]} results - refine filter.${RST}"
        select_timezone; return
    fi
    for i in "${!tz_list[@]}"; do echo "  $((i+1))) ${tz_list[$i]}"; done
    echo
    while true; do
        echo -ne "${CYN}Choice (0=manual)${RST}: "
        read -r c
        [ "$c" = "0" ] && { ask "Timezone" TIMEZONE "UTC"; return; }
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#tz_list[@]} )); then
            TIMEZONE="${tz_list[$((c-1))]}"; return
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
    echo -e "${BLD}Extra user accounts${RST} - leave blank to stop"
    echo
    while true; do
        echo -ne "${CYN}Username (blank=done)${RST}: "
        read -r uname
        [ -z "$uname" ] && break
        ask_pass "Password for $uname" upass
        local usudo="y"
        echo -ne "${CYN}Give $uname sudo rights? [Y/n]${RST}: "
        read -r usudo
        [[ "$usudo" =~ ^[Nn]$ ]] && usudo="n" || usudo="y"
        EXTRA_USERS+=("${uname}|${upass}|${usudo}")
        ok "Added: $uname (sudo: $usudo)"
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

partition_disk() {
    step "Partitioning $DISK..."
    EFI_END=$((2 + EFI_SIZE))
    SWAP_END=$((EFI_END + SWAP_SIZE))
    parted -s "$DISK" mklabel gpt                                || die "mklabel failed"
    parted -s "$DISK" mkpart bios_boot 1MiB 2MiB                || die "BIOS boot partition failed"
    parted -s "$DISK" set 1 bios_grub on                        || die "bios_grub flag failed"
    parted -s "$DISK" mkpart ESP fat32 2MiB "${EFI_END}MiB"     || die "EFI partition failed"
    parted -s "$DISK" set 2 esp on                              || die "esp flag failed"
    NEXT_PART=3
    if [ "$SWAP_SIZE" -gt 0 ]; then
        parted -s "$DISK" mkpart swap linux-swap "${EFI_END}MiB" "${SWAP_END}MiB" || die "swap partition failed"
        NEXT_PART=4
    fi
    ROOT_START=$([ "$SWAP_SIZE" -gt 0 ] && echo "${SWAP_END}MiB" || echo "${EFI_END}MiB")
    parted -s "$DISK" mkpart primary ext4 "$ROOT_START" 100%    || die "root partition failed"
    partprobe "$DISK" 2>/dev/null; sleep 2
    if [[ "$DISK" == *nvme* ]]; then
        SEP="p"
    else
        SEP=""
    fi
    BIOS="${DISK}${SEP}1"; EFI="${DISK}${SEP}2"
    if [ "$SWAP_SIZE" -gt 0 ]; then SWAP="${DISK}${SEP}3"; else SWAP=""; fi
    ROOT="${DISK}${SEP}${NEXT_PART}"
    [ -b "$BIOS" ] || die "BIOS partition $BIOS not found"
    [ -b "$EFI"  ] || die "EFI partition $EFI not found"
    [ -b "$ROOT" ] || die "Root partition $ROOT not found"
    mkfs.fat -F32 -n EFI "$EFI"      || die "mkfs.fat failed"
    if [ -n "$SWAP" ]; then
        mkswap -L borealswap "$SWAP" || die "mkswap failed"
    fi

    FINAL_ROOT="$ROOT"
    LUKS_UUID=""

    if [ "$USE_LUKS" = "y" ]; then
        step "Setting up LUKS encryption..."
        printf '%s' "$LUKS_PASS" > /tmp/borealkey
        chmod 600 /tmp/borealkey
        cryptsetup luksFormat --type luks2 -q "$ROOT" --key-file=/tmp/borealkey || { shred -u /tmp/borealkey; die "luksFormat failed"; }
        cryptsetup luksOpen "$ROOT" borealcrypt --key-file=/tmp/borealkey || { shred -u /tmp/borealkey; die "luksOpen failed"; }
        shred -u /tmp/borealkey
        FINAL_ROOT="/dev/mapper/borealcrypt"
        LUKS_UUID=$(cryptsetup luksUUID "$ROOT")
        [ -n "$LUKS_UUID" ] || die "Could not read LUKS UUID"
    fi

    if [ "$USE_LVM" = "y" ]; then
        step "Setting up LVM..."
        pvcreate -f "$FINAL_ROOT"          || die "pvcreate failed"
        vgcreate borealvg "$FINAL_ROOT"    || die "vgcreate failed"
        lvcreate -l 100%FREE -n root borealvg || die "lvcreate failed"
        FINAL_ROOT="/dev/borealvg/root"
        sleep 1
    fi

    mkfs.ext4 -F -L borealOS "$FINAL_ROOT" || die "mkfs.ext4 failed"
    sleep 1
    ROOT_UUID=$(blkid -s UUID -o value "$FINAL_ROOT") || die "blkid root failed"
    EFI_UUID=$(blkid -s UUID -o value "$EFI")   || die "blkid efi failed"
    [ -n "$ROOT_UUID" ] || die "Root UUID empty"
    [ -n "$EFI_UUID"  ] || die "EFI UUID empty"
    ok "Root UUID: $ROOT_UUID  EFI UUID: $EFI_UUID"
}

mount_target() {
    step "Mounting..."
    mount "$FINAL_ROOT" /mnt     || die "mount root failed"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi  || die "mount EFI failed"
    ok "Mounted."
}

rsync_system() {
    step "Copying live system to disk..."
    rsync -aAX \
        --exclude=/proc/* \
        --exclude=/sys/* \
        --exclude=/dev/* \
        --exclude=/run/* \
        --exclude=/tmp/* \
        --exclude=/mnt/* \
        --exclude=/media/* \
        --exclude=/live \
        --exclude=/boot/grub \
        --exclude=/boot/efi \
        --exclude=/opt/borealOS \
        --exclude=/usr/local/bin/borealOS-install \
        --exclude=/etc/profile.d/live-welcome.sh \
        / /mnt/ || die "rsync failed"
    mkdir -p /mnt/{proc,sys,dev,run,tmp,boot/grub,boot/efi}
    chmod 1777 /mnt/tmp
    ok "System copied."
}

install_bundled_packages() {
    step "Installing display manager into target system..."
    bind_mounts
    cp /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true

    # Install the DM directly into the target via apt — no pre-cached debs needed.
    # lightdm is the default; sddm for KDE (set by $DM_PKGS).
    local dm_to_install="${DM_PKGS:-lightdm lightdm-gtk-greeter}"
    chroot /mnt apt-get install -y $dm_to_install 2>/dev/null ||         warn "DM install failed — target may boot to TTY"

    # Install any other cached debs (bundled drivers, etc.)
    local deb_count
    deb_count=$(ls /opt/borealOS/debs/*.deb 2>/dev/null | wc -l)
    if [ "$deb_count" -gt 0 ]; then
        mkdir -p /mnt/tmp/debs
        cp /opt/borealOS/debs/*.deb /mnt/tmp/debs/
        chroot /mnt /bin/bash <<DPKG
dpkg -i --force-depends /tmp/debs/*.deb 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
rm -rf /tmp/debs
DPKG
        ok "Bundled debs installed ($deb_count)."
    fi

    unbind_mounts
    ok "Display manager installed."
}

bind_mounts() {
    for d in dev proc sys run; do
        mount --bind /$d /mnt/$d || die "bind mount /$d failed"
    done
}

unbind_mounts() {
    for d in dev proc sys run; do
        umount -l /mnt/$d 2>/dev/null || true
    done
}

write_fstab() {
    step "Writing fstab..."
    cat > /mnt/etc/fstab <<FSTAB
UUID=${ROOT_UUID}  /         ext4  errors=remount-ro  0  1
UUID=${EFI_UUID}   /boot/efi vfat  umask=0077         0  2
FSTAB
    if [ -n "$SWAP" ]; then
        SWAP_UUID=$(blkid -s UUID -o value "$SWAP")
        if [ -n "$SWAP_UUID" ]; then
            echo "UUID=${SWAP_UUID}   none      swap  sw                 0  0" >> /mnt/etc/fstab
        fi
    fi
    if [ "$USE_LUKS" = "y" ]; then
        cat > /mnt/etc/crypttab <<CRYPTTAB
borealcrypt UUID=${LUKS_UUID} none luks,discard
CRYPTTAB
    fi
    ok "fstab written."
}

write_network() {
    # Only loopback in interfaces - dhcpcd handles ethernet automatically
    # (dhcpcd skips interfaces listed in /etc/network/interfaces as DHCP)
    cat > /mnt/etc/network/interfaces <<IFACES
auto lo
iface lo inet loopback
IFACES
    rm -rf /mnt/etc/network/interfaces.d/* 2>/dev/null || true

    [ "$NET_TYPE" = "Skip" ] && { ok "Network skipped."; return; }

    step "Writing network config..."
    mkdir -p /mnt/etc/rc2.d /mnt/etc/runlevels/default

    if [ "$NET_TYPE" = "DHCP (automatic)" ]; then
        # dhcpcd with no interface arg = configures ALL ethernet interfaces automatically
        cat > /mnt/etc/dhcpcd.conf <<DHCP
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, routers
option ntp_servers
option interface_mtu
slaac private
static domain_name_servers=1.1.1.1 8.8.8.8
DHCP
        rm -f /mnt/etc/rc2.d/S*dhcpcd /mnt/etc/rc2.d/S*NetworkManager 2>/dev/null || true
        rm -f /mnt/etc/runlevels/default/dhcpcd /mnt/etc/runlevels/default/NetworkManager 2>/dev/null || true
        ln -sf ../init.d/dhcpcd /mnt/etc/rc2.d/S02dhcpcd
        ln -sf /etc/init.d/dhcpcd /mnt/etc/runlevels/default/dhcpcd 2>/dev/null || true
    else
        cat >> /mnt/etc/network/interfaces <<IFACES

auto ${NET_IF}
iface ${NET_IF} inet static
    address ${NET_IP}
    gateway ${NET_GW}
    dns-nameservers ${NET_DNS}
IFACES
    fi
    ok "Network config written."
}

configure_system() {
    step "Configuring system..."

    cat > /mnt/etc/apt/sources.list <<SOURCES
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
SOURCES
    rm -f /mnt/etc/apt/sources.list.d/*.list 2>/dev/null || true

    chroot /mnt /bin/bash <<CHROOT || die "System configuration failed"
set -e
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
HOSTS
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
sed -i "s|^# *${LOCALE}|${LOCALE}|" /etc/locale.gen 2>/dev/null || true
grep -q "^${LOCALE}" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
cat > /etc/os-release <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS alpha"
ID=borealos
ID_LIKE=
VERSION="alpha"
VERSION_ID="alpha"
HOME_URL="https://borealos.org"
OS
cat > /etc/lsb-release <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=alpha
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS alpha"
LSB
echo "BorealOS"     > /etc/issue
echo "BorealOS alpha" > /etc/issue.net
echo "BorealOS"     > /etc/debian_version
CHROOT

    step "Finalizing system branding..."
    find /mnt/usr/share \
        \( -name "*debian*" -not -path "*/dpkg/*" -not -path "*/apt/*" -not -path "*/python3/*" \) \
        -delete 2>/dev/null || true
    rm -rf /mnt/usr/share/images/desktop-base 2>/dev/null || true
    rm -rf /mnt/usr/share/images/vendor-logos 2>/dev/null || true

    if [ ! -s /mnt/usr/share/python3/debian_defaults ]; then
        PYVER=$(ls /mnt/usr/lib/ | grep -oP '^python3\.[0-9]+$' | sort -V | tail -1)
        if [ -n "$PYVER" ]; then
            mkdir -p /mnt/usr/share/python3
            cat > /mnt/usr/share/python3/debian_defaults <<PYDEFAULTS
[DEFAULT]
default-version = ${PYVER}
supported-versions = ${PYVER}
unsupported-versions =
requested-versions = 3.${PYVER#python3.}
PYDEFAULTS
        fi
    fi

    step "Installing artwork..."
    mkdir -p /mnt/usr/share/boreal-artwork
    cp /opt/borealOS/background_2.png   /mnt/usr/share/boreal-artwork/wallpaper-default.png
    cp /opt/borealOS/background_one.png /mnt/usr/share/boreal-artwork/wallpaper-waves.png
    cp /opt/borealOS/logo.png           /mnt/usr/share/boreal-artwork/logo.png

    ok "System configured."
}

set_passwords() {
    step "Setting passwords..."
    printf 'root:%s\n' "$ROOT_PASS" | chroot /mnt /usr/sbin/chpasswd || die "root password failed"
    for entry in "${EXTRA_USERS[@]}"; do
        local uname="${entry%%|*}"
        local rest="${entry#*|}"
        local upass="${rest%%|*}"
        local usudo="${rest##*|}"
        local groups="audio,video,netdev"
        [ "$usudo" = "y" ] && groups="sudo,${groups}"
        chroot /mnt useradd -m -G "$groups" -s "$SHELL_BIN" "$uname" 2>/dev/null || \
        chroot /mnt useradd -m -G "audio,video" -s "$SHELL_BIN" "$uname" || \
        die "useradd failed for $uname"
        printf '%s:%s\n' "$uname" "$upass" | chroot /mnt /usr/sbin/chpasswd || die "password failed for $uname"
    done
    ok "Passwords set."
}

remove_live_boot() {
    step "Removing live-boot..."
    chroot /mnt dpkg -r --force-depends \
        live-boot live-boot-initramfs-tools \
        live-config live-config-systemd 2>/dev/null || true
    find /mnt/usr/share/initramfs-tools \
         /mnt/etc/initramfs-tools \
         /mnt/etc/grub.d \
         -name "*live*" -delete 2>/dev/null || true
    rm -rf /mnt/lib/live /mnt/usr/lib/live 2>/dev/null || true
    rm -f /mnt/etc/profile.d/boreal-live.sh 2>/dev/null || true
    rm -f /mnt/usr/local/bin/boreal-start-graphical 2>/dev/null || true

    # Remove the minimal XFCE installer host environment unless the user
    # actually chose XFCE as their DE. If they chose XFCE, the full
    # xfce4-goodies suite was installed on top — nothing to remove.
    if [ "$DE_CHOICE" != "XFCE" ]; then
        step "Removing XFCE installer host (not the chosen DE)..."
        chroot /mnt apt-get remove --purge -y \
            xfce4 xfce4-terminal xfwm4 xfdesktop4 xfconf \
            xfce4-session xfce4-panel thunar \
            2>/dev/null || true
        chroot /mnt apt-get autoremove --purge -y 2>/dev/null || true
        ok "XFCE installer host removed."
    else
        ok "XFCE is the chosen DE — keeping full install."
    fi

    # Clean up the live-only deb caches from the target system
    rm -rf /mnt/opt/borealOS/gui-debs 2>/dev/null || true
    rm -rf /mnt/opt/borealOS/debs 2>/dev/null || true

    step "Purging plymouth from target (broken hook causes initramfs failure)..."
    # Plymouth's initramfs hook references /usr/share/plymouth/debian-logo.png
    # which doesn't exist in the target, causing update-initramfs to fail.
    # Purge it completely before rebuilding — we don't use plymouth anyway.
    chroot /mnt dpkg -r --force-depends         plymouth plymouth-themes libplymouth5         plymouth-label plymouth-theme-debian-logo         plymouth-theme-debian-spinner         2>/dev/null || true
    # Belt-and-suspenders: delete the hook files directly
    rm -f /mnt/usr/share/initramfs-tools/hooks/plymouth           /mnt/usr/share/initramfs-tools/scripts/init-top/plymouth           /mnt/usr/share/initramfs-tools/scripts/init-bottom/plymouth           /mnt/etc/initramfs-tools/conf.d/plymouth           /mnt/usr/share/plymouth/debian-logo.png 2>/dev/null || true
    find /mnt/etc/initramfs-tools -name "*plymouth*" -delete 2>/dev/null || true
    ok "Plymouth purged."

    step "Rebuilding initramfs..."
    chroot /mnt update-initramfs -u -k all 2>&1 || die "update-initramfs failed"
    ls /mnt/boot/initrd.img-* >/dev/null 2>&1 || die "No initrd after rebuild"
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
    step "Configuring DE: $DE_CHOICE..."
    mkdir -p /mnt/etc/runlevels/default /mnt/etc/rc2.d

    case "$DE_CHOICE" in
        "KDE Plasma")
            ln -sf /etc/init.d/sddm /mnt/etc/runlevels/default/sddm 2>/dev/null || true
            ln -sf ../init.d/sddm /mnt/etc/rc2.d/S03sddm 2>/dev/null || true
            mkdir -p /mnt/etc/sddm.conf.d
            cat > /mnt/etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/boreal-artwork/wallpaper-default.png
SDDM
            ;;
        "XFCE")
            ln -sf /etc/init.d/lightdm /mnt/etc/runlevels/default/lightdm 2>/dev/null || true
            ln -sf ../init.d/lightdm /mnt/etc/rc2.d/S03lightdm 2>/dev/null || true
            mkdir -p /mnt/etc/lightdm
            if ls /opt/borealOS/lightdm/* >/dev/null 2>&1; then
                cp -r /opt/borealOS/lightdm/. /mnt/etc/lightdm/
                ok "lightdm rice config applied."
            else
                cat > /mnt/etc/lightdm/lightdm-gtk-greeter.conf <<LDM
[greeter]
background=/usr/share/boreal-artwork/wallpaper-default.png
LDM
            fi
            mkdir -p /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
            {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo '<channel name="xfce4-desktop" version="1.0">'
            echo '  <property name="backdrop" type="empty">'
            echo '    <property name="screen0" type="empty">'
            echo '      <property name="monitor0" type="empty">'
            echo '        <property name="workspace0" type="empty">'
            echo '          <property name="last-image" type="string" value="/usr/share/boreal-artwork/wallpaper-default.png"/>'
            echo '          <property name="image-style" type="int" value="5"/>'
            echo '        </property>'
            echo '      </property>'
            for mon in Virtual-1 Virtual-0 VGA-1 VGA-0 HDMI-1 HDMI-0 DP-1 DP-0 eDP-1 eDP-0 DVI-I-1 DVI-D-1; do
                echo "      <property name=\"${mon}\" type=\"empty\">"
                echo '        <property name="workspace0" type="empty">'
                echo '          <property name="last-image" type="string" value="/usr/share/boreal-artwork/wallpaper-default.png"/>'
                echo '          <property name="image-style" type="int" value="5"/>'
                echo '        </property>'
                echo '      </property>'
            done
            echo '    </property>'
            echo '  </property>'
            echo '</channel>'
            } > /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
            # Also write to skel so any installed user actually gets it — the
            # system-default file above only applies when no per-user config
            # exists, and is silently ignored by some xfdesktop versions once
            # a session has run once.
            mkdir -p /mnt/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
            cp /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml \
               /mnt/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
            # Also drop the panel-icon autostart fixer (see live env section)
            # into skel so the panel logo applies for installed users too.
            mkdir -p /mnt/etc/skel/.config/autostart
            cp /usr/local/bin/boreal-panel-icon.sh /mnt/usr/local/bin/boreal-panel-icon.sh 2>/dev/null || true
            cat > /mnt/etc/skel/.config/autostart/boreal-panel-icon.desktop <<PANELAUTOSTART
[Desktop Entry]
Type=Application
Name=BorealOS Panel Icon
Exec=/usr/local/bin/boreal-panel-icon.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
PANELAUTOSTART
            ;;
        "Hyprland")
            mkdir -p /mnt/etc/hypr
            cat > /mnt/etc/hypr/hyprland.conf <<HYPR
\$mod = SUPER
monitor=,preferred,auto,1
exec-once = waybar
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(4dffd2ff)
    col.inactive_border = rgba(0d1b2aff)
}
decoration { rounding = 8 }
bind = \$mod, Return, exec, foot
bind = \$mod, D, exec, wofi --show run
bind = \$mod SHIFT, Q, killactive
bind = \$mod SHIFT, E, exit
bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
HYPR
            for u in "${EXTRA_USERS[@]}"; do
                local uname="${u%%|*}"
                mkdir -p /mnt/home/${uname}/.config/hypr
                cp /mnt/etc/hypr/hyprland.conf /mnt/home/${uname}/.config/hypr/
                chroot /mnt chown -R ${uname}:${uname} /home/${uname}/.config
            done
            ;;
        "Niri")
            mkdir -p /mnt/etc/niri
            cat > /mnt/etc/niri/config.kdl <<NIRI
input {
    keyboard { xkb { layout "us" } }
    touchpad { tap }
}
layout {
    gaps 16
    border { width 2; active-color "#4dffd2"; inactive-color "#0d1b2a" }
    focus-ring { off }
}
binds {
    Mod+Return { spawn "foot"; }
    Mod+D { spawn "wofi" "--show" "run"; }
    Mod+Shift+Q { close-window; }
    Mod+Shift+E { quit; }
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up    { focus-window-up; }
    Mod+Down  { focus-window-down; }
}
NIRI
            for u in "${EXTRA_USERS[@]}"; do
                local uname="${u%%|*}"
                mkdir -p /mnt/home/${uname}/.config/niri
                cp /mnt/etc/niri/config.kdl /mnt/home/${uname}/.config/niri/
                chroot /mnt chown -R ${uname}:${uname} /home/${uname}/.config
            done
            ;;
    esac
    ok "DE configured."
}

install_grub() {
    step "Installing GRUB theme..."
    mkdir -p /mnt/boot/grub/themes/boreal
    if [ -d /usr/share/grub/themes/boreal ]; then
        cp -r /usr/share/grub/themes/boreal/. /mnt/boot/grub/themes/boreal/
    fi

    step "Installing GRUB..."
    rm -rf /mnt/boot/efi/EFI 2>/dev/null || true

    cat > /mnt/etc/default/grub <<GRUBDEF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=BorealOS
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXMODE=auto
GRUBDEF
    if [ "$USE_LUKS" = "y" ]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /mnt/etc/default/grub
    fi

    GRUB_MODULES=""
    if [ "$USE_LUKS" = "y" ] && [ "$USE_LVM" = "y" ]; then
        GRUB_MODULES='--modules="cryptodisk luks2 luks lvm"'
    elif [ "$USE_LUKS" = "y" ]; then
        GRUB_MODULES='--modules="cryptodisk luks2 luks"'
    elif [ "$USE_LVM" = "y" ]; then
        GRUB_MODULES='--modules="lvm"'
    fi

    chroot /mnt bash -c "grub-install --target=i386-pc $GRUB_MODULES '$DISK'" \
        2>&1 || die "BIOS grub-install failed"

    chroot /mnt bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS --removable --recheck $GRUB_MODULES" \
        2>&1 || warn "EFI grub-install failed (ok if BIOS-only)"

    KVER=$(ls /mnt/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/mnt/boot/vmlinuz-||')
    [ -n "$KVER" ] || die "No kernel found in /mnt/boot"
    [ -f "/mnt/boot/initrd.img-${KVER}" ] || die "No initrd for kernel $KVER"

    UNLOCK=""
    if [ "$USE_LUKS" = "y" ]; then
        NODASH=$(echo "$LUKS_UUID" | tr -d '-')
        UNLOCK="insmod cryptodisk
insmod luks2
insmod luks
cryptomount -u ${NODASH}
"
        [ "$USE_LVM" = "y" ] && UNLOCK="${UNLOCK}insmod lvm
"
    elif [ "$USE_LVM" = "y" ]; then
        UNLOCK="insmod lvm
"
    fi

    mkdir -p /mnt/boot/efi/EFI/BOOT
    cat > /mnt/boot/efi/EFI/BOOT/grub.cfg <<EGCFG
${UNLOCK}search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
EGCFG

    mkdir -p /mnt/boot/grub
    cat > /mnt/boot/grub/grub.cfg <<GCFG
insmod all_video
insmod gfxterm
insmod png
set gfxmode=auto
terminal_output gfxterm

set default=0
set timeout=5

if [ -f /boot/grub/themes/boreal/theme.txt ]; then
    set theme=/boot/grub/themes/boreal/theme.txt
else
    set menu_color_normal=cyan/black
    set menu_color_highlight=black/cyan
fi

menuentry "BorealOS alpha" {
    ${UNLOCK}search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro quiet
    initrd /boot/initrd.img-${KVER}
}
menuentry "BorealOS alpha (recovery)" {
    ${UNLOCK}search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro single
    initrd /boot/initrd.img-${KVER}
}
GCFG

    ok "GRUB installed. Kernel: $KVER"
}

verify() {
    step "Verifying..."
    local fail=0
    [ -f /mnt/boot/grub/grub.cfg ]                 || { warn "grub.cfg missing";     fail=1; }
    [ -f /mnt/etc/fstab ]                          || { warn "fstab missing";         fail=1; }
    ls /mnt/boot/vmlinuz-* >/dev/null 2>&1         || { warn "No kernel";             fail=1; }
    ls /mnt/boot/initrd.img-* >/dev/null 2>&1      || { warn "No initrd";             fail=1; }
    grep -q "${ROOT_UUID}" /mnt/boot/grub/grub.cfg || { warn "UUID not in grub.cfg";  fail=1; }
    grep -q "${ROOT_UUID}" /mnt/etc/fstab          || { warn "UUID not in fstab";     fail=1; }
    grep -q "boot=live" /mnt/boot/grub/grub.cfg    && { warn "boot=live in grub.cfg!"; fail=1; }
    [ "$fail" = "1" ] && die "Verification failed."
    ok "All checks passed."
}

cleanup() {
    unbind_mounts 2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt 2>/dev/null || true
    [ -n "$SWAP" ] && swapoff "$SWAP" 2>/dev/null || true
    vgchange -an borealvg 2>/dev/null || true
    cryptsetup luksClose borealcrypt 2>/dev/null || true
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
    echo -e "${BLD}BorealOS Installer${RST}"
    echo -e "  DE: ${DE_CHOICE}  |  Shell: ${SHELL_BIN}"
    echo
    confirm "Begin?" || die "Aborted."

    select_disk
    select_partitioning
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
    install_bundled_packages
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

trap 'unbind_mounts 2>/dev/null; umount /mnt/boot/efi 2>/dev/null; umount /mnt 2>/dev/null; vgchange -an borealvg 2>/dev/null; cryptsetup luksClose borealcrypt 2>/dev/null' EXIT
main
