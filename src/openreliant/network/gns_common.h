#pragma once

#include <steam/steamnetworkingsockets.h>
#include <steam/isteamnetworkingutils.h>
#include <cstring>

namespace openreliant::gns {
inline bool require_encryption(ISteamNetworkingUtils *utils) {
    // Standalone GNS needs this setting for direct IP. Check the authenticated
    // identity before admitting a connection.
    return utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_IP_AllowWithoutAuth, 1) &&
           utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_Unencrypted, 0);
}

inline const char *authenticated_identity(const SteamNetConnectionInfo_t &info) {
    constexpr int unsafe = k_nSteamNetworkConnectionInfoFlags_Unauthenticated |
                           k_nSteamNetworkConnectionInfoFlags_Unencrypted;
    return info.m_nFlags & unsafe ? nullptr : info.m_identityRemote.GetGenericString();
}

inline bool receive_limits(int max_message, int queued_messages, int queued_bytes) {
    auto *utils = SteamNetworkingUtils();
    return utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_RecvMaxMessageSize, max_message) &&
           utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_RecvBufferMessages, queued_messages) &&
           utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_RecvBufferSize, queued_bytes);
}

inline bool send(uint32_t conn, uint16_t lane, const uint8_t *bytes, int size, bool reliable) {
    auto *message = SteamNetworkingUtils()->AllocateMessage(size);
    if (!message) return false;
    std::memcpy(message->m_pData, bytes, size);
    message->m_conn = conn;
    message->m_idxLane = lane;
    message->m_nFlags = reliable ? k_nSteamNetworkingSend_ReliableNoNagle
                                : k_nSteamNetworkingSend_UnreliableNoNagle;
    int64 result;
    SteamNetworkingSockets()->SendMessages(1, &message, &result, true);
    return result > 0;
}

inline int receive(uint32_t conn, uint8_t *bytes, int capacity, uint16_t &lane) {
    SteamNetworkingMessage_t *message;
    const int count = SteamNetworkingSockets()->ReceiveMessagesOnConnection(conn, &message, 1);
    if (count <= 0) return count;
    const int size = message->m_cbSize;
    if (size > 0 && size <= capacity) {
        std::memcpy(bytes, message->m_pData, size);
        lane = message->m_idxLane;
    }
    message->Release();
    return size > 0 && size <= capacity ? size : -1;
}
}
