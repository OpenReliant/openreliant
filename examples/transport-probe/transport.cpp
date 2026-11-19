// The probe uses only the public standalone API. All scenario state belongs to Zig.
#include <steam/steamnetworkingsockets.h>
#include <steam/isteamnetworkingutils.h>

#include "ice.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

extern "C" bool probe_connected(uint32_t connection, const char *identity, bool incoming);
extern "C" void probe_closed(uint32_t connection);
extern "C" int probe_run(const char *role, const char *address, bool shared_clock);

static bool using_ice;
static ice::Mode ice_mode = ice::Mode::direct;

static void status_changed(SteamNetConnectionStatusChangedCallback_t *event) {
    auto *net = SteamNetworkingSockets();
    const auto conn = event->m_hConn;
    const auto &info = event->m_info;
    const bool incoming = info.m_hListenSocket != k_HSteamListenSocket_Invalid;
    switch (info.m_eState) {
        case k_ESteamNetworkingConnectionState_Connecting:
            if (!incoming || net->AcceptConnection(conn) == k_EResultOK) return;
            break;
        case k_ESteamNetworkingConnectionState_Connected: {
            constexpr int unsafe = k_nSteamNetworkConnectionInfoFlags_Unauthenticated |
                                   k_nSteamNetworkConnectionInfoFlags_Unencrypted;
            constexpr int priorities[] = {0, 0, 1}; // Flight, mission events, background.
            const bool relayed = info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Relayed;
            if (using_ice && ((ice_mode == ice::Mode::direct && relayed) ||
                              (ice_mode == ice::Mode::relay_only && !relayed))) break;
            const char *identity = info.m_identityRemote.GetGenericString();
            if (!(info.m_nFlags & unsafe) && identity &&
                net->ConfigureConnectionLanes(conn, 3, priorities, nullptr) == k_EResultOK &&
                probe_connected(conn, identity, incoming)) {
                if (using_ice) std::fprintf(stderr, "ICE %s connected to %s\n", relayed ? "private TURN" : "direct UDP", identity);
                return;
            }
            break;
        }
        case k_ESteamNetworkingConnectionState_ClosedByPeer:
        case k_ESteamNetworkingConnectionState_ProblemDetectedLocally:
            probe_closed(conn);
            break;
        default:
            return;
    }
    net->CloseConnection(conn, 0, nullptr, false);
}

extern "C" bool probe_open(const char *address, bool host) {
    if (using_ice) return ice::open(address[3] ? address + 4 : nullptr, host, ice_mode);
    SteamNetworkingIPAddr endpoint;
    if (!endpoint.ParseString(address)) return false;
    auto *net = SteamNetworkingSockets();
    if (!host) return net->ConnectByIPAddress(endpoint, 0, nullptr) != k_HSteamNetConnection_Invalid;
    const auto socket = net->CreateListenSocketIP(endpoint, 0, nullptr);
    if (!socket || !net->GetListenSocketAddress(socket, &endpoint)) return false;
    std::printf("listening %u\n", unsigned(endpoint.m_port));
    std::fflush(stdout);
    return true;
}

extern "C" bool probe_send(uint32_t conn, uint16_t lane, const uint8_t *bytes, int size) {
    auto *message = SteamNetworkingUtils()->AllocateMessage(size);
    if (!message) return false;
    std::memcpy(message->m_pData, bytes, size);
    message->m_conn = conn;
    message->m_idxLane = lane;
    message->m_nFlags = lane == 0 ? k_nSteamNetworkingSend_UnreliableNoNagle
                                  : k_nSteamNetworkingSend_ReliableNoNagle;
    int64 result;
    SteamNetworkingSockets()->SendMessages(1, &message, &result, true);
    return result > 0;
}

extern "C" int probe_receive(uint32_t conn, uint8_t *bytes, int capacity, uint16_t *lane) {
    SteamNetworkingMessage_t *message;
    int count = SteamNetworkingSockets()->ReceiveMessagesOnConnection(conn, &message, 1);
    if (count <= 0) return count;
    int size = message->m_cbSize;
    if (size > 0 && size <= capacity) {
        std::memcpy(bytes, message->m_pData, size);
        *lane = message->m_idxLane;
    } else {
        size = -1;
    }
    message->Release();
    return size;
}

extern "C" bool probe_delivered(uint32_t conn) {
    SteamNetConnectionRealTimeStatus_t status;
    return SteamNetworkingSockets()->GetConnectionRealTimeStatus(conn, &status, 0, nullptr) == k_EResultOK &&
           status.m_cbPendingReliable == 0 && status.m_cbSentUnackedReliable == 0;
}

extern "C" int64_t probe_now() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
extern "C" bool probe_poll() {
    if (using_ice && !ice::poll()) return false;
    SteamNetworkingSockets()->RunCallbacks();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return true;
}

static bool set_certificate(const char *path, SteamNetworkingErrMsg &error) {
    // Read one complete credential and reject an oversized or unreadable file.
    unsigned char cert[4096];
    FILE *file = std::fopen(path, "rb");
    if (!file) return false;
    const size_t n = std::fread(cert, 1, sizeof(cert), file);
    const bool complete = n > 0 && std::feof(file) && !std::ferror(file);
    std::fclose(file);
    return complete && SteamNetworkingSockets()->SetCertificate(cert, int(n), error);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: transport-probe host|pilot1|pilot2|reject ADDRESS:PORT|ice[:STUN_LIST] CERT [--shared-clock] [--private-turn|--relay-only]\n");
        return 2;
    }
    using_ice = std::strcmp(argv[2], "ice") == 0 || std::strncmp(argv[2], "ice:", 4) == 0;
    bool shared_clock = false;
    for (int i = 4; i < argc; ++i) {
        if (!shared_clock && std::strcmp(argv[i], "--shared-clock") == 0) shared_clock = true;
        else if (using_ice && ice_mode == ice::Mode::direct && std::strcmp(argv[i], "--private-turn") == 0)
            ice_mode = ice::Mode::private_turn;
        else if (using_ice && ice_mode == ice::Mode::direct && std::strcmp(argv[i], "--relay-only") == 0)
            ice_mode = ice::Mode::relay_only;
        else return 2;
    }
    SteamNetworkingErrMsg error = {};
    if (!GameNetworkingSockets_Init(nullptr, error)) {
        std::fprintf(stderr, "initialisation failed: %s\n", error);
        return 1;
    }
    auto *utils = SteamNetworkingUtils();
    utils->SetDebugOutputFunction(using_ice ? k_ESteamNetworkingSocketsDebugOutputType_Msg : k_ESteamNetworkingSocketsDebugOutputType_Warning,
        [](ESteamNetworkingSocketsDebugOutputType, const char *message) {
            if (!using_ice || std::strncmp(message, "probe ICE ", 10) == 0)
                std::fprintf(stderr, "%s\n", message);
        });
    // Standalone GNS requires this to open a listener. The connected callback
    // checks both encryption and the authenticated identity before admitting a peer.
    int result = 1;
    if (set_certificate(argv[3], error) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_IP_AllowWithoutAuth, 1) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_Unencrypted, 0) &&
        utils->SetGlobalConfigValueFloat(k_ESteamNetworkingConfig_FakePacketLoss_Send, 8) &&
        utils->SetGlobalConfigValueFloat(k_ESteamNetworkingConfig_FakePacketReorder_Send, 12) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_FakePacketReorder_Time, 30) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_FakePacketLag_Send, 20) &&
        utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_SendRateMax, 64 * 1024) &&
        utils->SetGlobalCallback_SteamNetConnectionStatusChanged(status_changed)) {
        result = probe_run(argv[1], argv[2], shared_clock);
    } else {
        std::fprintf(stderr, "transport setup failed: %s\n", error);
    }
    GameNetworkingSockets_Kill();
    return result;
}
