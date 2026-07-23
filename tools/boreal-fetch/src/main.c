#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <pthread.h>
#include <dirent.h>
#include <sys/utsname.h>

/* ── ANSI basics ─────────────────────────────────────────────────────────── */
#define RESET "\033[0m"
#define BOLD  "\033[1m"
#define DIM   "\033[2m"

/* ── palette ──────────────────────────────────────────────────────────────
 * Named so the same colour is never hand-typed as raw RGB in more than one
 * place. Macros expand to bare "r,g,b" so they drop straight into fb_fg(). */
#define COL_BORDER   10, 40, 30    /* rule under the scene           */
#define COL_LABEL    15, 80, 60    /* "CPU", "RAM", ... row labels   */
#define COL_SEP      30, 60, 45    /* " | " separators               */
#define COL_MODEL   140,200,170    /* CPU / GPU model strings        */
#define COL_PLAIN   100,180,200    /* uptime / kernel values         */
#define COL_NA       80, 80, 80    /* "N/A" placeholder              */
#define COL_OK       50,200,130    /* status: healthy                */
#define COL_WARN    220,180,50     /* status: elevated               */
#define COL_CRIT    220, 80,60     /* status: critical               */

/* ── frame timing / terminal geometry ────────────────────────────────────── */
#define FPS          60.0
#define STATS_HZ_MS  800   /* live-stats refresh interval, ms */
#define DETECT_TIMEOUT_S 4 /* max wait for one-shot detectors  */

static int TW = 80, TH = 24, prev_TW = 0, prev_TH = 0;
static volatile sig_atomic_t running = 1;

/* ── terminal control ─────────────────────────────────────────────────────── */
static void hide_cursor(void)  { fputs("\033[?25l", stdout); fflush(stdout); }
static void show_cursor(void)  { fputs("\033[?25h", stdout); fflush(stdout); }
static void clear_screen(void) { fputs("\033[2J\033[H", stdout); fflush(stdout); }

static void update_term_size(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0) {
        TW = ws.ws_col > 80 ? ws.ws_col : 80;
        TH = ws.ws_row > 24 ? ws.ws_row : 24;
    }
}
static void handle_sig(int s)   { (void)s; running = 0; }
static void handle_winch(int s) { (void)s; update_term_size(); }

/* ── small string / file helpers ─────────────────────────────────────────── */
static void strip_after(char *s, char c) {
    char *p = strchr(s, c);
    if (p) *p = '\0';
}

/* Reads one line (sans trailing newline) into buf. Returns its length, or 0
 * on failure — callers rely on buf being left untouched on failure so any
 * pre-set default (e.g. "Unknown") survives. */
static int read_first_line(const char *path, char *buf, int sz) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    if (!fgets(buf, sz, f)) { fclose(f); return 0; }
    fclose(f);
    int n = (int)strlen(buf);
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = '\0';
    return n;
}

static int run_cmd(const char *cmd, char *buf, int sz) {
    FILE *p = popen(cmd, "r");
    if (!p) { buf[0] = '\0'; return 0; }
    size_t n = fread(buf, 1, (size_t)sz - 1, p);
    pclose(p);
    buf[n] = '\0';
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' ')) buf[--n] = '\0';
    return (int)n;
}

/* ── static system info (detected once at startup) ───────────────────────── */
static char g_shell  [64] = "Unknown";
static char g_desktop[64] = "Unknown";
static char g_init   [64] = "Unknown";
static char g_cpu    [80] = "Unknown";
static char g_gpu    [80] = "Unknown";
static char g_kernel [32] = "Unknown";
static char g_pkgs  [512] = "";
static char g_arch[64] = "Unknown";
static char g_os[128] = "Unknown";

static void detect_shell(void) {
    const char *s = getenv("SHELL");
    if (s) {
        const char *b = strrchr(s, '/');
        strncpy(g_shell, b ? b + 1 : s, sizeof(g_shell) - 1);
        return;
    }
    pid_t pid = getppid();
    for (int i = 0; i < 6; i++) {
        char path[64], comm[32];
        snprintf(path, sizeof(path), "/proc/%d/comm", (int)pid);
        if (!read_first_line(path, comm, sizeof(comm))) break;

        static const char *shells[] = {
            "bash","zsh","fish","sh","dash","ksh","tcsh","csh","nu","elvish", NULL
        };
        for (int j = 0; shells[j]; j++)
            if (!strcmp(comm, shells[j])) { strncpy(g_shell, comm, sizeof(g_shell) - 1); return; }

        char stat[256];
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
        if (!read_first_line(path, stat, sizeof(stat))) break;
        char *p = strrchr(stat, ')');
        if (!p) break;
        int ppid = 0;
        sscanf(p + 2, "%*c %d", &ppid);
        if (ppid <= 1) break;
        pid = (pid_t)ppid;
    }
}

static void detect_desktop(void) {
    static const char *vars[] = {
        "XDG_CURRENT_DESKTOP", "DESKTOP_SESSION", "XDG_SESSION_DESKTOP", NULL
    };
    for (int i = 0; vars[i]; i++) {
        const char *v = getenv(vars[i]);
        if (v && v[0]) {
            strncpy(g_desktop, v, sizeof(g_desktop) - 1);
            strip_after(g_desktop, ':');
            return;
        }
    }
}

static void detect_init(void) {
    char comm[32];
    if (read_first_line("/proc/1/comm", comm, sizeof(comm))) {
        if (strstr(comm, "systemd")) { strcpy(g_init, "SystemD"); return; }
        else if (strstr(comm, "openrc"))  { strcpy(g_init, "OpenRC");  return; }
        else if (strstr(comm, "runit"))   { strcpy(g_init, "runit");   return; }
        else if (strstr(comm, "s6"))      { strcpy(g_init, "s6");      return; }
        else if (strstr(comm, "dinit"))   { strcpy(g_init, "dinit");   return; }
        else if (strstr(comm, "laked") || strstr(comm, "laked-run"))   { strcpy(g_init, "LakeD");   return; }
        else { strcpy(g_init, comm);   return; }
    }
}

static void detect_cpu(void) {
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "model name", 10)) continue;
        char *p = strchr(line, ':');
        if (!p) continue;
        p++;
        while (*p == ' ') p++;

        char *dst = g_cpu, *end = g_cpu + sizeof(g_cpu) - 1;
        for (; *p && *p != '\n' && dst < end; p++) {
            if (!strncmp(p, "(R)", 3))  { p += 2; continue; }
            if (!strncmp(p, "(TM)", 4)) { p += 3; continue; }
            if (!strncmp(p, "CPU ", 4)) { p += 3; continue; }
            *dst++ = *p;
        }
        *dst = '\0';
        while (dst > g_cpu && dst[-1] == ' ') *--dst = '\0';
        break;
    }
    fclose(f);
}

static void detect_gpu(void) {
    char buf[4096];
    if (!run_cmd("lspci 2>/dev/null", buf, sizeof(buf))) return;

    char *line = strtok(buf, "\n");
    while (line) {
        if (strstr(line, "VGA") || strstr(line, "3D") || strstr(line, "Display")) {
            char *p = strrchr(line, ':');
            if (!p) { line = strtok(NULL, "\n"); continue; }
            p++;
            while (*p == ' ') p++;

            static const char *noise[] = {
                "Advanced Micro Devices, Inc.", "[AMD/ATI]",
                "NVIDIA Corporation", "Intel Corporation", "Technologies Inc", NULL
            };
            char tmp[128];
            strncpy(tmp, p, sizeof(tmp) - 1);
            tmp[sizeof(tmp) - 1] = '\0';
            for (int i = 0; noise[i]; i++) {
                char *hit;
                size_t nlen = strlen(noise[i]);
                while ((hit = strstr(tmp, noise[i])))
                    memmove(hit, hit + nlen, strlen(hit + nlen) + 1);
            }
            char *r = strstr(tmp, " (rev "); if (r) *r = '\0';
            char *b = strstr(tmp, " [");     if (b) *b = '\0';

            char *t = tmp;
            while (*t == ' ') t++;
            char *e = t + strlen(t) - 1;
            while (e > t && *e == ' ') *e-- = '\0';

            strncpy(g_gpu, t, sizeof(g_gpu) - 1);
            return;
        }
        line = strtok(NULL, "\n");
    }
}

static void detect_kernel(void) {
    char buf[32];
    if (read_first_line("/proc/sys/kernel/osrelease", buf, sizeof(buf))) {
        strip_after(buf, '-');
        strip_after(buf, '+');
        strncpy(g_kernel, buf, sizeof(g_kernel) - 1);
    }
    /* on failure g_kernel keeps its "Unknown" default */
}

static void detect_packages(void) {
    static const struct { const char *cmd, *label; } mgrs[] = {
        {"dpkg --list 2>/dev/null | grep -c '^ii'",    "dpkg"},
        {"pacman -Qq 2>/dev/null | wc -l",             "pacman"},
        {"rpm -qa 2>/dev/null | wc -l",                "rpm"},
        {"snap list 2>/dev/null | tail -n +2 | wc -l", "snap"},
        {"flatpak list 2>/dev/null | wc -l",           "flatpak"},
        {"nix-env -q 2>/dev/null | wc -l",             "nix"},
        {"apk list --installed | wc -l",               "apk"},
        {NULL, NULL}
    };
    char parts[512] = "";
    int np = 0;
    for (int i = 0; mgrs[i].cmd; i++) {
        char buf[32];
        if (!run_cmd(mgrs[i].cmd, buf, sizeof(buf))) continue;
        int n = atoi(buf);
        if (n <= 0) continue;
        char tmp[64];
        snprintf(tmp, sizeof(tmp), np == 0 ? "%d (%s)" : " + %d (%s)", n, mgrs[i].label);
        strncat(parts, tmp, sizeof(parts) - strlen(parts) - 1);
        np++;
    }
    strncpy(g_pkgs, np ? parts : "Unknown", sizeof(g_pkgs) - 1);
}

static void detect_arch(void) {
    struct utsname buffer;
    if (uname(&buffer) == 0) {
        strncpy(g_arch, buffer.machine, sizeof(g_arch) - 1);
    } else {
        strncpy(g_arch, "unknown", sizeof(g_arch) - 1);
    }
}

static void detect_os(void) {
    char line[256];
    FILE *f = fopen("/etc/os-release", "r");
    if (!f) {
        strncpy(g_os, "Linux", sizeof(g_os) - 1);
        return;
    }

    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "PRETTY_NAME=", 12) == 0 || strncmp(line, "NAME=", 5) == 0) {
            char *p = strchr(line, '=');
            if (p) {
                p++;
                size_t len = strlen(p);
                if (len > 0 && p[len - 1] == '\n') p[--len] = '\0';
                if (len > 0 && p[len - 1] == '\"') p[--len] = '\0';
                if (*p == '\"') p++;

                strncpy(g_os, p, sizeof(g_os) - 1);
                fclose(f);
                return;
            }
        }
    }
    fclose(f);
    strncpy(g_os, "Generic Linux", sizeof(g_os) - 1);
}
/* Run all one-shot detectors in parallel, bounded by DETECT_TIMEOUT_S so a
 * hung external command (e.g. a stalled package manager) can't stall boot
 * forever. */
static void *thr_fn(void *fn) { ((void (*)(void))fn)(); return NULL; }
static void gather_static(void) {
    void (*fns[])(void) = {
        detect_os, detect_shell, detect_arch, detect_desktop, detect_init,
        detect_cpu, detect_gpu, detect_kernel, detect_packages, NULL
    };
    pthread_t t[16];
    int n = 0;
    for (; fns[n]; n++) pthread_create(&t[n], NULL, thr_fn, (void *)fns[n]);

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += DETECT_TIMEOUT_S;
    for (int i = 0; i < n; i++) pthread_timedjoin_np(t[i], NULL, &deadline);
}

/* ── live stats (refreshed by a background thread) ───────────────────────── */
static pthread_mutex_t stats_lock = PTHREAD_MUTEX_INITIALIZER;
static double g_cpu_pct = 0, g_gpu_pct = -1;
static long   g_ram_used = 0, g_ram_total = 0;
static int    g_cpu_temp = -1;
static char   g_uptime[32] = "";

static long long cpu_prev_total = 0, cpu_prev_idle = 0;
static void update_cpu_pct(void) {
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return;
    char line[256];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return; }
    fclose(f);

    long long u, n, s, id, iow, irq, soft, steal;
    if (sscanf(line, "cpu %lld %lld %lld %lld %lld %lld %lld %lld",
                &u, &n, &s, &id, &iow, &irq, &soft, &steal) < 4) return;

    long long idle = id + iow, total = u + n + s + id + iow + irq + soft + steal;
    long long dt = total - cpu_prev_total, di = idle - cpu_prev_idle;
    if (dt > 0) {
        double p = (1.0 - (double)di / dt) * 100.0;
        pthread_mutex_lock(&stats_lock);
        g_cpu_pct = p < 0 ? 0 : p > 100 ? 100 : p;
        pthread_mutex_unlock(&stats_lock);
    }
    cpu_prev_total = total;
    cpu_prev_idle = idle;
}

static void update_ram(void) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return;
    char line[128];
    long tot = 0, avail = 0;
    while (fgets(line, sizeof(line), f)) {
        long v;
        char key[32];
        if (sscanf(line, "%31s %ld", key, &v) != 2) continue;
        if (!strcmp(key, "MemTotal:"))     tot = v;
        if (!strcmp(key, "MemAvailable:")) avail = v;
    }
    fclose(f);
    pthread_mutex_lock(&stats_lock);
    g_ram_total = tot / 1024;
    g_ram_used  = (tot - avail) / 1024;
    pthread_mutex_unlock(&stats_lock);
}

static void update_cpu_temp(void) {
    static const char *paths[] = {
        "/sys/class/thermal/thermal_zone0/temp",
        "/sys/class/hwmon/hwmon0/temp1_input",
        "/sys/class/hwmon/hwmon1/temp1_input",
        NULL
    };
    char buf[32];
    for (int i = 0; paths[i]; i++) {
        if (!read_first_line(paths[i], buf, sizeof(buf))) continue;
        int raw = atoi(buf);
        if (raw > 1000) raw /= 1000;
        if (raw > 0 && raw < 200) {
            pthread_mutex_lock(&stats_lock);
            g_cpu_temp = raw;
            pthread_mutex_unlock(&stats_lock);
            return;
        }
    }
}

static void update_uptime(void) {
    FILE *f = fopen("/proc/uptime", "r");
    if (!f) return;
    long long s = 0;
    if (fscanf(f, "%lld", &s) != 1) s = 0;
    fclose(f);

    long d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
    char tmp[32];
    if (d > 0)      snprintf(tmp, sizeof(tmp), "%ldd %ldh %ldm", d, h, m);
    else if (h > 0) snprintf(tmp, sizeof(tmp), "%ldh %ldm", h, m);
    else            snprintf(tmp, sizeof(tmp), "%ldm", m);

    pthread_mutex_lock(&stats_lock);
    strncpy(g_uptime, tmp, sizeof(g_uptime) - 1);
    pthread_mutex_unlock(&stats_lock);
}

static char gpu_path[256] = "";
static void init_gpu_source(void) {
    if (!system("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits >/dev/null 2>&1")) {
        strcpy(gpu_path, "nvidia");
        return;
    }
    DIR *d = opendir("/sys/class/drm");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        char p[300];
        snprintf(p, sizeof(p), "/sys/class/drm/%s/device/gpu_busy_percent", e->d_name);
        if (!access(p, R_OK)) { strncpy(gpu_path, p, sizeof(gpu_path) - 1); break; }
    }
    closedir(d);
}

static void update_gpu_pct(void) {
    if (!gpu_path[0]) return;
    double v = -1;
    char buf[32];
    if (!strcmp(gpu_path, "nvidia")) {
        run_cmd("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null",
                buf, sizeof(buf));
        v = atof(buf);
    } else {
        read_first_line(gpu_path, buf, sizeof(buf));
        v = atof(buf);
    }
    if (v >= 0) {
        pthread_mutex_lock(&stats_lock);
        g_gpu_pct = v > 100 ? 100 : v;
        pthread_mutex_unlock(&stats_lock);
    }
}

static void *stats_thread(void *arg) {
    (void)arg;
    init_gpu_source();
    while (running) {
        update_cpu_pct();
        update_ram();
        update_gpu_pct();
        update_cpu_temp();
        update_uptime();
        struct timespec ts = {0, STATS_HZ_MS * 1000000L};
        nanosleep(&ts, NULL);
    }
    return NULL;
}

/* ── frame buffer ─────────────────────────────────────────────────────────── */
#define FBUF_SIZE (2 * 1024 * 1024)
static char fbuf[FBUF_SIZE];
static int  fbpos = 0;

static void fb_reset(void)        { fbpos = 0; }
static void fb_str(const char *s) { int n = (int)strlen(s); memcpy(fbuf + fbpos, s, n); fbpos += n; }
static void fb_char(char c)       { fbuf[fbpos++] = c; }
static void fb_flush(void)        { fwrite(fbuf, 1, fbpos, stdout); fflush(stdout); }
#define fb_printf(...) (fbpos += snprintf(fbuf + fbpos, FBUF_SIZE - fbpos, __VA_ARGS__))
static void fb_fg(int r, int g, int b) { fb_printf("\033[38;2;%d;%d;%dm", r, g, b); }
static void fb_R(void)          { fb_str(RESET); }
static void fb_pad(int n)       { while (n-- > 0) fb_char(' '); }

/* Visible width of a string: skips ANSI escapes and UTF-8 continuation
 * bytes, so multi-byte box-drawing glyphs still count as one column. */
static int visw(const char *s) {
    int n = 0, esc = 0;
    for (; *s; s++) {
        if (*s == '\033') { esc = 1; continue; }
        if (esc) { if (*s == 'm') esc = 0; continue; }
        if ((*s & 0xC0) == 0x80) continue;
        n++;
    }
    return n;
}

/* 0..1 sine wave, used everywhere something should gently pulse. */
static double wave01(double phase) { return sin(phase) * 0.5 + 0.5; }

/* ── scene: aurora + water + treeline ─────────────────────────────────────── */
#define SCENE_H 11
#define GROUND   9
#define MAX_W  512

typedef struct { char ch; unsigned char r, g, b; } Cell;
static Cell scene[SCENE_H][MAX_W];

typedef struct { int x, h; char sz; } Tree;
static const Tree TREES[] = {
    {4,8,'L'},{10,6,'S'},{16,9,'L'},{22,5,'S'},{29,7,'S'},{35,4,'S'},
    {43,8,'L'},{50,6,'S'},{57,9,'L'},{64,5,'S'},{72,7,'L'},{80,5,'S'},
    {88,8,'L'},{95,6,'S'},{103,9,'L'},{111,5,'S'},{119,7,'S'},{127,4,'S'},
    {135,8,'L'},{143,6,'S'},{151,9,'L'},{160,5,'S'},{168,7,'L'},{176,4,'S'},
};
#define NTREES ((int)(sizeof(TREES) / sizeof(TREES[0])))

static void build_scene(double t) {
    int W = TW < MAX_W ? TW : MAX_W;
    for (int row = 0; row < SCENE_H; row++) {
        if (row >= GROUND) {
            for (int c = 0; c < W; c++)
                scene[row][c] = row == GROUND ? (Cell){1, 6, 40, 24} : (Cell){' ', 3, 20, 12};
            continue;
        }

        /* aurora backdrop */
        for (int c = 0; c < W; c++) {
            double w1 = sin(c * .06 + t * .35) * .5 + sin(c * .025 + t * .18 + 1.8) * .5;
            double w2 = sin(c * .04 + t * .22 + 3.) * .5 + sin(c * .08 + t * .28 + .5) * .5;
            double ii = (w1 * .55 + w2 * .45) * .5 + .5;
            ii *= 1. - (double)row / GROUND * .5;
            scene[row][c] = (Cell){
                ' ',
                (unsigned char)(4 + ii * 16),
                (unsigned char)(60 + ii * 150),
                (unsigned char)(80 + ii * 140)
            };
        }

        /* two drifting "ripple" bands */
        double wr1 = 2 + sin(t * .25 + .5) * .8, wr2 = 5 + sin(t * .2 + 2.) * .8;
        for (int c = 0; c < W; c++) {
            double wo = sin(c * .08 + t * .4) * 1.2;
            if (fabs(row - wr1 - wo) < .9)         scene[row][c] = (Cell){'~', 20, 210, 170};
            else if (fabs(row - wr2 - wo * .8) < .7) scene[row][c] = (Cell){'~', 10, 160, 180};
        }

        /* sparse stars */
        for (int c = 0; c < W; c++) {
            int sid = (c * 7 + 13) % 17, sr = sid % (GROUND - 1);
            if (sr == row && (c * 11 + sid) % 9 == 0) {
                unsigned char bv = (unsigned char)(100 + fabs(sin(t * 1.3 + c * .6 + sid)) * 155);
                scene[row][c] = (Cell){'.', bv, (unsigned char)(bv + 20 < 255 ? bv + 20 : 255), bv};
            }
        }

        /* treeline silhouette */
        int rfg = GROUND - row;
        for (int ti = 0; ti < NTREES; ti++) {
            int cx = TREES[ti].x, th = TREES[ti].h;
            char sz = TREES[ti].sz;
            if (cx >= W || rfg < 1 || rfg > th) continue;
            if (rfg == 1) { if (cx < W) scene[row][cx] = (Cell){'|', 8, 55, 30}; continue; }

            int hw = (int)round((1. - (double)rfg / th) * th * (sz == 'L' ? .38 : .28));
            if (hw < 0) hw = 0;
            for (int dc = -hw; dc <= hw; dc++) {
                int c = cx + dc;
                if (c < 0 || c >= W) continue;
                if (dc == 0 && rfg == th)   scene[row][c] = (Cell){'^', 10, 75, 38};
                else if (abs(dc) == hw)     scene[row][c] = (Cell){dc < 0 ? '/' : '\\', 8, 58, 30};
                else                        scene[row][c] = (Cell){'#', 6, 48, 24};
            }
        }
    }
}

static void render_scene(void) {
    int W = TW < MAX_W ? TW : MAX_W;
    for (int row = 0; row < SCENE_H; row++) {
        int pr = -1, pg = -1, pb = -1;
        for (int c = 0; c < W; c++) {
            Cell *cl = &scene[row][c];
            if (cl->r != pr || cl->g != pg || cl->b != pb) {
                fb_fg(cl->r, cl->g, cl->b);
                pr = cl->r; pg = cl->g; pb = cl->b;
            }
            if (row == GROUND) fb_str("\xe2\x96\x84");
            else                fb_char(cl->ch);
        }
        fb_R();
        fb_str("\r\n");
    }
}

/* ── title & tagline ──────────────────────────────────────────────────────── */
static const char *TITLE[] = {
    "  ____                        _  ___  ____  ",
    " | __ )  ___  _ __ ___  __ _ | |/ _ \\/ ___| ",
    " |  _ \\ / _ \\| '__/ _ \\/ _` || | | | \\___ \\ ",
    " | |_) | (_) | | |  __/ (_| || | |_| |___) |",
    " |____/ \\___/|_|  \\___|\\__,_||_|\\___/|____/ ",
};
#define NTITLE ((int)(sizeof(TITLE) / sizeof(TITLE[0])))

static void render_title(double t) {
    for (int i = 0; i < NTITLE; i++) {
        const char *line = TITLE[i];
        for (int ci = 0; line[ci]; ci++) {
            if (line[ci] == ' ') { fb_char(' '); continue; }
            double w = wave01(ci * .12 + t * .8 + i * .6);
            fb_fg((int)(8 + w * 20), (int)(150 + w * 100), (int)(140 + w * 100));
            fb_str(BOLD);
            fb_char(line[ci]);
            fb_R();
        }
        fb_str("\r\n");
    }
}

static void render_tagline(double t) {
    static const char *words[] = {"Lightweight.", "Featured.", "Novel."};
    fb_str("  ");
    for (int i = 0; i < 3; i++) {
        double w = wave01(t * .5 + i * 1.4);
        fb_fg((int)(20 + w * 30), (int)(130 + w * 100), (int)(120 + w * 100));
        fb_str(DIM);
        fb_str(words[i]);
        fb_R();
        fb_str("   ");
    }
    fb_str("\r\n");
}

/* ── info panel ───────────────────────────────────────────────────────────── */
#define LEFT_W   52
#define LABEL_W   8
#define HW_BUF  512
#define MAX_HW   12

/* Shared colour rule for anything with a "healthy / elevated / critical"
 * reading — used for both percentages and temperatures. */
static void status_color(double value, double warn_at, double crit_at) {
    if (value > crit_at)      fb_fg(COL_CRIT);
    else if (value > warn_at) fb_fg(COL_WARN);
    else                      fb_fg(COL_OK);
}

/* "LABEL   | " with correct visible-width padding. */
static void hw_label(const char *label) {
    fb_fg(COL_LABEL);
    fb_str(label);
    fb_pad(LABEL_W - visw(label));
    fb_fg(COL_SEP);
    fb_str(" | ");
    fb_R();
}

/* Each hw_* writes exactly one row's worth of content (no trailing \r\n),
 * so callers can capture it into a buffer and lay it out later. */
static void hw_model(const char *label, const char *val) {
    hw_label(label);
    fb_fg(COL_MODEL);
    fb_str(val);
    fb_R();
}
static void hw_pct(const char *label, double pct) {
    hw_label(label);
    status_color(pct, 50, 80);
    fb_printf("%.1f%%", pct);
    fb_R();
}
static void hw_ram(long used, long total, double pct) {
    hw_label("RAM");
    status_color(pct, 50, 80);
    fb_printf("%ld/%ld MB", used, total);
    fb_R();
}
static void hw_temp(int temp) {
    char tmp[16];
    snprintf(tmp, sizeof(tmp), "%d\xc2\xb0""C", temp);
    hw_label("CPU \xc2\xb0""C");
    status_color(temp, 60, 80);
    fb_str(tmp);
    fb_R();
}
static void hw_plain(const char *label, const char *val) {
    hw_label(label);
    fb_fg(COL_PLAIN);
    fb_str(val);
    fb_R();
}
static void hw_na(const char *label) {
    hw_label(label);
    fb_fg(COL_NA);
    fb_str("N/A");
    fb_R();
}

/* Runs an hw_* call, captures its output (without disturbing fbpos) into
 * hw[nhw++], so rows can be composed independently of column layout. */
#define CAPTURE_HW_ROW(call) do {                        \
        int _s = fbpos;                                  \
        call;                                             \
        int _len = fbpos - _s;                           \
        if (_len >= HW_BUF) _len = HW_BUF - 1;            \
        memcpy(hw[nhw], fbuf + _s, _len);                 \
        hw[nhw][_len] = '\0';                             \
        fbpos = _s;                                       \
        nhw++;                                            \
    } while (0)

static void render_info_panel(double t) {
    /* snapshot live stats under the lock, then release it before formatting */
    pthread_mutex_lock(&stats_lock);
    double cpu_p = g_cpu_pct, gpu_p = g_gpu_pct;
    long   ru = g_ram_used, rt = g_ram_total;
    int    ctemp = g_cpu_temp;
    char   uptime[32];
    strncpy(uptime, g_uptime, sizeof(uptime) - 1);
    uptime[sizeof(uptime) - 1] = '\0';
    pthread_mutex_unlock(&stats_lock);
    double ram_p = rt > 0 ? (double)ru / rt * 100.0 : 0;

    /* animated section headers */
    int hg = (int)(120 + wave01(t * .4) * 80);
    char lhdr[128], rhdr[64];
    snprintf(lhdr, sizeof(lhdr), "  \033[38;2;20;%d;100m\033[1m[ Software ]\033[0m", hg);
    snprintf(rhdr, sizeof(rhdr),   "\033[38;2;20;%d;100m\033[1m[ Hardware ]\033[0m", hg);
    fb_str(lhdr);
    fb_pad(LEFT_W + 2 - visw(lhdr));
    fb_str("  ");
    fb_str(rhdr);
    fb_str("\r\n\r\n");

    /* software (left) rows */
    struct { const char *label, *value; } sw[] = {
        {"Base",     g_os},
        {"Init",     g_init},
        {"Arch",     g_arch},
        {"Shell",    g_shell},
        {"Desktop",  g_desktop},
        {"Packages", g_pkgs},
        {"Repo",     "github.com/DamianDaniel/borealOS"},
        {NULL, NULL}
    };
    int nsw = 0;
    for (; sw[nsw].label; nsw++) {}

    /* hardware (right) rows, each rendered independently and captured */
    char hw[MAX_HW][HW_BUF];
    int nhw = 0;

    CAPTURE_HW_ROW(hw_ram(ru, rt, ram_p));
    CAPTURE_HW_ROW(hw_model("CPU", g_cpu));
    CAPTURE_HW_ROW(hw_pct("CPU %", cpu_p));
    if (ctemp > 0) CAPTURE_HW_ROW(hw_temp(ctemp));
    CAPTURE_HW_ROW(hw_model("GPU", g_gpu));
    if (gpu_p >= 0) CAPTURE_HW_ROW(hw_pct("GPU %", gpu_p));
    else            CAPTURE_HW_ROW(hw_na("GPU %"));
    CAPTURE_HW_ROW(hw_plain("Uptime", uptime));
    CAPTURE_HW_ROW(hw_plain("Kernel", g_kernel));

    /* left column layout: "  " + label(10) + " | " + value */
    const int val_col   = 2 + 10 + 3;              /* column where value text starts */
    const int val_avail = LEFT_W + 2 - val_col;    /* usable width for the value      */
    /* width available for the right (hardware) column at the current terminal
     * width — hardware rows are padded out to this so a value that's shorter
     * than what occupied that row last frame can't leave stale text behind. */
    int hw_avail = TW - LEFT_W - 4;
    if (hw_avail < 0) hw_avail = 0;

    int nrows = nsw > nhw ? nsw : nhw;
    int hwi = 0;

    for (int i = 0; i < nrows; i++) {
        /* --- left column, first line --- */
        fb_str("  ");

        const char *val = NULL;
        int vlen = 0, pos = 0, vg = 160;

        if (i < nsw) {
            double wv = wave01(t * .35 + i);
            int lg = (int)(70 + wv * 70);
            vg = (int)(160 + wv * 70);

            char prefix[80];
            snprintf(prefix, sizeof(prefix),
                     "\033[38;2;15;%d;80m%-10s\033[38;2;30;60;45m | \033[0m", lg, sw[i].label);
            fb_str(prefix);

            val = sw[i].value;
            vlen = (int)strlen(val);

            int chunk = vlen;
            if (chunk > val_avail) {
                /* break at the last space/'+' within the first chunk, if any */
                int bp = val_avail;
                while (bp > 0 && val[bp] != ' ' && val[bp] != '+') bp--;
                chunk = bp > 0 ? bp : val_avail;
            }
            fb_fg(40, vg, 140);
            memcpy(fbuf + fbpos, val, chunk);
            fbpos += chunk;
            fb_R();
            fb_pad(val_avail - chunk);

            pos = chunk;
            while (pos < vlen && val[pos] == ' ') pos++;
        } else {
            fb_pad(LEFT_W); /* no software row left — keep the right column aligned */
        }

        /* --- right column: hardware row, always on this first line --- */
        fb_str("  ");
        int hw_w = 0;
        if (hwi < nhw) { fb_str(hw[hwi]); hw_w = visw(hw[hwi]); hwi++; }
        if (hw_w < hw_avail) fb_pad(hw_avail - hw_w);
        fb_str("\r\n");

        /* --- any remaining wrapped chunks of a long value: left column only --- */
        while (val && pos < vlen) {
            int chunk = val_avail;
            if (pos + chunk < vlen) {
                int bp = chunk;
                while (bp > 0 && val[pos + bp] != ' ' && val[pos + bp] != '+') bp--;
                if (bp > 0) chunk = bp;
            } else {
                chunk = vlen - pos;
            }

            fb_pad(val_col);
            fb_fg(40, vg, 140);
            memcpy(fbuf + fbpos, val + pos, chunk);
            fbpos += chunk;
            fb_R();
            /* pad the rest of the line (left overflow + right column) so
             * stale text from a previous, longer frame can't show through */
            fb_pad(val_avail - chunk + 2 + hw_avail);
            fb_str("\r\n");

            pos += chunk;
            while (pos < vlen && val[pos] == ' ') pos++;
        }
    }
}

/* ── timing ───────────────────────────────────────────────────────────────── */
static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
static void sleep_until(double target) {
    double rem = target - now_sec();
    if (rem <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)rem;
    ts.tv_nsec = (long)((rem - ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
}

/* Count how many lines the frame built so far occupies, so the remainder of
 * the terminal can be blanked without relying on a hardcoded line estimate
 * (which would drift whenever a software value wraps onto extra lines). */
static int lines_in_frame(void) {
    int lines = 0;
    for (int i = 0; i < fbpos; i++) if (fbuf[i] == '\n') lines++;
    return lines;
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(void) {
    signal(SIGINT,  handle_sig);
    signal(SIGTERM, handle_sig);
    signal(SIGWINCH, handle_winch);

    update_term_size();
    gather_static();

    pthread_t stid;
    pthread_create(&stid, NULL, stats_thread, NULL);

    hide_cursor();
    clear_screen();
    double start = now_sec();

    while (running) {
        double t0 = now_sec(), t = t0 - start;

        update_term_size();
        if (TW != prev_TW || TH != prev_TH) {
            clear_screen();
            prev_TW = TW;
            prev_TH = TH;
        }

        fb_reset();
        fb_str("\033[?25l\033[H");

        build_scene(t);
        render_scene();

        fb_fg(COL_BORDER);
        for (int i = 0; i < TW; i++) fb_str("\xe2\x94\x80");
        fb_R();
        fb_str("\r\n\r\n");

        render_title(t);
        render_tagline(t);
        fb_str("\r\n");
        render_info_panel(t);

        for (int i = lines_in_frame(); i < TH - 1; i++) {
            for (int j = 0; j < TW; j++) fb_char(' ');
            fb_str("\r\n");
        }

        fb_flush();
        sleep_until(t0 + 1.0 / FPS);
    }

    pthread_join(stid, NULL);
    show_cursor();
    clear_screen();
    puts(RESET "bye.");
    return 0;
}
