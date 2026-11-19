# Multiplayer transport probe

The [headless probe](../../examples/transport-probe) exercises the standalone
GameNetworkingSockets library over encrypted UDP. It is a separate executable for evaluating the
[host-owned network model](https://github.com/OpenReliant/openreliant/issues/954). The release build has no dependency on it.

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

Before opening a connection, the probe configures GameNetworkingSockets to limit the size of
each incoming message to the workload's packet buffer. Each peer can queue up to 128 messages
and 64 KiB of received data. The public host also needs to bound pending admissions and keep
serving other pilots when a client breaks the protocol. See
[#1432](https://github.com/OpenReliant/openreliant/issues/1432).

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

## Run the headless arena

The same workload can drive the engine's arena simulation for
[#954](https://github.com/OpenReliant/openreliant/issues/954). Use the same scratch directory
and target as above.

```sh
python3 "$probe/build.py" "$work" "$target" --arena
python3 "$probe/loopback.py" "$work/$target/arena-probe/transport-probe" "$work/identities"
```

The fixture sets up two ships with test stats and runs the mission clock and frame loop without
opening a window or reading game files. The host binds each authenticated connection to its
participant and ship. Only the host runs physics. Each client checks the two ships' positions in
the host's snapshots and confirms receipt. The ships accelerate and turn in opposite directions.
The clients also check the directed test event and background transfer under the same packet loss.

The probe format carries the two positions in full each step. It is private and intended for this
test. Arena setup from game files, new or replaced ship bindings and full session snapshots belong
to [#954](https://github.com/OpenReliant/openreliant/issues/954). Six Beacons state and notices
have their own check in [#1416](https://github.com/OpenReliant/openreliant/issues/1416).

## Check a late join in Six Beacons

Use the same scratch directory and target to run the headless objective test.

```sh
python3 "$probe/build.py" "$work" "$target" --six-beacons
python3 "$probe/loopback.py" "$work/$target/six-beacons-probe/transport-probe" \
    "$work/six-beacons-identities" --six-beacons
```

Two pilots enter a small test arena. Once the host simulation awards the first beacon, the
runner connects a third pilot who leaves before sending a join request. It then tries the same
identity with an incompatible protocol revision. The host replies with the required revision
and closes the connection. Both attempts leave the pilot slot free. The runner then starts a client that reports
a different OpenReliant release but uses the same protocol. Its first snapshot contains all six
beacons, their positions, and the carrier's participant and ship identities. The host then runs the carrier's destruction
order. All three clients must confirm that the same beacon is loose at its drop position.

The protocol revision is separate from the OpenReliant version. Bump it when a change
makes the wire format or the meaning of its messages incompatible. Matching the revision
is one admission check. Game content compatibility has its own checks under
[#956](https://github.com/OpenReliant/openreliant/issues/956).
This workload uses its own short-lived test identities. It sends complete objective snapshots
on the reliable lane at the pickup and drop. Live session delivery and client notices are
tracked in [#954](https://github.com/OpenReliant/openreliant/issues/954) and
[#1416](https://github.com/OpenReliant/openreliant/issues/1416).

## Try a routed connection

To try a routed connection, run the host on its machine with `transport-probe host ADDRESS:PORT host.cert`.
Run `transport-probe pilot1 HOST:PORT pilot1.cert` and `transport-probe pilot2 HOST:PORT pilot2.cert`
on the clients with their own credentials from the same set. Start both clients within 30 seconds.
The probe opens UDP sockets, runs without a window or audio device, and exits after the exchange.

## ICE servers and routes

The probe uses direct UDP by default. Public STUN helps each peer learn the address its router
gives it. The default list has two independent operators:

| Operator | UDP endpoint |
| --- | --- |
| [Metered](https://www.metered.ca/docs/turn-server-service/quickstart/) | `stun.relay.metered.ca:80` |
| [Cloudflare](https://developers.cloudflare.com/realtime/turn/faq/) | `stun.cloudflare.com:3478` |

Run the same-machine test with the defaults, replace the list with your own comma-separated
hosts and ports, or pass an empty string to use only local candidates:

```sh
python3 "$probe/direct.py" "$work" "$target"
python3 "$probe/direct.py" "$work" "$target" "$STUN"
python3 "$probe/direct.py" "$work" "$target" ""
```

The executable accepts `ice` for the defaults and `ice:` followed by the replacement list.
A direct-IP connection opens a UDP socket to the supplied address without contacting an ICE
service.

TURN is optional. To allow a private relay alongside direct routes, configure
`OPENRELIANT_TURN_SERVER` (one UDP hostname and port), `OPENRELIANT_TURN_USERNAME` and
`OPENRELIANT_TURN_PASSWORD` in each participating process's environment. Supply each peer
with credentials from your relay. The library uses commas to separate list entries, so each
value must be free of commas. Run:

```sh
python3 "$probe/direct.py" --private-turn "$work" "$target"
```

Use `--relay-only` in place of `--private-turn` to verify the private relay. The default run
ignores TURN configuration and rejects relay candidates.

For a two-site test, place the host binary and its own certificate from the same build set on
the second machine. Start the host through a command that pipes standard input and output. For
example, with those two files in the remote working directory:

```sh
python3 "$probe/direct.py" "$work" "$target" "$STUN" \
    ssh -T "$REMOTE" "./transport-probe host ice:$STUN host.cert"
```

For a remote relay test, pass the same route flag to the runner and the remote executable.
Set the remote credentials on the host.

The runner checks each signal with the pinned Protobuf schema. It refuses application messages
and counts the candidate types it forwards. The transport reports when it sends a discovery
request, reads a mapped address, or gets a STUN error or timeout. Request counts include
retries and packets subject to simulated loss. A mapping that matches the interface already
has a host candidate. A different mapping can appear in a signal as `srflx`. Each authenticated
peer reports the selected route when it connects. The runner exits unsuccessfully if a peer fails and
prints the candidate counts even when no route connects.

The pinned native ICE library sends a mapped-address attribute in a STUN binding request.
Some services reject it with error 420. The probe omits the attribute from discovery and
keepalive requests. Both default services returned mappings that the peers advertised.
Cross-network route results are tracked in
[#1404](https://github.com/OpenReliant/openreliant/issues/1404).
