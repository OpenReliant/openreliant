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
include(../../deps/transport/PatchGnsSource.cmake)
# Configure and trace native ICE in a build-local copy of the pinned translation unit.
openreliant_patch_gns_source(src/steamnetworkingsockets/clientlib/steamnetworkingsockets_ice_client.cpp
    "${CMAKE_CURRENT_SOURCE_DIR}/native-ice.patch")

add_executable(transport-probe transport.cpp ice.cpp)
target_compile_features(transport-probe PRIVATE cxx_std_17)
if(PROBE_WORKLOAD_LIBRARY)
    target_link_libraries(transport-probe PRIVATE "${PROBE_WORKLOAD_LIBRARY}")
else()
    find_program(ZIG zig REQUIRED)
    if(PROBE_ZIG_TARGET)
        set(target_args -target "${PROBE_ZIG_TARGET}")
    elseif(CMAKE_CROSSCOMPILING)
        message(FATAL_ERROR "Set PROBE_ZIG_TARGET to the C++ compiler's target")
    endif()
    set(object "${CMAKE_CURRENT_BINARY_DIR}/scenario${CMAKE_CXX_OUTPUT_EXTENSION}")
    set(handshake_budget "${CMAKE_CURRENT_SOURCE_DIR}/../../src/openreliant/network/handshake_budget.zig")
    add_custom_command(OUTPUT "${object}"
        COMMAND "${ZIG}" build-obj -OReleaseSafe -fPIC ${target_args} -lc
                "-femit-bin=${object}" --dep host_simulation --dep handshake_budget
                "-Mroot=${CMAKE_CURRENT_SOURCE_DIR}/scenario.zig"
                -OReleaseSafe ${target_args} "-Mhost_simulation=${CMAKE_CURRENT_SOURCE_DIR}/toy.zig"
                -OReleaseSafe ${target_args} "-Mhandshake_budget=${handshake_budget}"
        DEPENDS scenario.zig socket.zig incoming_connections.zig toy.zig wire.zig "${handshake_budget}" VERBATIM)
    target_sources(transport-probe PRIVATE "${object}")
endif()
target_link_libraries(transport-probe PRIVATE GameNetworkingSockets::static)
