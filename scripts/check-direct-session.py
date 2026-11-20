"""Exercise the OpenReliant host and clients over local encrypted UDP."""

import argparse
import asyncio
import base64
import os
from pathlib import Path
import socket
import subprocess
import tempfile


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


class Loopback:
    def __init__(self, binary, credentials):
        self.binary = binary
        self.credentials = credentials
        self.sessions = []
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.bind(("127.0.0.1", 0))
            self.port = udp.getsockname()[1]
        self.address = f"127.0.0.1:{self.port}"

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        for session in self.sessions:
            if session.process.returncode is None:
                try:
                    session.process.kill()
                except ProcessLookupError:
                    pass
        await asyncio.gather(*(session.wait() for session in self.sessions))

    async def start(self, *args, cwd=None):
        process = await asyncio.create_subprocess_exec(
            str(self.binary), *args,
            cwd=cwd,
            stdin=asyncio.subprocess.PIPE if "keyboard" in args else None,
            stderr=asyncio.subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        session = Session(process)
        self.sessions.append(session)
        return session

    async def session(self, role, identity, *args, trust=None):
        root = trust if trust is not None else self.credentials / "root.pub"
        certificate = self.credentials / f"{identity}.cert"
        return await self.start("session", role, self.address, str(root), str(certificate), *args)

    async def join_target(self, target, steering, *args):
        pilot = await self.start("session", "join", target, steering, *args)
        await pilot.expect("admitted ")
        return pilot

    async def join(self, name, steering, *args):
        peer = await self.session("join", name, "host", steering, *args)
        await peer.expect("admitted ")
        return peer


async def finish(host, participants):
    for session in (host, *participants):
        require(await session.wait() == 0, f"a peer exited before the end of the round. Last message: {session.last_line}")
    end = host.finished
    require(end is not None, "the host did not finish")
    require(host.receipts == len(participants), "the host did not receive every final receipt")
    require(all(peer.finished == end for peer in participants), "pilots disagree about the final tick")
    require(all(peer.views[end] == participants[0].views[end] for peer in participants),
            "pilots disagree about the final snapshot")
    return end


async def check_training(binary, credentials):
    async with Loopback(binary, credentials) as game:
        with tempfile.TemporaryDirectory() as directory:
            invalid_key = Path(directory) / "root.pub"
            invalid_key.write_text("invalid public key\n", encoding="ascii")
            invalid = await game.session("host", "host", "175", trust=invalid_key)
            require(await invalid.wait() == 1 and invalid.last_line == "session: InvalidTransportIdentity",
                    "the host accepted an invalid trust root")
        host = await game.session("host", "host", "175")
        await host.expect("listening ")
        keyboard = os.name == "posix"
        first = await game.join("pilot1", "keyboard" if keyboard else "left")
        second = await game.join("pilot2", "right")
        if keyboard:
            first.process.stdin.write(b"a\n")
            await first.process.stdin.drain()
        await first.expect("view ")
        late = await game.join("pilot3", "straight", "12")
        slot, old_generation = late.admission
        await host.expect(f"left {slot} {old_generation}")
        require(await late.wait() == 0, "the late pilot could not leave cleanly")
        offset = 2 + slot * 3
        for peer in (first, second):
            await peer.expect("view ", lambda line: int(line.split()[offset]) == old_generation)
            await peer.expect("view ", lambda line: int(line.split()[offset]) == 0)
        replacement = await game.join("pilot3", "straight")
        new_slot, new_generation = replacement.admission
        require(slot == new_slot and old_generation != new_generation, "the slot was not admitted afresh")

        participants = (first, second, replacement)
        end = await finish(host, participants)

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



def beacon(line, index, state):
    fields = line.split()
    return fields[2:4] == [str(index), state]


async def check_beacons(binary, credentials):
    with tempfile.TemporaryDirectory() as directory:
        async with Loopback(binary, credentials) as game:
            await six_beacons(game, Path(directory).resolve() / "server.ini")


async def check_invites(binary, credentials):
    with tempfile.TemporaryDirectory() as directory:
        async with Loopback(binary, credentials) as game:
            await ip_invites(game, Path(directory))


async def ip_invites(game, directory):
    (directory / "server.ini").write_text(f"""[Server]
BindAddress=0.0.0.0
InviteAddress=127.0.0.1
Port={game.port}
Arena=training
Players=2
RoundTicks=175
""", encoding="ascii")

    async def start_host():
        host = await game.start("--headless", cwd=directory)
        invite = (await host.expect("invite ")).split()[1]
        require(invite.startswith(f"orl1:{game.address}/"), "invite has the wrong IP or port")
        return host, invite

    host, invite = await start_host()
    key = directory / "server.key"
    require(key.is_file(), "the host did not create its identity")
    if os.name == "posix":
        require(key.stat().st_mode & 0o077 == 0, "other users can access the server key")
    before_restart = await game.join_target(invite, "left")
    host.process.terminate()
    await host.wait()
    before_restart.process.terminate()
    await before_restart.wait()

    host, restarted_invite = await start_host()
    require(invite == restarted_invite, "the invite changed after restarting")
    other_root = (game.credentials / "root.pub").read_text(encoding="ascii").split()[1]
    other_key = base64.urlsafe_b64encode(base64.b64decode(other_root)[-32:]).decode().rstrip("=")
    wrong_invite = f"{invite.split('/')[0]}/{other_key}"
    denied = await game.start("session", "join", wrong_invite, "left")
    require(await denied.wait() == 1 and denied.last_line == "session: UnverifiedServer",
            f"the client did not reject a different server key. Last message: {denied.last_line}")
    require(denied.admission is None, "a pilot with the wrong invite was admitted")

    first = await game.join_target(invite, "left")
    leaving = await game.join_target(game.address, "right", "12")
    slot, generation = leaving.admission
    await host.expect(f"left {slot} {generation}")
    require(await leaving.wait() == 0, "the direct-IP pilot could not leave cleanly")
    offset = 2 + slot * 3
    await first.expect("view ", lambda line: int(line.split()[offset]) == generation)
    await first.expect("view ", lambda line: int(line.split()[offset]) == 0)
    returned = await game.join_target(game.address, "right")
    new_slot, new_generation = returned.admission
    require(new_slot == slot and new_generation != generation, "the returning pilot did not get a fresh admission")
    await first.expect("view ", lambda line: int(line.split()[offset]) == new_generation)
    end = await finish(host, (first, returned))
    print(f"IP invite: the same invite worked after restart, the wrong key was rejected, and both pilots confirmed tick {end} after a direct-IP reconnect.")


async def six_beacons(game, config):
    root = os.path.relpath(game.credentials / "root.pub", config.parent)
    certificate = os.path.relpath(game.credentials / "host.cert", config.parent)
    config.write_text(f"""[Server]
Port={game.port}
Arena=six-beacons
Players=3
RoundTicks=175

[Identity]
RootPublicKey={root}
Certificate={certificate}
""", encoding="utf-8")
    host = await game.start("--headless", cwd=config.parent)
    await host.expect("listening ")
    first = await game.join("pilot1", "straight", "75")
    second = await game.join_target(game.address, "straight")
    slot, generation = first.admission

    async def pickup(peer):
        line = await peer.expect("beacon ", lambda line: beacon(line, 0, "carried"))
        require(tuple(map(int, line.split()[4:])) == (slot, generation), "the pickup had the wrong carrier")

    await pickup(first)
    await pickup(second)
    third = await game.join("pilot3", "straight")
    await pickup(third)
    await host.expect(f"left {slot} {generation}")
    require(await first.wait() == 0, "the carrier could not leave cleanly")
    drops = [await peer.expect("beacon ", lambda line: beacon(line, 0, "loose")) for peer in (second, third)]
    require(drops[0] == drops[1], "pilots saw different beacon drops")

    replacement = await game.join("pilot1", "straight")
    new_slot, new_generation = replacement.admission
    require(new_slot == slot and new_generation != generation, "the carrier's slot did not get a fresh admission")
    restored = await replacement.expect("beacon ", lambda line: beacon(line, 0, "loose"))
    require(restored.split()[4:] == drops[0].split()[4:], "the returning pilot saw a different beacon position")

    end = await finish(host, (second, third, replacement))
    print(f"Six Beacons: a late pilot saw the pickup, both active pilots saw the drop, and the returning pilot confirmed tick {end}.")


async def run(binary, credentials):
    for check in (check_training, check_beacons, check_invites):
        await asyncio.wait_for(check(binary, credentials), 30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("credentials", type=Path)
    args = parser.parse_args()
    asyncio.run(run(args.binary.resolve(), args.credentials.resolve()))
