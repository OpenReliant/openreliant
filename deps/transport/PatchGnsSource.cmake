find_program(PATCH patch REQUIRED)

# Patch a build-local copy so the pinned dependency checkout stays pristine.
function(openreliant_patch_gns_source relative patch_file)
    set(original "${GNS_SOURCE}/${relative}")
    get_filename_component(directory "${original}" DIRECTORY)
    get_filename_component(name "${original}" NAME)
    set(patched "${CMAKE_CURRENT_BINARY_DIR}/${name}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${original}" "${patch_file}")
    execute_process(
        COMMAND "${PATCH}" -s -F 0 -o "${patched}" "${original}" -i "${patch_file}"
        COMMAND_ERROR_IS_FATAL ANY)
    set_source_files_properties("${original}" TARGET_DIRECTORY GameNetworkingSockets_s PROPERTIES HEADER_FILE_ONLY TRUE)
    target_sources(GameNetworkingSockets_s PRIVATE "${patched}")
    set_source_files_properties("${patched}" TARGET_DIRECTORY GameNetworkingSockets_s
        PROPERTIES INCLUDE_DIRECTORIES "${directory}")
endfunction()

openreliant_patch_gns_source(src/steamnetworkingsockets/clientlib/csteamnetworkingsockets.cpp
    "${CMAKE_CURRENT_LIST_DIR}/local-certificate-key.patch")
# A host answers the LAN lists' queries on its game port.
openreliant_patch_gns_source(src/steamnetworkingsockets/clientlib/steamnetworkingsockets_udp.cpp
    "${CMAKE_CURRENT_LIST_DIR}/lan-query.patch")
