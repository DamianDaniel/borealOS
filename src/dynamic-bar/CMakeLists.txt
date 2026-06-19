cmake_minimum_required(VERSION 3.16)
project(MyDynamicBar LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)

# Create your executable with just the C++ sources
add_executable(BorealDynamicBar
        src/Main.cpp
)

# Define the QML module (This replaces qt_add_resources and manual registration!)
qt_add_qml_module(BorealDynamicBar
        URI org.borealos.components
        VERSION 1.0
        SOURCES
        src/systemstatus.h # Qt will scan this for QML_ELEMENT
        QML_FILES
        qml/main.qml
)

target_link_libraries(BorealDynamicBar PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
)

target_include_directories(BorealDynamicBar PRIVATE src)