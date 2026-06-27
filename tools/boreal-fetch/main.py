#!/usr/bin/env python3
import sys, time, math, os, signal, subprocess, threading, re

os.system('')

ESC = "\033["
def pos(r,c):   return f"{ESC}{r};{c}H"
def hide_cur(): sys.stdout.write(f"{ESC}?25l"); sys.stdout.flush()
def show_cur(): sys.stdout.write(f"{ESC}?25h"); sys.stdout.flush()
def clr():      sys.stdout.write(f"{ESC}2J{ESC}H"); sys.stdout.flush()
def R():        return "\033[0m"
def B():        return "\033[1m"
def DIM():      return "\033[2m"
def fg(r,g,b):  return f"\033[38;2;{r};{g};{b}m"

ANSI_RE = re.compile(r'\033\[[^m]*m')
def vis(s):       return len(ANSI_RE.sub('', s))
def pad_to(s, w): return s + ' ' * max(0, w - vis(s))

# ── Terminal size (re-read every frame) ───────────────────────────────────────

def term_size():
    try:
        ts = os.get_terminal_size()
        return max(ts.columns, 80), max(ts.lines, 24)
    except Exception:
        return 80, 30

running = True
def bye(sig, frame):
    global running; running = False
signal.signal(signal.SIGINT, bye)
signal.signal(signal.SIGTERM, bye)

TITLE_BIG = [
    r"  ____                       _  ___  ____  ",
    r" | __ )  ___  _ __ ___  __ _| |/ _ \/ ___| ",
    r" |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \ ",
    r" | |_) | (_) | | |  __/ (_| | | |_| |___) |",
    r" |____/ \___/|_|  \___|\__,_|_|\___/|____/ ",
]

# ── System detection ──────────────────────────────────────────────────────────

def read_file(path):
    try:
        with open(path) as f: return f.read().strip()
    except Exception: return ""

def detect_shell():
    # 1. $SHELL env var (login shell)
    s = os.environ.get("SHELL", "")
    if s: return os.path.basename(s)
    # 2. $0 (current shell in some setups)
    s = os.environ.get("0", "")
    if s: return os.path.basename(s.lstrip('-'))
    # 3. Walk up process tree via /proc to find parent shell
    try:
        pid = os.getppid()
        for _ in range(5):
            comm = read_file(f"/proc/{pid}/comm")
            if comm in ("bash","zsh","fish","sh","dash","ksh","tcsh","csh","nu","elvish"):
                return comm
            stat = read_file(f"/proc/{pid}/stat")
            if not stat: break
            pid = int(stat.split()[3])   # ppid field
    except Exception: pass
    return "Unknown"

def detect_desktop():
    for var in ("XDG_CURRENT_DESKTOP", "DESKTOP_SESSION", "XDG_SESSION_DESKTOP"):
        v = os.environ.get(var, "").strip()
        if v: return v.split(":")[0]
    try:
        out = subprocess.check_output(["ps","-e","-o","comm="],
                                      stderr=subprocess.DEVNULL, text=True)
        procs = set(out.split())
        for name, label in [("plasmashell","KDE"),("xfce4-session","XFCE"),
                             ("niri","Niri"),("taigawm","TaigaWM"),
                             ("gnome-shell","GNOME"),("sway","Sway"),
                             ("i3","i3"),("openbox","Openbox")]:
            if name in procs: return label
    except Exception: pass
    return "Unknown"

def get_cpu_model():
    for line in read_file("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            raw = line.split(":",1)[1].strip()
            for d in ["(R)","(TM)","CPU ","  "]: raw = raw.replace(d,"")
            return raw[:34].strip()
    return "Unknown"

def get_kernel():
    v = read_file("/proc/sys/kernel/osrelease")
    return v.split("-")[0] if v else "Unknown"

def get_gpu_model():
    try:
        out = subprocess.check_output(["lspci"],stderr=subprocess.DEVNULL,text=True)
        for line in out.splitlines():
            if any(k in line for k in ("VGA","3D","Display","GPU")):
                part = line.split(":",2)[-1].strip()
                for d in ["Advanced Micro Devices, Inc.","[AMD/ATI]",
                          "NVIDIA Corporation","Intel Corporation","Technologies Inc"]:
                    part = part.replace(d,"")
                return part.strip()[:34]
    except Exception: pass
    return "Unknown"

# ── CPU usage (background thread) ─────────────────────────────────────────────

_cpu_prev = None; _cpu_pct = 0.0; _cpu_lock = threading.Lock()

def _parse_cpu_stat():
    try:
        with open("/proc/stat") as f: line = f.readline()
    except Exception: return None
    parts = line.split()
    if parts[0] != "cpu": return None
    vals = list(map(int, parts[1:]))
    idle = vals[3] + (vals[4] if len(vals)>4 else 0)
    return sum(vals), idle

def _cpu_thread():
    global _cpu_prev, _cpu_pct
    while running:
        cur = _parse_cpu_stat()
        if cur and _cpu_prev:
            dt, di = cur[0]-_cpu_prev[0], cur[1]-_cpu_prev[1]
            with _cpu_lock: _cpu_pct = max(0., min(100., (1.-di/dt)*100 if dt else 0.))
        _cpu_prev = cur
        time.sleep(0.8)

threading.Thread(target=_cpu_thread, daemon=True).start()
def get_cpu_pct():
    with _cpu_lock: return _cpu_pct

# ── GPU usage (background thread) ─────────────────────────────────────────────

_gpu_pct = None; _gpu_lock = threading.Lock()

def _gpu_thread():
    global _gpu_pct
    nvidia = False
    try:
        subprocess.check_output(["nvidia-smi","--query-gpu=utilization.gpu",
                                  "--format=csv,noheader,nounits"],stderr=subprocess.DEVNULL)
        nvidia = True
    except Exception: pass
    amd_path = ""
    if not nvidia:
        try:
            for card in sorted(os.listdir("/sys/class/drm")):
                p = f"/sys/class/drm/{card}/device/gpu_busy_percent"
                if os.path.exists(p): amd_path = p; break
        except Exception: pass
    if not nvidia and not amd_path:
        with _gpu_lock: _gpu_pct = None
        return
    while running:
        try:
            if nvidia:
                out = subprocess.check_output(
                    ["nvidia-smi","--query-gpu=utilization.gpu",
                     "--format=csv,noheader,nounits"],
                    stderr=subprocess.DEVNULL, text=True)
                val = float(out.strip().splitlines()[0])
            else:
                val = float(read_file(amd_path))
            with _gpu_lock: _gpu_pct = max(0., min(100., val))
        except Exception: pass
        time.sleep(0.9)

threading.Thread(target=_gpu_thread, daemon=True).start()
def get_gpu_pct():
    with _gpu_lock: return _gpu_pct

# ── RAM ───────────────────────────────────────────────────────────────────────

def get_ram():
    data = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        data[k.strip()] = int(v.split()[0]) if v.split() else 0
    total = data.get("MemTotal", 0); avail = data.get("MemAvailable", 0)
    used  = total - avail
    return used//1024, total//1024

# ── Static data — gathered in parallel at startup ────────────────────────────
# Each slow call runs in its own thread so total wait = slowest single call,
# not sum of all calls. Results stored in dict, read after join().

_static = {}

def _gather():
    tasks = {
        "shell":   detect_shell,
        "desktop": detect_desktop,
        "cpu":     get_cpu_model,
        "gpu":     get_gpu_model,
        "kernel":  get_kernel,
    }
    threads = {k: threading.Thread(target=lambda k=k,f=f: _static.update({k: f()}),
                                   daemon=True)
               for k, f in tasks.items()}
    for th in threads.values(): th.start()
    for th in threads.values(): th.join(timeout=2.0)   # max 2s total wait
    # Fill any that timed out
    for k in tasks:
        _static.setdefault(k, "Unknown")

_gather()

_SHELL     = _static["shell"]
_DESKTOP   = _static["desktop"]
_CPU_MODEL = _static["cpu"]
_GPU_MODEL = _static["gpu"]
_KERNEL    = _static["kernel"]

DISTRO_ROWS = [
    ("Base",    "Debian stable"),
    ("Init",    "OpenRC"),
    ("Arch",    "x86_64"),
    ("Shell",   _SHELL),
    ("Desktop", _DESKTOP),
    ("Repo",    "github.com/DamianDaniel/borealOS"),
]

# ── Scene ─────────────────────────────────────────────────────────────────────

SCENE_H = 11; GROUND_ROW = 9
TREES = [
    (4,8,'L'),(10,6,'S'),(16,9,'L'),(22,5,'S'),(29,7,'S'),(35,4,'S'),
    (43,8,'L'),(50,6,'S'),(57,9,'L'),(64,5,'S'),(72,7,'L'),(80,5,'S'),
    (88,8,'L'),(95,6,'S'),(103,9,'L'),(111,5,'S'),(119,7,'S'),(127,4,'S'),
    (135,8,'L'),(143,6,'S'),(151,9,'L'),(160,5,'S'),(168,7,'L'),(176,4,'S'),
]

def scene_width(TW): return TW

def build_scene(t, TW):
    W = scene_width(TW); rows = []
    for row in range(SCENE_H):
        if row >= GROUND_ROW:
            rows.append([('▄',(6,40,24)) if row==GROUND_ROW else (' ',(3,20,12))]*W)
            continue
        line = list([(' ',(4,15,28))]*W)
        for c in range(W):
            w1 = math.sin(c*.06+t*.35)*.5+math.sin(c*.025+t*.18+1.8)*.5
            w2 = math.sin(c*.04+t*.22+3.)*.5+math.sin(c*.08+t*.28+.5)*.5
            i  = (w1*.55+w2*.45)*.5+.5; i *= 1.-(row/GROUND_ROW)*.5
            line[c] = (' ',(int(4+i*16),int(60+i*150),int(80+i*140)))
        wr1 = 2+math.sin(t*.25+.5)*.8; wr2 = 5+math.sin(t*.2+2.)*.8
        for c in range(W):
            woff = math.sin(c*.08+t*.4)*1.2
            if abs(row-wr1-woff)<.9:       line[c]=('~',(20,210,170))
            elif abs(row-wr2-woff*.8)<.7:  line[c]=('~',(10,160,180))
        for c in range(W):
            sid=(c*7+13)%17; sr=sid%(GROUND_ROW-1)
            if sr==row and (c*11+sid)%9==0:
                bv=int(100+abs(math.sin(t*1.3+c*.6+sid))*155)
                line[c]=('.',(bv,min(255,bv+20),bv))
        rfg = GROUND_ROW-row
        for cx,th,st in TREES:
            if cx>=W or rfg<1 or rfg>th: continue
            if rfg==1:
                if cx<W: line[cx]=('|',(8,55,30))
                continue
            hw=max(0,round((1.-rfg/th)*th*(.38 if st=='L' else .28)))
            for dc in range(-hw,hw+1):
                c=cx+dc
                if c<0 or c>=W: continue
                if dc==0 and rfg==th:  line[c]=('^',(10,75,38))
                elif abs(dc)==hw:      line[c]=('/' if dc<0 else '\\',(8,58,30))
                else:                  line[c]=('#',(6,48,24))
        rows.append(line)
    return rows

def render_scene(rows):
    out = []
    for row in rows:
        s,prev='',None
        for ch,col in row:
            if col!=prev: s+=fg(*col); prev=col
            s+=ch
        out.append(s+R())
    return out

# ── Right column: live sys stats ──────────────────────────────────────────────

def mkbar(pct, width=12):
    filled = round(pct/100*width)
    return '█'*filled+'░'*(width-filled)

def val_col(pct):
    if pct>80: return (220,80,60)
    if pct>50: return (220,180,50)
    return (50,200,130)

def build_sys_lines(t):
    cpu_p = get_cpu_pct()
    gpu_p = get_gpu_pct()
    ru, rt = get_ram()
    ram_p = (ru/rt*100) if rt else 0

    sep = fg(30,60,45)+" | "+R()

    def kv(label, value_str, vcol=None):
        lc = fg(15,80,60)
        vc = fg(*vcol) if vcol else fg(140,200,170)
        return lc+f"{label:<8}"+sep+vc+value_str+R()

    lines = []
    lines.append(kv("RAM",   f"{ru}/{rt} MB  "+mkbar(ram_p), val_col(ram_p)))
    lines.append(kv("CPU",   _CPU_MODEL))
    lines.append(kv("CPU %", f"{cpu_p:5.1f}%  "+mkbar(cpu_p), val_col(cpu_p)))
    lines.append(kv("GPU",   _GPU_MODEL))
    if gpu_p is not None:
        lines.append(kv("GPU %", f"{gpu_p:5.1f}%  "+mkbar(gpu_p), val_col(gpu_p)))
    else:
        lines.append(kv("GPU %", "N/A", (80,80,80)))
    lines.append(kv("Kernel", _KERNEL, (100,180,200)))
    return lines

# ── Two-column info panel ─────────────────────────────────────────────────────

LEFT_W = 52  # visible chars reserved for left column

def build_distro_line(i, label, value, t):
    wave = math.sin(t*.35+i*1.0)*.5+.5
    lg=int(70+wave*70); vg=int(160+wave*70)
    return fg(15,lg,80)+f"{label:<10}"+fg(30,60,45)+" | "+fg(40,vg,140)+value+R()

def render_info_panel(distro_shown, t):
    left_lines  = [build_distro_line(i,l,v,t) for i,(l,v) in enumerate(distro_shown)]
    right_lines = build_sys_lines(t)

    wave = math.sin(t*.4)*.5+.5
    hdr_g = int(120+wave*80)

    def hdr(text):
        return fg(20,hdr_g,100)+B()+text+R()

    # Header row: "[ Software ]" left, "[ Hardware ]" right
    left_hdr  = "  " + hdr("[ Software ]")
    right_hdr = hdr("[ Hardware ]")
    lines = [ pad_to(left_hdr, 2+LEFT_W) + "  " + right_hdr ]

    # Blank line under each header
    lines.append("")

    n = max(len(left_lines), len(right_lines))
    for i in range(n):
        left  = left_lines[i]  if i < len(left_lines)  else ""
        right = right_lines[i] if i < len(right_lines) else ""
        lines.append("  " + pad_to(left, LEFT_W) + "  " + right)

    return lines

# ── Title & tagline ───────────────────────────────────────────────────────────

def render_title(shown, t):
    lines = []
    for i, line in enumerate(shown):
        out = ''
        for ci, ch in enumerate(line):
            if ch==' ': out+=ch; continue
            wave=math.sin(ci*.12+t*.8+i*.6)*.5+.5
            out+=fg(int(8+wave*20),int(150+wave*100),int(140+wave*100))+B()+ch+R()
        lines.append(out)
    return lines

def render_tagline(t):
    words=["Lightweight.","Featured.","Novel."]; out='  '
    for i,w in enumerate(words):
        wave=math.sin(t*.5+i*1.4)*.5+.5
        out+=fg(int(20+wave*30),int(130+wave*100),int(120+wave*100))+DIM()+w+R()+'   '
    return out

# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    hide_cur(); clr()

    start=time.time(); frame_dt=1/60
    prev_size = (0, 0)

    while running:
        t0=time.time(); t=t0-start

        # Re-read terminal size every frame; clear on resize
        TW, TH = term_size()
        if (TW, TH) != prev_size:
            clr()
            prev_size = (TW, TH)

        scene_rows = build_scene(t, TW)
        out_lines  = render_scene(scene_rows)
        out_lines.append(fg(10,40,30)+'─'*scene_width(TW)+R())
        out_lines.append('')
        out_lines += render_title(TITLE_BIG, t)
        out_lines.append(render_tagline(t))
        out_lines.append('')
        out_lines += render_info_panel(DISTRO_ROWS, t)

        # Build entire frame as one write — overwrite in place, no erase flicker
        buf = f"{ESC}?25l"   # keep cursor hidden
        buf += pos(1,1)
        for i, line in enumerate(out_lines):
            if i >= TH-1: break
            # Strip trailing reset if present, then re-add, then pad to full width
            # so old characters are overwritten and color doesn't bleed into padding
            stripped = line.rstrip()
            visible_w = vis(stripped)
            padding = max(0, TW - visible_w)
            buf += stripped + R() + ' '*padding + "\r\n"
        # Overwrite remaining rows with spaces
        blank = ' '*TW + "\r\n"
        for i in range(len(out_lines), TH-1):
            buf += blank

        sys.stdout.write(buf); sys.stdout.flush()
        sleep = frame_dt-(time.time()-t0)
        if sleep > 0: time.sleep(sleep)

    show_cur(); clr()
    print(R()+"bye.")

if __name__=='__main__':
    main()