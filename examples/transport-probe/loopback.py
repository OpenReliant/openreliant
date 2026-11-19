"""Run the host and pilots as background processes over loopback UDP."""

import argparse
import asyncio
from pathlib import Path
import socket


async def run(binary, credentials, late_pilot):
    children = []

    join_attempts = ("cancel_join", "wrong_protocol", "silent_join")
    playing_attempts = ("leave_play", "silent_play")

    async def start(role, address):
        identity = "pilot1" if role == "reject" else role
        if role in join_attempts + playing_attempts:
            identity = "pilot3"
        child = await asyncio.create_subprocess_exec(
            str(binary), role, address, str(credentials / (identity + ".cert")), "--shared-clock",
            stdout=asyncio.subprocess.PIPE if role == "host" else None,
            stdin=asyncio.subprocess.PIPE if late_pilot and role != "host" else None,
        )
        children.append(child)
        return child

    async def check(child):
        if await child.wait() != 0:
            raise RuntimeError("transport probe failed")

    async def release(child):
        child.stdin.write(b"\n")
        await child.stdin.drain()
        child.stdin.close()

    async def released(host, role):
        result = await host.stdout.readline()
        # With packet loss, the host can expire a cancelled connection before its close arrives.
        if role == "cancel_join" and result == b"silent join expired\n":
            return
        expected = b"silent join expired\n" if role == "silent_join" else b"join slot free\n"
        if role in playing_attempts:
            expected = b"playing slot free\n"
        if result != expected:
            raise RuntimeError(f"host did not release the pilot slot after {role}")

    async def listen():
        # Valve requires an explicit port. Retry if another process claims it first.
        for _ in range(3):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            address = f"127.0.0.1:{port}"
            host = await start("host", address)
            if await host.stdout.readline() == f"listening {port}\n".encode():
                return host, address
            await host.wait()
        raise RuntimeError("could not start the host")

    try:
        if not late_pilot:
            wrong_host, address = await listen()
            await check(await start("reject", address))
            wrong_host.terminate()
            await wrong_host.wait()
        host, address = await listen()
        pilots = [await start(role, address) for role in ("pilot1", "pilot2")]
        if late_pilot:
            if await host.stdout.readline() != b"beacon carried\n":
                raise RuntimeError("host did not confirm the first pickup")
            for role in join_attempts + playing_attempts:
                attempt = await start(role, address)
                if await host.stdout.readline() != b"checking late join\n":
                    raise RuntimeError(f"host did not receive {role}")
                if role != "cancel_join":
                    await released(host, role)
                await release(attempt)
                await check(attempt)
                if role == "cancel_join":
                    await released(host, role)
            pilots.append(await start("pilot3", address))
            await check(host)
            for pilot in pilots:
                await release(pilot)
        else:
            pilots.append(host)
        await asyncio.gather(*(check(peer) for peer in pilots))
    finally:
        for child in children:
            if child.returncode is None:
                try:
                    child.kill()
                except ProcessLookupError:
                    pass
        await asyncio.gather(*(child.wait() for child in children))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("credentials", type=Path)
    parser.add_argument("--six-beacons", action="store_true")
    args = parser.parse_args()
    asyncio.run(asyncio.wait_for(run(args.binary.resolve(), args.credentials, args.six_beacons), 45))
