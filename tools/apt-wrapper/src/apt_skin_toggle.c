#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "theme.h"
#include "config.h"

static void print_usage(const char *prog) {
    fprintf(stderr, "usage: %s [on|off|status]\n", prog);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        print_usage(argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "status") == 0) {
        int enabled = boreal_config_is_enabled();
        printf(C_WHITE "boreal-apt is currently " C_RESET "%s%s" C_RESET "\n",
               enabled ? C_GREEN : C_YELLOW,
               enabled ? "on" : "off");
        return 0;
    }

    if (strcmp(argv[1], "on") == 0 || strcmp(argv[1], "off") == 0) {
        int enabled = strcmp(argv[1], "on") == 0;
        if (geteuid() != 0) {
            fprintf(stderr, C_RED "boreal-apt must be run as root to change this setting\n" C_RESET);
            return 1;
        }
        if (boreal_config_set_enabled(enabled) != 0) {
            fprintf(stderr, C_RED "failed to write config\n" C_RESET);
            return 1;
        }
        printf("%sboreal-apt is now %s%s\n",
               enabled ? C_GREEN : C_YELLOW,
               enabled ? "on" : "off",
               C_RESET);
        return 0;
    }

    print_usage(argv[0]);
    return 1;
}
