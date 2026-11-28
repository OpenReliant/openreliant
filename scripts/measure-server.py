"""Measure what a dedicated OpenReliant host needs: CPU use, memory, step time and traffic.

Starts a headless host with its metrics on, joins it with terminal pilots over loopback, and
once every pilot is flying, reads the host's metrics and the operating system's figures for the
host process every few seconds. Each sample is printed as a line of JSON, and the range of each
figure follows at the end.

On Linux and macOS the pilots fire and steer at random through their keyboard controls. At the
end, with every pilot still in the game, each is sent Q and the host must count them all leaving,
which shows that their keys arrived. On Windows the terminal client reads keys from the console
rather than from a pipe, so the pilots fly fixed turns with their guns off.
"""

import argparse
import asyncio
import collections
import json
import os
import random
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def require(condition, description):
    if not condition:
        raise RuntimeError(description)


def linux_figures(pid):
    # The fields after the command's closing bracket start with the state, so user time and
    # system time are the 12th and 13th of them.
    fields = Path(f"/proc/{pid}/stat").read_text().rpartition(")")[2].split()
    ticks = os.sysconf("SC_CLK_TCK")
    status = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        name, _, value = line.partition(":")
        if value.strip().endswith(" kB"):
            status[name] = int(value.split()[0]) / 1024
    return {"cpu_s": (int(fields[11]) + int(fields[12])) / ticks, "rss_mib": status["VmRSS"],
            "peak_rss_mib": status["VmHWM"], "private_mib": status["RssAnon"]}


def ps_figures(pid):
    rss, cpu = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True,
                              check=True).stdout.split()
    # ps writes CPU time as [[days-]hours:]minutes:seconds.
    days, _, clock = cpu.rpartition("-")
    seconds = 0.0
    for part in clock.split(":"):
        seconds = seconds * 60 + float(part)
    return {"cpu_s": int(days or 0) * 86400 + seconds, "rss_mib": int(rss) / 1024, "peak_rss_mib": None,
            "private_mib": None}


def windows_figures(pid):
    import ctypes
    import ctypes.wintypes as wt

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD)] + [(name, ctypes.c_size_t) for name in (
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage",
            "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage",
            "PrivateUsage")]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    memory = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    kernel.OpenProcess.restype = wt.HANDLE
    kernel.GetProcessTimes.argtypes = [wt.HANDLE] + [ctypes.POINTER(wt.FILETIME)] * 4
    kernel.CloseHandle.argtypes = [wt.HANDLE]
    memory.GetProcessMemoryInfo.argtypes = [wt.HANDLE, ctypes.POINTER(Counters), wt.DWORD]
    query_information, read_memory = 0x1000, 0x0010
    handle = kernel.OpenProcess(query_information | read_memory, False, pid)
    require(handle, f"cannot open the host process: error {ctypes.get_last_error()}")
    try:
        times = [wt.FILETIME() for _ in range(4)]
        require(kernel.GetProcessTimes(handle, *map(ctypes.byref, times)), "cannot read the host's CPU time")
        counters = Counters(cb=ctypes.sizeof(Counters))
        require(memory.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb), "cannot read the host's memory")
        # FILETIME counts 100 ns; the last two are kernel time and user time.
        cpu = sum(t.dwHighDateTime << 32 | t.dwLowDateTime for t in times[2:]) / 1e7
        return {"cpu_s": cpu, "rss_mib": counters.WorkingSetSize / 2**20,
                "peak_rss_mib": counters.PeakWorkingSetSize / 2**20, "private_mib": counters.PrivateUsage / 2**20}
    finally:
        kernel.CloseHandle(handle)


if sys.platform == "linux":
    process_figures = linux_figures
elif os.name == "nt":
    process_figures = windows_figures
else:
    process_figures = ps_figures


async def scrape(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(b"GET /metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        await writer.drain()
        head, _, body = (await reader.read()).partition(b"\r\n\r\n")
        require(head.startswith(b"HTTP/1.1 200 "), "the metrics endpoint did not return 200")
        return {name: float(value) for name, value in (row.rsplit(" ", 1) for row in body.decode("ascii").splitlines()
                                                        if row and not row.startswith("#"))}
    finally:
        writer.close()
        await writer.wait_closed()


class Process:
    def __init__(self, name, process):
        self.name = name
        self.process = process
        # Pilots print a line for every snapshot, so keep only the recent ones.
        self.lines = collections.deque(maxlen=500)
        self.count = 0
        self.changed = asyncio.Event()
        self.reader = asyncio.create_task(self.read())

    async def read(self):
        async for line in self.process.stderr:
            self.lines.append(line.decode(errors="replace").rstrip())
            self.count += 1
            self.changed.set()
        self.changed.set()

    async def expect(self, text, seconds=30):
        """Wait for a line that starts with `text`."""
        async def found():
            seen = self.count
            for line in self.lines:
                if line.startswith(text):
                    return line
            while True:
                fresh = list(self.lines)[-(self.count - seen):] if self.count > seen else []
                seen = self.count
                for line in fresh:
                    if line.startswith(text):
                        return line
                if self.reader.done():
                    raise RuntimeError(f"the {self.name} ended before printing {text!r}: {list(self.lines)[-3:]}")
                self.changed.clear()
                await self.changed.wait()
        try:
            return await asyncio.wait_for(found(), seconds)
        except (TimeoutError, asyncio.TimeoutError):
            raise RuntimeError(f"the {self.name} did not print {text!r} in {seconds} s: {list(self.lines)[-3:]}") from None

    async def key(self, key):
        require(self.process.returncode is None, f"the {self.name} stopped: {list(self.lines)[-3:]}")
        try:
            self.process.stdin.write(key.encode("ascii") + b"\n")
            await self.process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            raise RuntimeError(f"the {self.name} stopped: {list(self.lines)[-3:]}") from None


async def start(name, binary, *args, cwd=None, keyboard=False):
    process = await asyncio.create_subprocess_exec(
        binary, *args, cwd=cwd, stdin=subprocess.PIPE if keyboard else subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        env={**os.environ, "SDL_AUDIO_DRIVER": "dummy", "ALSOFT_DRIVERS": "null"},
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    return Process(name, process)


def sample(before, after, figures, last_cpu, seconds):
    def change(name):
        return after[name] - before[name]

    ticks = change("openreliant_simulation_tick_duration_seconds_count")
    step = change("openreliant_simulation_tick_duration_seconds_sum")
    return {"pilots": after["openreliant_players"], "cpu_percent_of_one_core": round(100 * (figures["cpu_s"] - last_cpu) / seconds, 2),
            **{name: round(value, 1) for name, value in figures.items() if name != "cpu_s" and value is not None},
            "steps_per_second": round(ticks / seconds, 1), "average_step_ms": round(1000 * step / ticks, 3) if ticks else None,
            "slow_steps": change("openreliant_simulation_slow_ticks_total"),
            "sent_kB_per_second": round(change('openreliant_game_bytes_total{direction="sent"}') / seconds / 1000, 2),
            "received_kB_per_second": round(change('openreliant_game_bytes_total{direction="received"}') / seconds / 1000, 2),
            "messages_sent_per_second": round(change('openreliant_game_messages_total{direction="sent"}') / seconds, 1)}


async def measure(args):
    keyboard = os.name == "posix"
    pilots = 8 if args.mode == "deathmatch" else 4
    game = (f"Arena={args.arena}\nPlayers={pilots}\nMinPlayers={pilots}\nRoundSeconds={args.seconds + 60}\nRepeatRounds=0\n"
            if args.mode == "deathmatch" else f"Mission={args.mission}\nPlayers={pilots}\n")
    port, metrics = free_port(socket.SOCK_DGRAM), free_port()
    started = []
    with tempfile.TemporaryDirectory() as folder:
        config = Path(folder) / "server.ini"
        config.write_text(f"[Server]\nPort={port}\nBindAddress=127.0.0.1\nGameDirectory={args.game.resolve()}\n{game}"
                          f"StartDelaySeconds=0\nLanDiscovery=0\nCheckUpdates=0\n[Metrics]\nPort={metrics}\n", encoding="utf-8")
        try:
            host = await start("host", args.binary, "--headless", str(config), cwd=folder)
            started.append(host)
            await host.expect("listening ")
            await asyncio.sleep(5)
            waiting = process_figures(host.process.pid)
            print(json.dumps({"waiting": {name: round(value, 1) for name, value in waiting.items()
                                          if name != "cpu_s" and value is not None}}), flush=True)
            steering = random.Random(args.seed)
            for index in range(pilots):
                pilot = await start(f"pilot {index + 1}", args.binary, "session", "join", f"127.0.0.1:{port}",
                                    "keyboard" if keyboard else ("left", "right")[index % 2], keyboard=keyboard)
                started.append(pilot)
                await pilot.expect("admitted ")
            # Sample flight only: a pilot prints a view for each snapshot of the flight it gets.
            for pilot in started[1:]:
                await pilot.expect("view ", 120)
            for pilot in started[1:]:
                if keyboard and args.guns:
                    await pilot.key("f")
                if keyboard and args.steering == "circle":
                    await pilot.key(steering.choice("ad"))
            if not keyboard:
                print("Windows: the pilots fly fixed turns with their guns off.", file=sys.stderr)
            begin = last = time.monotonic()
            before, last_cpu, samples = await scrape(metrics), process_figures(host.process.pid)["cpu_s"], []
            while last - begin < args.seconds:
                for _ in range(args.interval):
                    await asyncio.sleep(1)
                    if keyboard and args.steering == "random":
                        for pilot in started[1:]:
                            if steering.random() < 0.3:
                                await pilot.key(steering.choice("asd"))
                require(host.process.returncode is None, f"the host stopped: {list(host.lines)[-3:]}")
                now, after, figures = time.monotonic(), await scrape(metrics), process_figures(host.process.pid)
                samples.append(sample(before, after, figures, last_cpu, now - last))
                print(json.dumps(samples[-1]), flush=True)
                before, last_cpu, last = after, figures["cpu_s"], now
            if keyboard:
                end = await scrape(metrics)
                gone = end.get('openreliant_departures_total{outcome="normal"}', 0)
                require(end["openreliant_players"] == pilots and gone == 0,
                        f"{pilots - end['openreliant_players']:g} of {pilots} pilots left during the run")
                for pilot in started[1:]:
                    await pilot.key("q")
                # A pilot that never got its keys stays on, and the count below says so.
                await asyncio.wait([asyncio.create_task(pilot.process.wait()) for pilot in started[1:]], timeout=20)
                left = (await scrape(metrics)).get('openreliant_departures_total{outcome="normal"}', 0)
                require(left == pilots, f"{left:g} of {pilots} pilots left with Q, so their keys did not all arrive")
        finally:
            for process in started:
                if process.process.returncode is None:
                    process.process.kill()
            await asyncio.gather(*(process.process.wait() for process in started))
    # A figure missing from any sample is left out: macOS has no peak or private memory, and a
    # sample without a step has no average step.
    print(json.dumps({"range": {name: [min(values), max(values)] for name in samples[0]
                                if None not in (values := [entry[name] for entry in samples])}}), flush=True)


def positive(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be 1 or more")
    return value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binary", type=Path, help="the openreliant executable, built with multiplayer")
    parser.add_argument("game", type=Path, help="the game's folder")
    parser.add_argument("mode", choices=("deathmatch", "coop"), help="eight pilots in an arena, or four in a mission")
    parser.add_argument("--seconds", type=positive, default=120, help="how long to sample the flight (default 120)")
    parser.add_argument("--interval", type=positive, default=10, help="seconds between samples (default 10)")
    parser.add_argument("--arena", default="asteroid-field", help="the deathmatch arena (default asteroid-field)")
    parser.add_argument("--mission", type=int, default=1, help="the co-op mission (default 1)")
    parser.add_argument("--steering", choices=("random", "circle"), default="random",
                        help="turn at random, or hold one turn each (default random)")
    parser.add_argument("--no-guns", dest="guns", action="store_false", help="keep the pilots' guns off")
    parser.add_argument("--seed", type=int, default=1, help="the seed for the pilots' turns (default 1)")
    arguments = parser.parse_args()
    arguments.binary = str(arguments.binary.resolve())
    asyncio.run(measure(arguments))
