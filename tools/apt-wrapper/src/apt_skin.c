#define _XOPEN_SOURCE 600
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pty.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include "theme.h"
#include "config.h"

#define REAL_APT "/usr/bin/apt"
#define LINE_BUF_SIZE 8192

static struct termios orig_termios;
static int have_orig_termios = 0;

static void restore_terminal(void) {
    if (have_orig_termios) {
        tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
    }
}

static void enable_raw_mode(void) {
    if (!isatty(STDIN_FILENO)) return;
    if (tcgetattr(STDIN_FILENO, &orig_termios) != 0) return;
    have_orig_termios = 1;

    struct termios raw = orig_termios;
    raw.c_lflag &= ~(ICANON | ECHO | ISIG);
    raw.c_iflag &= ~(IXON | ICRNL);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

static void emit_styled(const char *buf, size_t len, char sep) {
    const char *color = boreal_classify_line(buf, len);
    if (color) {
        fwrite(color, 1, strlen(color), stdout);
    }
    fwrite(buf, 1, len, stdout);
    if (color) {
        fwrite(C_RESET, 1, strlen(C_RESET), stdout);
    }
    if (sep) {
        fputc(sep, stdout);
    }
    fflush(stdout);
}

static void pump_master_output(int master) {
    static char acc[LINE_BUF_SIZE];
    static size_t acc_len = 0;

    char chunk[4096];
    ssize_t n = read(master, chunk, sizeof(chunk));
    if (n <= 0) {
        if (acc_len > 0) {
            emit_styled(acc, acc_len, 0);
            acc_len = 0;
        }
        return;
    }

    for (ssize_t i = 0; i < n; i++) {
        char c = chunk[i];
        if (c == '\n' || c == '\r') {
            emit_styled(acc, acc_len, c);
            acc_len = 0;
        } else if (acc_len < sizeof(acc) - 1) {
            acc[acc_len++] = c;
        }
    }
}

static int run_skinned(int argc, char **argv) {
    boreal_print_banner();

    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != 0) {
        memset(&ws, 0, sizeof(ws));
        ws.ws_row = 24;
        ws.ws_col = 80;
    }

    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        perror("forkpty");
        execv(REAL_APT, argv);
        return 1;
    }

    if (pid == 0) {
        execv(REAL_APT, argv);
        _exit(127);
    }

    enable_raw_mode();

    int status = 0;
    int child_running = 1;

    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(master, &rfds);
        FD_SET(STDIN_FILENO, &rfds);
        int maxfd = master > STDIN_FILENO ? master : STDIN_FILENO;

        struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
        int ready = select(maxfd + 1, &rfds, NULL, NULL, &tv);

        if (ready > 0) {
            if (FD_ISSET(master, &rfds)) {
                pump_master_output(master);
            }
            if (FD_ISSET(STDIN_FILENO, &rfds)) {
                char in[256];
                ssize_t n = read(STDIN_FILENO, in, sizeof(in));
                if (n > 0) {
                    write(master, in, n);
                }
            }
        }

        if (child_running) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid) {
                child_running = 0;
            }
        } else {
            pump_master_output(master);
            break;
        }
    }

    restore_terminal();
    close(master);

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}

int main(int argc, char **argv) {
    if (!boreal_config_is_enabled()) {
        execv(REAL_APT, argv);
        perror("execv");
        return 127;
    }

    if (!isatty(STDOUT_FILENO)) {
        execv(REAL_APT, argv);
        perror("execv");
        return 127;
    }

    return run_skinned(argc, argv);
}
