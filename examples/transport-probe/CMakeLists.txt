cmake_minimum_required(VERSION 3.24)
project(openreliant_transport_probe LANGUAGES C CXX)

# The probe has its own trust root and links its own copy of the transport.
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PROBE_ROOT_KEY}")
file(STRINGS "${PROBE_ROOT_KEY}" root_key LIMIT_COUNT 1)
set(BUILD_SHARED_LIB OFF CACHE BOOL "")
set(BUILD_STATIC_LIB ON CACHE BOOL "")
add_subdirectory("${GNS_SOURCE}" gns)
target_compile_definitions(GameNetworkingSockets_s PRIVATE
    STEAMNETWORKINGSOCKETS_HARDCODED_ROOT_CA_KEY="${root_key}")

find_program(ZIG zig REQUIRED)
if(PROBE_ZIG_TARGET)
    set(target_args -target "${PROBE_ZIG_TARGET}")
elseif(CMAKE_CROSSCOMPILING)
    message(FATAL_ERROR "Set PROBE_ZIG_TARGET to the C++ compiler's target")
endif()
set(object "${CMAKE_CURRENT_BINARY_DIR}/scenario${CMAKE_CXX_OUTPUT_EXTENSION}")
add_custom_command(OUTPUT "${object}"
    COMMAND "${ZIG}" build-obj "${CMAKE_CURRENT_SOURCE_DIR}/scenario.zig"
            -OReleaseSafe -fPIC ${target_args} "-femit-bin=${object}" -lc
    DEPENDS scenario.zig wire.zig VERBATIM)
add_executable(transport-probe transport.cpp "${object}")
target_link_libraries(transport-probe PRIVATE GameNetworkingSockets::static)
