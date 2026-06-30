#include "theme.h"
#include <stdio.h>
#include <string.h>

static int starts_with(const char *buf, size_t len, const char *prefix) {
    size_t plen = strlen(prefix);
    if (len < plen) return 0;
    return strncmp(buf, prefix, plen) == 0;
}

static int contains(const char *buf, size_t len, const char *needle) {
    if (len == 0) return 0;
    char tmp[2048];
    size_t n = len < sizeof(tmp) - 1 ? len : sizeof(tmp) - 1;
    memcpy(tmp, buf, n);
    tmp[n] = '\0';
    return strstr(tmp, needle) != NULL;
}

const char *boreal_classify_line(const char *buf, size_t len) {
    if (len == 0) return NULL;

    if (starts_with(buf, len, "E:")) return C_RED C_BOLD;
    if (starts_with(buf, len, "W:")) return C_YELLOW;
    if (starts_with(buf, len, "Get:")) return C_GREEN;
    if (starts_with(buf, len, "Fetched")) return C_GREEN;
    if (starts_with(buf, len, "Hit:")) return C_TEAL;
    if (starts_with(buf, len, "Ign:")) return C_YELLOW;
    if (starts_with(buf, len, "Reading package lists")) return C_TEAL;
    if (starts_with(buf, len, "Building dependency tree")) return C_TEAL;
    if (starts_with(buf, len, "Reading state information")) return C_TEAL;
    if (starts_with(buf, len, "Setting up")) return C_SKY;
    if (starts_with(buf, len, "Unpacking")) return C_SKY;
    if (starts_with(buf, len, "Preparing to unpack")) return C_SKY;
    if (starts_with(buf, len, "Selecting previously unselected package")) return C_SKY;
    if (starts_with(buf, len, "Processing triggers")) return C_DEEP;
    if (starts_with(buf, len, "The following NEW packages")) return C_GREEN C_BOLD;
    if (starts_with(buf, len, "The following packages will be REMOVED")) return C_RED;
    if (starts_with(buf, len, "Do you want to continue")) return C_WHITE C_BOLD;
    if (contains(buf, len, "Progress:")) return C_TEAL;
    if (contains(buf, len, "is already the newest version")) return C_TEAL;
    if (contains(buf, len, "upgraded,")) return C_GREEN;

    return NULL;
}

void boreal_print_banner(void) {
    fprintf(stdout,
        C_GREEN "   /\\  " C_TEAL "   /\\  " C_SKY "   /\\\n" C_RESET
        C_GREEN "  /  \\ " C_TEAL "  /  \\ " C_SKY "  /  \\   " C_WHITE C_BOLD "BorealOS" C_RESET C_DEEP " apt" C_RESET "\n"
        C_GREEN " /----\\" C_TEAL " /----\\" C_SKY " /----\\  " C_DEEP "lightweight. featured. novel." C_RESET "\n"
        "\n"
    );
    fflush(stdout);
}

void boreal_print_disabled_notice(void) {
    fprintf(stderr, C_YELLOW "boreal-apt skin is disabled, falling back to plain apt\n" C_RESET);
    fflush(stderr);
}
