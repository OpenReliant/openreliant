// The runner routes these messages between peers over a separate signalling channel.
#include "ice.h"
#include "incoming.h"
#include <steam/steamnetworkingsockets.h>
#include <steam/isteamnetworkingutils.h>
#include <steam/steamnetworkingcustomsignaling.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#ifdef _WIN32
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace ice {
namespace {
constexpr size_t max_signal = 16384;
std::string pending;

class Channel final : public ISteamNetworkingConnectionSignaling {
    const std::string peer;
public:
    explicit Channel(const char *name) : peer(name) {}
    bool SendSignal(HSteamNetConnection, const SteamNetConnectionInfo_t &, const void *data, int size) override {
        if (size <= 0 || size > int(max_signal)) return false;
        constexpr char hex[] = "0123456789abcdef";
        std::string line = "S " + peer + " ";
        line.reserve(line.size() + 2 * size + 1);
        const auto *bytes = static_cast<const unsigned char *>(data);
        for (int i = 0; i < size; ++i) {
            line += hex[bytes[i] >> 4];
            line += hex[bytes[i] & 15];
        }
        line += '\n';
        return std::fwrite(line.data(), 1, line.size(), stdout) == line.size() && std::fflush(stdout) == 0;
    }
    void Release() override { delete this; }
};

class Receiver final : public ISteamNetworkingSignalingRecvContext {
    ISteamNetworkingConnectionSignaling *OnConnectRequest(HSteamNetConnection conn, const SteamNetworkingIdentity &id, int port) override {
        const char *name = id.GetGenericString();
        if (port || !name || (std::strcmp(name, "pilot1") && std::strcmp(name, "pilot2"))) return nullptr;
        if (!probe_reserve_incoming(conn)) return nullptr;
        return new Channel(name);
    }
    void SendRejectionSignal(const SteamNetworkingIdentity &, const void *, int) override {}
};

int nibble(char digit) {
    if (digit >= '0' && digit <= '9') return digit - '0';
    if (digit >= 'a' && digit <= 'f') return digit - 'a' + 10;
    return -1;
}

bool dispatch() {
    if (pending.empty() || pending.size() % 2) return false;
    for (size_t i = 0; i < pending.size(); i += 2) {
        int high = nibble(pending[i]), low = nibble(pending[i + 1]);
        if (high < 0 || low < 0) return false;
        pending[i / 2] = char(high * 16 + low);
    }
    Receiver receiver;
    return SteamNetworkingSockets()->ReceivedP2PCustomSignal(pending.data(), int(pending.size() / 2), &receiver);
}
}

bool open(const char *stun, bool host, Mode mode) {
#ifndef _WIN32
    int flags = fcntl(STDIN_FILENO, F_GETFL);
    if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) < 0) return false;
#endif
    auto *utils = SteamNetworkingUtils();
    int candidates = k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_Public |
                     k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_Private;
    if (mode != Mode::direct) {
        // The native API treats commas as separators, including in usernames and passwords.
        const char *server = std::getenv("OPENRELIANT_TURN_SERVER");
        const char *user = std::getenv("OPENRELIANT_TURN_USERNAME");
        const char *password = std::getenv("OPENRELIANT_TURN_PASSWORD");
        for (const char *value : {server, user, password}) {
            if (!value || !*value || std::strchr(value, ',')) {
                std::fputs("Private TURN requires one server, username and password per peer.\n", stderr);
                return false;
            }
        }
        if (!utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_TURN_ServerList, server) ||
            !utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_TURN_UserList, user) ||
            !utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_TURN_PassList, password)) return false;
        if (mode == Mode::relay_only) candidates = 0;
        candidates |= k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_Relay;
    }
    constexpr char defaults[] = "stun.relay.metered.ca:80,stun.cloudflare.com:3478";
    if (!utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Implementation, 1) ||
        !utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Enable, candidates) ||
        !utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_STUN_ServerList, stun ? stun : defaults)) return false;

    auto *net = SteamNetworkingSockets();
    if (host) {
        if (!net->CreateListenSocketP2P(0, 0, nullptr)) return false;
        std::puts("READY");
        return std::fflush(stdout) == 0;
    }
    SteamNetworkingIdentity id;
    id.Clear();
    id.SetGenericString("host");
    return net->ConnectP2PCustomSignaling(new Channel("host"), &id, 0, 0, nullptr) != k_HSteamNetConnection_Invalid;
}

bool poll() {
    char buffer[4096];
#ifdef _WIN32
    HANDLE pipe = GetStdHandle(STD_INPUT_HANDLE);
    DWORD available, count;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) return false;
    if (!available) return true;
    if (!ReadFile(pipe, buffer, sizeof(buffer), &count, nullptr)) return false;
#else
    auto count = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (count < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
#endif
    for (decltype(count) i = 0; i < count; ++i) {
        if (buffer[i] == '\n') {
            if (!dispatch()) return false;
            pending.clear();
        } else {
            if (pending.size() == 2 * max_signal) return false;
            pending += buffer[i];
        }
    }
    return count > 0;
}
}
