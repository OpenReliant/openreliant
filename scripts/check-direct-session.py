"""Exercise the OpenReliant host and clients over local encrypted UDP."""

import argparse
import asyncio
import base64
import os
from pathlib import Path
import random
import socket
import subprocess
import tempfile

STOCK_TRACKS = {
    "dark-reign": "new_sim02.wav",
    "nuclear-threat": "new_sim03.wav",
    "tag-bomb": "new_sim04.wav",
    "hunt-the-shadow": "new_sim08.wav",
    "asteroid-field": "new_sim09.wav",
    "vampires": "new_sim10.wav",
}


class Session:
    def __init__(self, process):
        self.process = process
        self.admission = None
        self.views = {}
        self.beacon_changes = {}
        self.music = []
        self.finished = None
        self.receipts = None
        self.last_line = ""
        self.messages = asyncio.Queue()
        self.reader = asyncio.create_task(self.read())

    async def read(self):
        async for line in self.process.stderr:
            self.last_line = line.decode().rstrip().removeprefix("info(network_host): ")
            parts = self.last_line.split()
            if len(parts) == 3 and parts[0] == "admitted":
                self.admission = tuple(map(int, parts[1:]))
            elif len(parts) >= 5 and (len(parts) - 2) % 3 == 0 and parts[0] == "view":
                self.views[int(parts[1])] = tuple(
                    (int(parts[i]), float(parts[i + 1]), float(parts[i + 2]))
                    for i in range(2, len(parts), 3)
                )
            elif parts and parts[0] == "finished":
                self.finished = int(parts[1])
                if len(parts) == 3:
                    self.receipts = int(parts[2])
            elif parts and parts[0] == "beacon" and parts[2] == "0":
                self.beacon_changes[int(parts[1])] = tuple(parts[3:])
            elif self.last_line.startswith("mission music "):
                self.music.append(self.last_line.removeprefix("mission music "))
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

    def beacon_views(self):
        state = None
        for tick in sorted(self.views):
            state = self.beacon_changes.get(tick, state)
            if state is not None:
                yield tick, state


def require(condition, description):
    if not condition:
        raise RuntimeError(description)


class ImpairedLink(asyncio.DatagramProtocol):
    """One loopback path with independent loss and jitter in both directions."""

    def __init__(self, host, seed, vary_by_direction):
        self.host = host
        self.random = random.Random(seed)
        self.loop = asyncio.get_running_loop()
        self.client = None
        self.network = tuple(
            (self.random.uniform(0.03, 0.09), self.random.uniform(0.008, 0.024), self.random.uniform(0.044, 0.080))
            if vary_by_direction else (0.06, 0.008, 0.044)
            for _ in range(2)
        )

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, sender):
        from_host = sender == self.host
        if from_host:
            if self.client is None:
                return
            destination = self.client
        else:
            if self.client is None:
                self.client = sender
            if sender != self.client:
                return
            destination = self.host
        loss, low_delay, high_delay = self.network[from_host]
        if self.random.random() >= loss:
            self.loop.call_later(self.random.uniform(low_delay, high_delay), self.deliver, data, destination)

    def deliver(self, data, destination):
        if not self.transport.is_closing():
            self.transport.sendto(data, destination)


class Loopback:
    def __init__(self, binary, credentials, seed=None, *, vary_by_direction=False):
        self.seed = None if seed is None else random.Random(seed)
        self.vary_by_direction = vary_by_direction
        self.links = []
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
        for link in self.links:
            link.close()

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

    async def path(self, target):
        if self.seed is None:
            return target
        invite = target.startswith("orl1:")
        address, _, key = target.removeprefix("orl1:").partition("/")
        host_ip, port = address.rsplit(":", 1)
        require(host_ip == "127.0.0.1", "packet impairment is for IPv4 loopback")
        loop = asyncio.get_running_loop()
        seed = self.seed.getrandbits(64)
        transport, _ = await loop.create_datagram_endpoint(
            lambda: ImpairedLink((host_ip, int(port)), seed, self.vary_by_direction), local_addr=("127.0.0.1", 0))
        self.links.append(transport)
        local_ip, local_port = transport.get_extra_info("sockname")
        local = f"{local_ip}:{local_port}"
        return f"orl1:{local}/{key}" if invite else local

    async def session(self, role, identity, *args, trust=None):
        root = trust if trust is not None else self.credentials / "root.pub"
        certificate = self.credentials / f"{identity}.cert"
        address = await self.path(self.address) if role == "join" else self.address
        return await self.start("session", role, address, str(root), str(certificate), *args)

    async def join_target(self, target, steering, *args):
        pilot = await self.start("session", "join", await self.path(target), steering, *args)
        await pilot.expect("admitted ")
        return pilot

    async def join(self, name, steering, *args):
        peer = await self.session("join", name, "host", steering, *args)
        await peer.expect("admitted ")
        return peer


async def finish(host, participants):
    for session in (host, *participants):
        status = await session.wait()
        require(status == 0, f"Peer {session.admission} exited with {status}, final tick {session.finished}, "
                             f"host tick {host.finished}, receipts {host.receipts}. Last message: {session.last_line}")
    end = host.finished
    require(end is not None, "the host did not finish")
    require(host.receipts == len(participants), "the host did not receive every final receipt")
    require(all(peer.finished == end for peer in participants), "pilots disagree about the final tick")
    require(all(peer.views[end] == participants[0].views[end] for peer in participants),
            "pilots disagree about the final snapshot")
    return end


async def check_training(binary, credentials, seed):
    async with Loopback(binary, credentials, seed) as game:
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
        if keyboard:
            await send_key(first, "c")
            await second.expect(f"chat flight {first.admission[0]} Check my six")
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


async def check_beacons(binary, credentials, seed):
    with tempfile.TemporaryDirectory() as directory:
        async with Loopback(binary, credentials, seed, vary_by_direction=True) as game:
            await six_beacons(game, Path(directory).resolve() / "server.ini")


async def check_invites(binary, credentials, seed):
    with tempfile.TemporaryDirectory() as directory:
        async with Loopback(binary, credentials, seed) as game:
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
    denied = await game.start("session", "join", await game.path(wrong_invite), "left")
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
Players=8
RoundTicks=225

[Identity]
RootPublicKey={root}
Certificate={certificate}
""", encoding="utf-8")
    host = await game.start("--headless", cwd=config.parent)
    await host.expect("listening ")
    first = await game.join("pilot1", "straight", "100")
    second = await game.join_target(game.address, "straight")
    slot, generation = first.admission

    async def pickup(peer):
        line = await peer.expect("beacon ", lambda line: beacon(line, 0, "carried"))
        require(tuple(map(int, line.split()[4:])) == (slot, generation), "the pickup had the wrong carrier")

    await pickup(first)
    await pickup(second)
    late = await asyncio.gather(game.join("pilot3", "straight"),
                                *(game.join_target(game.address, "straight") for _ in range(5)))
    active = (second, *late)
    await asyncio.gather(*(pickup(peer) for peer in late))
    await host.expect(f"left {slot} {generation}")
    require(await first.wait() == 0, "the carrier could not leave cleanly")
    drops = await asyncio.gather(*(peer.expect("beacon ", lambda line: beacon(line, 0, "loose")) for peer in active))
    drop_tick = min(int(drop.split()[1]) for drop in drops)

    replacement = await game.join("pilot1", "straight")
    new_slot, new_generation = replacement.admission
    require(new_slot == slot and new_generation != generation, "the carrier's slot did not get a fresh admission")
    end = await finish(host, (*active, replacement))
    # Loss and jitter can hide different parts of the pickup history from each pilot.
    # Compare what two pilots saw at the same host tick.
    observed = dict(second.beacon_views())
    for peer in (*late, replacement):
        states = [(tick, state) for tick, state in peer.beacon_views() if tick >= drop_tick and tick in observed]
        require(bool(states), "pilots had no overlapping beacon views after the drop")
        require(all(state == observed[tick] for tick, state in states), "pilots disagreed about the beacon at the same tick")
    print(f"Six Beacons: six late pilots saw the pickup, all seven remaining pilots saw the drop, and all eight confirmed tick {end}.")


async def check_full_arena(binary, credentials, seed, mode="training", game_dir=None):
    async with Loopback(binary, credentials, seed, vary_by_direction=game_dir is not None) as game:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "server.ini"
            count = 8
            settings = f"[Server]\nPort={game.port}\nArena={mode}\nPlayers={count}\nRoundTicks=175\n"
            if game_dir is not None:
                settings += f"GameDirectory={game_dir}\nRepeatRounds=0\nStartDelaySeconds=0\n"
            config.write_text(settings, encoding="utf-8")
            host = await game.start("--headless", str(config))
            await host.expect("listening ")
            paths = ("left", "straight", "right")
            first = await asyncio.gather(*(game.join_target(game.address, path) for path in paths[:2]))
            track = STOCK_TRACKS.get(mode)
            if track:
                await asyncio.gather(*(peer.expect(f"mission music now {track}") for peer in first))
            rest = await asyncio.gather(*(game.join_target(game.address, paths[slot % len(paths)]) for slot in range(2, count)))
            pilots = [*first, *rest]
            admissions = {peer.admission[0]: peer.admission[1] for peer in pilots}
            require(set(admissions) == set(range(count)), "the arena did not admit eight pilots")
            end = await finish(host, pilots)
            generations = tuple(admissions[slot] for slot in range(count))
            for peer in pilots:
                if track:
                    require(peer.music == [f"now {track}"], f"{mode}: pilot {peer.admission[0]} received {peer.music}")
                live_views = sum(tuple(ship[0] for ship in view) == generations
                                 for tick, view in peer.views.items() if tick < end)
                require(live_views >= end // 3, f"{mode}: pilot {peer.admission[0]} saw only {live_views} full-roster views")
                require(tuple(ship[0] for ship in peer.views[end]) == generations, "the final view lost an admitted pilot")
            music = f", received the cue for {track}," if track else ""
            print(f"{mode}: eight pilots saw the full roster in flight{music} and agreed on tick {end}.")


async def send_key(pilot, key):
    pilot.process.stdin.write(key.encode("ascii") + b"\n")
    await pilot.process.stdin.drain()


async def check_team_cycle(binary, credentials, seed, game_dir):
    async with Loopback(binary, credentials, seed, vary_by_direction=True) as game:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "server.ini"
            settings = {"Port": game.port, "GameDirectory": game_dir, "Arena": "dark-reign",
                        "Players": 8, "Teams": 1, "RoundTicks": 125, "RepeatRounds": 1, "StartDelaySeconds": 5}
            config.write_text("[Server]\n" + "".join(f"{key}={value}\n" for key, value in settings.items()), encoding="utf-8")
            host = await game.start("--headless", str(config))
            await host.expect("listening ")
            pilots = sorted(await asyncio.gather(*(game.join_target(game.address, "keyboard") for _ in range(8))),
                            key=lambda pilot: pilot.admission)
            admissions = tuple(pilot.admission[1] for pilot in pilots)
            await asyncio.gather(*(pilot.expect("arena setup 0") for pilot in pilots))
            teams = ("first", "second", "third", "fourth")
            await asyncio.gather(*(send_key(pilot, str(slot % len(teams) + 1)) for slot, pilot in enumerate(pilots)))
            for floor in (0, settings["RoundTicks"]):
                await asyncio.gather(*(pilot.expect(f"arena flight {floor} dark_reign {teams[slot % len(teams)]}")
                                       for slot, pilot in enumerate(pilots)))
                tick = floor + settings["RoundTicks"] // 2
                await asyncio.gather(*(pilot.expect("view ", lambda line: int(line.split()[1]) >= tick) for pilot in pilots))
                for pilot in pilots:
                    require(tuple(ship[0] for ship in pilot.views[max(pilot.views)]) == admissions,
                            "the team lobby changed an admission")
                await asyncio.gather(*(pilot.expect(f"arena lobby {floor + settings['RoundTicks']} dark_reign") for pilot in pilots))
            empty_team = (pilots[2], pilots[6])
            await asyncio.gather(*(send_key(pilot, "q") for pilot in empty_team))
            await asyncio.gather(*(pilot.wait() for pilot in empty_team))
            floor = settings["RoundTicks"] * 2
            await pilots[0].expect(f"arena flight {floor} dark_reign first")
            first = await game.join_target(game.address, "keyboard")
            second = await game.join_target(game.address, "keyboard")
            await asyncio.gather(*(pilot.expect(f"arena flight {floor} dark_reign third") for pilot in (first, second)))
            require({first.admission[0], second.admission[0]} == {2, 6}, "late joins changed the open seats")
            for pilot in (first, second):
                slot, generation = pilot.admission
                require(generation > admissions[slot], "late join inherited a former pilot's admission")
            print("Team Deathmatch: eight pilots kept their seats and teams through two rounds. Two late joins filled the empty team in the next round.")


async def check_coop(binary, credentials, seed, game_dir):
    async with Loopback(binary, credentials, seed) as game:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "server.ini"
            config.write_text(f"[Server]\nPort={game.port}\nGameDirectory={game_dir}\nMission=1\nPlayers=4\n",
                              encoding="utf-8")
            host = await game.start("--headless", str(config))
            await host.expect("listening ")
            pilots = sorted(await asyncio.gather(*(game.join_target(game.address, "keyboard") for _ in range(4))),
                            key=lambda pilot: pilot.admission)
            lead = pilots[0]
            for decision, following in (("r", 1), ("n", 2)):
                await asyncio.gather(*(pilot.expect("mission 1 lead 0 jump true") for pilot in pilots))
                launches = 1 if decision == "r" else 2
                for pilot in pilots:
                    require(pilot.music.count("fade new_launch.wav") == launches,
                            f"Mission 1 attempt {launches}: pilot {pilot.admission[0]} received {pilot.music}")
                await asyncio.gather(*(send_key(pilot, "e") for pilot in pilots[1:]))
                running = max(lead.views)
                await lead.expect("view ", lambda line: int(line.split()[1]) > running + 20)
                await send_key(lead, "e")
                mask = (1 << len(pilots)) - 1
                await asyncio.gather(*(pilot.expect(f"debrief-crew 0 {mask} {mask} 0") for pilot in pilots))
                if decision == "r":
                    await send_key(lead, "c")
                    await asyncio.gather(*(pilot.expect("chat lobby 0 Check my six") for pilot in pilots[1:]))
                    leaving = pilots.pop()
                    await send_key(leaving, "q")
                    await host.expect(f"left {leaving.admission[0]} ")
                    mask >>= 1
                    await asyncio.gather(*(pilot.expect(f"debrief-crew 0 {mask} {mask} 0") for pilot in pilots))
                await asyncio.gather(*(send_key(pilot, "y") for pilot in pilots[1:]))
                await lead.expect(f"debrief-crew 0 {mask} {mask} {mask ^ 1}")
                await send_key(lead, decision)
                await asyncio.gather(*(pilot.expect(f"briefing {following}") for pilot in pilots))
            await asyncio.gather(*(pilot.expect("mission 2 lead 0") for pilot in pilots))
            print("Co-op: four pilots ejected, a departure updated the debrief, and three replayed then reached Mission 2.")


def free_metrics_port(game_port):
    while True:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as endpoint:
            endpoint.bind(("127.0.0.1", 0))
            port = endpoint.getsockname()[1]
        if port != game_port:
            return port


async def scrape(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(b"GET /metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        await writer.drain()
        head, _, body = (await reader.read()).partition(b"\r\n\r\n")
        require(head.startswith(b"HTTP/1.1 200 "), "metrics endpoint did not return 200")
        require(b"content-type: text/plain; version=0.0.4" in head.lower(), "missing metrics content type")
        return {name: float(value) for name, value in (row.split() for row in body.decode("ascii").splitlines()
                                                        if not row.startswith("#"))}
    finally:
        writer.close()
        await writer.wait_closed()


async def await_sample(port, ready):
    while True:
        sample = await scrape(port)
        if ready(sample):
            return sample
        await asyncio.sleep(0.05)


async def check_dedicated_cycle(binary, credentials, seed, game_dir):
    async with Loopback(binary, credentials, seed, vary_by_direction=True) as game:
        with tempfile.TemporaryDirectory() as directory:
            metrics = free_metrics_port(game.port)
            config = Path(directory) / "server.ini"
            config.write_text(
                f"[Server]\nPort={game.port}\nArena=asteroid-field\nGameDirectory={game_dir}\n"
                f"Players=4\nMinPlayers=3\nStartDelaySeconds=4\nRoundSeconds=2\n[Metrics]\nPort={metrics}\n",
                encoding="utf-8",
            )
            host = await game.start("--headless", str(config))
            await host.expect("listening ")
            players = "openreliant_players"
            ticks = "openreliant_simulation_tick_duration_seconds_count"
            starts = 'openreliant_rounds_started_total{mode="asteroid-field"}'
            completions = 'openreliant_rounds_completed_total{mode="asteroid-field"}'
            before = await scrape(metrics)
            require(before[players] == 0 and before["openreliant_player_capacity"] == 4, "the dedicated host counts as a pilot")
            pilots = list(await asyncio.gather(*(game.join_target(game.address, "keyboard") for _ in range(2))))
            sample = await await_sample(metrics, lambda data: data[players] == 2)
            require(sample[ticks] == 0 and sample[starts] == 0, "the arena started below its configured minimum")
            pilots.append(await game.join_target(game.address, "keyboard"))
            await await_sample(metrics, lambda data: data[players] == 3)
            await asyncio.sleep(1.6)
            pilots.append(await game.join_target(game.address, "keyboard"))
            await asyncio.sleep(2.8)
            sample = await scrape(metrics)
            require(sample[players] == 4 and sample[ticks] == 0, "the last admission did not restart the countdown")
            launched = await await_sample(metrics, lambda data: data[starts] == 1 and data[ticks] > 5)
            for direction in ("sent", "received"):
                require(launched[f'openreliant_game_bytes_total{{direction="{direction}"}}'] > 0, "game traffic was not counted")
            require(launched['openreliant_joins_total{outcome="admitted"}'] == 4, "admissions did not reach metrics")
            denied = await game.start("session", "join", await game.path(game.address), "straight")
            await await_sample(metrics, lambda data: data['openreliant_joins_total{outcome="rejected"}'] > 0)
            require(await denied.wait() != 0 and denied.admission is None, "a full server admitted another pilot")
            await await_sample(metrics, lambda data: data[completions] >= 1)
            await await_sample(metrics, lambda data: data[starts] >= 2)
            await asyncio.gather(*(send_key(pilot, "q") for pilot in pilots))
            await asyncio.gather(*(pilot.wait() for pilot in pilots))
            empty = await await_sample(metrics, lambda data: data[players] == 0)
            require(empty['openreliant_departures_total{outcome="normal"}'] == 4, "departures did not reach metrics")
            await asyncio.sleep(0.25)
            idle = await scrape(metrics)
            await asyncio.sleep(0.25)
            require((await scrape(metrics))[ticks] == idle[ticks], "the empty server did not stop simulating")
            print("Dedicated: the fourth pilot reset the countdown, a timed round returned to the lobby and relaunched, and an empty server waited.")


async def check_metrics_shutdown(binary, credentials, seed):
    async with Loopback(binary, credentials, seed) as game:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "server.ini"
            metrics = free_metrics_port(game.port)
            config.write_text(f"[Server]\nPort={game.port}\nArena=training\nPlayers=2\nRoundSeconds=1\n"
                              f"[Metrics]\nPort={metrics}\n", encoding="ascii")
            host = await game.start("--headless", str(config))
            await host.expect("listening ")
            require((await scrape(metrics))["openreliant_players"] == 0, "empty server metric is wrong")
            pilots = await asyncio.gather(*(game.join_target(game.address, "straight") for _ in range(2)))
            # A scraper can be connected while the game shuts down.
            reader, writer = await asyncio.open_connection("127.0.0.1", metrics)
            try:
                await finish(host, pilots)
                require(not await reader.read(1), "the metrics listener left the scrape connection open")
            finally:
                writer.close()
                await writer.wait_closed()
            try:
                _, unexpected = await asyncio.open_connection("127.0.0.1", metrics)
            except ConnectionRefusedError:
                pass
            else:
                unexpected.close()
                await unexpected.wait_closed()
                raise RuntimeError("the metrics listener stayed open after shutdown")
            print("Metrics: the independent HTTP listener served a scrape and closed with the game.")


async def run(binary, credentials, seed, game_dir):
    print("Clean loopback" if seed is None else f"Loopback seed {seed}, 6% packet loss, 8 to 44 ms one-way lag")
    for check in (check_training, check_beacons, check_invites, check_full_arena, check_metrics_shutdown):
        await asyncio.wait_for(check(binary, credentials, seed), 40)
    if game_dir is not None:
        if seed is not None:
            print("Stock arenas independently vary each direction of each link, with 3 to 9% loss and 8 to 80 ms latency.")
        for index, mode in enumerate(("nuclear-threat", "asteroid-field", "dark-reign", "tag-bomb", "hunt-the-shadow", "vampires")):
            await asyncio.wait_for(check_full_arena(binary, credentials, None if seed is None else seed + index, mode, game_dir), 45)
        await asyncio.wait_for(check_dedicated_cycle(binary, credentials, seed, game_dir), 60)
        await asyncio.wait_for(check_team_cycle(binary, credentials, seed, game_dir), 45)
        await asyncio.wait_for(check_coop(binary, credentials, seed, game_dir), 180)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("credentials", type=Path)
    parser.add_argument("--seed", type=int, default=1483, help="seed for packet loss and latency")
    parser.add_argument("--clean", action="store_true", help="run without packet impairment")
    parser.add_argument("--game-dir", type=Path, help="installed data for the stock modes and campaign")
    args = parser.parse_args()
    game_dir = args.game_dir.resolve() if args.game_dir else None
    asyncio.run(run(args.binary.resolve(), args.credentials.resolve(), None if args.clean else args.seed, game_dir))
