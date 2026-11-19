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

The probe listener has four connection slots shared by handshakes, pilots negotiating admission
and playing pilots. It allows four handshake starts in any rolling second. Direct UDP reserves a
slot before accepting the connection. ICE reserves one before creating the incoming signalling
channel and uses the same reservation when the transport accepts the connection. Closing a
connection frees its slot. Its start still counts for the rest of that second. The transport
checks encryption and the signed identity before the workload admits a pilot.

GameNetworkingSockets limits each incoming message to the workload's packet buffer. Each
accepted connection can queue up to 128 messages and 64 KiB of received data, for a total of
512 messages and 256 KiB across the four slots. These limits cover receive queues on accepted
connections. The library processes initial packets before it calls the listener.
Public-server traffic limits and isolation of errors from playing pilots remain in
[#1432](https://github.com/OpenReliant/openreliant/issues/1432).

The host reports the time between sending a snapshot and receiving a pilot's acknowledgement
that it applied it. This includes the return trip and the wait for the next input message. All
times in that measurement come from the host's clock. Each pilot also reports how many snapshots
it applied. When the loopback runner starts all three processes on one machine, they share the
system's monotonic clock. Each pilot then reports the 95th percentile and maximum snapshot age at
the time it applied the update.

## Run a direct-IP session in OpenReliant

The `openreliant session` command starts the host or a terminal pilot in an original training
arena with three slots. Two admitted pilots start the round. The host advances the normal
flight simulation and sends positions from its own state. An admitted pilot can leave or
reconnect during the round. The other pilots keep receiving snapshots.

Release builds include the transport on every target. To build it locally, use the same target
for both the libraries and the executable. This example uses Apple silicon. The test option
creates a disposable trust root and signs Ed25519 certificates for the host and three pilots.
The certificates expire after 24 hours. The private keys stay in the scratch directory. Each
process reads the root's public key and its own certificate at startup.

```sh
target=aarch64-macos.15.0
work=/path/to/scratch
python3 -m pip install -r scripts/transport-test-requirements.txt
python3 scripts/build_transport.py "$work" "$target" --test-identities
zig build -Dtarget="$target" -Dgns-prefix="$work/$target/prefix"
python3 scripts/check-direct-session.py zig-out/bin/openreliant "$work/session-identities"
```

To try it by hand, start the host first. Choose a different certificate for each pilot.
These commands exercise the optional managed identities. A pilot can also join this host with
`openreliant session join 127.0.0.1:27020`. In keyboard mode, type A, S, D or Q
and press Enter to steer left, fly straight, steer right or leave.

```sh
ids="$work/session-identities"
zig-out/bin/openreliant session host 127.0.0.1:27020 "$ids/root.pub" "$ids/host.cert"
zig-out/bin/openreliant session join 127.0.0.1:27020 "$ids/root.pub" "$ids/pilot1.cert" host keyboard
zig-out/bin/openreliant session join 127.0.0.1:27020 "$ids/root.pub" "$ids/pilot2.cert" host keyboard
```

The host limits accepted handshakes, buffers and messages per pilot. It checks the encrypted
connection and protocol revision before it allocates a ship, and accepts flight commands only for the
current admission. A reconnect receives a fresh admission and ship. The app release can differ
when the protocol revision matches. Each pilot confirms the final snapshot's tick. The host
reports how many pilots confirmed it before shutdown.

Held flight controls and interim snapshots use unreliable delivery. The host releases held
controls if no fresh input arrives for 250 milliseconds. Throttle presets and afterburner
toggles use reliable delivery, as do admission, departures and the final result.
A held input takes up to 25 bytes and a three-pilot training snapshot takes 120 bytes before
transport headers. At 25 updates per second in both directions that is up to 3,625 payload bytes
per second per pilot for those messages. A Six Beacons snapshot takes at most 198 bytes and
contains all six locations or carriers. A carried beacon
names a slot from the same snapshot, so it refers to the ship and admission in that view. The host
encodes each snapshot once and sends those bytes to each pilot. Routed latency and sustained
throughput measurements are tracked in [#1405](https://github.com/OpenReliant/openreliant/issues/1405).

### Start the Six Beacons headless host

Run `openreliant --headless path/to/server.ini` with the settings in the
[headless server guide](../guide/configuration.md#headless-server-configuration-serverini).
Pilots can join by IP, with an optional port. By default the host also prints an invite for
`openreliant session join '<invite>'`, which checks the host identity on the game connection. The loopback check verifies that the same invite works
after restart and that a pilot can leave and return during a round. A separate Six Beacons check
starts the host with managed identity files and verifies that both active pilots and the returning
pilot see the beacon in the same position after a carrier leaves.

The training session is the first game-executable path under
[#954](https://github.com/OpenReliant/openreliant/issues/954). The release build prepares the
transport prefix automatically. Test identities are generated separately and stay outside the
package. The dedicated server must manage its identity and renewal through its normal setup.
Players must be able to join a public server by reachable IP address or from the server list.
A DNS hostname is optional. Operators set game options such as the port, player limit and match
rotation. A long-running server can also use a hostname and an external identity provider that
renews its credentials. A Certbot or Let's Encrypt certificate can secure that provider's HTTPS
endpoint. The provider still issues
[GameNetworkingSockets identities](https://github.com/ValveSoftware/GameNetworkingSockets/blob/v1.6.1/include/steam/isteamnetworkingsockets.h)
for game traffic. Dedicated server setup is tracked in [#364](https://github.com/OpenReliant/openreliant/issues/364).
The probe below still exercises ICE, TURN and directed events.

## Run it

On a Unix build machine, install Zig 0.17, Git, patch, CMake, Ninja, Make, Perl, a native C++ compiler
and Python 3.9 or newer. Install the test certificate helper's dependencies with
`python3 -m pip install -r scripts/transport-test-requirements.txt`. Apple targets need
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
sources and native Protobuf compiler across targets. The script builds Protobuf 36.2 (C++ 7.36.2)
and Abseil 20260817.0 for the host compiler and the target runtime. It builds
GameNetworkingSockets 1.6.1 with OpenSSL 4.1.0 on Linux and macOS. Windows uses BCrypt.
The OpenSSL build uses portable C with assembly disabled. Production dependency versions,
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

Two pilots start on the real host simulation. After the first beacon pickup, the runner uses
the third pilot's identity to check admission. One client cancels, one reports an incompatible
protocol revision, and one stays connected without sending a join message. The host releases
each connection. A silent client must time out before the runner starts its replacement.

During late admission, the host advances the arena at its normal simulation step and sends both
playing pilots full objective snapshots. Each pilot acknowledges the tick it applied. The host
keeps at most one snapshot per pilot awaiting acknowledgement and skips intermediate views for a
slow reader. At expiry it checks that both pilots acknowledged multiple
fresh views, including a tick from the second half of the wait.

The runner then admits two pilots in turn with that same identity. One disconnects after
reading its first snapshot. The other reads its snapshot and withholds the receipt. The host
checks at most one receipt per pilot per poll. A bad receipt, a disconnect or a three-second
receipt timeout releases that connection and revokes its participant. Both original pilots must
acknowledge a snapshot from after each release. The host also checks that the departed pilot's
control reference cannot fly the replacement's ship.

The original restores beacon positions and pilot counts on a mid-round join
(`six_beacons_init`, 0x004B2F10). On departure, `mp_player_departed` (0x004B6890) calls the
arena mode before resetting the ship slot. In Six Beacons the host drops the departing
pilot's cargo and sends the new counts (`six_beacons_pilot_left`, 0x004B30A0). The headless
arena follows this order and creates a fresh ship when another pilot takes the slot. The
playable lobby and mission notices are tracked in
[#1442](https://github.com/OpenReliant/openreliant/issues/1442).

The replacement reports a different OpenReliant release with the same protocol revision. Its
first snapshot includes all six beacons, their positions and the carrier's participant and ship
identities. The host runs the carrier's destruction order, and all three pilots confirm that the
same beacon is loose at its drop position.

The protocol revision is separate from the OpenReliant version. Bump it when the wire format
or message semantics become incompatible. The workload uses short-lived test identities.
Public server admission and traffic limits are tracked in
[#1432](https://github.com/OpenReliant/openreliant/issues/1432), content compatibility in
[#956](https://github.com/OpenReliant/openreliant/issues/956), and playable client delivery in
[#954](https://github.com/OpenReliant/openreliant/issues/954) and
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
