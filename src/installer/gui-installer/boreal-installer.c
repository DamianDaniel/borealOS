#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

typedef struct {
    char name[64];
    char pass[128];
    gboolean sudo;
} ExtraUser;

typedef struct {
    GtkWidget *window;
    GtkWidget *stack;
    GtkWidget *btn_back, *btn_next, *btn_cancel;

    GtkWidget *disk_list;
    GtkWidget *lvm_check, *luks_check, *luks_pass_entry, *luks_pass2_entry, *luks_box;
    GtkWidget *part_auto, *part_advanced, *advanced_box, *efi_size_entry, *swap_size_entry;
    GtkWidget *hostname_entry, *pass1_entry, *pass2_entry, *locale_entry;
    GtkWidget *tz_filter_entry, *tz_list;
    GtkWidget *user_list_box;
    GtkWidget *net_dhcp, *net_static, *net_skip, *net_if_combo;
    GtkWidget *net_ip_entry, *net_gw_entry, *net_dns_entry;
    GtkWidget *net_static_box;
    GtkWidget *net_wifi, *wifi_box, *wifi_ssid_combo, *wifi_pass_entry;
    GtkWidget *summary_label;
    GtkWidget *progress_bar, *progress_label, *log_view;
    GtkWidget *finish_box;

    char disk[64];
    char hostname[128];
    char root_pass[128];
    char locale[64];
    char timezone[128];
    char de_choice[64];
    char de_start[64];
    char shell_bin[64];
    char net_type[16];
    char net_if[64];
    char net_ip[64];
    char net_gw[64];
    char net_dns[64];
    char wifi_ssid[128];
    char wifi_pass[128];
    char root_uuid[64];
    char efi_uuid[64];
    char bios_part[64];
    char efi_part[64];
    char swap_part[64];
    char root_part[64];
    char final_root_dev[64];
    char luks_uuid[64];
    gboolean use_lvm;
    gboolean use_luks;
    char luks_pass[128];
    gboolean advanced_part;
    int efi_size_mib;
    int swap_size_mib;

    GList *extra_users;

    GtkTextBuffer *log_buffer;
    int current_page;
} App;

static App app;

typedef struct { char *text; } LogMsg;
typedef struct { double frac; char *label; } ProgMsg;

static gboolean log_idle(gpointer data) {
    LogMsg *m = data;
    GtkTextIter end;
    gtk_text_buffer_get_end_iter(app.log_buffer, &end);
    gtk_text_buffer_insert(app.log_buffer, &end, m->text, -1);
    gtk_text_buffer_insert(app.log_buffer, &end, "\n", -1);
    gtk_text_buffer_get_end_iter(app.log_buffer, &end);
    gtk_text_buffer_place_cursor(app.log_buffer, &end);
    GtkTextMark *mark = gtk_text_buffer_get_insert(app.log_buffer);
    gtk_text_view_scroll_to_mark(GTK_TEXT_VIEW(app.log_view), mark, 0.0, FALSE, 0, 0);
    g_free(m->text);
    g_free(m);
    return FALSE;
}

static void log_line(const char *fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    LogMsg *m = g_new0(LogMsg, 1);
    m->text = g_strdup(buf);
    g_idle_add(log_idle, m);
}

static gboolean prog_idle(gpointer data) {
    ProgMsg *m = data;
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(app.progress_bar), m->frac);
    gtk_label_set_text(GTK_LABEL(app.progress_label), m->label);
    gtk_widget_queue_draw(app.progress_bar);
    g_free(m->label);
    g_free(m);
    return FALSE;
}

static void set_progress(double frac, const char *label) {
    ProgMsg *m = g_new0(ProgMsg, 1);
    m->frac = frac;
    m->label = g_strdup(label);
    g_idle_add(prog_idle, m);
}

static int run_cmd(const char *cmd) {
    log_line("$ %s", cmd);
    char full[4096];
    snprintf(full, sizeof(full), "DEBIAN_FRONTEND=noninteractive %s </dev/null 2>&1", cmd);
    FILE *fp = popen(full, "r");
    if (!fp) { log_line("failed to spawn command"); return -1; }
    char line[1024];
    while (fgets(line, sizeof(line), fp)) {
        size_t l = strlen(line);
        if (l && line[l - 1] == '\n') line[l - 1] = 0;
        log_line("%s", line);
    }
    int status = pclose(fp);
    return WEXITSTATUS(status);
}

static char *run_capture(const char *cmd) {
    FILE *fp = popen(cmd, "r");
    if (!fp) return NULL;
    GString *s = g_string_new(NULL);
    char line[1024];
    while (fgets(line, sizeof(line), fp)) g_string_append(s, line);
    pclose(fp);
    return g_string_free(s, FALSE);
}

static void write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    if (!f) { log_line("ERROR: cannot write %s", path); return; }
    fputs(content, f);
    fclose(f);
}

typedef struct { gboolean *result; char *msg; } ErrMsg;

static void on_dialog_realize(GtkWidget *widget, gpointer data) {
    (void)data;
    GdkWindow *w = gtk_widget_get_window(widget);
    if (w) {
        GdkCursor *c = gdk_cursor_new_from_name(gdk_display_get_default(), "default");
        if (c) gdk_window_set_cursor(w, c);
    }
}

static void center_dialog_text(GtkWidget *container) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(container));
    for (GList *l = children; l; l = l->next) {
        if (GTK_IS_LABEL(l->data)) {
            gtk_label_set_justify(GTK_LABEL(l->data), GTK_JUSTIFY_CENTER);
            gtk_widget_set_halign(GTK_WIDGET(l->data), GTK_ALIGN_CENTER);
        } else if (GTK_IS_CONTAINER(l->data)) {
            center_dialog_text(GTK_WIDGET(l->data));
        }
    }
    g_list_free(children);
}

static void style_dialog(GtkWidget *dlg) {
    gtk_widget_set_name(dlg, "boreal-dialog");
    g_signal_connect(dlg, "realize", G_CALLBACK(on_dialog_realize), NULL);
    if (GTK_IS_MESSAGE_DIALOG(dlg)) {
        GtkWidget *area = gtk_message_dialog_get_message_area(GTK_MESSAGE_DIALOG(dlg));
        if (area) center_dialog_text(area);
    }
    const int responses[] = {GTK_RESPONSE_OK, GTK_RESPONSE_CANCEL, GTK_RESPONSE_YES, GTK_RESPONSE_NO};
    for (size_t i = 0; i < sizeof(responses) / sizeof(responses[0]); i++) {
        GtkWidget *btn = gtk_dialog_get_widget_for_response(GTK_DIALOG(dlg), responses[i]);
        if (btn) gtk_widget_set_name(btn, "nav-button");
    }
}

static gboolean err_idle(gpointer data) {
    ErrMsg *m = data;
    GtkWidget *dlg = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
        GTK_MESSAGE_ERROR, GTK_BUTTONS_OK, "%s", m->msg);
    style_dialog(dlg);
    gtk_dialog_run(GTK_DIALOG(dlg));
    gtk_widget_destroy(dlg);
    g_free(m->msg);
    g_free(m);
    return FALSE;
}

static void fail_install(const char *msg) {
    log_line("FATAL: %s", msg);
    ErrMsg *m = g_new0(ErrMsg, 1);
    m->msg = g_strdup_printf("Installation failed: %s\n\nSee the log below for details.", msg);
    g_idle_add(err_idle, m);
}

#define STEP(desc) log_line("==> %s", desc)

static gboolean check_assets(void) {
    if (access("/opt/borealOS/rootfs.tar.gz", F_OK) != 0) { fail_install("rootfs.tar.gz missing"); return FALSE; }
    if (access("/opt/borealOS/de", F_OK) != 0) { fail_install("/opt/borealOS/de missing"); return FALSE; }
    if (access("/opt/borealOS/shell", F_OK) != 0) { fail_install("/opt/borealOS/shell missing"); return FALSE; }
    char *de = run_capture("cat /opt/borealOS/de");
    char *de_start = run_capture("cat /opt/borealOS/de-start");
    char *sh = run_capture("cat /opt/borealOS/shell");
    if (de) { g_strstrip(de); strncpy(app.de_choice, de, sizeof(app.de_choice) - 1); g_free(de); }
    if (de_start) { g_strstrip(de_start); strncpy(app.de_start, de_start, sizeof(app.de_start) - 1); g_free(de_start); }
    if (sh) { g_strstrip(sh); strncpy(app.shell_bin, sh, sizeof(app.shell_bin) - 1); g_free(sh); }
    return TRUE;
}

static gboolean partition_disk(void) {
    STEP("Partitioning disk");
    char cmd[512];
    int efi_mib = app.advanced_part && app.efi_size_mib > 0 ? app.efi_size_mib : 512;
    int swap_mib = app.advanced_part ? app.swap_size_mib : 0;
    int efi_end = 2 + efi_mib;
    int swap_end = efi_end + swap_mib;
    gboolean has_swap = swap_mib > 0;

    snprintf(cmd, sizeof(cmd), "parted -s %s mklabel gpt", app.disk);
    if (run_cmd(cmd) != 0) { fail_install("mklabel failed"); return FALSE; }
    snprintf(cmd, sizeof(cmd), "parted -s %s mkpart bios_boot 1MiB 2MiB", app.disk);
    if (run_cmd(cmd) != 0) { fail_install("bios_boot partition failed"); return FALSE; }
    snprintf(cmd, sizeof(cmd), "parted -s %s set 1 bios_grub on", app.disk);
    run_cmd(cmd);
    snprintf(cmd, sizeof(cmd), "parted -s %s mkpart ESP fat32 2MiB %dMiB", app.disk, efi_end);
    if (run_cmd(cmd) != 0) { fail_install("ESP partition failed"); return FALSE; }
    snprintf(cmd, sizeof(cmd), "parted -s %s set 2 esp on", app.disk);
    run_cmd(cmd);

    int next_part_num = 3;
    if (has_swap) {
        snprintf(cmd, sizeof(cmd), "parted -s %s mkpart swap linux-swap %dMiB %dMiB", app.disk, efi_end, swap_end);
        if (run_cmd(cmd) != 0) { fail_install("swap partition failed"); return FALSE; }
        next_part_num = 4;
    }
    snprintf(cmd, sizeof(cmd), "parted -s %s mkpart primary ext4 %dMiB 100%%", app.disk, has_swap ? swap_end : efi_end);
    if (run_cmd(cmd) != 0) { fail_install("root partition failed"); return FALSE; }
    snprintf(cmd, sizeof(cmd), "partprobe %s", app.disk);
    run_cmd(cmd);
    sleep(2);

    const char *sep = strstr(app.disk, "nvme") ? "p" : "";
    snprintf(app.bios_part, sizeof(app.bios_part), "%s%s1", app.disk, sep);
    snprintf(app.efi_part, sizeof(app.efi_part), "%s%s2", app.disk, sep);
    if (has_swap) snprintf(app.swap_part, sizeof(app.swap_part), "%s%s3", app.disk, sep);
    snprintf(app.root_part, sizeof(app.root_part), "%s%s%d", app.disk, sep, next_part_num);

    if (access(app.efi_part, F_OK) != 0 || access(app.root_part, F_OK) != 0) {
        fail_install("Partitions did not appear after partitioning");
        return FALSE;
    }

    snprintf(cmd, sizeof(cmd), "mkfs.fat -F32 -n EFI %s", app.efi_part);
    if (run_cmd(cmd) != 0) { fail_install("mkfs.fat failed"); return FALSE; }

    if (has_swap) {
        snprintf(cmd, sizeof(cmd), "mkswap -L borealswap %s", app.swap_part);
        if (run_cmd(cmd) != 0) { fail_install("mkswap failed"); return FALSE; }
    }

    strncpy(app.final_root_dev, app.root_part, sizeof(app.final_root_dev) - 1);

    if (app.use_luks) {
        STEP("Setting up LUKS encryption");
        write_file("/tmp/borealkey", app.luks_pass);
        run_cmd("chmod 600 /tmp/borealkey");
        snprintf(cmd, sizeof(cmd),
            "cryptsetup luksFormat --type luks2 -q %s --key-file=/tmp/borealkey", app.root_part);
        int fmt_rc = run_cmd(cmd);
        if (fmt_rc != 0) { run_cmd("shred -u /tmp/borealkey"); fail_install("luksFormat failed"); return FALSE; }
        snprintf(cmd, sizeof(cmd),
            "cryptsetup luksOpen %s borealcrypt --key-file=/tmp/borealkey", app.root_part);
        int open_rc = run_cmd(cmd);
        run_cmd("shred -u /tmp/borealkey");
        if (open_rc != 0) { fail_install("luksOpen failed"); return FALSE; }
        strncpy(app.final_root_dev, "/dev/mapper/borealcrypt", sizeof(app.final_root_dev) - 1);

        snprintf(cmd, sizeof(cmd), "cryptsetup luksUUID %s", app.root_part);
        char *lu = run_capture(cmd);
        if (lu) { g_strstrip(lu); strncpy(app.luks_uuid, lu, sizeof(app.luks_uuid) - 1); g_free(lu); }
        if (!app.luks_uuid[0]) { fail_install("Could not read LUKS UUID"); return FALSE; }
    }

    if (app.use_lvm) {
        STEP("Setting up LVM");
        snprintf(cmd, sizeof(cmd), "pvcreate -f %s", app.final_root_dev);
        if (run_cmd(cmd) != 0) { fail_install("pvcreate failed"); return FALSE; }
        snprintf(cmd, sizeof(cmd), "vgcreate borealvg %s", app.final_root_dev);
        if (run_cmd(cmd) != 0) { fail_install("vgcreate failed"); return FALSE; }
        if (run_cmd("lvcreate -l 100%FREE -n root borealvg") != 0) { fail_install("lvcreate failed"); return FALSE; }
        strncpy(app.final_root_dev, "/dev/borealvg/root", sizeof(app.final_root_dev) - 1);
        sleep(1);
    }

    snprintf(cmd, sizeof(cmd), "mkfs.ext4 -F -L borealOS %s", app.final_root_dev);
    if (run_cmd(cmd) != 0) { fail_install("mkfs.ext4 failed"); return FALSE; }
    sleep(1);

    snprintf(cmd, sizeof(cmd), "blkid -s UUID -o value %s", app.final_root_dev);
    char *u = run_capture(cmd);
    if (u) { g_strstrip(u); strncpy(app.root_uuid, u, sizeof(app.root_uuid) - 1); g_free(u); }
    snprintf(cmd, sizeof(cmd), "blkid -s UUID -o value %s", app.efi_part);
    u = run_capture(cmd);
    if (u) { g_strstrip(u); strncpy(app.efi_uuid, u, sizeof(app.efi_uuid) - 1); g_free(u); }

    if (!app.root_uuid[0] || !app.efi_uuid[0]) { fail_install("Could not read partition UUIDs"); return FALSE; }
    log_line("Root UUID: %s  EFI UUID: %s", app.root_uuid, app.efi_uuid);
    return TRUE;
}

static gboolean mount_target(void) {
    STEP("Mounting target");
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "mount %s /mnt", app.final_root_dev);
    if (run_cmd(cmd) != 0) { fail_install("mount root failed"); return FALSE; }
    run_cmd("mkdir -p /mnt/boot/efi");
    snprintf(cmd, sizeof(cmd), "mount %s /mnt/boot/efi", app.efi_part);
    if (run_cmd(cmd) != 0) { fail_install("mount EFI failed"); return FALSE; }
    return TRUE;
}

static gboolean rsync_system(void) {
    STEP("Copying live system to disk");
    int rc = run_cmd(
        "rsync -aAX "
        "--exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/* "
        "--exclude=/tmp/* --exclude=/mnt/* --exclude=/media/* --exclude=/live "
        "--exclude=/boot/grub --exclude=/boot/efi --exclude=/opt/borealOS "
        "--exclude=/usr/local/bin/borealOS-install --exclude=/usr/local/bin/boreal-installer "
        "--exclude=/etc/profile.d/live-welcome.sh "
        "/ /mnt/");
    if (rc != 0) { fail_install("rsync failed"); return FALSE; }
    run_cmd("mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp /mnt/boot/grub /mnt/boot/efi");
    run_cmd("chmod 1777 /mnt/tmp");
    return TRUE;
}

static void bind_mounts(void) {
    run_cmd("mount --bind /dev /mnt/dev");
    run_cmd("mount --bind /proc /mnt/proc");
    run_cmd("mount --bind /sys /mnt/sys");
    run_cmd("mount --bind /run /mnt/run");
}

static void unbind_mounts(void) {
    run_cmd("umount -l /mnt/dev 2>/dev/null; umount -l /mnt/proc 2>/dev/null; "
            "umount -l /mnt/sys 2>/dev/null; umount -l /mnt/run 2>/dev/null");
}

static gboolean install_bundled_packages(void) {
    STEP("Installing display manager into target");
    bind_mounts();
    run_cmd("cp /etc/resolv.conf /mnt/etc/resolv.conf");

    const char *dm = "lightdm lightdm-gtk-greeter";
    if (strcmp(app.de_choice, "KDE Plasma") == 0) dm = "sddm";
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "chroot /mnt apt-get install -y %s", dm);
    if (run_cmd(cmd) != 0) log_line("WARN: display manager install failed, target may boot to TTY");

    unbind_mounts();
    return TRUE;
}

static gboolean write_fstab(void) {
    STEP("Writing fstab");
    char buf[768];
    int n = snprintf(buf, sizeof(buf),
        "UUID=%s  /         ext4  errors=remount-ro  0  1\n"
        "UUID=%s   /boot/efi vfat  umask=0077         0  2\n",
        app.root_uuid, app.efi_uuid);
    if (app.swap_part[0]) {
        char cmd[128];
        snprintf(cmd, sizeof(cmd), "blkid -s UUID -o value %s", app.swap_part);
        char *su = run_capture(cmd);
        if (su) {
            g_strstrip(su);
            snprintf(buf + n, sizeof(buf) - n, "UUID=%s   none      swap  sw                 0  0\n", su);
            g_free(su);
        }
    }
    write_file("/mnt/etc/fstab", buf);

    if (app.use_luks) {
        char cbuf[192];
        snprintf(cbuf, sizeof(cbuf), "borealcrypt UUID=%s none luks,discard\n", app.luks_uuid);
        write_file("/mnt/etc/crypttab", cbuf);
    }
    return TRUE;
}

static gboolean write_network(void) {
    STEP("Writing network configuration");
    write_file("/mnt/etc/network/interfaces", "auto lo\niface lo inet loopback\n");
    run_cmd("rm -rf /mnt/etc/network/interfaces.d/*");

    if (strcmp(app.net_type, "skip") == 0) return TRUE;

    run_cmd("mkdir -p /mnt/etc/rc2.d /mnt/etc/runlevels/default");

    if (strcmp(app.net_type, "dhcp") == 0) {
        write_file("/mnt/etc/dhcpcd.conf",
            "hostname\nclientid\npersistent\noption rapid_commit\n"
            "option domain_name_servers, domain_name, domain_search, routers\n"
            "option ntp_servers\noption interface_mtu\nslaac private\n"
            "static domain_name_servers=1.1.1.1 8.8.8.8\n");
        run_cmd("rm -f /mnt/etc/rc2.d/S*dhcpcd /mnt/etc/rc2.d/S*NetworkManager");
        run_cmd("rm -f /mnt/etc/runlevels/default/dhcpcd /mnt/etc/runlevels/default/NetworkManager");
        run_cmd("ln -sf ../init.d/dhcpcd /mnt/etc/rc2.d/S02dhcpcd");
        run_cmd("ln -sf /etc/init.d/dhcpcd /mnt/etc/runlevels/default/dhcpcd");
    } else if (strcmp(app.net_type, "wifi") == 0) {
        run_cmd("rm -f /mnt/etc/rc2.d/S*dhcpcd /mnt/etc/rc2.d/S*NetworkManager");
        run_cmd("rm -f /mnt/etc/runlevels/default/dhcpcd /mnt/etc/runlevels/default/NetworkManager");
        run_cmd("ln -sf ../init.d/NetworkManager /mnt/etc/rc2.d/S02NetworkManager");
        run_cmd("ln -sf /etc/init.d/NetworkManager /mnt/etc/runlevels/default/NetworkManager");

        char *uuid = run_capture("cat /proc/sys/kernel/random/uuid");
        if (uuid) g_strstrip(uuid);
        run_cmd("mkdir -p /mnt/etc/NetworkManager/system-connections");
        char conf[1024];
        snprintf(conf, sizeof(conf),
            "[connection]\nid=%s\nuuid=%s\ntype=wifi\nautoconnect=true\n\n"
            "[wifi]\nmode=infrastructure\nssid=%s\n\n"
            "[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n"
            "[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n",
            app.wifi_ssid, uuid ? uuid : "00000000-0000-0000-0000-000000000000",
            app.wifi_ssid, app.wifi_pass);
        char path[256];
        snprintf(path, sizeof(path), "/mnt/etc/NetworkManager/system-connections/%s.nmconnection", app.wifi_ssid);
        write_file(path, conf);
        char chmodcmd[300];
        snprintf(chmodcmd, sizeof(chmodcmd), "chmod 600 '%s'", path);
        run_cmd(chmodcmd);
        g_free(uuid);
    } else {
        FILE *f = fopen("/mnt/etc/network/interfaces", "a");
        if (f) {
            fprintf(f, "\nauto %s\niface %s inet static\n    address %s\n    gateway %s\n    dns-nameservers %s\n",
                app.net_if, app.net_if, app.net_ip, app.net_gw, app.net_dns);
            fclose(f);
        }
    }
    return TRUE;
}

static gboolean configure_system(void) {
    STEP("Configuring system");
    write_file("/mnt/etc/apt/sources.list",
        "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware\n"
        "deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware\n"
        "deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware\n");
    run_cmd("rm -f /mnt/etc/apt/sources.list.d/*.list");

    char script[4096];
    snprintf(script, sizeof(script),
        "set -e\n"
        "echo '%s' > /etc/hostname\n"
        "cat > /etc/hosts <<HOSTS\n127.0.0.1   localhost\n127.0.1.1   %s\n::1         localhost ip6-localhost ip6-loopback\nHOSTS\n"
        "ln -sf /usr/share/zoneinfo/%s /etc/localtime\n"
        "echo '%s' > /etc/timezone\n"
        "sed -i 's|^# *%s|%s|' /etc/locale.gen 2>/dev/null || true\n"
        "grep -q '^%s' /etc/locale.gen 2>/dev/null || echo '%s UTF-8' >> /etc/locale.gen\n"
        "locale-gen\n"
        "echo 'LANG=%s' > /etc/locale.conf\n"
        "cat > /etc/os-release <<OS\nNAME=\"BorealOS\"\nPRETTY_NAME=\"BorealOS alpha\"\nID=borealos\nID_LIKE=\nVERSION=\"alpha\"\nVERSION_ID=\"alpha\"\nHOME_URL=\"https://borealos.org\"\nOS\n"
        "cat > /etc/lsb-release <<LSB\nDISTRIB_ID=BorealOS\nDISTRIB_RELEASE=alpha\nDISTRIB_CODENAME=boreal\nDISTRIB_DESCRIPTION=\"BorealOS alpha\"\nLSB\n"
        "echo 'BorealOS' > /etc/issue\necho 'BorealOS alpha' > /etc/issue.net\necho 'BorealOS' > /etc/debian_version\n",
        app.hostname, app.hostname, app.timezone, app.timezone,
        app.locale, app.locale, app.locale, app.locale, app.locale);
    write_file("/mnt/tmp/boreal-configure.sh", script);
    if (run_cmd("chroot /mnt /bin/bash /tmp/boreal-configure.sh") != 0) {
        fail_install("System configuration failed");
        return FALSE;
    }

    run_cmd("find /mnt/usr/share \\( -name '*debian*' -not -path '*/dpkg/*' -not -path '*/apt/*' -not -path '*/python3/*' \\) -delete");
    run_cmd("rm -rf /mnt/usr/share/images/desktop-base /mnt/usr/share/images/vendor-logos");

    if (run_cmd("test -s /mnt/usr/share/python3/debian_defaults") != 0) {
        char *pyver = run_capture("ls /mnt/usr/lib/ | grep -oP '^python3\\.[0-9]+$' | sort -V | tail -1");
        if (pyver) g_strstrip(pyver);
        if (pyver && pyver[0]) {
            char pybuf[512];
            const char *verno = pyver + strlen("python3.");
            snprintf(pybuf, sizeof(pybuf),
                "[DEFAULT]\ndefault-version = %s\nsupported-versions = %s\n"
                "unsupported-versions =\nrequested-versions = 3.%s\n",
                pyver, pyver, verno);
            run_cmd("mkdir -p /mnt/usr/share/python3");
            write_file("/mnt/usr/share/python3/debian_defaults", pybuf);
        }
        g_free(pyver);
    }

    STEP("Installing artwork");
    run_cmd("mkdir -p /mnt/usr/share/boreal-artwork");
    run_cmd("cp /opt/borealOS/background_main.png /mnt/usr/share/boreal-artwork/wallpaper-default.png");
    run_cmd("cp /opt/borealOS/background_2.png    /mnt/usr/share/boreal-artwork/wallpaper-waves.png");
    run_cmd("cp /opt/borealOS/background_one.png  /mnt/usr/share/boreal-artwork/wallpaper-alt.png");
    run_cmd("cp /opt/borealOS/logo.png            /mnt/usr/share/boreal-artwork/logo.png");
    run_cmd("cp /opt/borealOS/banner.png /mnt/usr/share/boreal-artwork/banner.png 2>/dev/null || true");
    run_cmd("chmod 755 /mnt/usr/share/boreal-artwork");
    run_cmd("chmod 644 /mnt/usr/share/boreal-artwork/*.png");
    return TRUE;
}

static gboolean set_passwords(void) {
    STEP("Setting passwords");
    char cmd[256];
    FILE *p = popen("chroot /mnt chpasswd", "w");
    if (!p) { fail_install("chpasswd spawn failed"); return FALSE; }
    fprintf(p, "root:%s\n", app.root_pass);
    if (pclose(p) != 0) { fail_install("root password failed"); return FALSE; }

    for (GList *l = app.extra_users; l; l = l->next) {
        ExtraUser *u = l->data;
        const char *groups = u->sudo ? "sudo,audio,video,netdev" : "audio,video,netdev";
        snprintf(cmd, sizeof(cmd), "chroot /mnt useradd -m -G %s -s %s %s", groups, app.shell_bin, u->name);
        if (run_cmd(cmd) != 0) {
            snprintf(cmd, sizeof(cmd), "chroot /mnt useradd -m -G audio,video -s %s %s", app.shell_bin, u->name);
            if (run_cmd(cmd) != 0) { fail_install("useradd failed"); return FALSE; }
        }
        p = popen("chroot /mnt chpasswd", "w");
        if (p) { fprintf(p, "%s:%s\n", u->name, u->pass); pclose(p); }
    }
    return TRUE;
}

static gboolean remove_live_boot(void) {
    STEP("Removing live-boot components");
    run_cmd("chroot /mnt dpkg -r --force-depends live-boot live-boot-initramfs-tools live-config live-config-systemd");
    run_cmd("find /mnt/usr/share/initramfs-tools /mnt/etc/initramfs-tools /mnt/etc/grub.d -name '*live*' -delete");
    run_cmd("rm -rf /mnt/lib/live /mnt/usr/lib/live");
    run_cmd("rm -f /mnt/etc/profile.d/boreal-live.sh /mnt/usr/local/bin/boreal-start-graphical");

    if (strcmp(app.de_choice, "XFCE") != 0) {
        STEP("Removing XFCE installer host environment");
        run_cmd("chroot /mnt apt-get remove --purge -y xfce4 xfce4-terminal xfwm4 xfdesktop4 xfconf xfce4-session xfce4-panel thunar");
        run_cmd("chroot /mnt apt-get autoremove --purge -y");
    }
    run_cmd("rm -rf /mnt/opt/borealOS");
    run_cmd("rm -f /mnt/usr/local/bin/boreal-installer");
    run_cmd("rm -f /mnt/usr/share/applications/boreal-installer.desktop");
    run_cmd("rm -rf /mnt/usr/share/boreal-installer");
    run_cmd("rm -f \"/mnt/root/Desktop/Install BorealOS.desktop\" \"/mnt/etc/skel/Desktop/Install BorealOS.desktop\"");
    run_cmd("find /mnt/home -maxdepth 2 -name 'Install BorealOS.desktop' -delete 2>/dev/null || true");

    STEP("Purging plymouth");
    run_cmd("chroot /mnt dpkg -r --force-depends plymouth plymouth-themes libplymouth5 "
            "plymouth-label plymouth-theme-debian-logo plymouth-theme-debian-spinner");
    run_cmd("rm -f /mnt/usr/share/initramfs-tools/hooks/plymouth "
            "/mnt/usr/share/initramfs-tools/scripts/init-top/plymouth "
            "/mnt/usr/share/initramfs-tools/scripts/init-bottom/plymouth "
            "/mnt/etc/initramfs-tools/conf.d/plymouth /mnt/usr/share/plymouth/debian-logo.png");
    run_cmd("find /mnt/etc/initramfs-tools -name '*plymouth*' -delete");

    STEP("Rebuilding initramfs");
    if (run_cmd("chroot /mnt update-initramfs -u -k all") != 0) { fail_install("update-initramfs failed"); return FALSE; }
    if (run_cmd("ls /mnt/boot/initrd.img-* >/dev/null 2>&1") != 0) { fail_install("no initrd after rebuild"); return FALSE; }
    return TRUE;
}

static gboolean restore_inittab(void) {
    STEP("Restoring inittab");
    write_file("/mnt/etc/inittab",
        "id:2:initdefault:\n"
        "si::sysinit:/etc/init.d/rcS\n"
        "~~:S:wait:/sbin/sulogin --force\n"
        "l0:0:wait:/etc/init.d/rc 0\nl1:1:wait:/etc/init.d/rc 1\nl2:2:wait:/etc/init.d/rc 2\n"
        "l3:3:wait:/etc/init.d/rc 3\nl4:4:wait:/etc/init.d/rc 4\nl5:5:wait:/etc/init.d/rc 5\nl6:6:wait:/etc/init.d/rc 6\n"
        "z6:6:respawn:/sbin/sulogin --force\n"
        "ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now\n"
        "pf::powerwait:/etc/init.d/powerfail start\npn::powerfailnow:/etc/init.d/powerfail now\npo::powerokwait:/etc/init.d/powerfail stop\n"
        "1:2345:respawn:/sbin/getty --noclear 38400 tty1\n"
        "2:23:respawn:/sbin/getty 38400 tty2\n3:23:respawn:/sbin/getty 38400 tty3\n");
    return TRUE;
}

static gboolean setup_de(void) {
    STEP("Configuring desktop environment");
    run_cmd("mkdir -p /mnt/etc/runlevels/default /mnt/etc/rc2.d");

    if (strcmp(app.de_choice, "KDE Plasma") == 0) {
        run_cmd("ln -sf /etc/init.d/sddm /mnt/etc/runlevels/default/sddm");
        run_cmd("ln -sf ../init.d/sddm /mnt/etc/rc2.d/S03sddm");
        run_cmd("mkdir -p /mnt/etc/sddm.conf.d");
        write_file("/mnt/etc/sddm.conf.d/borealos.conf",
            "[General]\nDisplayServer=x11\n[Theme]\nBackground=/usr/share/boreal-artwork/wallpaper-default.png\n");
    } else if (strcmp(app.de_choice, "XFCE") == 0) {
        run_cmd("mkdir -p /mnt/etc/xdg/xfce4");
        write_file("/mnt/etc/xdg/xfce4/helpers.rc", "TerminalEmulator=kitty\nFileManager=Thunar\n");
        run_cmd("mkdir -p /mnt/etc/xdg");
        write_file("/mnt/etc/xdg/mimeapps.list",
            "[Default Applications]\ninode/directory=thunar.desktop\n");
        run_cmd("ln -sf /etc/init.d/lightdm /mnt/etc/runlevels/default/lightdm");
        run_cmd("ln -sf ../init.d/lightdm /mnt/etc/rc2.d/S03lightdm");
        run_cmd("mkdir -p /mnt/etc/lightdm");
        if (run_cmd("ls /opt/borealOS/lightdm/* >/dev/null 2>&1") == 0) {
            run_cmd("cp -r /opt/borealOS/lightdm/. /mnt/etc/lightdm/");
        } else {
            write_file("/mnt/etc/lightdm/lightdm-gtk-greeter.conf",
                "[greeter]\nbackground=/usr/share/boreal-artwork/wallpaper-default.png\n");
        }
        run_cmd("mkdir -p /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml");
        const char *mons[] = {"Virtual-1","Virtual-0","VGA-1","VGA-0","HDMI-1","HDMI-0",
                               "DP-1","DP-0","eDP-1","eDP-0","DVI-I-1","DVI-D-1", NULL};
        GString *xml = g_string_new(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<channel name=\"xfce4-desktop\" version=\"1.0\">\n"
            "  <property name=\"backdrop\" type=\"empty\">\n    <property name=\"screen0\" type=\"empty\">\n"
            "      <property name=\"monitor0\" type=\"empty\">\n        <property name=\"workspace0\" type=\"empty\">\n"
            "          <property name=\"last-image\" type=\"string\" value=\"/usr/share/boreal-artwork/wallpaper-default.png\"/>\n"
            "          <property name=\"image-style\" type=\"int\" value=\"5\"/>\n"
            "        </property>\n      </property>\n");
        for (int i = 0; mons[i]; i++) {
            g_string_append_printf(xml,
                "      <property name=\"%s\" type=\"empty\">\n        <property name=\"workspace0\" type=\"empty\">\n"
                "          <property name=\"last-image\" type=\"string\" value=\"/usr/share/boreal-artwork/wallpaper-default.png\"/>\n"
                "          <property name=\"image-style\" type=\"int\" value=\"5\"/>\n        </property>\n      </property>\n", mons[i]);
        }
        g_string_append(xml, "    </property>\n  </property>\n</channel>\n");
        write_file("/mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml", xml->str);
        run_cmd("mkdir -p /mnt/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml");
        run_cmd("cp /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml "
                "/mnt/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml");

        run_cmd("mkdir -p /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml");
        write_file("/mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<channel name=\"xsettings\" version=\"1.0\">\n"
            "  <property name=\"Net\" type=\"empty\">\n"
            "    <property name=\"IconThemeName\" type=\"string\" value=\"Adwaita\"/>\n"
            "  </property>\n</channel>\n");
        run_cmd("mkdir -p /mnt/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml");
        run_cmd("cp /mnt/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml "
                "/mnt/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml");

        run_cmd("find /mnt/usr/share/backgrounds /mnt/usr/share/wallpapers /mnt/usr/share/xfce4/backdrops "
                "-type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \\) -exec cp /mnt/usr/share/boreal-artwork/wallpaper-default.png {} \\; 2>/dev/null || true");
        run_cmd("mkdir -p /mnt/etc/skel/.config/autostart");
        run_cmd("cp /usr/local/bin/boreal-panel-icon.sh /mnt/usr/local/bin/boreal-panel-icon.sh");
        write_file("/mnt/etc/skel/.config/autostart/boreal-panel-icon.desktop",
            "[Desktop Entry]\nType=Application\nName=BorealOS Panel Icon\n"
            "Exec=/usr/local/bin/boreal-panel-icon.sh\nHidden=false\nNoDisplay=true\n"
            "X-GNOME-Autostart-enabled=true\nStartupNotify=false\n");
        g_string_free(xml, TRUE);
    } else if (strcmp(app.de_choice, "Niri") == 0) {
        run_cmd("mkdir -p /mnt/etc/niri");
        write_file("/mnt/etc/niri/config.kdl",
            "input {\n    keyboard { xkb { layout \"us\" } }\n    touchpad { tap }\n}\n"
            "layout {\n    gaps 16\n    border { width 2; active-color \"#4dffd2\"; inactive-color \"#0d1b2a\" }\n"
            "    focus-ring { off }\n}\nbinds {\n    Mod+Return { spawn \"foot\"; }\n"
            "    Mod+D { spawn \"wofi\" \"--show\" \"run\"; }\n    Mod+Shift+Q { close-window; }\n"
            "    Mod+Shift+E { quit; }\n    Mod+Left  { focus-column-left; }\n"
            "    Mod+Right { focus-column-right; }\n    Mod+Up    { focus-window-up; }\n"
            "    Mod+Down  { focus-window-down; }\n}\n");
        for (GList *l = app.extra_users; l; l = l->next) {
            ExtraUser *u = l->data;
            char cmd[512];
            snprintf(cmd, sizeof(cmd), "mkdir -p /mnt/home/%s/.config/niri && cp /mnt/etc/niri/config.kdl /mnt/home/%s/.config/niri/ && chroot /mnt chown -R %s:%s /home/%s/.config",
                u->name, u->name, u->name, u->name, u->name);
            run_cmd(cmd);
        }
    }
    return TRUE;
}

static gboolean install_grub(void) {
    STEP("Installing GRUB theme");
    run_cmd("mkdir -p /mnt/boot/grub/themes/boreal");
    run_cmd("cp -r /usr/share/grub/themes/boreal/. /mnt/boot/grub/themes/boreal/");

    STEP("Installing GRUB");
    run_cmd("rm -rf /mnt/boot/efi/EFI");
    char grubdefault[256];
    snprintf(grubdefault, sizeof(grubdefault),
        "GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_DISTRIBUTOR=BorealOS\n"
        "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\nGRUB_CMDLINE_LINUX=\"\"\n"
        "GRUB_DISABLE_OS_PROBER=true\nGRUB_GFXMODE=auto\n%s",
        app.use_luks ? "GRUB_ENABLE_CRYPTODISK=y\n" : "");
    write_file("/mnt/etc/default/grub", grubdefault);

    char cmd[512];
    const char *grub_modules = (app.use_luks && app.use_lvm) ? "--modules=\"cryptodisk luks2 luks lvm\" " :
                               app.use_luks ? "--modules=\"cryptodisk luks2 luks\" " :
                               app.use_lvm ? "--modules=\"lvm\" " : "";
    snprintf(cmd, sizeof(cmd), "chroot /mnt grub-install --target=i386-pc %s%s", grub_modules, app.disk);
    if (run_cmd(cmd) != 0) { fail_install("BIOS grub-install failed"); return FALSE; }
    snprintf(cmd, sizeof(cmd),
        "chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi "
        "--bootloader-id=BorealOS --removable --recheck %s", grub_modules);
    if (run_cmd(cmd) != 0)
        log_line("WARN: EFI grub-install failed (ok if BIOS-only)");

    char *kver_raw = run_capture("ls /mnt/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1");
    if (!kver_raw || !kver_raw[0]) { fail_install("No kernel found in /mnt/boot"); return FALSE; }
    g_strstrip(kver_raw);
    const char *prefix = "/mnt/boot/vmlinuz-";
    char *kver = g_strdup(kver_raw + strlen(prefix));
    g_free(kver_raw);

    char initrd_path[256];
    snprintf(initrd_path, sizeof(initrd_path), "/mnt/boot/initrd.img-%s", kver);
    if (access(initrd_path, F_OK) != 0) { fail_install("No matching initrd for kernel"); g_free(kver); return FALSE; }

    run_cmd("mkdir -p /mnt/boot/efi/EFI/BOOT");
    char unlock[256] = "";
    if (app.use_luks) {
        char nodash[64]; int j = 0;
        for (int i = 0; app.luks_uuid[i] && j < (int)sizeof(nodash) - 1; i++)
            if (app.luks_uuid[i] != '-') nodash[j++] = app.luks_uuid[i];
        nodash[j] = 0;
        snprintf(unlock, sizeof(unlock),
            "insmod cryptodisk\ninsmod luks2\ninsmod luks\ncryptomount -u %s\n%s",
            nodash, app.use_lvm ? "insmod lvm\n" : "");
    } else if (app.use_lvm) {
        strcpy(unlock, "insmod lvm\n");
    }

    char buf[1536];
    snprintf(buf, sizeof(buf),
        "%ssearch --no-floppy --fs-uuid --set=root %s\nset prefix=($root)/boot/grub\nconfigfile ($root)/boot/grub/grub.cfg\n",
        unlock, app.root_uuid);
    write_file("/mnt/boot/efi/EFI/BOOT/grub.cfg", buf);

    run_cmd("mkdir -p /mnt/boot/grub");
    snprintf(buf, sizeof(buf),
        "insmod all_video\ninsmod gfxterm\ninsmod png\nset gfxmode=auto\nterminal_output gfxterm\n\n"
        "set default=0\nset timeout=5\n\n"
        "if [ -f /boot/grub/themes/boreal/theme.txt ]; then\n    set theme=/boot/grub/themes/boreal/theme.txt\n"
        "else\n    set menu_color_normal=cyan/black\n    set menu_color_highlight=black/cyan\nfi\n\n"
        "menuentry \"BorealOS alpha\" {\n    %ssearch --no-floppy --fs-uuid --set=root %s\n"
        "    linux /boot/vmlinuz-%s root=UUID=%s ro quiet\n    initrd /boot/initrd.img-%s\n}\n"
        "menuentry \"BorealOS alpha (recovery)\" {\n    %ssearch --no-floppy --fs-uuid --set=root %s\n"
        "    linux /boot/vmlinuz-%s root=UUID=%s ro single\n    initrd /boot/initrd.img-%s\n}\n",
        unlock, app.root_uuid, kver, app.root_uuid, kver,
        unlock, app.root_uuid, kver, app.root_uuid, kver);
    write_file("/mnt/boot/grub/grub.cfg", buf);
    log_line("GRUB installed. Kernel: %s", kver);
    g_free(kver);
    return TRUE;
}

static gboolean verify_install(void) {
    STEP("Verifying installation");
    gboolean fail = FALSE;
    if (access("/mnt/boot/grub/grub.cfg", F_OK) != 0) { log_line("WARN: grub.cfg missing"); fail = TRUE; }
    if (access("/mnt/etc/fstab", F_OK) != 0) { log_line("WARN: fstab missing"); fail = TRUE; }
    if (run_cmd("ls /mnt/boot/vmlinuz-* >/dev/null 2>&1") != 0) { log_line("WARN: no kernel"); fail = TRUE; }
    if (run_cmd("ls /mnt/boot/initrd.img-* >/dev/null 2>&1") != 0) { log_line("WARN: no initrd"); fail = TRUE; }
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "grep -q '%s' /mnt/boot/grub/grub.cfg", app.root_uuid);
    if (run_cmd(cmd) != 0) { log_line("WARN: UUID not in grub.cfg"); fail = TRUE; }
    snprintf(cmd, sizeof(cmd), "grep -q '%s' /mnt/etc/fstab", app.root_uuid);
    if (run_cmd(cmd) != 0) { log_line("WARN: UUID not in fstab"); fail = TRUE; }
    if (run_cmd("grep -q 'boot=live' /mnt/boot/grub/grub.cfg") == 0) { log_line("WARN: boot=live still in grub.cfg"); fail = TRUE; }
    if (fail) { fail_install("Verification failed, see log"); return FALSE; }
    return TRUE;
}

static void cleanup_mounts(void) {
    unbind_mounts();
    run_cmd("umount /mnt/boot/efi 2>/dev/null; umount /mnt 2>/dev/null");
    if (app.swap_part[0]) {
        char cmd[96];
        snprintf(cmd, sizeof(cmd), "swapoff %s 2>/dev/null || true", app.swap_part);
        run_cmd(cmd);
    }
    run_cmd("vgchange -an borealvg 2>/dev/null || true");
    run_cmd("cryptsetup luksClose borealcrypt 2>/dev/null || true");
}

static gboolean show_finish_idle(gpointer data) {
    gtk_stack_set_visible_child_name(GTK_STACK(app.stack), "finish");
    gtk_widget_hide(app.btn_back);
    gtk_widget_hide(app.btn_next);
    gtk_widget_hide(app.btn_cancel);
    return FALSE;
}

typedef gboolean (*StepFn)(void);

static gboolean show_failed_idle(gpointer data) {
    (void)data;
    gtk_widget_show(app.btn_cancel);
    gtk_button_set_label(GTK_BUTTON(app.btn_cancel), "Quit");
    return FALSE;
}

static void *install_thread(void *arg) {
    (void)arg;
    struct { const char *name; StepFn fn; double frac; } steps[] = {
        {"Partitioning disk", partition_disk, 0.10},
        {"Mounting target", mount_target, 0.15},
        {"Copying system (can take a while)", rsync_system, 0.45},
        {"Installing display manager", install_bundled_packages, 0.55},
        {"Writing fstab", write_fstab, 0.58},
        {"Writing network config", write_network, 0.60},
        {"Configuring system", configure_system, 0.68},
        {"Setting passwords", set_passwords, 0.72},
        {"Removing live-boot", remove_live_boot, 0.85},
        {"Restoring inittab", restore_inittab, 0.87},
        {"Configuring desktop", setup_de, 0.90},
        {"Installing GRUB", install_grub, 0.97},
        {"Verifying", verify_install, 1.00},
    };
    bind_mounts();
    unbind_mounts();
    for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        set_progress(steps[i].frac - 0.02, steps[i].name);
        gboolean use_bind = (steps[i].fn == configure_system || steps[i].fn == set_passwords ||
                              steps[i].fn == remove_live_boot || steps[i].fn == setup_de ||
                              steps[i].fn == install_grub);
        if (use_bind) bind_mounts();
        gboolean ok = steps[i].fn();
        if (use_bind) unbind_mounts();
        if (!ok) { cleanup_mounts(); g_idle_add(show_failed_idle, NULL); return NULL; }
        set_progress(steps[i].frac, steps[i].name);
    }
    cleanup_mounts();
    log_line("Installation complete.");
    g_idle_add(show_finish_idle, NULL);
    return NULL;
}

static gboolean sync_selected_disk(void);

static void collect_state_from_ui(void) {
    sync_selected_disk();
    app.use_lvm = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.lvm_check));
    app.use_luks = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.luks_check));
    strncpy(app.luks_pass, gtk_entry_get_text(GTK_ENTRY(app.luks_pass_entry)), sizeof(app.luks_pass) - 1);
    app.advanced_part = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.part_advanced));
    app.efi_size_mib = atoi(gtk_entry_get_text(GTK_ENTRY(app.efi_size_entry)));
    app.swap_size_mib = atoi(gtk_entry_get_text(GTK_ENTRY(app.swap_size_entry)));
    strncpy(app.hostname, gtk_entry_get_text(GTK_ENTRY(app.hostname_entry)), sizeof(app.hostname) - 1);
    strncpy(app.root_pass, gtk_entry_get_text(GTK_ENTRY(app.pass1_entry)), sizeof(app.root_pass) - 1);
    strncpy(app.locale, gtk_entry_get_text(GTK_ENTRY(app.locale_entry)), sizeof(app.locale) - 1);

    if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.net_dhcp))) strcpy(app.net_type, "dhcp");
    else if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.net_wifi))) strcpy(app.net_type, "wifi");
    else if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.net_static))) strcpy(app.net_type, "static");
    else strcpy(app.net_type, "skip");

    gchar *ssid_active = gtk_combo_box_text_get_active_text(GTK_COMBO_BOX_TEXT(app.wifi_ssid_combo));
    if (ssid_active) { strncpy(app.wifi_ssid, ssid_active, sizeof(app.wifi_ssid) - 1); g_free(ssid_active); }
    strncpy(app.wifi_pass, gtk_entry_get_text(GTK_ENTRY(app.wifi_pass_entry)), sizeof(app.wifi_pass) - 1);

    GtkTreeIter iter;
    if (gtk_combo_box_get_active_iter(GTK_COMBO_BOX(app.net_if_combo), &iter)) {
        GtkTreeModel *model = gtk_combo_box_get_model(GTK_COMBO_BOX(app.net_if_combo));
        gchar *val;
        gtk_tree_model_get(model, &iter, 0, &val, -1);
        strncpy(app.net_if, val, sizeof(app.net_if) - 1);
        g_free(val);
    }
    strncpy(app.net_ip, gtk_entry_get_text(GTK_ENTRY(app.net_ip_entry)), sizeof(app.net_ip) - 1);
    strncpy(app.net_gw, gtk_entry_get_text(GTK_ENTRY(app.net_gw_entry)), sizeof(app.net_gw) - 1);
    strncpy(app.net_dns, gtk_entry_get_text(GTK_ENTRY(app.net_dns_entry)), sizeof(app.net_dns) - 1);
    if (!app.net_dns[0]) strncpy(app.net_dns, "1.1.1.1", sizeof(app.net_dns) - 1);
}

static void on_start_install(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    collect_state_from_ui();
    gtk_stack_set_visible_child_name(GTK_STACK(app.stack), "progress");
    gtk_widget_hide(app.btn_back);
    gtk_widget_hide(app.btn_next);
    pthread_t t;
    pthread_create(&t, NULL, install_thread, NULL);
    pthread_detach(t);
}

static const char *PAGE_ORDER[] = {
    "welcome", "disk", "partitioning", "user", "timezone", "extrausers", "network", "summary", "progress", "finish"
};
#define N_PAGES (sizeof(PAGE_ORDER) / sizeof(PAGE_ORDER[0]))

static int page_index(const char *name) {
    for (size_t i = 0; i < N_PAGES; i++) if (!strcmp(PAGE_ORDER[i], name)) return (int)i;
    return -1;
}

static void update_nav_buttons(void) {
    int idx = app.current_page;
    gtk_widget_set_sensitive(app.btn_back, idx > 0);
    if (idx == page_index("summary")) {
        gtk_button_set_label(GTK_BUTTON(app.btn_next), "Install");
    } else {
        gtk_button_set_label(GTK_BUTTON(app.btn_next), "Next");
    }
}

static void add_summary_row(GtkGrid *grid, int row, const char *key, const char *value) {
    GtkWidget *k = gtk_label_new(key);
    gtk_widget_set_halign(k, GTK_ALIGN_START);
    PangoAttrList *attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
    gtk_label_set_attributes(GTK_LABEL(k), attrs);
    pango_attr_list_unref(attrs);
    GtkWidget *v = gtk_label_new(value);
    gtk_widget_set_halign(v, GTK_ALIGN_START);
    gtk_grid_attach(grid, k, 0, row, 1, 1);
    gtk_grid_attach(grid, v, 1, row, 1, 1);
}

static void build_summary(void) {
    collect_state_from_ui();
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.summary_label));
    for (GList *l = children; l; l = l->next) gtk_widget_destroy(GTK_WIDGET(l->data));
    g_list_free(children);

    GtkGrid *grid = GTK_GRID(app.summary_label);
    char users[16];
    snprintf(users, sizeof(users), "%d", g_list_length(app.extra_users));
    add_summary_row(grid, 0, "Disk", app.disk);
    add_summary_row(grid, 1, "Hostname", app.hostname);
    add_summary_row(grid, 2, "Locale", app.locale);
    add_summary_row(grid, 3, "Timezone", app.timezone);
    add_summary_row(grid, 4, "Desktop", app.de_choice);
    add_summary_row(grid, 5, "Network", app.net_type);
    add_summary_row(grid, 6, "Extra users", users);
    add_summary_row(grid, 7, "LVM", app.use_lvm ? "yes" : "no");
    add_summary_row(grid, 8, "Encryption", app.use_luks ? "LUKS" : "none");
    gtk_widget_show_all(GTK_WIDGET(grid));
}

static gboolean validate_page(int idx) {
    const char *name = PAGE_ORDER[idx];
    if (!strcmp(name, "disk")) {
        sync_selected_disk();
        if (!app.disk[0]) {
            GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Select a target disk.");
            style_dialog(d);
            gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
            return FALSE;
        }
    } else if (!strcmp(name, "partitioning")) {
        if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.part_advanced))) {
            int efi_mib = atoi(gtk_entry_get_text(GTK_ENTRY(app.efi_size_entry)));
            int swap_mib = atoi(gtk_entry_get_text(GTK_ENTRY(app.swap_size_entry)));
            if (efi_mib < 100 || swap_mib < 0) {
                GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                    GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "EFI size must be at least 100 MiB, swap size must be 0 or more.");
                style_dialog(d);
                gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
                return FALSE;
            }
        }
        if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(app.luks_check))) {
            const char *p1 = gtk_entry_get_text(GTK_ENTRY(app.luks_pass_entry));
            const char *p2 = gtk_entry_get_text(GTK_ENTRY(app.luks_pass2_entry));
            if (!p1[0] || strcmp(p1, p2)) {
                GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                    GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Enter a matching encryption passphrase.");
                style_dialog(d);
                gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
                return FALSE;
            }
        }
    } else if (!strcmp(name, "user")) {
        const char *h = gtk_entry_get_text(GTK_ENTRY(app.hostname_entry));
        const char *p1 = gtk_entry_get_text(GTK_ENTRY(app.pass1_entry));
        const char *p2 = gtk_entry_get_text(GTK_ENTRY(app.pass2_entry));
        if (!h[0] || !p1[0] || strcmp(p1, p2)) {
            GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Enter a hostname and matching root passwords.");
            style_dialog(d);
            gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
            return FALSE;
        }
    } else if (!strcmp(name, "timezone")) {
        if (!app.timezone[0]) {
            GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Select a timezone.");
            style_dialog(d);
            gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
            return FALSE;
        }
    } else if (!strcmp(name, "network")) {
        collect_state_from_ui();
        if (!strcmp(app.net_type, "static") && (!app.net_if[0] || !app.net_ip[0] || !app.net_gw[0])) {
            GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Fill in interface, IP and gateway for static networking.");
            style_dialog(d);
            gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
            return FALSE;
        }
        if (!strcmp(app.net_type, "wifi") && (!app.wifi_ssid[0] || !app.wifi_pass[0])) {
            GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
                GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Select a Wi-Fi network and enter its password.");
            style_dialog(d);
            gtk_dialog_run(GTK_DIALOG(d)); gtk_widget_destroy(d);
            return FALSE;
        }
    }
    return TRUE;
}

static void goto_page(int idx) {
    app.current_page = idx;
    gtk_stack_set_visible_child_name(GTK_STACK(app.stack), PAGE_ORDER[idx]);
    if (!strcmp(PAGE_ORDER[idx], "summary")) build_summary();
    update_nav_buttons();
}

static void on_next(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    if (!validate_page(app.current_page)) return;
    if (!strcmp(PAGE_ORDER[app.current_page], "summary")) {
        GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
            GTK_MESSAGE_WARNING, GTK_BUTTONS_YES_NO,
            "All data on %s will be permanently erased. Continue?", app.disk);
        style_dialog(d);
        int r = gtk_dialog_run(GTK_DIALOG(d));
        gtk_widget_destroy(d);
        if (r != GTK_RESPONSE_YES) return;
        on_start_install(NULL, NULL);
        app.current_page = page_index("progress");
        return;
    }
    if (app.current_page < (int)N_PAGES - 1) goto_page(app.current_page + 1);
}

static void on_back(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    if (app.current_page > 0) goto_page(app.current_page - 1);
}

static gboolean on_delete_event(GtkWidget *widget, GdkEvent *event, gpointer data) {
    (void)widget; (void)event; (void)data;
    return TRUE;
}

static void on_cancel(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    gtk_main_quit();
}

static void on_reboot(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    system("reboot");
}

static void on_shell(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    system("xterm &");
}

static void refresh_disk_list(void) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.disk_list));
    for (GList *l = children; l; l = l->next) gtk_widget_destroy(GTK_WIDGET(l->data));
    g_list_free(children);

    char *out = run_capture("lsblk -dpno NAME,SIZE,MODEL | grep -v 'loop\\|sr0'");
    if (!out) return;
    GtkRadioButton *group = NULL;
    gchar **lines = g_strsplit(out, "\n", -1);
    for (int i = 0; lines[i]; i++) {
        if (!lines[i][0]) continue;
        char devname[64];
        sscanf(lines[i], "%63s", devname);
        GtkWidget *radio = gtk_radio_button_new_with_label_from_widget(group, lines[i]);
        group = GTK_RADIO_BUTTON(radio);
        g_object_set_data_full(G_OBJECT(radio), "devname", g_strdup(devname), g_free);
        gtk_box_pack_start(GTK_BOX(app.disk_list), radio, FALSE, FALSE, 2);
        gtk_widget_show(radio);
    }
    g_strfreev(lines);
    g_free(out);
}

static void on_disk_toggled(GtkToggleButton *btn, gpointer data) {
    (void)data;
    if (!gtk_toggle_button_get_active(btn)) return;
    const char *dev = g_object_get_data(G_OBJECT(btn), "devname");
    if (dev) strncpy(app.disk, dev, sizeof(app.disk) - 1);
}

static gboolean sync_selected_disk(void) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.disk_list));
    gboolean found = FALSE;
    for (GList *l = children; l; l = l->next) {
        if (GTK_IS_TOGGLE_BUTTON(l->data) && gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(l->data))) {
            const char *dev = g_object_get_data(G_OBJECT(l->data), "devname");
            if (dev) { strncpy(app.disk, dev, sizeof(app.disk) - 1); found = TRUE; }
            break;
        }
    }
    g_list_free(children);
    return found;
}

static void wire_disk_radios(void) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.disk_list));
    for (GList *l = children; l; l = l->next)
        g_signal_connect(l->data, "toggled", G_CALLBACK(on_disk_toggled), NULL);
    g_list_free(children);
}

static void refresh_iface_list(void) {
    GtkListStore *store = gtk_list_store_new(1, G_TYPE_STRING);
    char *out = run_capture("ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo'");
    if (out) {
        gchar **lines = g_strsplit(out, "\n", -1);
        for (int i = 0; lines[i]; i++) {
            if (!lines[i][0]) continue;
            GtkTreeIter it;
            gtk_list_store_append(store, &it);
            gtk_list_store_set(store, &it, 0, lines[i], -1);
        }
        g_strfreev(lines);
        g_free(out);
    }
    gtk_combo_box_set_model(GTK_COMBO_BOX(app.net_if_combo), GTK_TREE_MODEL(store));
    gtk_combo_box_set_active(GTK_COMBO_BOX(app.net_if_combo), 0);
    g_object_unref(store);
}

static void refresh_wifi_list(void) {
    gtk_combo_box_text_remove_all(GTK_COMBO_BOX_TEXT(app.wifi_ssid_combo));
    run_cmd("nmcli device wifi rescan 2>/dev/null");
    char *out = run_capture("nmcli -t -f SSID device wifi list 2>/dev/null | awk 'NF && !seen[$0]++'");
    if (!out) return;
    gchar **lines = g_strsplit(out, "\n", -1);
    for (int i = 0; lines[i]; i++) {
        if (!lines[i][0]) continue;
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(app.wifi_ssid_combo), lines[i]);
    }
    gtk_combo_box_set_active(GTK_COMBO_BOX(app.wifi_ssid_combo), 0);
    g_strfreev(lines);
    g_free(out);
}

static void on_wifi_scan(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    refresh_wifi_list();
}

static void on_net_wifi_toggled(GtkToggleButton *btn, gpointer data) {
    (void)data;
    gboolean active = gtk_toggle_button_get_active(btn);
    if (active) {
        gtk_widget_show_all(app.wifi_box);
        refresh_wifi_list();
    } else {
        gtk_widget_hide(app.wifi_box);
    }
}

static void on_net_static_toggled(GtkToggleButton *btn, gpointer data) {
    (void)data;
    if (gtk_toggle_button_get_active(btn)) {
        gtk_widget_show_all(app.net_static_box);
    } else {
        gtk_widget_hide(app.net_static_box);
    }
}

static void on_tz_row_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    if (!row) return;
    GtkWidget *lbl = gtk_bin_get_child(GTK_BIN(row));
    strncpy(app.timezone, gtk_label_get_text(GTK_LABEL(lbl)), sizeof(app.timezone) - 1);
}

static gboolean on_tz_button_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
    (void)data;
    if (event->type != GDK_BUTTON_PRESS || event->button != 1) return FALSE;
    GtkListBoxRow *clicked = gtk_list_box_get_row_at_y(GTK_LIST_BOX(widget), (int)event->y);
    GtkListBoxRow *selected = gtk_list_box_get_selected_row(GTK_LIST_BOX(widget));
    if (clicked && selected && clicked == selected) {
        on_next(NULL, NULL);
        return TRUE;
    }
    return FALSE;
}

static void refresh_tz_list(void) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.tz_list));
    for (GList *l = children; l; l = l->next) gtk_widget_destroy(GTK_WIDGET(l->data));
    g_list_free(children);

    const char *filter = gtk_entry_get_text(GTK_ENTRY(app.tz_filter_entry));
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "find /usr/share/zoneinfo -type f -o -type l 2>/dev/null | sed 's|/usr/share/zoneinfo/||' | "
        "grep -v '^posix\\|^right\\|\\.tab$\\|^leap\\|\\.list$\\|^tzdata\\|^iso3166' | sort | grep -i '%s' | head -80",
        filter);
    char *out = run_capture(cmd);
    if (!out) return;
    gchar **lines = g_strsplit(out, "\n", -1);
    for (int i = 0; lines[i]; i++) {
        if (!lines[i][0]) continue;
        GtkWidget *lbl = gtk_label_new(lines[i]);
        gtk_widget_set_halign(lbl, GTK_ALIGN_START);
        gtk_list_box_insert(GTK_LIST_BOX(app.tz_list), lbl, -1);
        gtk_widget_show(lbl);
    }
    g_strfreev(lines);
    g_free(out);
}

static void on_tz_filter_changed(GtkEditable *e, gpointer data) {
    (void)e; (void)data;
    refresh_tz_list();
}

static void refresh_user_list_display(void) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.user_list_box));
    for (GList *l = children; l; l = l->next) gtk_widget_destroy(GTK_WIDGET(l->data));
    g_list_free(children);

    for (GList *l = app.extra_users; l; l = l->next) {
        ExtraUser *u = l->data;
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        char buf[128];
        snprintf(buf, sizeof(buf), "%s%s", u->name, u->sudo ? "  (sudo)" : "");
        GtkWidget *lbl = gtk_label_new(buf);
        gtk_widget_set_halign(lbl, GTK_ALIGN_START);
        gtk_box_pack_start(GTK_BOX(row), lbl, TRUE, TRUE, 0);
        gtk_box_pack_start(GTK_BOX(app.user_list_box), row, FALSE, FALSE, 2);
        gtk_widget_show_all(row);
    }
}

static void on_add_user(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    GtkWidget *dlg = gtk_dialog_new_with_buttons("Add user", GTK_WINDOW(app.window),
        GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL, "_Add", GTK_RESPONSE_OK, NULL);
    style_dialog(dlg);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 8);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 12);

    GtkWidget *name_e = gtk_entry_new();
    gtk_widget_set_name(name_e, "dark-entry");
    GtkWidget *pass_e = gtk_entry_new();
    gtk_widget_set_name(pass_e, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(pass_e), FALSE);
    GtkWidget *pass2_e = gtk_entry_new();
    gtk_widget_set_name(pass2_e, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(pass2_e), FALSE);
    GtkWidget *sudo_c = gtk_check_button_new_with_label("Grant sudo");

    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Username"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), name_e, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Password"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), pass_e, 1, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Confirm password"), 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), pass2_e, 1, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), sudo_c, 1, 3, 1, 1);
    gtk_container_add(GTK_CONTAINER(content), grid);
    gtk_widget_show_all(dlg);

    gboolean added = FALSE;
    while (!added) {
        int resp = gtk_dialog_run(GTK_DIALOG(dlg));
        if (resp != GTK_RESPONSE_OK) break;
        const char *name = gtk_entry_get_text(GTK_ENTRY(name_e));
        const char *pass = gtk_entry_get_text(GTK_ENTRY(pass_e));
        const char *pass2 = gtk_entry_get_text(GTK_ENTRY(pass2_e));
        if (!name[0] || !pass[0] || strcmp(pass, pass2)) {
            GtkWidget *d = gtk_message_dialog_new(GTK_WINDOW(dlg), GTK_DIALOG_MODAL,
                GTK_MESSAGE_WARNING, GTK_BUTTONS_OK, "Enter a username and matching passwords.");
            style_dialog(d);
            gtk_dialog_run(GTK_DIALOG(d));
            gtk_widget_destroy(d);
            continue;
        }
        ExtraUser *u = g_new0(ExtraUser, 1);
        strncpy(u->name, name, sizeof(u->name) - 1);
        strncpy(u->pass, pass, sizeof(u->pass) - 1);
        u->sudo = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(sudo_c));
        app.extra_users = g_list_append(app.extra_users, u);
        refresh_user_list_display();
        added = TRUE;
    }
    gtk_widget_destroy(dlg);
}

static GtkWidget *page_welcome(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    GtkWidget *img;
    if (access("/usr/share/boreal-artwork/banner.png", F_OK) == 0) {
        GdkPixbuf *pix = gdk_pixbuf_new_from_file_at_scale("/usr/share/boreal-artwork/banner.png", 420, -1, TRUE, NULL);
        img = pix ? gtk_image_new_from_pixbuf(pix) : gtk_image_new_from_file("/usr/share/boreal-artwork/logo.png");
    } else {
        img = gtk_image_new_from_file("/usr/share/boreal-artwork/logo.png");
    }
    GtkWidget *sub = gtk_label_new("This will guide you through installing BorealOS to disk.");
    gtk_widget_set_margin_bottom(sub, 20);
    gtk_widget_set_margin_start(sub, 24);
    gtk_widget_set_margin_end(sub, 24);
    gtk_box_pack_start(GTK_BOX(box), img, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), sub, FALSE, FALSE, 0);
    return box;
}

static GtkWidget *page_disk(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Select target disk");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    GtkWidget *warn = gtk_label_new("All data on the selected disk will be erased.");
    gtk_widget_set_name(warn, "warn-label");
    gtk_widget_set_halign(warn, GTK_ALIGN_START);
    app.disk_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *refresh = gtk_button_new_with_label("Refresh");
    gtk_widget_set_name(refresh, "nav-button");
    g_signal_connect_swapped(refresh, "clicked", G_CALLBACK(refresh_disk_list), NULL);
    g_signal_connect_after(refresh, "clicked", G_CALLBACK(wire_disk_radios), NULL);
    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), warn, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.disk_list, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), refresh, FALSE, FALSE, 0);
    return box;
}

static void on_luks_toggled(GtkToggleButton *btn, gpointer data) {
    (void)data;
    if (gtk_toggle_button_get_active(btn)) {
        gtk_widget_show_all(app.luks_box);
    } else {
        gtk_widget_hide(app.luks_box);
    }
}

static void on_part_advanced_toggled(GtkToggleButton *btn, gpointer data) {
    (void)data;
    if (gtk_toggle_button_get_active(btn)) {
        gtk_widget_show_all(app.advanced_box);
    } else {
        gtk_widget_hide(app.advanced_box);
    }
}

static GtkWidget *page_partitioning(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Partitioning");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    GtkWidget *info = gtk_label_new("BIOS boot + EFI system partition + optional swap + root.");
    gtk_widget_set_halign(info, GTK_ALIGN_START);

    app.part_auto = gtk_radio_button_new_with_label(NULL, "Automatic");
    app.part_advanced = gtk_radio_button_new_with_label_from_widget(GTK_RADIO_BUTTON(app.part_auto), "Advanced");
    g_signal_connect(app.part_advanced, "toggled", G_CALLBACK(on_part_advanced_toggled), NULL);

    app.advanced_box = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(app.advanced_box), 6);
    gtk_grid_set_column_spacing(GTK_GRID(app.advanced_box), 12);
    app.efi_size_entry = gtk_entry_new();
    gtk_widget_set_name(app.efi_size_entry, "dark-entry");
    gtk_entry_set_text(GTK_ENTRY(app.efi_size_entry), "512");
    app.swap_size_entry = gtk_entry_new();
    gtk_widget_set_name(app.swap_size_entry, "dark-entry");
    gtk_entry_set_text(GTK_ENTRY(app.swap_size_entry), "0");
    gtk_entry_set_placeholder_text(GTK_ENTRY(app.swap_size_entry), "0 = no swap");
    gtk_grid_attach(GTK_GRID(app.advanced_box), gtk_label_new("EFI size (MiB)"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.advanced_box), app.efi_size_entry, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.advanced_box), gtk_label_new("Swap size (MiB)"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(app.advanced_box), app.swap_size_entry, 1, 1, 1, 1);
    gtk_widget_set_no_show_all(app.advanced_box, TRUE);
    gtk_widget_hide(app.advanced_box);

    GtkWidget *sep = gtk_label_new("Encryption & LVM");
    gtk_widget_set_name(sep, "title-label");
    gtk_widget_set_halign(sep, GTK_ALIGN_START);
    gtk_widget_set_margin_top(sep, 16);

    app.lvm_check = gtk_check_button_new_with_label("Use LVM");
    app.luks_check = gtk_check_button_new_with_label("Encrypt root with LUKS");
    g_signal_connect(app.luks_check, "toggled", G_CALLBACK(on_luks_toggled), NULL);

    app.luks_box = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(app.luks_box), 6);
    gtk_grid_set_column_spacing(GTK_GRID(app.luks_box), 12);
    app.luks_pass_entry = gtk_entry_new();
    gtk_widget_set_name(app.luks_pass_entry, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(app.luks_pass_entry), FALSE);
    app.luks_pass2_entry = gtk_entry_new();
    gtk_widget_set_name(app.luks_pass2_entry, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(app.luks_pass2_entry), FALSE);
    gtk_grid_attach(GTK_GRID(app.luks_box), gtk_label_new("Passphrase"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.luks_box), app.luks_pass_entry, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.luks_box), gtk_label_new("Confirm"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(app.luks_box), app.luks_pass2_entry, 1, 1, 1, 1);
    gtk_widget_set_no_show_all(app.luks_box, TRUE);
    gtk_widget_hide(app.luks_box);

    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), info, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.part_auto, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), app.part_advanced, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.advanced_box, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), sep, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.lvm_check, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), app.luks_check, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.luks_box, FALSE, FALSE, 8);
    return box;
}

static GtkWidget *page_user(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("System settings");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 8);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);

    app.hostname_entry = gtk_entry_new();
    gtk_widget_set_name(app.hostname_entry, "dark-entry");
    gtk_entry_set_text(GTK_ENTRY(app.hostname_entry), "borealOS");
    app.pass1_entry = gtk_entry_new();
    gtk_widget_set_name(app.pass1_entry, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(app.pass1_entry), FALSE);
    app.pass2_entry = gtk_entry_new();
    gtk_widget_set_name(app.pass2_entry, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(app.pass2_entry), FALSE);
    app.locale_entry = gtk_entry_new();
    gtk_widget_set_name(app.locale_entry, "dark-entry");
    gtk_entry_set_text(GTK_ENTRY(app.locale_entry), "en_US.UTF-8");

    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Hostname"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), app.hostname_entry, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Root password"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), app.pass1_entry, 1, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Confirm password"), 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), app.pass2_entry, 1, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Locale"), 0, 3, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), app.locale_entry, 1, 3, 1, 1);

    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), grid, FALSE, FALSE, 8);
    return box;
}

static GtkWidget *page_timezone(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Timezone");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    app.tz_filter_entry = gtk_entry_new();
    gtk_widget_set_name(app.tz_filter_entry, "dark-entry");
    gtk_entry_set_placeholder_text(GTK_ENTRY(app.tz_filter_entry), "Filter, e.g. Europe/Berlin");
    g_signal_connect(app.tz_filter_entry, "changed", G_CALLBACK(on_tz_filter_changed), NULL);

    GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_widget_set_size_request(scroll, 480, 380);
    app.tz_list = gtk_list_box_new();
    gtk_widget_set_name(app.tz_list, "dark-listbox");
    g_signal_connect(app.tz_list, "row-selected", G_CALLBACK(on_tz_row_selected), NULL);
    g_signal_connect(app.tz_list, "button-press-event", G_CALLBACK(on_tz_button_press), NULL);
    gtk_container_add(GTK_CONTAINER(scroll), app.tz_list);

    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.tz_filter_entry, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), scroll, TRUE, TRUE, 8);
    return box;
}

static GtkWidget *page_extrausers(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Extra user accounts");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    app.user_list_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *add = gtk_button_new_with_label("Add user");
    gtk_widget_set_name(add, "nav-button");
    g_signal_connect(add, "clicked", G_CALLBACK(on_add_user), NULL);
    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.user_list_box, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), add, FALSE, FALSE, 0);
    return box;
}

static GtkWidget *page_network(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Network");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);

    app.net_dhcp = gtk_radio_button_new_with_label(NULL, "DHCP (automatic)");
    app.net_wifi = gtk_radio_button_new_with_label_from_widget(GTK_RADIO_BUTTON(app.net_dhcp), "Wi-Fi");
    app.net_static = gtk_radio_button_new_with_label_from_widget(GTK_RADIO_BUTTON(app.net_dhcp), "Static IP");
    app.net_skip = gtk_radio_button_new_with_label_from_widget(GTK_RADIO_BUTTON(app.net_dhcp), "Skip");
    g_signal_connect(app.net_static, "toggled", G_CALLBACK(on_net_static_toggled), NULL);
    g_signal_connect(app.net_wifi, "toggled", G_CALLBACK(on_net_wifi_toggled), NULL);

    app.wifi_box = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(app.wifi_box), 6);
    gtk_grid_set_column_spacing(GTK_GRID(app.wifi_box), 12);
    app.wifi_ssid_combo = gtk_combo_box_text_new();
    app.wifi_pass_entry = gtk_entry_new();
    gtk_widget_set_name(app.wifi_pass_entry, "dark-entry");
    gtk_entry_set_visibility(GTK_ENTRY(app.wifi_pass_entry), FALSE);
    GtkWidget *wifi_refresh = gtk_button_new_with_label("Scan");
    gtk_widget_set_name(wifi_refresh, "nav-button");
    g_signal_connect(wifi_refresh, "clicked", G_CALLBACK(on_wifi_scan), NULL);
    gtk_grid_attach(GTK_GRID(app.wifi_box), gtk_label_new("Network"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.wifi_box), app.wifi_ssid_combo, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.wifi_box), wifi_refresh, 2, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.wifi_box), gtk_label_new("Password"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(app.wifi_box), app.wifi_pass_entry, 1, 1, 2, 1);
    gtk_widget_set_no_show_all(app.wifi_box, TRUE);

    app.net_static_box = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(app.net_static_box), 6);
    gtk_grid_set_column_spacing(GTK_GRID(app.net_static_box), 12);
    app.net_if_combo = gtk_combo_box_text_new();
    app.net_ip_entry = gtk_entry_new();
    gtk_widget_set_name(app.net_ip_entry, "dark-entry");
    gtk_entry_set_placeholder_text(GTK_ENTRY(app.net_ip_entry), "192.168.1.100/24");
    app.net_gw_entry = gtk_entry_new();
    gtk_widget_set_name(app.net_gw_entry, "dark-entry");
    app.net_dns_entry = gtk_entry_new();
    gtk_widget_set_name(app.net_dns_entry, "dark-entry");
    gtk_entry_set_placeholder_text(GTK_ENTRY(app.net_dns_entry), "1.1.1.1");

    gtk_grid_attach(GTK_GRID(app.net_static_box), gtk_label_new("Interface"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), app.net_if_combo, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), gtk_label_new("IP/prefix"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), app.net_ip_entry, 1, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), gtk_label_new("Gateway"), 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), app.net_gw_entry, 1, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), gtk_label_new("DNS"), 0, 3, 1, 1);
    gtk_grid_attach(GTK_GRID(app.net_static_box), app.net_dns_entry, 1, 3, 1, 1);
    gtk_widget_set_no_show_all(app.net_static_box, TRUE);

    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.net_dhcp, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.net_wifi, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.wifi_box, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), app.net_static, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.net_static_box, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(box), app.net_skip, FALSE, FALSE, 0);
    return box;
}

static GtkWidget *page_summary(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Summary");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    app.summary_label = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(app.summary_label), 6);
    gtk_grid_set_column_spacing(GTK_GRID(app.summary_label), 16);
    gtk_widget_set_halign(app.summary_label, GTK_ALIGN_START);
    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.summary_label, FALSE, FALSE, 8);
    return box;
}

static gboolean on_progress_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
    (void)data;
    int width = gtk_widget_get_allocated_width(widget);
    int height = gtk_widget_get_allocated_height(widget);
    double fraction = gtk_progress_bar_get_fraction(GTK_PROGRESS_BAR(widget));
    const char *text = gtk_label_get_text(GTK_LABEL(app.progress_label));
    if (!text || !text[0]) return FALSE;

    PangoLayout *layout = pango_cairo_create_layout(cr);
    pango_layout_set_text(layout, text, -1);
    PangoFontDescription *desc = pango_font_description_from_string("sans bold 11");
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    int th;
    pango_layout_get_pixel_size(layout, NULL, &th);
    double x = 12.0;
    double y = (height - th) / 2.0;
    int split = (int)(width * fraction);

    cairo_save(cr);
    cairo_rectangle(cr, 0, 0, split, height);
    cairo_clip(cr);
    cairo_set_source_rgb(cr, 0.05, 0.12, 0.17);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    cairo_restore(cr);

    cairo_save(cr);
    cairo_rectangle(cr, split, 0, width - split, height);
    cairo_clip(cr);
    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    cairo_restore(cr);

    g_object_unref(layout);
    return FALSE;
}

static GtkWidget *page_progress(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 24);
    GtkWidget *title = gtk_label_new("Installing BorealOS");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    app.progress_label = gtk_label_new("Starting...");
    gtk_widget_set_no_show_all(app.progress_label, TRUE);
    gtk_widget_hide(app.progress_label);
    app.progress_bar = gtk_progress_bar_new();
    gtk_widget_set_name(app.progress_bar, "boreal-progress");
    gtk_widget_set_size_request(app.progress_bar, -1, 28);
    g_signal_connect_after(app.progress_bar, "draw", G_CALLBACK(on_progress_draw), NULL);
    GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_widget_set_size_request(scroll, 760, 480);
    app.log_view = gtk_text_view_new();
    gtk_widget_set_name(app.log_view, "log-view");
    gtk_text_view_set_editable(GTK_TEXT_VIEW(app.log_view), FALSE);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(app.log_view), TRUE);
    app.log_buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(app.log_view));
    gtk_container_add(GTK_CONTAINER(scroll), app.log_view);

    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), app.progress_bar, FALSE, FALSE, 4);
    gtk_box_pack_start(GTK_BOX(box), scroll, TRUE, TRUE, 8);
    return box;
}

static GtkWidget *page_finish(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 20);
    gtk_container_set_border_width(GTK_CONTAINER(box), 32);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    GtkWidget *title = gtk_label_new("Installation complete");
    gtk_widget_set_name(title, "title-label");
    gtk_widget_set_halign(title, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_bottom(title, 12);
    GtkWidget *reboot = gtk_button_new_with_label("Reboot");
    gtk_widget_set_name(reboot, "primary-button");
    gtk_widget_set_size_request(reboot, 200, -1);
    g_signal_connect(reboot, "clicked", G_CALLBACK(on_reboot), NULL);
    GtkWidget *shell = gtk_button_new_with_label("Open shell");
    gtk_widget_set_name(shell, "nav-button");
    gtk_widget_set_size_request(shell, 200, -1);
    g_signal_connect(shell, "clicked", G_CALLBACK(on_shell), NULL);
    gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), reboot, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), shell, FALSE, FALSE, 0);
    app.finish_box = box;
    return box;
}

static GtkWidget *wrap_page(GtkWidget *content) {
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_valign(outer, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(outer, GTK_ALIGN_CENTER);
    GtkWidget *panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_name(panel, "content-panel");
    gtk_container_set_border_width(GTK_CONTAINER(panel), 8);
    gtk_box_pack_start(GTK_BOX(panel), content, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(outer), panel, TRUE, TRUE, 24);
    return outer;
}

static void on_css_parse_error(GtkCssProvider *p, GtkCssSection *section, GError *error, gpointer data) {
    (void)p; (void)data;
    guint line = gtk_css_section_get_end_line(section);
    fprintf(stderr, "CSS parse error at line %u: %s\n", line + 1, error->message);
}

static void load_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    g_signal_connect(provider, "parsing-error", G_CALLBACK(on_css_parse_error), NULL);
    GError *err = NULL;
    if (!gtk_css_provider_load_from_path(provider, "/usr/share/boreal-installer/style.css", &err)) {
        fprintf(stderr, "CSS load failed: %s\n", err ? err->message : "unknown");
        if (err) g_error_free(err);
    }
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
        GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

int main(int argc, char **argv) {
    g_set_prgname("boreal-installer");
    gtk_init(&argc, &argv);
    memset(&app, 0, sizeof(app));
    strcpy(app.net_type, "dhcp");

    if (geteuid() != 0) {
        GtkWidget *d = gtk_message_dialog_new(NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR,
            GTK_BUTTONS_OK, "The installer must run as root.");
        g_signal_connect(d, "realize", G_CALLBACK(on_dialog_realize), NULL);
        gtk_dialog_run(GTK_DIALOG(d));
        return 1;
    }
    check_assets();

    load_css();

    GList *icon_list = NULL;
    const int icon_sizes[] = {16, 24, 32, 48, 64, 128};
    for (size_t i = 0; i < sizeof(icon_sizes) / sizeof(icon_sizes[0]); i++) {
        GError *e = NULL;
        GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_scale("/usr/share/boreal-artwork/logo.png",
            icon_sizes[i], icon_sizes[i], TRUE, &e);
        if (pb) icon_list = g_list_append(icon_list, pb);
        else {
            fprintf(stderr, "icon load failed at size %d: %s\n", icon_sizes[i], e ? e->message : "unknown");
            if (e) g_error_free(e);
        }
    }
    if (icon_list) {
        gtk_window_set_default_icon_list(icon_list);
        g_list_free_full(icon_list, g_object_unref);
    } else {
        fprintf(stderr, "no icon could be loaded from /usr/share/boreal-artwork/logo.png\n");
    }

    app.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(app.window), "BorealOS Installer");

    int win_w = 760, win_h = 560;
    int screen_w = 0, screen_h = 0;
    GdkDisplay *display = gdk_display_get_default();
    if (display) {
        GdkMonitor *mon = gdk_display_get_monitor(display, 0);
        if (mon) {
            GdkRectangle geo;
            gdk_monitor_get_geometry(mon, &geo);
            screen_w = geo.width;
            screen_h = geo.height;
            win_w = (int)(geo.width * 0.75);
            win_h = (int)(geo.height * 0.80);
            if (win_w > 900) win_w = 900;
            if (win_h > 680) win_h = 680;
        }
    }
    gtk_window_set_default_size(GTK_WINDOW(app.window), win_w, win_h);
    gtk_window_set_position(GTK_WINDOW(app.window), GTK_WIN_POS_CENTER);
    gtk_window_set_icon_from_file(GTK_WINDOW(app.window), "/usr/share/boreal-artwork/logo.png", NULL);
    gtk_widget_set_name(app.window, "boreal-window");
    g_signal_connect(app.window, "delete-event", G_CALLBACK(on_delete_event), NULL);
    g_signal_connect(app.window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    GtkWidget *root_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    app.stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(app.stack), GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT);

    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_welcome()), "welcome");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_disk()), "disk");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_partitioning()), "partitioning");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_user()), "user");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_timezone()), "timezone");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_extrausers()), "extrausers");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_network()), "network");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_summary()), "summary");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_progress()), "progress");
    gtk_stack_add_named(GTK_STACK(app.stack), wrap_page(page_finish()), "finish");

    GtkWidget *nav = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(nav), 12);
    app.btn_cancel = gtk_button_new_with_label("Cancel");
    gtk_widget_set_name(app.btn_cancel, "nav-button");
    g_signal_connect(app.btn_cancel, "clicked", G_CALLBACK(on_cancel), NULL);
    app.btn_back = gtk_button_new_with_label("Back");
    gtk_widget_set_name(app.btn_back, "nav-button");
    g_signal_connect(app.btn_back, "clicked", G_CALLBACK(on_back), NULL);
    app.btn_next = gtk_button_new_with_label("Next");
    gtk_widget_set_name(app.btn_next, "primary-button");
    g_signal_connect(app.btn_next, "clicked", G_CALLBACK(on_next), NULL);

    gtk_box_pack_start(GTK_BOX(nav), app.btn_cancel, FALSE, FALSE, 0);
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_pack_start(GTK_BOX(nav), spacer, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(nav), app.btn_back, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(nav), app.btn_next, FALSE, FALSE, 0);

    gtk_box_pack_start(GTK_BOX(root_box), app.stack, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(root_box), nav, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(app.window), root_box);

    refresh_disk_list();
    wire_disk_radios();
    refresh_iface_list();
    refresh_tz_list();
    app.current_page = 0;
    update_nav_buttons();

    if (screen_w > 0 && screen_h > 0) {
        gtk_window_set_decorated(GTK_WINDOW(app.window), FALSE);
        gtk_window_set_default_size(GTK_WINDOW(app.window), screen_w, screen_h);
        gtk_window_move(GTK_WINDOW(app.window), 0, 0);
    }
    gtk_window_fullscreen(GTK_WINDOW(app.window));
    gtk_widget_show_all(app.window);
    if (screen_w > 0 && screen_h > 0) {
        gtk_window_resize(GTK_WINDOW(app.window), screen_w, screen_h);
        gtk_window_move(GTK_WINDOW(app.window), 0, 0);
    }
    gtk_widget_hide(app.net_static_box);
    gtk_widget_hide(app.wifi_box);
    refresh_wifi_list();

    GdkWindow *gdkwin = gtk_widget_get_window(app.window);
    if (gdkwin) {
        GdkCursor *cursor = gdk_cursor_new_from_name(gdk_display_get_default(), "default");
        if (cursor) gdk_window_set_cursor(gdkwin, cursor);
    }
    gtk_main();
    return 0;
}
