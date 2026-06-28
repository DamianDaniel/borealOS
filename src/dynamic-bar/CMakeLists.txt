cmake_minimum_required(VERSION 3.16)
project(BorealDynamicBar LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick WaylandClient)

# Set Qt policies to suppress warnings
qt_policy(SET QTP0001 NEW) # Use ':/qt/qml/' as the default resource prefix
qt_policy(SET QTP0004 NEW) # Require qmldir files for extra directories

# Define the QML module as a SHARED library so it becomes a plugin
qt_add_qml_module(BorealDynamicBar
    URI org.borealos.components
    VERSION 1.0
    PLUGIN_TARGET BorealDynamicBarPlugin
    SOURCES
        src/systemstatus.h
    QML_FILES
        qml/main.qml
    OUTPUT_DIRECTORY org/borealos/components
)

# Ensure it's in the output directory
set_target_properties(BorealDynamicBarPlugin PROPERTIES 
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/org/borealos/components"
)

# Now define a separate launcher executable
add_executable(BorealDynamicBarLauncher
    src/Main.cpp
)

target_link_libraries(BorealDynamicBarLauncher PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
)

target_link_libraries(BorealDynamicBar PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::WaylandClient
)

target_include_directories(BorealDynamicBar PRIVATE src)
target_include_directories(BorealDynamicBarLauncher PRIVATE src)