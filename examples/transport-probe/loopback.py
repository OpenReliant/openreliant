"""Run the three peers as background processes on real loopback UDP sockets."""

import asyncio
from pathlib import Path
import socket
import sys


async def run(binary, credentials):
    children = []

    async def start(role, address):
        identity = "pilot1" if role == "reject" else role
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
        wrong_host, address = await listen()
        await check(await start("reject", address))
        wrong_host.terminate()
        await wrong_host.wait()
        host, address = await listen()
        pilots = [await start(role, address) for role in ("pilot1", "pilot2")]
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
    asyncio.run(asyncio.wait_for(run(Path(sys.argv[1]).resolve(), Path(sys.argv[2])), 45))
