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

static int TW = 80, TH = 24, prev_TW = 0, prev_TH = 0;
static volatile int running = 1;

static void hide_cursor(void) { fputs("\033[?25l", stdout); fflush(stdout); }
static void show_cursor(void) { fputs("\033[?25h", stdout); fflush(stdout); }
static void clear_screen(void){ fputs("\033[2J\033[H", stdout); fflush(stdout); }

static void update_term_size(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0) {
        TW = ws.ws_col > 80 ? ws.ws_col : 80;
        TH = ws.ws_row > 24 ? ws.ws_row : 24;
    }
}
static void handle_sig(int s)   { (void)s; running = 0; }
static void handle_winch(int s) { (void)s; update_term_size(); }

/* ── file helpers ─────────────────────────────────────────────────────────── */
static void strip_after(char *s, char c) {
    char *p = strchr(s, c); if (p) *p = '\0';
}

static int read_first_line(const char *path, char *buf, int sz) {
    FILE *f = fopen(path, "r");
    if (!f) { buf[0]='\0'; return 0; }
    if (!fgets(buf, sz, f)) { buf[0]='\0'; fclose(f); return 0; }
    fclose(f);
    int n = strlen(buf);
    while (n > 0 && (buf[n-1]=='\n'||buf[n-1]=='\r')) buf[--n]='\0';
    return n;
}

static int run_cmd(const char *cmd, char *buf, int sz) {
    FILE *p = popen(cmd, "r");
    if (!p) { buf[0]='\0'; return 0; }
    int n = fread(buf, 1, sz-1, p);
    pclose(p);
    if (n < 0) n = 0;
    buf[n] = '\0';
    while (n > 0 && (buf[n-1]=='\n'||buf[n-1]=='\r'||buf[n-1]==' ')) buf[--n]='\0';
    return n;
}

/* ── static system info ───────────────────────────────────────────────────── */
static char g_shell  [64] = "Unknown";
static char g_desktop[64] = "Unknown";
static char g_init   [64] = "Unknown";
static char g_cpu    [80] = "Unknown";
static char g_gpu    [80] = "Unknown";
static char g_kernel [32] = "Unknown";
static char g_pkgs  [512] = "";

static void detect_shell(void) {
    const char *s = getenv("SHELL");
    if (s) { const char *b=strrchr(s,'/'); strncpy(g_shell,b?b+1:s,63); return; }
    pid_t pid = getppid();
    for (int i=0; i<6; i++) {
        char path[64], comm[32];
        snprintf(path,sizeof(path),"/proc/%d/comm",(int)pid);
        if (!read_first_line(path,comm,sizeof(comm))) break;
        const char *shells[]={"bash","zsh","fish","sh","dash","ksh","tcsh","csh","nu","elvish",NULL};
        for (int j=0; shells[j]; j++) if (!strcmp(comm,shells[j])) { strncpy(g_shell,comm,63); return; }
        char stat[256]; snprintf(path,sizeof(path),"/proc/%d/stat",(int)pid);
        if (!read_first_line(path,stat,sizeof(stat))) break;
        char *p=strrchr(stat,')'); if(!p) break;
        int ppid=0; sscanf(p+2,"%*c %d",&ppid);
        if (ppid<=1) break;
        pid=(pid_t)ppid;
    }
}

static void detect_desktop(void) {
    const char *vars[]={"XDG_CURRENT_DESKTOP","DESKTOP_SESSION","XDG_SESSION_DESKTOP",NULL};
    for (int i=0; vars[i]; i++) {
        const char *v=getenv(vars[i]);
        if (v&&v[0]) { strncpy(g_desktop,v,63); strip_after(g_desktop,':'); return; }
    }
    char buf[4096];
    run_cmd("ps -e -o comm= 2>/dev/null",buf,sizeof(buf));
    struct { const char *proc,*name; } wm[]={
        {"plasmashell","KDE"},{"xfce4-session","XFCE"},{"niri","Niri"},
        {"taigawm","TaigaWM"},{"gnome-shell","GNOME"},{"sway","Sway"},
        {"i3","i3"},{"openbox","Openbox"},{NULL,NULL}
    };
    for (int i=0; wm[i].proc; i++)
        if (strstr(buf,wm[i].proc)) { strncpy(g_desktop,wm[i].name,63); return; }
}

static void detect_init(void) {
    char comm[32];
    if (read_first_line("/proc/1/comm",comm,sizeof(comm))) {
        if (strstr(comm,"systemd")) { strcpy(g_init,"systemd"); return; }
        if (strstr(comm,"openrc"))  { strcpy(g_init,"OpenRC");  return; }
        if (strstr(comm,"runit"))   { strcpy(g_init,"runit");   return; }
        if (strstr(comm,"s6"))      { strcpy(g_init,"s6");      return; }
        if (strstr(comm,"dinit"))   { strcpy(g_init,"dinit");   return; }
    }
    if (!access("/run/systemd/private",F_OK)) { strcpy(g_init,"systemd"); return; }
    if (!access("/run/openrc",F_OK))          { strcpy(g_init,"OpenRC");  return; }
    if (!access("/run/runit",F_OK))           { strcpy(g_init,"runit");   return; }
    if (!access("/etc/dinit.d",F_OK))         { strcpy(g_init,"dinit");   return; }
    if (!system("systemctl is-system-running >/dev/null 2>&1")) { strcpy(g_init,"systemd"); return; }
    if (!system("rc-status >/dev/null 2>&1"))                   { strcpy(g_init,"OpenRC");  return; }
}

static void detect_cpu(void) {
    FILE *f = fopen("/proc/cpuinfo","r"); if(!f) return;
    char line[256];
    while (fgets(line,sizeof(line),f)) {
        if (strncmp(line,"model name",10)) continue;
        char *p=strchr(line,':'); if(!p) continue; p++; while(*p==' ')p++;
        char *dst=g_cpu, *end=g_cpu+sizeof(g_cpu)-1;
        for(;*p&&*p!='\n'&&dst<end;p++){
            if(!strncmp(p,"(R)",3)){p+=2;continue;}
            if(!strncmp(p,"(TM)",4)){p+=3;continue;}
            if(!strncmp(p,"CPU ",4)){p+=3;continue;}
            *dst++=*p;
        }
        *dst='\0';
        while(dst>g_cpu&&dst[-1]==' ')*--dst='\0';
        break;
    }
    fclose(f);
}

static void detect_gpu(void) {
    char buf[4096];
    if (!run_cmd("lspci 2>/dev/null",buf,sizeof(buf))) return;
    char *line=strtok(buf,"\n");
    while (line) {
        if (strstr(line,"VGA")||strstr(line,"3D")||strstr(line,"Display")) {
            char *p=strrchr(line,':'); if(!p){line=strtok(NULL,"\n");continue;}
            p++; while(*p==' ')p++;
            const char *noise[]={
                "Advanced Micro Devices, Inc.","[AMD/ATI]",
                "NVIDIA Corporation","Intel Corporation","Technologies Inc",NULL
            };
            char tmp[128]; strncpy(tmp,p,127); tmp[127]='\0';
            for(int i=0;noise[i];i++){
                char *f2;
                while((f2=strstr(tmp,noise[i])))
                    memmove(f2,f2+strlen(noise[i]),strlen(f2+strlen(noise[i]))+1);
            }
            /* strip " (rev XX)" and " [...]" */
            char *r=strstr(tmp," (rev "); if(r)*r='\0';
            char *b=strstr(tmp," [");    if(b)*b='\0';
            char *t=tmp; while(*t==' ')t++;
            char *e=t+strlen(t)-1; while(e>t&&*e==' ')*e--='\0';
            strncpy(g_gpu,t,sizeof(g_gpu)-1);
            return;
        }
        line=strtok(NULL,"\n");
    }
}

static void detect_kernel(void) {
    read_first_line("/proc/sys/kernel/osrelease",g_kernel,sizeof(g_kernel));
    strip_after(g_kernel,'-');
    strip_after(g_kernel,'+');
}

static void detect_packages(void) {
    struct { const char *cmd; const char *label; } mgrs[]={
        {"dpkg --list 2>/dev/null | grep -c '^ii'",    "dpkg"},
        {"pacman -Qq 2>/dev/null | wc -l",             "pacman"},
        {"rpm -qa 2>/dev/null | wc -l",                "rpm"},
        {"snap list 2>/dev/null | tail -n +2 | wc -l", "snap"},
        {"flatpak list 2>/dev/null | wc -l",           "flatpak"},
        {"nix-env -q 2>/dev/null | wc -l",             "nix"},
        {NULL,NULL}
    };
    char parts[512]=""; int np=0;
    for(int i=0;mgrs[i].cmd;i++){
        char buf[32]; if(!run_cmd(mgrs[i].cmd,buf,sizeof(buf))) continue;
        int n=atoi(buf); if(n<=0) continue;
        char tmp[64];
        snprintf(tmp,sizeof(tmp),np==0?"%d (%s)":" + %d (%s)",n,mgrs[i].label);
        strncat(parts,tmp,sizeof(parts)-strlen(parts)-1);
        np++;
    }
    strncpy(g_pkgs,np?parts:"Unknown",sizeof(g_pkgs)-1);
}

/* parallel gather */
static void *thr_fn(void *fn) { ((void(*)(void))fn)(); return NULL; }
static void gather_static(void) {
    void (*fns[])(void)={detect_shell,detect_desktop,detect_init,
                         detect_cpu,detect_gpu,detect_kernel,detect_packages,NULL};
    pthread_t t[16]; int n=0;
    for(;fns[n];n++) pthread_create(&t[n],NULL,thr_fn,(void*)fns[n]);
    struct timespec dl; clock_gettime(CLOCK_REALTIME,&dl); dl.tv_sec+=4;
    for(int i=0;i<n;i++) pthread_timedjoin_np(t[i],NULL,&dl);
}

/* ── live stats ───────────────────────────────────────────────────────────── */
static pthread_mutex_t stats_lock = PTHREAD_MUTEX_INITIALIZER;
static double g_cpu_pct = 0, g_gpu_pct = -1;
static long   g_ram_used = 0, g_ram_total = 0;
static int    g_cpu_temp = -1;
static char   g_uptime[32] = "";

static long long cpu_prev_total=0, cpu_prev_idle=0;
static void update_cpu_pct(void) {
    char line[256]; FILE *f=fopen("/proc/stat","r"); if(!f) return;
    if (!fgets(line,sizeof(line),f)) { fclose(f); return; }
    fclose(f);
    long long u,n,s,id,iow,irq,soft,steal;
    if (sscanf(line,"cpu %lld %lld %lld %lld %lld %lld %lld %lld",
               &u,&n,&s,&id,&iow,&irq,&soft,&steal) < 4) return;
    long long idle=id+iow, total=u+n+s+id+iow+irq+soft+steal;
    long long dt=total-cpu_prev_total, di=idle-cpu_prev_idle;
    if (dt>0) {
        double p=(1.0-(double)di/dt)*100.0;
        pthread_mutex_lock(&stats_lock);
        g_cpu_pct = p<0?0:p>100?100:p;
        pthread_mutex_unlock(&stats_lock);
    }
    cpu_prev_total=total; cpu_prev_idle=idle;
}

static void update_ram(void) {
    FILE *f=fopen("/proc/meminfo","r"); if(!f) return;
    char line[128]; long tot=0,avail=0;
    while(fgets(line,sizeof(line),f)){
        long v; char key[32];
        if(sscanf(line,"%31s %ld",key,&v)!=2) continue;
        if(!strcmp(key,"MemTotal:"))     tot=v;
        if(!strcmp(key,"MemAvailable:")) avail=v;
    }
    fclose(f);
    pthread_mutex_lock(&stats_lock);
    g_ram_total=tot/1024; g_ram_used=(tot-avail)/1024;
    pthread_mutex_unlock(&stats_lock);
}

static void update_cpu_temp(void) {
    const char *paths[]={
        "/sys/class/thermal/thermal_zone0/temp",
        "/sys/class/hwmon/hwmon0/temp1_input",
        "/sys/class/hwmon/hwmon1/temp1_input",
        NULL
    };
    char buf[32];
    for(int i=0;paths[i];i++){
        if(!read_first_line(paths[i],buf,sizeof(buf))) continue;
        int raw=atoi(buf);
        if(raw>1000) raw/=1000;
        if(raw>0&&raw<200){
            pthread_mutex_lock(&stats_lock);
            g_cpu_temp=raw;
            pthread_mutex_unlock(&stats_lock);
            return;
        }
    }
}

static void update_uptime(void) {
    FILE *f=fopen("/proc/uptime","r"); if(!f) return;
    long long s=0; fscanf(f,"%lld",&s); fclose(f);
    long d=s/86400, h=(s%86400)/3600, m=(s%3600)/60;
    char tmp[32];
    if(d>0)      snprintf(tmp,sizeof(tmp),"%ldd %ldh %ldm",d,h,m);
    else if(h>0) snprintf(tmp,sizeof(tmp),"%ldh %ldm",h,m);
    else         snprintf(tmp,sizeof(tmp),"%ldm",m);
    pthread_mutex_lock(&stats_lock);
    strncpy(g_uptime,tmp,sizeof(g_uptime)-1);
    pthread_mutex_unlock(&stats_lock);
}

static char gpu_path[256]="";
static void init_gpu_source(void) {
    if(!system("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits >/dev/null 2>&1")){
        strcpy(gpu_path,"nvidia"); return;
    }
    DIR *d=opendir("/sys/class/drm"); if(!d) return;
    struct dirent *e;
    while((e=readdir(d))){
        char p[300];
        snprintf(p,sizeof(p),"/sys/class/drm/%s/device/gpu_busy_percent",e->d_name);
        if(!access(p,R_OK)){ strncpy(gpu_path,p,sizeof(gpu_path)-1); break; }
    }
    closedir(d);
}

static void update_gpu_pct(void) {
    if(!gpu_path[0]) return;
    double v=-1;
    if(!strcmp(gpu_path,"nvidia")){
        char buf[32]; run_cmd("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null",buf,sizeof(buf));
        v=atof(buf);
    } else {
        char buf[32]; read_first_line(gpu_path,buf,sizeof(buf)); v=atof(buf);
    }
    if(v>=0){ pthread_mutex_lock(&stats_lock); g_gpu_pct=v>100?100:v; pthread_mutex_unlock(&stats_lock); }
}

static void *stats_thread(void *a){
    (void)a; init_gpu_source();
    while(running){
        update_cpu_pct(); update_ram(); update_gpu_pct();
        update_cpu_temp(); update_uptime();
        struct timespec ts={0,800000000L}; nanosleep(&ts,NULL);
    }
    return NULL;
}

/* ── frame buffer ─────────────────────────────────────────────────────────── */
#define FBUF_SIZE (2*1024*1024)
static char fbuf[FBUF_SIZE];
static int  fbpos=0;

static void fb_reset(void)         { fbpos=0; }
static void fb_str(const char *s)  { int n=strlen(s); memcpy(fbuf+fbpos,s,n); fbpos+=n; }
static void fb_char(char c)        { fbuf[fbpos++]=c; }
static void fb_flush(void)         { fwrite(fbuf,1,fbpos,stdout); fflush(stdout); }
#define fb_printf(...) (fbpos+=snprintf(fbuf+fbpos,FBUF_SIZE-fbpos,__VA_ARGS__))
static void fb_fg(int r,int g,int b){ fb_printf("\033[38;2;%d;%d;%dm",r,g,b); }
static void fb_R(void)              { fb_str(RESET); }
static void fb_pad(int n)           { while(n-->0) fb_char(' '); }

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

/* ── scene ────────────────────────────────────────────────────────────────── */
#define SCENE_H 11
#define GROUND   9
#define MAX_W  512

typedef struct { char ch; unsigned char r,g,b; } Cell;
static Cell scene[SCENE_H][MAX_W];

typedef struct { int x,h; char sz; } Tree;
static const Tree TREES[]={
    {4,8,'L'},{10,6,'S'},{16,9,'L'},{22,5,'S'},{29,7,'S'},{35,4,'S'},
    {43,8,'L'},{50,6,'S'},{57,9,'L'},{64,5,'S'},{72,7,'L'},{80,5,'S'},
    {88,8,'L'},{95,6,'S'},{103,9,'L'},{111,5,'S'},{119,7,'S'},{127,4,'S'},
    {135,8,'L'},{143,6,'S'},{151,9,'L'},{160,5,'S'},{168,7,'L'},{176,4,'S'},
};
#define NTREES (int)(sizeof(TREES)/sizeof(TREES[0]))

static void build_scene(double t){
    int W=TW<MAX_W?TW:MAX_W;
    for(int row=0;row<SCENE_H;row++){
        if(row>=GROUND){
            for(int c=0;c<W;c++)
                scene[row][c]= row==GROUND ? (Cell){1,6,40,24} : (Cell){' ',3,20,12};
            continue;
        }
        for(int c=0;c<W;c++){
            double w1=sin(c*.06+t*.35)*.5+sin(c*.025+t*.18+1.8)*.5;
            double w2=sin(c*.04+t*.22+3.)*.5+sin(c*.08+t*.28+.5)*.5;
            double ii=(w1*.55+w2*.45)*.5+.5; ii*=1.-(double)row/GROUND*.5;
            scene[row][c]=(Cell){' ',(unsigned char)(4+ii*16),(unsigned char)(60+ii*150),(unsigned char)(80+ii*140)};
        }
        double wr1=2+sin(t*.25+.5)*.8, wr2=5+sin(t*.2+2.)*.8;
        for(int c=0;c<W;c++){
            double wo=sin(c*.08+t*.4)*1.2;
            if(fabs(row-wr1-wo)<.9)        scene[row][c]=(Cell){'~',20,210,170};
            else if(fabs(row-wr2-wo*.8)<.7) scene[row][c]=(Cell){'~',10,160,180};
        }
        for(int c=0;c<W;c++){
            int sid=(c*7+13)%17, sr=sid%(GROUND-1);
            if(sr==row&&(c*11+sid)%9==0){
                unsigned char bv=(unsigned char)(100+fabs(sin(t*1.3+c*.6+sid))*155);
                scene[row][c]=(Cell){'.',bv,(unsigned char)(bv+20<255?bv+20:255),bv};
            }
        }
        int rfg=GROUND-row;
        for(int ti=0;ti<NTREES;ti++){
            int cx=TREES[ti].x, th=TREES[ti].h; char sz=TREES[ti].sz;
            if(cx>=W||rfg<1||rfg>th) continue;
            if(rfg==1){ if(cx<W) scene[row][cx]=(Cell){'|',8,55,30}; continue; }
            int hw=(int)round((1.-(double)rfg/th)*th*(sz=='L'?.38:.28));
            if(hw<0) hw=0;
            for(int dc=-hw;dc<=hw;dc++){
                int c=cx+dc; if(c<0||c>=W) continue;
                if(dc==0&&rfg==th)   scene[row][c]=(Cell){'^',10,75,38};
                else if(abs(dc)==hw) scene[row][c]=(Cell){dc<0?'/':'\\',8,58,30};
                else                 scene[row][c]=(Cell){'#',6,48,24};
            }
        }
    }
}

static void render_scene(void){
    int W=TW<MAX_W?TW:MAX_W;
    for(int row=0;row<SCENE_H;row++){
        int pr=-1,pg=-1,pb=-1;
        for(int c=0;c<W;c++){
            Cell *cl=&scene[row][c];
            if(cl->r!=pr||cl->g!=pg||cl->b!=pb){ fb_fg(cl->r,cl->g,cl->b); pr=cl->r;pg=cl->g;pb=cl->b; }
            if(row==GROUND) fb_str("\xe2\x96\x84");
            else            fb_char(cl->ch);
        }
        fb_R(); fb_str("\r\n");
    }
}

/* ── title ────────────────────────────────────────────────────────────────── */
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
            if(line[ci]==' '){fb_char(' ');continue;}
            double w=sin(ci*.12+t*.8+i*.6)*.5+.5;
            fb_fg((int)(8+w*20),(int)(150+w*100),(int)(140+w*100));
            fb_str(BOLD); fb_char(line[ci]); fb_R();
        }
        fb_str("\r\n");
    }
}

static void render_tagline(double t){
    const char *words[]={"Lightweight.","Featured.","Novel."};
    fb_str("  ");
    for(int i=0;i<3;i++){
        double w=sin(t*.5+i*1.4)*.5+.5;
        fb_fg((int)(20+w*30),(int)(130+w*100),(int)(120+w*100));
        fb_str(DIM); fb_str(words[i]); fb_R(); fb_str("   ");
    }
    fb_str("\r\n");
}

/* ── info panel ───────────────────────────────────────────────────────────── */
#define LEFT_W   52
#define LABEL_W   8

static void valcol(double pct){
    if(pct>80)      fb_fg(220,80,60);
    else if(pct>50) fb_fg(220,180,50);
    else            fb_fg(50,200,130);
}

static void tempcol(int t){
    if(t>80)      fb_fg(220,80,60);
    else if(t>60) fb_fg(220,180,50);
    else          fb_fg(50,200,130);
}

/* write "LABEL   | " with correct visible-width padding */
static void hw_label(const char *label){
    fb_fg(15,80,60);
    fb_str(label);
    fb_pad(LABEL_W - visw(label));
    fb_fg(30,60,45);
    fb_str(" | ");
    fb_R();
}

/* each hw_* function writes exactly one row's worth of content (no \r\n) */
static void hw_model(const char *label, const char *val){
    hw_label(label); fb_fg(140,200,170); fb_str(val); fb_R();
}
static void hw_pct(const char *label, double pct){
    hw_label(label); valcol(pct); fb_printf("%.1f%%",pct); fb_R();
}
static void hw_ram(long used, long total, double pct){
    hw_label("RAM"); valcol(pct); fb_printf("%ld/%ld MB",used,total); fb_R();
}
static void hw_temp(int temp){
    char tmp[16]; snprintf(tmp,sizeof(tmp),"%d\xc2\xb0""C",temp);
    hw_label("CPU \xc2\xb0""C"); tempcol(temp); fb_str(tmp); fb_R();
}
static void hw_plain(const char *label, const char *val, int r, int g, int b){
    hw_label(label); fb_fg(r,g,b); fb_str(val); fb_R();
}

/* capture one hw row into a fixed buffer */
#define HW_BUF 512
static int capture_hw(char *dst, void (*fn)(void), void *arg1, void *arg2, void *arg3) {
    (void)arg1; (void)arg2; (void)arg3;
    int s=fbpos; fn(); int len=fbpos-s;
    if(len>=HW_BUF) len=HW_BUF-1;
    memcpy(dst,fbuf+s,len); dst[len]='\0';
    fbpos=s;
    return len;
}

static void render_info_panel(double t){
    /* snapshot live stats */
    pthread_mutex_lock(&stats_lock);
    double cpu_p=g_cpu_pct, gpu_p=g_gpu_pct;
    long   ru=g_ram_used,   rt=g_ram_total;
    int    ctemp=g_cpu_temp;
    char   uptime[32]; strncpy(uptime,g_uptime,31); uptime[31]='\0';
    pthread_mutex_unlock(&stats_lock);
    double ram_p = rt>0 ? (double)ru/rt*100.0 : 0;

    /* animated header colour */
    double wave=sin(t*.4)*.5+.5;
    int hg=(int)(120+wave*80);

    /* build headers */
    char lhdr[128], rhdr[64];
    snprintf(lhdr,sizeof(lhdr),"  \033[38;2;20;%d;100m\033[1m[ Software ]\033[0m",hg);
    snprintf(rhdr,sizeof(rhdr),   "\033[38;2;20;%d;100m\033[1m[ Hardware ]\033[0m",hg);
    fb_str(lhdr); fb_pad(LEFT_W+2-visw(lhdr));
    fb_str("  "); fb_str(rhdr); fb_str("\r\n\r\n");

    /* software (left) rows */
    struct { const char *label, *value; } sw[]={
        {"Base",     "Debian stable"},
        {"Init",     g_init},
        {"Arch",     "x86_64"},
        {"Shell",    g_shell},
        {"Desktop",  g_desktop},
        {"Packages", g_pkgs},
        {"Repo",     "github.com/DamianDaniel/borealOS"},
        {NULL,NULL}
    };
    int nsw=0; for(;sw[nsw].label;nsw++);

    /* hardware (right) rows — build each into its own buffer */
#define MAX_HW 12
    char hw[MAX_HW][HW_BUF];
    int nhw=0;

    /* macro: run a hw_* call, capture output into hw[nhw++] */
#define CAP(call) do { \
    int _s=fbpos; call; int _l=fbpos-_s; \
    if(_l>=HW_BUF)_l=HW_BUF-1; \
    memcpy(hw[nhw],fbuf+_s,_l); hw[nhw][_l]='\0'; \
    fbpos=_s; nhw++; \
} while(0)

    CAP(hw_ram(ru,rt,ram_p));
    CAP(hw_model("CPU",g_cpu));
    CAP(hw_pct("CPU %",cpu_p));
    if(ctemp>0){ CAP(hw_temp(ctemp)); }
    CAP(hw_model("GPU",g_gpu));
    if(gpu_p>=0){ CAP(hw_pct("GPU %",gpu_p)); }
    else { CAP({ hw_label("GPU %"); fb_fg(80,80,80); fb_str("N/A"); fb_R(); }); }
    CAP(hw_plain("Uptime",uptime,100,180,200));
    CAP(hw_plain("Kernel",g_kernel,100,180,200));

    /* left column available value width */
    /* layout: "  " + label(10) + " | " + value = 2+10+3+value */
    int val_col = 2 + 10 + 3;   /* = 15: column where value starts */
    int val_avail = LEFT_W + 2 - val_col; /* available chars for value */

    int nrows = nsw > nhw ? nsw : nhw;
    int hwi = 0;

    for(int i=0;i<nrows;i++){
        int extra = 0;   /* extra lines produced by wrapping */

        /* --- left column --- */
        fb_str("  ");
        if(i<nsw){
            double wv=sin(t*.35+i)*.5+.5;
            int lg=(int)(70+wv*70), vg=(int)(160+wv*70);

            char prefix[80];
            snprintf(prefix,sizeof(prefix),
                "\033[38;2;15;%d;80m%-10s\033[38;2;30;60;45m | \033[0m",lg,sw[i].label);
            fb_str(prefix);

            const char *val=sw[i].value;
            int vlen=(int)strlen(val);

            if(vlen<=val_avail){
                fb_fg(40,vg,140); fb_str(val); fb_R();
                fb_pad(val_avail - vlen);
            } else {
                /* first chunk on current line, rest on continuation lines */
                int pos=0;
                int first=1;
                while(pos<vlen){
                    int avail = first ? val_avail : val_avail;
                    int chunk = avail;
                    if(pos+chunk < vlen){
                        /* break at last space or + within chunk */
                        int bp=chunk;
                        while(bp>0 && val[pos+bp]!=' ' && val[pos+bp]!='+') bp--;
                        if(bp>0) chunk=bp;
                    } else {
                        chunk=vlen-pos;
                    }
                    if(first){
                        fb_fg(40,vg,140);
                        memcpy(fbuf+fbpos, val+pos, chunk); fbpos+=chunk;
                        fb_R();
                        /* pad remainder of first line so hw col is correct */
                        fb_pad(val_avail - chunk);
                        first=0;
                    } else {
                        /* continuation line: pad to value column, print chunk, newline */
                        fb_str("\r\n");
                        fb_pad(val_col);
                        fb_fg(40,vg,140);
                        memcpy(fbuf+fbpos, val+pos, chunk); fbpos+=chunk;
                        fb_R();
                        extra++;
                    }
                    pos+=chunk;
                    while(pos<vlen && val[pos]==' ') pos++;
                }
            }
        } else {
            /* no sw row — just indent to match right column position */
            fb_pad(LEFT_W);
        }

        /* --- right column --- */
        fb_str("  ");
        if(hwi<nhw) fb_str(hw[hwi++]);
        fb_str("\r\n");

        /* continuation lines have no right column content */
        for(int e=0;e<extra;e++){ fb_pad(val_col+val_avail+2); fb_str("\r\n"); }
    }
}

/* ── timing ───────────────────────────────────────────────────────────────── */
static double now_sec(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return ts.tv_sec+ts.tv_nsec*1e-9;
}
static void sleep_until(double target){
    double rem=target-now_sec(); if(rem<=0) return;
    struct timespec ts;
    ts.tv_sec=(time_t)rem;
    ts.tv_nsec=(long)((rem-ts.tv_sec)*1e9);
    nanosleep(&ts,NULL);
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(void){
    signal(SIGINT, handle_sig);
    signal(SIGTERM,handle_sig);
    signal(SIGWINCH,handle_winch);

    update_term_size();
    gather_static();

    pthread_t stid;
    pthread_create(&stid,NULL,stats_thread,NULL);

    hide_cursor(); clear_screen();
    double start=now_sec();

    while(running){
        double t0=now_sec(), t=t0-start;

        update_term_size();
        if(TW!=prev_TW||TH!=prev_TH){ clear_screen(); prev_TW=TW; prev_TH=TH; }

        fb_reset();
        fb_str("\033[?25l\033[H");

        build_scene(t); render_scene();

        fb_fg(10,40,30);
        for(int i=0;i<TW;i++) fb_str("\xe2\x94\x80");
        fb_R(); fb_str("\r\n\r\n");

        render_title(t);
        render_tagline(t);
        fb_str("\r\n");
        render_info_panel(t);

        /* clear remaining lines */
        int approx_lines = SCENE_H+2+NTITLE+2+2+2+12;
        for(int i=approx_lines;i<TH-1;i++){
            for(int j=0;j<TW;j++) fb_char(' ');
            fb_str("\r\n");
        }

        fb_flush();
        sleep_until(t0+1.0/60.0);
    }

    running=0;
    pthread_join(stid,NULL);
    show_cursor(); clear_screen();
    puts(RESET "bye.");
    return 0;
}
