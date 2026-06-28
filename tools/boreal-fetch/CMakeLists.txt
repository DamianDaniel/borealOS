cmake_minimum_required(VERSION 3.16)
project(boreal-fetch C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_FLAGS_RELEASE "-O2 -march=native -pipe")

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_executable(boreal-fetch src/main.c)
target_link_libraries(boreal-fetch m pthread)

install(TARGETS boreal-fetch DESTINATION bin)
