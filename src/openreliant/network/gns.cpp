// The transport owns sockets. Zig owns admission, input validation and the simulation.
#include "gns_common.h"
#if defined(_WIN32)
#include <conio.h>
#else
#include <poll.h>
#include <unistd.h>
#endif

enum class Status : int { incoming, authenticated, closed };
extern "C" void session_status(uint32_t conn, Status status, const char *identity);
extern "C" bool OpenReliant_SetTransportRoot(const char *key, size_t size);

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
            else
                session_status(conn, Status::closed, nullptr);
            break;
        }
        case k_ESteamNetworkingConnectionState_ClosedByPeer:
        case k_ESteamNetworkingConnectionState_ProblemDetectedLocally:
            session_status(conn, Status::closed, nullptr);
            break;
        default:
            break;
    }
}

extern "C" bool session_init(const char *root, size_t root_size,
                             const uint8_t *certificate, int size, int max_message) {
    SteamNetworkingErrMsg error{};
    if (!GameNetworkingSockets_Init(nullptr, error)) return false;
    auto *utils = SteamNetworkingUtils();
    const bool configured =
        OpenReliant_SetTransportRoot(root, root_size) &&
        openreliant::gns::require_encryption(utils) &&
        openreliant::gns::receive_limits(max_message, queued_messages, queued_bytes) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_SendBufferSize, queued_bytes) &&
        utils->SetGlobalCallback_SteamNetConnectionStatusChanged(changed) &&
        SteamNetworkingSockets()->SetCertificate(certificate, size, error);
    if (!configured) GameNetworkingSockets_Kill();
    return configured;
}

extern "C" void session_deinit() { GameNetworkingSockets_Kill(); }

extern "C" uint32_t session_open(const char *address, bool host) {
    SteamNetworkingIPAddr endpoint;
    if (!endpoint.ParseString(address) || !endpoint.m_port) return 0;
    auto *net = SteamNetworkingSockets();
    if (host) return net->CreateListenSocketIP(endpoint, 0, nullptr);
    return net->ConnectByIPAddress(endpoint, 0, nullptr);
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
