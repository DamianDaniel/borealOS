#ifndef BOREAL_THEME_H
#define BOREAL_THEME_H

#include <stddef.h>

#define C_RESET   "\x1b[0m"
#define C_BOLD    "\x1b[1m"
#define C_GREEN   "\x1b[38;2;124;226;107m"
#define C_TEAL    "\x1b[38;2;79;179;201m"
#define C_SKY     "\x1b[38;2;120;205;221m"
#define C_DEEP    "\x1b[38;2;43;94;138m"
#define C_DARK    "\x1b[38;2;20;40;63m"
#define C_WHITE   "\x1b[97m"
#define C_RED     "\x1b[91m"
#define C_YELLOW  "\x1b[93m"

const char *boreal_classify_line(const char *buf, size_t len);
void boreal_print_banner(void);
void boreal_print_disabled_notice(void);

#endif
