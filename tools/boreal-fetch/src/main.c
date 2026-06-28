/*  boreal-fetch  –  BorealOS system info fetcher
    Build:  cmake -B build && cmake --build build
    Run:    ./build/boreal-fetch
*/
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

#define RESET "\033[0m"
#define BOLD  "\033[1m"
#define DIM   "\033[2m"

static void hide_cursor(void) { fputs("\033[?25l", stdout); fflush(stdout); }
static void show_cursor(void) { fputs("\033[?25h", stdout); fflush(stdout); }
static void clear_screen(void){ fputs("\033[2J\033[H", stdout); fflush(stdout); }

static int TW = 80, TH = 24;
static int prev_TW = 0, prev_TH = 0;

static void update_term_size(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0) {
        TW = ws.ws_col > 80 ? ws.ws_col : 80;
        TH = ws.ws_row > 24 ? ws.ws_row : 24;
    }
}

static volatile int running = 1;
static void handle_sig(int s)    { (void)s; running = 0; }
static void handle_winch(int s)  { (void)s; update_term_size(); }

static int read_file(const char *path, char *buf, int sz) {
    FILE *f = fopen(path, "r");
    if (!f) { buf[0]='\0'; return 0; }
    int n = (int)fread(buf, 1, sz-1, f);
    fclose(f);
    if (n < 0) n = 0;
    buf[n] = '\0';
    while (n > 0 && (buf[n-1]=='\n'||buf[n-1]=='\r')) buf[--n]='\0';
    return n;
}

static int run_cmd(const char *cmd, char *buf, int sz) {
    FILE *p = popen(cmd, "r");
    if (!p) { buf[0]='\0'; return 0; }
    int n = (int)fread(buf, 1, sz-1, p);
    pclose(p);
    if (n < 0) n = 0;
    buf[n] = '\0';
    while (n > 0 && (buf[n-1]=='\n'||buf[n-1]=='\r')) buf[--n]='\0';
    return n;
}

static int file_exists(const char *path) { return access(path, F_OK) == 0; }

static char _shell  [64] = "Unknown";
static char _desktop[64] = "Unknown";
static char _init   [64] = "Unknown";
static char _cpu    [64] = "Unknown";
static char _gpu    [64] = "Unknown";
static char _kernel [64] = "Unknown";

static void detect_shell(void) {
    const char *s = getenv("SHELL");
    if (s) {
        const char *b = strrchr(s, '/');
        strncpy(_shell, b ? b+1 : s, sizeof(_shell)-1);
        return;
    }
    pid_t pid = getppid();
    for (int i = 0; i < 6; i++) {
        char path[64], comm[64];
        snprintf(path, sizeof(path), "/proc/%d/comm", (int)pid);
        if (!read_file(path, comm, sizeof(comm))) break;
        const char *shells[] = {"bash","zsh","fish","sh","dash","ksh",
                                 "tcsh","csh","nu","elvish",NULL};
        for (int j = 0; shells[j]; j++) {
            if (strcmp(comm, shells[j]) == 0) {
                strncpy(_shell, comm, sizeof(_shell)-1); return;
            }
        }
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
        char stat[256];
        if (!read_file(path, stat, sizeof(stat))) break;
        char *p = strrchr(stat, ')');
        if (!p) break;
        int ppid = 0;
        sscanf(p+2, "%*c %d", &ppid);
        if (ppid <= 1) break;
        pid = (pid_t)ppid;
    }
}

static void detect_desktop(void) {
    const char *vars[] = {"XDG_CURRENT_DESKTOP","DESKTOP_SESSION",
                          "XDG_SESSION_DESKTOP",NULL};
    for (int i = 0; vars[i]; i++) {
        const char *v = getenv(vars[i]);
        if (v && v[0]) {
            strncpy(_desktop, v, sizeof(_desktop)-1);
            char *c = strchr(_desktop, ':'); if (c) *c='\0';
            return;
        }
    }
    char buf[4096];
    run_cmd("ps -e -o comm= 2>/dev/null", buf, sizeof(buf));
    struct { const char *proc, *name; } wm[] = {
        {"plasmashell","KDE"},{"xfce4-session","XFCE"},
        {"niri","Niri"},{"taigawm","TaigaWM"},
        {"gnome-shell","GNOME"},{"sway","Sway"},
        {"i3","i3"},{"openbox","Openbox"},{NULL,NULL}
    };
    for (int i = 0; wm[i].proc; i++)
        if (strstr(buf, wm[i].proc)) {
            strncpy(_desktop, wm[i].name, sizeof(_desktop)-1); return;
        }
}

static void detect_init(void) {
    
    char comm[64];
    if (read_file("/proc/1/comm", comm, sizeof(comm))) {
        if (strstr(comm,"systemd")) { strcpy(_init,"systemd"); return; }
        if (strstr(comm,"openrc"))  { strcpy(_init,"OpenRC");  return; }
        if (strstr(comm,"runit"))   { strcpy(_init,"runit");   return; }
        if (strstr(comm,"s6"))      { strcpy(_init,"s6");      return; }
        if (strstr(comm,"dinit"))   { strcpy(_init,"dinit");   return; }
        if (strstr(comm,"sysvinit")){ strcpy(_init,"SysVinit");return; }
        if (strstr(comm,"init"))    {
            
        }
    }
    
    if (file_exists("/run/systemd/private"))       { strcpy(_init,"systemd");  return; }
    if (file_exists("/run/openrc"))                { strcpy(_init,"OpenRC");   return; }
    if (file_exists("/run/runit"))                 { strcpy(_init,"runit");    return; }
    if (file_exists("/run/s6"))                    { strcpy(_init,"s6");       return; }
    if (file_exists("/etc/dinit.d"))               { strcpy(_init,"dinit");    return; }
    if (file_exists("/sbin/openrc"))               { strcpy(_init,"OpenRC");   return; }
    
    if (system("systemctl is-system-running >/dev/null 2>&1")==0)
        { strcpy(_init,"systemd"); return; }
    if (system("rc-status >/dev/null 2>&1")==0)
        { strcpy(_init,"OpenRC"); return; }
    strcpy(_init,"Unknown");
}

static void detect_cpu(void) {
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "model name", 10) != 0) continue;
        char *p = strchr(line, ':'); if (!p) continue;
        p++; while (*p==' ') p++;
        char *dst = _cpu, *end = _cpu+sizeof(_cpu)-1;
        for (; *p && *p!='\n' && dst<end; p++) {
            if (strncmp(p,"(R)",3)==0){p+=2;continue;}
            if (strncmp(p,"(TM)",4)==0){p+=3;continue;}
            if (strncmp(p,"CPU ",4)==0){p+=3;continue;}
            *dst++=*p;
        }
        *dst='\0';
        while (dst>_cpu && dst[-1]==' ') *--dst='\0';
        break;
    }
    fclose(f);
}

static void detect_gpu(void) {
    char buf[4096];
    if (!run_cmd("lspci 2>/dev/null", buf, sizeof(buf))) return;
    char *line = strtok(buf, "\n");
    while (line) {
        if (strstr(line,"VGA")||strstr(line,"3D")||
            strstr(line,"Display")||strstr(line,"GPU")) {
            char *p = strrchr(line, ':');
            if (!p) { line=strtok(NULL,"\n"); continue; }
            p++; while (*p==' ') p++;
            const char *noise[] = {
                "Advanced Micro Devices, Inc.","[AMD/ATI]",
                "NVIDIA Corporation","Intel Corporation","Technologies Inc",NULL
            };
            char tmp[128]; strncpy(tmp, p, sizeof(tmp)-1); tmp[127]='\0';
            for (int i=0; noise[i]; i++) {
                char *found;
                while ((found=strstr(tmp,noise[i])))
                    memmove(found, found+strlen(noise[i]),
                            strlen(found+strlen(noise[i]))+1);
            }
            char *t=tmp; while(*t==' ')t++;
            char *e=t+strlen(t)-1; while(e>t&&*e==' ')*e--='\0';
            strncpy(_gpu, t, sizeof(_gpu)-1);
            return;
        }
        line = strtok(NULL, "\n");
    }
}

static void detect_kernel(void) {
    read_file("/proc/sys/kernel/osrelease", _kernel, sizeof(_kernel));
    char *d = strchr(_kernel, '-'); if (d) *d='\0';
}

static void *thr_shell  (void*a){(void)a;detect_shell();  return NULL;}
static void *thr_desktop(void*a){(void)a;detect_desktop();return NULL;}
static void *thr_init   (void*a){(void)a;detect_init();   return NULL;}
static void *thr_cpu    (void*a){(void)a;detect_cpu();    return NULL;}
static void *thr_gpu    (void*a){(void)a;detect_gpu();    return NULL;}
static void *thr_kernel (void*a){(void)a;detect_kernel(); return NULL;}

static void gather_static(void) {
    pthread_t t[6];
    pthread_create(&t[0],NULL,thr_shell,  NULL);
    pthread_create(&t[1],NULL,thr_desktop,NULL);
    pthread_create(&t[2],NULL,thr_init,   NULL);
    pthread_create(&t[3],NULL,thr_cpu,    NULL);
    pthread_create(&t[4],NULL,thr_gpu,    NULL);
    pthread_create(&t[5],NULL,thr_kernel, NULL);
    struct timespec dl; clock_gettime(CLOCK_REALTIME,&dl); dl.tv_sec+=2;
    for (int i=0;i<6;i++) pthread_timedjoin_np(t[i],NULL,&dl);
}

static pthread_mutex_t stats_lock = PTHREAD_MUTEX_INITIALIZER;
static double cpu_pct=0, gpu_pct=-1;
static long   ram_used=0, ram_total=0;

static long long _cpu_ptotal=0, _cpu_pidle=0;

static void update_cpu(void) {
    char line[256]; FILE *f=fopen("/proc/stat","r");
    if(!f) return; fgets(line,sizeof(line),f); fclose(f);
    long long u,n,s,id,iow,irq,soft,steal;
    sscanf(line,"cpu %lld %lld %lld %lld %lld %lld %lld %lld",
           &u,&n,&s,&id,&iow,&irq,&soft,&steal);
    long long idle=id+iow, total=u+n+s+id+iow+irq+soft+steal;
    long long dt=total-_cpu_ptotal, di=idle-_cpu_pidle;
    if(dt>0){
        double p=(1.0-(double)di/dt)*100.0;
        pthread_mutex_lock(&stats_lock);
        cpu_pct=p<0?0:p>100?100:p;
        pthread_mutex_unlock(&stats_lock);
    }
    _cpu_ptotal=total; _cpu_pidle=idle;
}

static void update_ram(void) {
    FILE *f=fopen("/proc/meminfo","r"); if(!f) return;
    char line[128]; long tot=0,avail=0;
    while(fgets(line,sizeof(line),f)){
        long v; char key[32];
        if(sscanf(line,"%31s %ld",key,&v)!=2) continue;
        if(strcmp(key,"MemTotal:")==0)     tot=v;
        if(strcmp(key,"MemAvailable:")==0) avail=v;
    }
    fclose(f);
    pthread_mutex_lock(&stats_lock);
    ram_total=tot/1024; ram_used=(tot-avail)/1024;
    pthread_mutex_unlock(&stats_lock);
}

static char _gpu_path[256]="";
static void init_gpu_source(void) {
    if(system("nvidia-smi --query-gpu=utilization.gpu "
              "--format=csv,noheader,nounits >/dev/null 2>&1")==0){
        strcpy(_gpu_path,"nvidia"); return;
    }
    DIR *d=opendir("/sys/class/drm"); if(!d) return;
    struct dirent *e;
    while((e=readdir(d))){
        char p[300];
        snprintf(p,sizeof(p),"/sys/class/drm/%s/device/gpu_busy_percent",e->d_name);
        if(access(p,R_OK)==0){ strncpy(_gpu_path,p,sizeof(_gpu_path)-1); break; }
    }
    closedir(d);
}

static void update_gpu(void) {
    if(!_gpu_path[0]) return;
    double v=-1;
    if(strcmp(_gpu_path,"nvidia")==0){
        char buf[32];
        run_cmd("nvidia-smi --query-gpu=utilization.gpu "
                "--format=csv,noheader,nounits 2>/dev/null",buf,sizeof(buf));
        v=atof(buf);
    } else {
        char buf[32]; read_file(_gpu_path,buf,sizeof(buf)); v=atof(buf);
    }
    if(v>=0){ pthread_mutex_lock(&stats_lock); gpu_pct=v>100?100:v; pthread_mutex_unlock(&stats_lock); }
}

static void *stats_thread(void *a){
    (void)a; init_gpu_source();
    while(running){
        update_cpu(); update_ram(); update_gpu();
        struct timespec ts={0,800000000L}; nanosleep(&ts,NULL);
    }
    return NULL;
}

#define FBUF_SIZE (2*1024*1024)
static char fbuf[FBUF_SIZE];
static int  fbpos=0;

static void fb_reset(void)        { fbpos=0; }
static void fb_str(const char *s) { int n=strlen(s); memcpy(fbuf+fbpos,s,n); fbpos+=n; }
static void fb_char(char c)       { fbuf[fbpos++]=c; }
static void fb_flush(void)        { fwrite(fbuf,1,fbpos,stdout); fflush(stdout); }
#define fb_printf(...) (fbpos+=snprintf(fbuf+fbpos,FBUF_SIZE-fbpos,__VA_ARGS__))

static void fb_fg(int r,int g,int b){ fb_printf("\033[38;2;%d;%d;%dm",r,g,b); }
static void fb_R(void)              { fb_str(RESET); }

static int visw(const char *s){
    int n=0,esc=0;
    for(;*s;s++){
        if(*s=='\033'){esc=1;continue;}
        if(esc){if(*s=='m')esc=0;continue;}
        
        if((*s&0xC0)==0x80) continue;
        n++;
    }
    return n;
}

static void fb_pad(int n){ for(int i=0;i<n;i++) fb_char(' '); }

#define SCENE_H    11
#define GROUND_ROW  9
#define MAX_COLS   512

typedef struct { char ch; unsigned char r,g,b; } Cell;
static Cell scene[SCENE_H][MAX_COLS];

typedef struct { int x,h; char sz; } Tree;
static const Tree TREES[]={
    {4,8,'L'},{10,6,'S'},{16,9,'L'},{22,5,'S'},{29,7,'S'},{35,4,'S'},
    {43,8,'L'},{50,6,'S'},{57,9,'L'},{64,5,'S'},{72,7,'L'},{80,5,'S'},
    {88,8,'L'},{95,6,'S'},{103,9,'L'},{111,5,'S'},{119,7,'S'},{127,4,'S'},
    {135,8,'L'},{143,6,'S'},{151,9,'L'},{160,5,'S'},{168,7,'L'},{176,4,'S'},
};
#define NTREES (int)(sizeof(TREES)/sizeof(TREES[0]))

static void build_scene(double t){
    int W=TW<MAX_COLS?TW:MAX_COLS;
    for(int row=0;row<SCENE_H;row++){
        if(row>=GROUND_ROW){
            for(int c=0;c<W;c++){
                if(row==GROUND_ROW) scene[row][c]=(Cell){1,6,40,24};
                else                scene[row][c]=(Cell){' ',3,20,12};
            }
            continue;
        }
        for(int c=0;c<W;c++){
            double w1=sin(c*.06+t*.35)*.5+sin(c*.025+t*.18+1.8)*.5;
            double w2=sin(c*.04+t*.22+3.)*.5+sin(c*.08+t*.28+.5)*.5;
            double i=(w1*.55+w2*.45)*.5+.5; i*=1.-(double)row/GROUND_ROW*.5;
            scene[row][c]=(Cell){' ',(unsigned char)(4+i*16),
                                     (unsigned char)(60+i*150),
                                     (unsigned char)(80+i*140)};
        }
        double wr1=2+sin(t*.25+.5)*.8, wr2=5+sin(t*.2+2.)*.8;
        for(int c=0;c<W;c++){
            double woff=sin(c*.08+t*.4)*1.2;
            if(fabs(row-wr1-woff)<.9)       scene[row][c]=(Cell){'~',20,210,170};
            else if(fabs(row-wr2-woff*.8)<.7)scene[row][c]=(Cell){'~',10,160,180};
        }
        for(int c=0;c<W;c++){
            int sid=(c*7+13)%17, sr=sid%(GROUND_ROW-1);
            if(sr==row&&(c*11+sid)%9==0){
                unsigned char bv=(unsigned char)(100+fabs(sin(t*1.3+c*.6+sid))*155);
                unsigned char bg=bv+20<255?bv+20:255;
                scene[row][c]=(Cell){'.',bv,bg,bv};
            }
        }
        int rfg=GROUND_ROW-row;
        for(int ti=0;ti<NTREES;ti++){
            int cx=TREES[ti].x, th=TREES[ti].h; char sz=TREES[ti].sz;
            if(cx>=W||rfg<1||rfg>th) continue;
            if(rfg==1){ if(cx<W) scene[row][cx]=(Cell){'|',8,55,30}; continue; }
            int hw=(int)round((1.-(double)rfg/th)*th*(sz=='L'?.38:.28));
            if(hw<0)hw=0;
            for(int dc=-hw;dc<=hw;dc++){
                int c=cx+dc; if(c<0||c>=W) continue;
                if(dc==0&&rfg==th)    scene[row][c]=(Cell){'^',10,75,38};
                else if(abs(dc)==hw)  scene[row][c]=(Cell){dc<0?'/':'\\',8,58,30};
                else                  scene[row][c]=(Cell){'#',6,48,24};
            }
        }
    }
}

static void render_scene(void){
    int W=TW<MAX_COLS?TW:MAX_COLS;
    for(int row=0;row<SCENE_H;row++){
        int pr=-1,pg=-1,pb=-1;
        for(int c=0;c<W;c++){
            Cell *cl=&scene[row][c];
            if(cl->r!=pr||cl->g!=pg||cl->b!=pb){
                fb_fg(cl->r,cl->g,cl->b); pr=cl->r;pg=cl->g;pb=cl->b;
            }
            if(row==GROUND_ROW) fb_str("\xe2\x96\x84"); 
            else                fb_char(cl->ch);
        }
        fb_R(); fb_str("\r\n");
    }
}

static const char *TITLE[]={
    "  ____                        _  ___  ____  ",
    " | __ )  ___  _ __ ___  __ _ | |/ _ \\/ ___| ",
    " |  _ \\ / _ \\| '__/ _ \\/ _` || | | | \\___ \\ ",
    " | |_) | (_) | | |  __/ (_| || | |_| |___) |",
    " |____/ \\___/|_|  \\___|\\__,_||_|\\___/|____/ ",
};
#define NTITLE 5

static void render_title(double t){
    for(int i=0;i<NTITLE;i++){
        const char *line=TITLE[i];
        for(int ci=0;line[ci];ci++){
            char ch=line[ci];
            if(ch==' '){fb_char(' ');continue;}
            double wave=sin(ci*.12+t*.8+i*.6)*.5+.5;
            fb_fg((int)(8+wave*20),(int)(150+wave*100),(int)(140+wave*100));
            fb_str(BOLD); fb_char(ch); fb_R();
        }
        fb_str("\r\n");
    }
}

static void render_tagline(double t){
    const char *words[]={"Lightweight.","Featured.","Novel."};
    fb_str("  ");
    for(int i=0;i<3;i++){
        double wave=sin(t*.5+i*1.4)*.5+.5;
        fb_fg((int)(20+wave*30),(int)(130+wave*100),(int)(120+wave*100));
        fb_str(DIM); fb_str(words[i]); fb_R(); fb_str("   ");
    }
    fb_str("\r\n");
}

#define LEFT_W   52   
#define BAR_W    12   
#define LABEL_W   8   

static void fb_bar(double pct){
    int filled=(int)round(pct/100.0*BAR_W);
    for(int i=0;i<BAR_W;i++)
        fb_str(i<filled?"\xe2\x96\x88":"\xe2\x96\x91");
}

static void fb_valcol(double pct){
    if(pct>80)      fb_fg(220,80,60);
    else if(pct>50) fb_fg(220,180,50);
    else            fb_fg(50,200,130);
}

/*
 * Right column row layout (all values start at same column):
 *   LABEL___  |  VALUE   BAR
 *   ←LABEL_W→ | ← value starts here
 *
 * For percentage rows the value is "XX.X%  ███░░░░░░░░░"
 * For model rows  the value is just the model string
 * For kernel/ram  the value is formatted string
 *
 * To align the bars, we measure the widest percentage string
 * at render time and pad shorter ones. Since we use "%.1f%%"
 * the max is "100.0%" (6 chars) — we always pad to 6.
 */
static void fb_hw_label(const char *label){
    fb_fg(15,80,60);
    fb_printf("%-*s", LABEL_W, label);
    fb_fg(30,60,45); fb_str(" | "); fb_R();
}

/* All right-column rows:
 *   LABEL_W(8) + " | "(3) + VALUE_W(20) + "  " + BAR_W(12)
 *   Value field is always 20 visible chars wide — truncated or padded.
 *   This guarantees every bar starts at the exact same column.
 */
#define VALUE_W 20

static void fb_hw_row(const char *label, const char *value,
                      int has_bar, double pct)
{
    fb_hw_label(label);
    
    int vw = visw(value);
    if(vw > VALUE_W){
        
        int vis=0; const char *p=value; int esc=0;
        while(*p && vis<VALUE_W){
            if(*p=='\033'){esc=1;fb_char(*p++);continue;}
            if(esc){fb_char(*p); if(*p=='m')esc=0; p++;continue;}
            if((*p&0xC0)==0x80){fb_char(*p++);continue;} 
            fb_char(*p++); vis++;
        }
        fb_R();
        fb_pad(0);
    } else {
        fb_str(value); fb_R();
        fb_pad(VALUE_W - vw);
    }
    fb_str("  ");
    if(has_bar){ fb_valcol(pct); fb_bar(pct); fb_R(); }
}

static void fb_hw_model(const char *label, const char *value){
    fb_hw_row(label, value, 0, 0);
}

static void fb_hw_pct(const char *label, double pct){
    char tmp[16]; snprintf(tmp,sizeof(tmp),"%.1f%%",pct);
    
    char vbuf[64]; int n=0;
    if(pct>80)      n+=snprintf(vbuf+n,sizeof(vbuf)-n,"\033[38;2;220;80;60m");
    else if(pct>50) n+=snprintf(vbuf+n,sizeof(vbuf)-n,"\033[38;2;220;180;50m");
    else            n+=snprintf(vbuf+n,sizeof(vbuf)-n,"\033[38;2;50;200;130m");
    snprintf(vbuf+n,sizeof(vbuf)-n,"%s\033[0m",tmp);
    fb_hw_row(label, vbuf, 1, pct);
}

static void fb_hw_ram(const char *label, long used, long total, double pct){
    char tmp[32]; snprintf(tmp,sizeof(tmp),"%ld/%ld MB",used,total);
    char vbuf[64]; int n=0;
    if(pct>80)      n+=snprintf(vbuf+n,sizeof(vbuf)-n,"\033[38;2;220;80;60m");
    else if(pct>50) n+=snprintf(vbuf+n,sizeof(vbuf)-n,"\033[38;2;220;180;50m");
    else            n+=snprintf(vbuf+n,sizeof(vbuf)-n,"\033[38;2;50;200;130m");
    snprintf(vbuf+n,sizeof(vbuf)-n,"%s\033[0m",tmp);
    fb_hw_row(label, vbuf, 1, pct);
}

static void render_info_panel(double t){
    pthread_mutex_lock(&stats_lock);
    double cpu_p=cpu_pct, gpu_p=gpu_pct;
    long   ru=ram_used,   rt=ram_total;
    pthread_mutex_unlock(&stats_lock);
    double ram_p=rt>0?(double)ru/rt*100.0:0;

    double wave=sin(t*.4)*.5+.5;
    int hg=(int)(120+wave*80);

    
    char lhdr[128], rhdr[64];
    snprintf(lhdr,sizeof(lhdr),"  \033[38;2;20;%d;100m\033[1m[ Software ]\033[0m",hg);
    snprintf(rhdr,sizeof(rhdr),   "\033[38;2;20;%d;100m\033[1m[ Hardware ]\033[0m",hg);
    int lhv=visw(lhdr);
    fb_str(lhdr); fb_pad(LEFT_W+2-lhv); fb_str("  "); fb_str(rhdr); fb_str("\r\n");
    fb_str("\r\n"); 

    
    struct { const char *label, *value; } drows[]={
        {"Base",    "Debian stable"},
        {"Init",    _init},
        {"Arch",    "x86_64"},
        {"Shell",   _shell},
        {"Desktop", _desktop},
        {"Repo",    "github.com/DamianDaniel/borealOS"},
        {NULL,NULL}
    };
    int nd=0; for(;drows[nd].label;nd++);

    
#define MAX_HW 8
    char hw[MAX_HW][512]; int nhw=0;

    
#define CAPTURE(code) do{ \
    int _s=fbpos; code; \
    int _len=fbpos-_s; \
    if(_len<511){memcpy(hw[nhw],fbuf+_s,_len);hw[nhw][_len]='\0';} \
    else{hw[nhw][0]='\0';} \
    fbpos=_s; nhw++; \
}while(0)

    CAPTURE(fb_hw_ram("RAM",ru,rt,ram_p));
    CAPTURE(fb_hw_model("CPU",_cpu));
    CAPTURE(fb_hw_pct("CPU %",cpu_p));
    CAPTURE(fb_hw_model("GPU",_gpu));
    if(gpu_p>=0){ CAPTURE(fb_hw_pct("GPU %",gpu_p)); }
    else {
        CAPTURE({
            fb_hw_label("GPU %");
            fb_fg(80,80,80); fb_str("N/A"); fb_R();
        });
    }
    CAPTURE({
        fb_hw_label("Kernel");
        fb_fg(100,180,200); fb_str(_kernel); fb_R();
    });

    
    int nrows=nd>nhw?nd:nhw;
    for(int i=0;i<nrows;i++){
        
        fb_str("  ");
        if(i<nd){
            double wv=sin(t*.35+i*1.0)*.5+.5;
            int lg=(int)(70+wv*70), vg=(int)(160+wv*70);
            char lbuf[256];
            int llen=snprintf(lbuf,sizeof(lbuf),
                "\033[38;2;15;%d;80m%-10s\033[38;2;30;60;45m | \033[38;2;40;%d;140m%s\033[0m",
                lg, drows[i].label, vg, drows[i].value);
            (void)llen;
            int lv=visw(lbuf);
            fb_str(lbuf);
            fb_pad(LEFT_W-lv);
        } else {
            fb_pad(LEFT_W);
        }
        fb_str("  ");
        
        if(i<nhw) fb_str(hw[i]);
        fb_str("\r\n");
    }
}

static double now_sec(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return ts.tv_sec+ts.tv_nsec*1e-9;
}
static void sleep_until(double target){
    double rem=target-now_sec(); if(rem<=0) return;
    struct timespec ts;
    ts.tv_sec=(time_t)rem;
    ts.tv_nsec=(long)((rem-(double)ts.tv_sec)*1e9);
    nanosleep(&ts,NULL);
}

int main(void){
    signal(SIGINT,  handle_sig);
    signal(SIGTERM, handle_sig);
    signal(SIGWINCH,handle_winch);

    update_term_size();
    gather_static();

    pthread_t stats_tid;
    pthread_create(&stats_tid,NULL,stats_thread,NULL);

    hide_cursor();
    clear_screen();

    double start=now_sec();
    const double frame_dt=1.0/60.0;

    while(running){
        double t0=now_sec(), t=t0-start;

        if(TW!=prev_TW||TH!=prev_TH){ clear_screen(); prev_TW=TW; prev_TH=TH; }

        fb_reset();
        fb_str("\033[?25l\033[H");

        build_scene(t);
        render_scene();

        
        fb_fg(10,40,30);
        for(int i=0;i<TW;i++) fb_str("\xe2\x94\x80"); 
        fb_R(); fb_str("\r\n\r\n");

        render_title(t);
        render_tagline(t);
        fb_str("\r\n");
        render_info_panel(t);

        
        
        int used = SCENE_H + 1  + 1  + NTITLE + 1 + 1
                 + 2 + 8;
        for(int i=used; i<TH-1; i++){
            for(int j=0;j<TW;j++) fb_char(' ');
            fb_str("\r\n");
        }

        fb_flush();
        sleep_until(t0+frame_dt);
    }

    running=0;
    pthread_join(stats_tid,NULL);
    show_cursor();
    clear_screen();
    puts(RESET "bye.");
    return 0;
}