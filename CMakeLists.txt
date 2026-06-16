cmake_minimum_required(VERSION 3.20)
project(NppZapGremlins VERSION 1.0.1 LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR        "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE  "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_library(NppZapGremlins SHARED src/ZapGremlins.mm)
target_include_directories(NppZapGremlins PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    src)
target_link_libraries(NppZapGremlins PRIVATE "-framework Cocoa")
target_compile_options(NppZapGremlins PRIVATE
    -Wall -Wno-unused-parameter
    -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(NppZapGremlins PROPERTIES PREFIX "" SUFFIX ".dylib")
# Stamp version into the dylib Mach-O current_version (Plugins Admin reads it).
target_link_options(NppZapGremlins PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/NppZapGremlins")
install(TARGETS NppZapGremlins DESTINATION "${PLUGIN_INSTALL_DIR}")
install(DIRECTORY resources/ DESTINATION "${PLUGIN_INSTALL_DIR}/resources"
    PATTERN ".DS_Store"  EXCLUDE
    PATTERN ".gitignore" EXCLUDE)
