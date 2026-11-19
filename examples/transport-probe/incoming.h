#pragma once

#include <cstdint>

// The poll thread owns the listener's reservations, including during ICE signalling.
extern "C" bool probe_reserve_incoming(std::uint32_t conn);
extern "C" bool probe_has_incoming(std::uint32_t conn);
extern "C" void probe_release_incoming(std::uint32_t conn);
