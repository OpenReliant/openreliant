"""Run the host and pilots as background processes over loopback UDP."""

import argparse
import asyncio
from pathlib import Path
import socket


async def run(binary, credentials, late_pilot):
    children = []

    async def start(role, address):
        identity = {"reject": "pilot1", "wrong_protocol": "pilot3"}.get(role, role)
        child = await asyncio.create_subprocess_exec(
            str(binary), role, address, str(credentials / (identity + ".cert")), "--shared-clock",
            stdout=asyncio.subprocess.PIPE if role == "host" else None,
        )
        children.append(child)
        return child

    async def check(child):
        if await child.wait() != 0:
            raise RuntimeError("transport probe failed")

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
            await check(await start("wrong_protocol", address))
            pilots.append(await start("pilot3", address))
        await asyncio.gather(*(check(peer) for peer in [host, *pilots]))
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
