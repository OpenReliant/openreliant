#pragma once

namespace ice {
enum class Mode { direct, private_turn, relay_only };
bool open(const char *stun, bool host, Mode mode);
bool poll();
}
