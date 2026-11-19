cmake_minimum_required(VERSION 3.24)
project(openreliant_transport LANGUAGES C CXX)

set(BUILD_SHARED_LIB OFF CACHE BOOL "")
set(BUILD_STATIC_LIB ON CACHE BOOL "")
add_subdirectory("${GNS_SOURCE}" gns)

include(PatchGnsSource.cmake)
# The release library has no built-in trusted key.
openreliant_patch_gns_source(src/steamnetworkingsockets/steamnetworkingsockets_certstore.cpp
    "${CMAKE_CURRENT_SOURCE_DIR}/runtime-root.patch")
