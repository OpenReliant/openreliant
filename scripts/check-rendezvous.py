"""Join OpenReliant hosts through a directory's rendezvous, and try to abuse it.

Runs a directory on this machine, hosts that have no address to give, and pilots that join them
with an invite alone. The directory sees each side at a different public address, as it would
two home networks, through a small proxy for each.
"""

import argparse
import asyncio
import base64
import contextlib
import http.client
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

GAME = "org.openreliant.starlancer"
HOST_SOURCE = "5.5.5.5"
PILOT_SOURCE = "6.6.6.6"
STRANGER = "7.7.7.7"


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def require(condition, description):
    if not condition:
        raise RuntimeError(description)


def proxy(upstream, source):
    """A loopback proxy that names its callers' address, as a public directory's HTTPS proxy does."""

    class Proxy(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def forward(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "x-forwarded-for", "connection")}
            headers["X-Forwarded-For"] = source
            try:
                connection = http.client.HTTPConnection("127.0.0.1", upstream, timeout=5)
                connection.request(self.command, self.path, body or None, headers)
                answer = connection.getresponse()
                data = answer.read()
            except OSError:
                self.send_error(502)
                return
            self.send_response(answer.status)
            for key, value in answer.getheaders():
                if key.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True

        do_GET = do_POST = forward

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def ask(port, method, path, body=None, source=STRANGER, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(method, path, None if body is None else json.dumps(body),
                       {"X-Forwarded-For": source, "Content-Type": "application/json", **(headers or {})})
    answer = connection.getresponse()
    data = answer.read()
    return answer.status, (json.loads(data) if data else None)


class Directory:
    def __init__(self, binary, *options):
        self.port = free_port()
        self.process = subprocess.Popen([binary, "--bind", f"127.0.0.1:{self.port}", "--trust-proxy", "--no-update-check", *options],
                                        stderr=subprocess.DEVNULL)
        self.host_side = proxy(self.port, HOST_SOURCE)
        self.pilot_side = proxy(self.port, PILOT_SOURCE)
        self.host_url = f"http://127.0.0.1:{self.host_side.server_address[1]}"
        self.pilot_port = self.pilot_side.server_address[1]

    async def ready(self):
        for _ in range(100):
            with contextlib.suppress(OSError):
                if ask(self.port, "GET", "/v1/capabilities")[0] == 200:
                    return
            await asyncio.sleep(0.05)
        raise RuntimeError("the directory did not start")

    def listings(self):
        return ask(self.port, "GET", f"/v1/listings?game={GAME}&cursor=0")[1]["listings"]

    def stop(self):
        self.process.terminate()
        self.process.wait()

    def close(self):
        self.stop()
        self.host_side.shutdown()
        self.pilot_side.shutdown()


class Process:
    def __init__(self, process):
        self.process = process
        self.lines = []
        self.reader = asyncio.create_task(self.read())
        self.changed = asyncio.Event()

    async def read(self):
        async for line in self.process.stderr:
            self.lines.append(line.decode(errors="replace").rstrip())
            self.changed.set()
        self.changed.set()

    async def expect(self, text, seconds=15):
        async def found():
            seen = 0
            while True:
                for line in self.lines[seen:]:
                    if text in line:
                        return line
                seen = len(self.lines)
                if self.process.returncode is not None and self.reader.done():
                    raise RuntimeError(f"the process ended before {text!r}: {self.lines[-3:]}")
                self.changed.clear()
                await self.changed.wait()
        return await asyncio.wait_for(found(), seconds)

    async def wait(self, seconds=30):
        return await asyncio.wait_for(self.process.wait(), seconds)

    def kill(self):
        if self.process.returncode is None:
            self.process.kill()


class Game:
    def __init__(self, binary):
        self.binary = binary
        self.started = []

    async def start(self, *args, cwd=None):
        process = await asyncio.create_subprocess_exec(self.binary, *args, cwd=cwd, stdin=subprocess.DEVNULL,
                                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                                       env={**os.environ, "SDL_AUDIO_DRIVER": "dummy", "ALSOFT_DRIVERS": "null"})
        started = Process(process)
        self.started.append(started)
        return started

    async def host(self, folder, directory_url, *, unlisted, ticks=500, players=4):
        config = Path(folder) / "server.ini"
        config.write_text(f"[Server]\nPort={free_port(socket.SOCK_DGRAM)}\nArena=training\nPlayers={players}\nRoundTicks={ticks}\n"
                          f"LanDiscovery=0\nCheckUpdates=0\nName=Rendezvous check\nDirectoryServers={directory_url}\n"
                          f"Rendezvous=1\nUnlisted={int(unlisted)}\n", encoding="utf-8")
        return await self.start("--headless", str(config), cwd=folder)

    async def join(self, invite, *more):
        return await self.start("session", "join", invite, *more)

    def close(self):
        for started in self.started:
            started.kill()


def invite_of(line):
    return line[line.index("orl3:"):].strip()


def through(invite, port):
    """The invite as a pilot on another network has it: the same directory, reached its own way."""
    scheme, rest = invite.removeprefix("orl3:").split("://", 1)
    _, key, session = rest.rsplit("/", 2)
    return f"orl3:{scheme}://127.0.0.1:{port}/{key}/{session}"


def target_of(invite):
    _, key, session = invite.rsplit("/", 2)
    return {"key": base64.urlsafe_b64decode(key + "=").hex(), "session": session}


def signal(payload):
    return base64.b64encode(payload).decode()


async def finish(host, pilots):
    line = await host.expect("finished ", 40)
    require(await host.wait() == 0, "the host did not end its round cleanly")
    for pilot in pilots:
        require(await pilot.wait() == 0, f"a pilot did not end the round cleanly: {pilot.lines[-3:]}")
    return int(line.split("finished ")[1].split()[0])


async def check_invite_only(game, directory_binary):
    directory = Directory(directory_binary)
    try:
        await directory.ready()
        with tempfile.TemporaryDirectory() as folder:
            host = await game.host(folder, directory.host_url, unlisted=True)
            invite = through(invite_of(await host.expect("invite orl3:")), directory.pilot_port)
            require(directory.listings() == [], "a game for invited players was listed")
            target = target_of(invite)

            # A stranger without the invite's session can't open an exchange with the host.
            wrong = {**target, "session": "0" * 32}
            require(ask(directory.port, "POST", "/v1/rendezvous/offer", {**wrong, "signal": signal(b"x")})[0] in (403, 404),
                    "the directory opened an exchange for a session that isn't the host's")
            # Nor can it read the host's mail without the host's token.
            status, _ = ask(directory.port, "POST", "/v1/rendezvous/poll", {}, headers={"X-Directory-Rendezvous": "0" * 64})
            require(status in (401, 403, 404), f"the directory answered a guessed host token with {status}")

            # Someone who has the invite sends the host rubbish for signals, and too many of them.
            refused = 0
            for index in range(40):
                status, _ = ask(directory.port, "POST", "/v1/rendezvous/offer", {**target, "signal": signal(os.urandom(64 + index))})
                refused += status == 429
            require(refused > 0, "the directory let one address open exchanges without limit")
            status, _ = ask(directory.port, "POST", "/v1/rendezvous/offer", {**target, "signal": signal(os.urandom(4000))})
            require(status in (400, 413, 429), f"the directory took a signal larger than the transport sends ({status})")
            await asyncio.sleep(2.5)
            require(host.process.returncode is None, "the host stopped on rubbish signals")

            # An invite to a game that isn't there fails fast rather than hanging.
            stale = await game.join(invite[:-32] + "0" * 32, "straight")
            require(await stale.wait(15) != 0, "a pilot joined with an invite for another session")

            # Two invited pilots still get in, on another network than the stranger's, and fly a round.
            pilots = [await game.join(invite, steering) for steering in ("left", "right")]
            for pilot in pilots:
                await pilot.expect("admitted ", 25)
            # The connection is the pilots' own by now: the directory can go away.
            directory.stop()
            end = await finish(host, pilots)
            print(f"Invite only: two pilots joined a host with no address through the directory, and flew on to tick {end} "
                  "after it stopped. Rubbish signals, guessed tokens and a stale invite got nowhere.")
    finally:
        directory.close()


async def check_public(game, directory_binary):
    directory = Directory(directory_binary)
    try:
        await directory.ready()
        with tempfile.TemporaryDirectory() as folder:
            host = await game.host(folder, directory.host_url, unlisted=False, ticks=300)
            await host.expect("invite orl3:")
            listed = directory.listings()
            require(len(listed) == 1 and listed[0]["advertisement"].get("rendezvous") is True, f"the public game was not listed for rendezvous: {listed}")
            # What a pilot's list makes of the listing: an invite through the directory it came from.
            key = base64.urlsafe_b64encode(bytes.fromhex(listed[0]["key"])).decode().rstrip("=")
            invite = f"orl3:http://127.0.0.1:{directory.pilot_port}/{key}/{listed[0]['session']}"
            pilots = [await game.join(invite, steering) for steering in ("left", "right")]
            for pilot in pilots:
                await pilot.expect("admitted ", 25)
            end = await finish(host, pilots)
            # A host that stops takes its listing with it.
            require(directory.listings() == [], "the stopped host stayed listed")
            print(f"Public: two pilots joined a listed host through the directory and agreed on tick {end}.")
    finally:
        directory.close()


async def check_no_rendezvous(game, directory_binary):
    directory = Directory(directory_binary, "--no-rendezvous")
    try:
        await directory.ready()
        with tempfile.TemporaryDirectory() as folder:
            host = await game.host(folder, directory.host_url, unlisted=True)
            await host.expect("offers no rendezvous")
            await asyncio.sleep(2)
            require(directory.listings() == [], "a game for invited players was listed by a directory without rendezvous")
            require(host.process.returncode is None, "the host stopped without rendezvous")
            require(not any("invite orl3:" in line for line in host.lines), "the host gave an invite it can't honour")
            print("No rendezvous: a host for invited players stayed up, unlisted and without an invite.")
    finally:
        directory.close()


async def check_dead_directory(game):
    """A pilot whose invite names a directory that is not there gives up soon."""
    invite = f"orl3:http://127.0.0.1:{free_port()}/{'A' * 43}/{'0' * 32}"
    pilot = await game.join(invite, "straight")
    require(await pilot.wait(15) != 0, "a pilot joined through a directory that is not there")
    print("Dead directory: the join gave up.")


async def run(binary, directory_binary):
    game = Game(binary)
    try:
        await asyncio.wait_for(check_invite_only(game, directory_binary), 120)
        await asyncio.wait_for(check_public(game, directory_binary), 90)
        await asyncio.wait_for(check_no_rendezvous(game, directory_binary), 60)
        await asyncio.wait_for(check_dead_directory(game), 30)
    finally:
        game.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="the openreliant executable")
    parser.add_argument("directory", type=Path, help="the openreliant-directory executable, 0.4.0 or later")
    args = parser.parse_args()
    asyncio.run(run(str(args.binary.resolve()), str(args.directory.resolve())))
