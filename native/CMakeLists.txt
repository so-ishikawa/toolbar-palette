cmake_minimum_required(VERSION 3.20)

# ── Max version ──────────────────────────────────────────────────
set(MAX_VERSION "2027" CACHE STRING "Target 3ds Max version (2023, 2024, 2025, 2026, 2027)")
message(STATUS "Building ToolPalette plugin for 3ds Max ${MAX_VERSION}")

project(ToolPalette VERSION 1.0.0 LANGUAGES CXX)

# 3ds Max 2027 SDK requires C++20; earlier versions use C++17.
if(MAX_VERSION GREATER_EQUAL 2027)
    set(CMAKE_CXX_STANDARD 20)
else()
    set(CMAKE_CXX_STANDARD 17)
endif()
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Max SDK ──────────────────────────────────────────────────────
if(NOT DEFINED MAXSDK_PATH)
    set(MAXSDK_PATH "C:/Program Files/Autodesk/3ds Max ${MAX_VERSION} SDK/maxsdk"
        CACHE PATH "Path to 3ds Max SDK")
endif()

if(NOT EXISTS "${MAXSDK_PATH}/include/max.h")
    message(FATAL_ERROR "Cannot find max.h at ${MAXSDK_PATH}/include/max.h")
endif()

# ── Sources ──────────────────────────────────────────────────────
add_library(ToolPalette SHARED src/toolpalette_plugin.cpp)

# Output as .gup directly into the toolbar-palette folder (alongside
# ToolPalette.ms / ToolPalette_Config.ms / qtres\), so the whole folder
# stays a single, portable, distributable unit.
set_target_properties(ToolPalette PROPERTIES
    SUFFIX ".gup"
    OUTPUT_NAME "ToolPalette"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/.."
    LIBRARY_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

target_sources(ToolPalette PRIVATE src/ToolPalette.def)

# ── Qt SDK (2027+ only, for native QResource registration) ────────
if(MAX_VERSION GREATER_EQUAL 2027)
    set(QT_SDK_PATH "C:/WorkSpace/SDK/Qt/6.8.3/msvc2022_64" CACHE PATH "Path to Qt SDK for native QResource registration")
    if(NOT EXISTS "${QT_SDK_PATH}/include/QtCore/qresource.h")
        message(FATAL_ERROR "Cannot find QtCore/qresource.h at ${QT_SDK_PATH}")
    endif()
endif()

# ── Includes ─────────────────────────────────────────────────────
target_include_directories(ToolPalette PRIVATE
    "${MAXSDK_PATH}/include"
)
if(MAX_VERSION GREATER_EQUAL 2027)
    target_include_directories(ToolPalette PRIVATE
        "${QT_SDK_PATH}/include"
        "${QT_SDK_PATH}/include/QtCore"
    )
endif()

# ── Preprocessor ─────────────────────────────────────────────────
target_compile_definitions(ToolPalette PRIVATE
    NOMINMAX
    _UNICODE UNICODE
    WIN32 _WIN32
    _USRDLL
    _CRT_SECURE_NO_WARNINGS
    MAX_SILENCE_DEPRECATED_MATRIX_BOOL_CTOR
    MAX_SDK_VERSION=${MAX_VERSION}
)

# ── Link ─────────────────────────────────────────────────────────
target_link_directories(ToolPalette PRIVATE
    "${MAXSDK_PATH}/lib/x64/Release"
)

target_link_libraries(ToolPalette PRIVATE
    core.lib
    maxutil.lib
    gup.lib
    Paramblk2.lib
    Maxscrpt.lib
    Geom.lib
    comctl32.lib
)
if(MAX_VERSION GREATER_EQUAL 2027)
    target_link_directories(ToolPalette PRIVATE "${QT_SDK_PATH}/lib")
    target_link_libraries(ToolPalette PRIVATE Qt6Core.lib)
    target_compile_definitions(ToolPalette PRIVATE QT_NO_KEYWORDS)
endif()

# ── MSVC ─────────────────────────────────────────────────────────
if(MSVC)
    target_compile_options(ToolPalette PRIVATE /W3 /MP /EHa /utf-8)
    if(MAX_VERSION GREATER_EQUAL 2027)
        # Qt6 headers check __cplusplus directly; MSVC only reports the true
        # standard version there when this flag is passed.
        target_compile_options(ToolPalette PRIVATE /Zc:__cplusplus)
    endif()
    set_property(TARGET ToolPalette PROPERTY MSVC_RUNTIME_LIBRARY
        "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()
