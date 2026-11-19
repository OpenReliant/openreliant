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

# Trace native ICE in a build-local copy of the pinned translation unit.
set(clientlib "${GNS_SOURCE}/src/steamnetworkingsockets/clientlib")
set(ice_source "${clientlib}/steamnetworkingsockets_ice_client.cpp")
set(trace_source "${CMAKE_CURRENT_BINARY_DIR}/ice-trace.cpp")
find_program(PATCH patch REQUIRED)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${ice_source}" ice-trace.patch)
execute_process(
    COMMAND "${PATCH}" -s -F 0 -o "${trace_source}" "${ice_source}" -i "${CMAKE_CURRENT_SOURCE_DIR}/ice-trace.patch"
    COMMAND_ERROR_IS_FATAL ANY)
set_source_files_properties("${ice_source}" TARGET_DIRECTORY GameNetworkingSockets_s PROPERTIES HEADER_FILE_ONLY TRUE)
target_sources(GameNetworkingSockets_s PRIVATE "${trace_source}")
set_source_files_properties("${trace_source}" TARGET_DIRECTORY GameNetworkingSockets_s
    PROPERTIES INCLUDE_DIRECTORIES "${clientlib}")

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
add_executable(transport-probe transport.cpp ice.cpp "${object}")
target_link_libraries(transport-probe PRIVATE GameNetworkingSockets::static)
