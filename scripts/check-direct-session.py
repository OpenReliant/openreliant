"""Exercise the OpenReliant host and clients over local encrypted UDP."""

import argparse
import asyncio
import os
from pathlib import Path
import socket


class Session:
    def __init__(self, process):
        self.process = process
        self.admission = None
        self.views = {}
        self.finished = None
        self.receipts = None
        self.last_line = ""
        self.messages = asyncio.Queue()
        self.reader = asyncio.create_task(self.read())

    async def read(self):
        async for line in self.process.stderr:
            self.last_line = line.decode().rstrip()
            parts = self.last_line.split()
            if len(parts) == 3 and parts[0] == "admitted":
                self.admission = tuple(map(int, parts[1:]))
            elif len(parts) == 11 and parts[0] == "view":
                self.views[int(parts[1])] = tuple(
                    (int(parts[i]), float(parts[i + 1]), float(parts[i + 2]))
                    for i in range(2, len(parts), 3)
                )
            elif parts and parts[0] == "finished":
                self.finished = int(parts[1])
                if len(parts) == 3:
                    self.receipts = int(parts[2])
            await self.messages.put(self.last_line)
        await self.messages.put(None)

    async def expect(self, text, check=lambda _: True):
        while True:
            line = await self.messages.get()
            if line is None:
                raise RuntimeError(f"process exited before {text!r}. Last message: {self.last_line}")
            if line.startswith(text) and check(line):
                return line

    async def wait(self):
        status = await self.process.wait()
        await self.reader
        return status


def require(condition, description):
    if not condition:
        raise RuntimeError(description)


async def run(binary, credentials):
    sessions = []

    async def start(role, identity, *args):
        process = await asyncio.create_subprocess_exec(
            str(binary), "session", role, address, str(credentials / f"{identity}.cert"), *args,
            stdin=asyncio.subprocess.PIPE if "keyboard" in args else None,
            stderr=asyncio.subprocess.PIPE,
        )
        session = Session(process)
        sessions.append(session)
        return session

    async def join(name, steering, *args):
        return await start("join", name, "host", steering, *args)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.bind(("127.0.0.1", 0))
        address = f"127.0.0.1:{udp.getsockname()[1]}"

    try:
        host = await start("host", "host", "175")
        await host.expect("listening ")
        keyboard = os.name == "posix"
        first = await join("pilot1", "keyboard" if keyboard else "left")
        second = await join("pilot2", "right")
        await first.expect("admitted ")
        if keyboard:
            first.process.stdin.write(b"a\n")
            await first.process.stdin.drain()
        await first.expect("view ")
        late = await join("pilot3", "straight", "12")
        await late.expect("admitted ")
        slot, old_generation = late.admission
        await host.expect(f"left {slot} {old_generation}")
        require(await late.wait() == 0, "the late pilot could not leave cleanly")
        offset = 2 + slot * 3
        for peer in (first, second):
            await peer.expect("view ", lambda line: int(line.split()[offset]) == old_generation)
            await peer.expect("view ", lambda line: int(line.split()[offset]) == 0)
        replacement = await join("pilot3", "straight")
        await replacement.expect("admitted ")
        new_slot, new_generation = replacement.admission
        require(slot == new_slot and old_generation != new_generation, "the slot was not admitted afresh")

        participants = (first, second, replacement)
        for session in (host, *participants):
            require(await session.wait() == 0, f"a peer exited before the end of the round. Last message: {session.last_line}")
        end = host.finished
        require(end is not None, "the host did not finish")
        require(host.receipts == len(participants), "the host did not receive every final receipt")
        require(all(peer.finished == end for peer in participants), "pilots disagree about the final tick")
        require(all(peer.views[end] == first.views[end] for peer in participants), "pilots disagree about the final snapshot")

        for peer in (first, second):
            generations = [ships[slot][0] for _, ships in sorted(peer.views.items())]
            departed = generations.index(old_generation)
            rejoined = generations.index(new_generation)
            require(departed < rejoined and 0 in generations[departed:rejoined], "an active pilot missed the departure")
            require(len(peer.views) >= end // 2, "an active pilot missed most of the moving snapshots")
        first_slot, _ = first.admission
        second_slot, _ = second.admission
        start = first.views[min(first.views)]
        result = first.views[end]
        dx1 = result[first_slot][1] - start[first_slot][1]
        dx2 = result[second_slot][1] - start[second_slot][1]
        require(dx1 * dx2 < 0 and min(abs(dx1), abs(dx2)) > 1, "opposite flight inputs did not move the two ships apart")
        require(all(result[i][2] > start[i][2] for i in (first_slot, second_slot)), "the host did not move the ships forward")
        print(f"Three pilots confirmed tick {end}. Slot {slot} rejoined with a new admission.")
    finally:
        for session in sessions:
            if session.process.returncode is None:
                try:
                    session.process.kill()
                except ProcessLookupError:
                    pass
        await asyncio.gather(*(session.wait() for session in sessions))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("credentials", type=Path)
    args = parser.parse_args()
    asyncio.run(asyncio.wait_for(run(args.binary.resolve(), args.credentials.resolve()), 30))
