# Multiplayer transport probe

The [headless probe](../../examples/transport-probe) exercises the standalone
GameNetworkingSockets library over encrypted UDP. It is a separate executable for evaluating the
[host-owned network model](https://github.com/OpenReliant/openreliant/issues/954). The game and
its public modding API have no dependency on it.

A host and two pilots run as separate processes. The pilots send opposite controls and acknowledge
the latest snapshot they applied. The host advances two positions at 25 ticks per second and sends
both positions in each snapshot. Each pilot checks them against its controls and the host's tick
number. A late snapshot cannot replace a newer one. These positions and messages are test data.

The host queues 64 KiB of reliable background traffic per pilot and sends one reliable recall to
the first pilot. Flight updates and mission events have separate lanes at the same priority.
Background traffic has a lower priority. The probe caps the send rate at 64 KiB/s per connection
and simulates 8% outgoing packet loss, 20 ms of delay and 12% reordering with an extra 30 ms of
delay. Both pilots must apply snapshots during the burst, receive every background message in
order and receive exactly the number of recalls the host assigned them. Each pilot reports that
it finished, waits for the host's receipt and confirms it. The host can finish as soon as both
pilots confirm, even if a relay delays the connection close notifications.

The host reports the time between sending a snapshot and receiving a pilot's acknowledgement
that it applied it. This includes the return trip and the wait for the next input message. All
times in that measurement come from the host's clock. Each pilot also reports how many snapshots
it applied. When the loopback runner starts all three processes on one machine, they share the
system's monotonic clock. Each pilot then reports the 95th percentile and maximum snapshot age at
the time it applied the update.

## Run it

On a Unix build machine, install Zig 0.17, Git, patch, CMake, Ninja, Make, Perl, a native C++ compiler
and Python 3.9 or newer with the `cryptography` package (version 40 or newer). Apple targets need
the macOS SDK. From the repository root, pick a target and a scratch directory outside the checkout.
For example, on an Apple silicon Mac:

```sh
probe=examples/transport-probe
work="$(mktemp -d)"
target=aarch64-macos.15.0
python3 "$probe/build.py" "$work" "$target"
zig test "$probe/wire.zig"
python3 "$probe/loopback.py" "$work/$target/probe/transport-probe" "$work/identities"
```

The build script accepts x86_64 and aarch64 for Windows GNU, Linux GNU with glibc 2.31, and
macOS 15. Its `--help` lists the target names. Reuse the scratch directory to share the pinned
sources and native Protobuf compiler across targets. The script builds Protobuf 3.21.12 for the
host compiler and the target runtime, GameNetworkingSockets 1.6.1, and OpenSSL 3.5.9 on Linux
and macOS. Windows uses BCrypt. The OpenSSL build uses portable C with assembly disabled. Production dependency versions,
CPU throughput and reproducible release packaging are tracked in
[#1405](https://github.com/OpenReliant/openreliant/issues/1405).

Each build trusts the public key in the scratch directory's `identities/root.pub`. The three
`.cert` files contain separate private keys and signed identities that expire after one day.
The build discards the test authority's signing key after issuing them. To renew the set, move
the `identities` directory aside and rebuild each peer against the new root. The standalone
listener requires the library to allow an unauthenticated handshake. The probe admits a connection
only after the library reports encryption and a trusted certificate and the peer presents the
expected identity. The loopback runner checks that a pilot rejects a valid signature for a
different host before running the workload.

To try a routed connection, run the host on its machine with `transport-probe host ADDRESS:PORT host.cert`.
Run `transport-probe pilot1 HOST:PORT pilot1.cert` and `transport-probe pilot2 HOST:PORT pilot2.cert`
on the clients with their own credentials from the same set. Start both clients within 30 seconds.
The probe opens UDP sockets, runs without a window or audio device, and exits after the exchange.

## Trace direct ICE

Run the same workload over native ICE with a STUN server of your choice. Use an explicit port
for each server. The probe accepts a comma-separated server list. It enables local and public
candidates and disables relay candidates. To run a same-machine control, set `STUN` to the
server's hostname and port and run:

```sh
python3 "$probe/direct.py" "$work" "$target" "$STUN"
```

For a two-site test, place the host binary and its own certificate from the same build set on
the second machine. Start the host through a command that pipes standard input and output. For
example, with those two files in the remote working directory:

```sh
python3 "$probe/direct.py" "$work" "$target" "$STUN" \
    ssh -T "$REMOTE" "./transport-probe host ice:$STUN host.cert"
```

The runner checks each signal with the pinned Protobuf schema. It refuses application messages
and counts the candidate types it forwards. The transport reports when it sends a discovery
request, reads a mapped address, or gets a STUN error or timeout. Request counts include
retries and packets subject to simulated loss. A mapping that matches the interface already
has a host candidate. A different mapping can appear in a signal as `srflx`. Each authenticated
peer reports when it connects directly. The runner exits unsuccessfully if a peer fails and
prints the candidate counts even when no route connects.

On two independent networks, the tested STUN service returned error 420 (unknown attribute)
to native ICE. All three peers advertised only host candidates and the workload timed out.
A separate binding request to the same service received a mapped address. Adding only the
`MAPPED-ADDRESS` attribute to that request reproduced error 420, and the reply named that
attribute. With a controlled responder on one machine, all three peers accepted and advertised
a mapping and the workload completed. Cross-network TURN and automatic relay fallback completed
in the earlier relay test. Direct punchthrough remains open in
[#1404](https://github.com/OpenReliant/openreliant/issues/1404).
