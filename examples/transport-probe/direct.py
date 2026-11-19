"""Run two local pilots against a local or remote host with direct ICE or an optional private relay."""

import argparse
import asyncio
from collections import Counter
from pathlib import Path
import re
import subprocess


def candidates(work, payload):
    schema = work / "sources/GameNetworkingSockets/src/common"
    decoded = subprocess.run(
        [work / "host/protoc", "-I", schema, "--decode=CMsgSteamNetworkingP2PRendezvous",
         "steamnetworkingsockets_messages.proto"],
        input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3,
    )
    if decoded.returncode or re.search(rb"^application_messages \{", decoded.stdout, re.M):
        raise ValueError("refused a malformed signal or one carrying application messages")
    return re.findall(rb'^\s*candidate: "[^"\n]+ typ (host|srflx|prflx|relay)\b', decoded.stdout, re.M)


async def run(args):
    peers = {}
    counts = {name: Counter() for name in ("host", "pilot1", "pilot2")}
    binary = args.work / args.target / "probe/transport-probe"
    endpoint = "ice" if args.stun is None else "ice:" + args.stun

    async def start(name, command):
        peers[name] = await asyncio.create_subprocess_exec(
            *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )

    async def report(name, peer):
        events = Counter()
        async for raw in peer.stderr:
            line = raw.decode(errors="replace").strip()
            if line.startswith("probe ICE "):
                events[line.removeprefix("probe ICE ")] += 1
            elif line.startswith(("ICE direct UDP connected to ", "ICE private TURN connected to ", "Private TURN requires ", "host:", "pilot ", "pilot1:", "pilot2:")):
                print(line if line.startswith(name + ":") else f"{name}: {line}", flush=True)
        for event, count in events.items():
            print(f"{name}: {event} ({count})", flush=True)

    async def route(name, peer):
        async for line in peer.stdout:
            signal = re.fullmatch(rb"S (host|pilot1|pilot2) ([0-9a-f]{2,32768})\r?\n", line)
            if not signal or len(signal[2]) % 2:
                raise ValueError("invalid signalling frame")
            other = signal[1].decode()
            if (name == "host") == (other == "host"):
                raise ValueError("unexpected signalling destination")
            types = await asyncio.to_thread(candidates, args.work, bytes.fromhex(signal[2].decode()))
            if not args.mode and b"relay" in types:
                raise ValueError("unexpected relay candidate")
            try:
                peers[other].stdin.write(signal[2] + b"\n")
                await peers[other].stdin.drain()
                counts[name].update(kind.decode() for kind in types)
            except (BrokenPipeError, ConnectionResetError):
                # A peer can finish before the library sends its last close signal.
                pass

    def local(name):
        return [binary, name, endpoint, args.work / "identities" / (name + ".cert"), *([args.mode] if args.mode else [])]

    try:
        await start("host", args.host_command or local("host"))
        if (await peers["host"].stdout.readline()).rstrip() != b"READY":
            await report("host", peers["host"])
            raise RuntimeError("host did not listen")
        for name in ("pilot1", "pilot2"):
            await start(name, local(name))
        await asyncio.gather(*(task(name, peer) for name, peer in peers.items() for task in (route, report)))
        codes = {name: await peer.wait() for name, peer in peers.items()}
        if any(codes.values()):
            raise RuntimeError(f"peer exit codes {codes}")
    finally:
        for name, peer in peers.items():
            if peer.returncode is None:
                try:
                    peer.kill()
                except ProcessLookupError:
                    pass
            print(f"{name} advertised candidates (including retries): "
                  f"host={counts[name]['host']} srflx={counts[name]['srflx']} prflx={counts[name]['prflx']} relay={counts[name]['relay']}")
        await asyncio.gather(*(peer.wait() for peer in peers.values()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work", type=Path)
    parser.add_argument("target", help="local build target")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--private-turn", dest="mode", action="store_const", const="--private-turn",
                       help="allow an operator-configured relay alongside direct routes")
    modes.add_argument("--relay-only", dest="mode", action="store_const", const="--relay-only",
                       help="require the private relay for a route test")
    parser.add_argument("stun", nargs="?", help="comma-separated STUN hosts with explicit ports")
    parser.add_argument("host_command", nargs=argparse.REMAINDER,
                        help="optional command to start the remote host with stdin and stdout connected")
    try:
        asyncio.run(asyncio.wait_for(run(parser.parse_args()), 50))
    except (OSError, RuntimeError, ValueError, asyncio.TimeoutError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"direct ICE probe failed ({type(error).__name__}): {error}")
