cmake_minimum_required(VERSION 3.10)
project(borealos-apt-skin C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

include_directories(include)

add_executable(apt
    src/apt_skin.c
    src/theme.c
    src/config.c
)
target_link_libraries(apt util)

add_executable(boreal-apt
    src/apt_skin_toggle.c
    src/theme.c
    src/config.c
)

install(TARGETS apt RUNTIME DESTINATION /usr/local/bin)
install(TARGETS boreal-apt RUNTIME DESTINATION /usr/local/bin)
