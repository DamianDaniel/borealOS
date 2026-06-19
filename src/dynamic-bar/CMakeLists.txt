cmake_minimum_required(VERSION 3.16)
project(BorealDynamicBar LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Enable automatic compilation handling for Qt
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)

# Define the executable and include source files
add_executable(MyDynamicBar
        src/main.cpp
        src/window_manager.cpp
        src/window_manager.h
        qml/main.qml # Directly embedding QML into the binary build
)

# Link Qt6 libraries
target_link_libraries(MyDynamicBar PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
)

# Tell Qt where to bundle the QML resources
qt_add_resources(MyDynamicBar "qml"
        PREFIX "/qt/qml"
        FILES qml/main.qml
)