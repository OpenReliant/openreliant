// The transport owns sockets. Zig owns admission, input validation and the simulation.
#include "gns_common.h"
#if defined(_WIN32)
#include <conio.h>
#else
#include <poll.h>
#include <unistd.h>
#endif

enum class Status : int { incoming, authenticated, closed, unverified, lost, dropped };
extern "C" void session_status(uint32_t conn, Status status, const char *identity);
extern "C" bool OpenReliant_SetTransportRoot(const char *key, size_t size);
extern "C" void OpenReliant_ClearTransportRoot();
extern "C" bool OpenReliant_SetTransportCertificate(const void *certificate, int size);

constexpr int dropped_for_lag = k_ESteamNetConnectionEnd_App_Min + 1;
constexpr int queued_messages = 32;
constexpr int queued_bytes = 4096;

static void changed(SteamNetConnectionStatusChangedCallback_t *event) {
    auto conn = event->m_hConn;
    const auto &info = event->m_info;
    switch (info.m_eState) {
        case k_ESteamNetworkingConnectionState_Connecting:
            if (info.m_hListenSocket != k_HSteamListenSocket_Invalid)
                session_status(conn, Status::incoming, nullptr);
            break;
        case k_ESteamNetworkingConnectionState_Connected: {
            if (const char *identity = openreliant::gns::authenticated_identity(info))
                session_status(conn, Status::authenticated, identity);
            else if ((info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Unauthenticated) &&
                     !(info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Unencrypted))
                session_status(conn, Status::unverified, nullptr);
            else
                session_status(conn, Status::closed, nullptr);
            break;
        }
        case k_ESteamNetworkingConnectionState_ClosedByPeer:
            session_status(conn, info.m_eEndReason == dropped_for_lag ? Status::dropped : Status::closed, nullptr);
            break;
        case k_ESteamNetworkingConnectionState_ProblemDetectedLocally:
            session_status(conn, Status::lost, nullptr);
            break;
        default:
            break;
    }
}

extern "C" bool session_set_certificate(const uint8_t *certificate, int size) {
    return OpenReliant_SetTransportCertificate(certificate, size);
}

extern "C" bool session_init(const char *root, size_t root_size,
                             const uint8_t *certificate, int size, int max_message) {
    SteamNetworkingErrMsg error{};
    if (!GameNetworkingSockets_Init(nullptr, error)) return false;
    auto *utils = SteamNetworkingUtils();
    const bool configured =
        (root ? OpenReliant_SetTransportRoot(root, root_size) : !certificate) &&
        openreliant::gns::require_encryption(utils) &&
        openreliant::gns::receive_limits(max_message, queued_messages, queued_bytes) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_SendBufferSize, queued_bytes) &&
        utils->SetGlobalCallback_SteamNetConnectionStatusChanged(changed) &&
        (!certificate || session_set_certificate(certificate, size));
    if (!configured) {
        GameNetworkingSockets_Kill();
        OpenReliant_ClearTransportRoot();
    }
    return configured;
}

extern "C" void session_deinit() {
    GameNetworkingSockets_Kill();
    OpenReliant_ClearTransportRoot();
}

extern "C" uint32_t session_open(const char *address, bool host) {
    SteamNetworkingIPAddr endpoint;
    if (!endpoint.ParseString(address) || !endpoint.m_port) return 0;
    auto *net = SteamNetworkingSockets();
    if (host) return net->CreateListenSocketIP(endpoint, 0, nullptr);
    return net->ConnectByIPAddress(endpoint, 0, nullptr);
}

extern "C" bool session_local_pair(uint32_t *server, uint32_t *client) {
    return SteamNetworkingSockets()->CreateSocketPair(server, client, false, nullptr, nullptr);
}

extern "C" bool session_peer_ip(uint32_t conn, uint8_t *address) {
    SteamNetConnectionInfo_t info{};
    if (!SteamNetworkingSockets()->GetConnectionInfo(conn, &info)) return false;
    std::memcpy(address, info.m_addrRemote.m_ipv6, sizeof(info.m_addrRemote.m_ipv6));
    return true;
}

extern "C" int session_ping_ms(uint32_t conn) {
    SteamNetConnectionRealTimeStatus_t status{};
    return SteamNetworkingSockets()->GetConnectionRealTimeStatus(conn, &status, 0, nullptr) ==
                   k_EResultOK
               ? status.m_nPing
               : -1;
}

extern "C" void session_listen_close(uint32_t listener) {
    SteamNetworkingSockets()->CloseListenSocket(listener);
}

extern "C" bool session_accept(uint32_t conn) {
    return SteamNetworkingSockets()->AcceptConnection(conn) == k_EResultOK;
}

extern "C" void session_close(uint32_t conn) {
    SteamNetworkingSockets()->CloseConnection(conn, 0, nullptr, false);
}

extern "C" void session_drop(uint32_t conn) {
    SteamNetworkingSockets()->CloseConnection(conn, dropped_for_lag, nullptr, false);
}

extern "C" void session_poll() { SteamNetworkingSockets()->RunCallbacks(); }

extern "C" bool session_send(uint32_t conn, const uint8_t *bytes, int size, bool reliable) {
    return openreliant::gns::send(conn, 0, bytes, size, reliable);
}

extern "C" int session_receive(uint32_t conn, uint8_t *bytes, int capacity) {
    uint16_t lane;
    return openreliant::gns::receive(conn, bytes, capacity, lane);
}

extern "C" uint8_t session_key() {
#if defined(_WIN32)
    return _kbhit() ? static_cast<uint8_t>(_getch()) : 0;
#else
    pollfd input{STDIN_FILENO, POLLIN, 0};
    uint8_t key = 0;
    if (poll(&input, 1, 0) == 1 && (input.revents & POLLIN)) {
        if (read(STDIN_FILENO, &key, 1) != 1) return 0;
    }
    return key;
#endif
}
