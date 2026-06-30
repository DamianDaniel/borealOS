#ifndef BOREAL_CONFIG_H
#define BOREAL_CONFIG_H

#define BOREAL_CONFIG_DIR  "/etc/borealos"
#define BOREAL_CONFIG_FILE "/etc/borealos/apt-skin.conf"

int boreal_config_is_enabled(void);
int boreal_config_set_enabled(int enabled);

#endif
