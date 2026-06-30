#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>

int boreal_config_is_enabled(void) {
    FILE *f = fopen(BOREAL_CONFIG_FILE, "r");
    if (!f) return 1;

    char line[128];
    int enabled = 1;
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = line;
        char *val = eq + 1;
        val[strcspn(val, "\r\n")] = '\0';
        if (strcmp(key, "enabled") == 0) {
            enabled = atoi(val);
        }
    }
    fclose(f);
    return enabled;
}

int boreal_config_set_enabled(int enabled) {
    if (mkdir(BOREAL_CONFIG_DIR, 0755) != 0 && errno != EEXIST) {
        return -1;
    }

    FILE *f = fopen(BOREAL_CONFIG_FILE, "w");
    if (!f) return -1;

    fprintf(f, "enabled=%d\n", enabled ? 1 : 0);
    fclose(f);
    return 0;
}
