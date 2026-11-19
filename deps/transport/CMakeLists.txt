cmake_minimum_required(VERSION 3.24)
project(openreliant_transport LANGUAGES C CXX)

set(BUILD_SHARED_LIB OFF CACHE BOOL "")
set(BUILD_STATIC_LIB ON CACHE BOOL "")
add_subdirectory("${GNS_SOURCE}" gns)

# Build the certificate store with a runtime trust root. The library has no built-in trusted key.
set(certstore_dir "${GNS_SOURCE}/src/steamnetworkingsockets")
set(certstore "${certstore_dir}/steamnetworkingsockets_certstore.cpp")
set(patched "${CMAKE_CURRENT_BINARY_DIR}/steamnetworkingsockets_certstore.cpp")
set(root_patch "${CMAKE_CURRENT_SOURCE_DIR}/runtime-root.patch")
find_program(PATCH patch REQUIRED)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${certstore}" "${root_patch}")
execute_process(
    COMMAND "${PATCH}" -s -F 0 -o "${patched}" "${certstore}" -i "${root_patch}"
    COMMAND_ERROR_IS_FATAL ANY)
set_source_files_properties("${certstore}" TARGET_DIRECTORY GameNetworkingSockets_s PROPERTIES HEADER_FILE_ONLY TRUE)
target_sources(GameNetworkingSockets_s PRIVATE "${patched}")
set_source_files_properties("${patched}" TARGET_DIRECTORY GameNetworkingSockets_s
    PROPERTIES INCLUDE_DIRECTORIES "${certstore_dir}")
