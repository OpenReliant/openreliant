"""Build the isolated probe from source on a Unix host."""

import argparse
import fcntl
import os
from pathlib import Path
import shlex
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
TARGETS = [f"{arch}-{system}" for arch in ("x86_64", "aarch64")
           for system in ("windows-gnu", "linux-gnu.2.31", "macos.15.0")]


def source(work, project, commit):
    path = work / "sources" / project.rsplit("/", 1)[1]
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q", path], check=True)
    if not (path / ".git").is_dir():
        raise RuntimeError(f"expected an isolated dependency checkout at {path}")
    if subprocess.check_output(["git", "-C", path, "status", "--porcelain", "--untracked-files=no"]):
        raise RuntimeError(f"source tree contains local changes: {path}")
    if subprocess.run(["git", "-C", path, "cat-file", "-e", commit],
                      stderr=subprocess.DEVNULL).returncode:
        subprocess.run(["git", "-C", path, "fetch", "--depth=1",
                        f"https://github.com/{project}.git", commit], check=True)
    # Always build the pin. Git refuses a checkout that would overwrite local work.
    subprocess.run(["git", "-C", path, "checkout", "-q", "--detach", commit], check=True)
    return path


def cmake(src, out, options, target=None):
    subprocess.run(["cmake", "-S", src, "-B", out, "-G", "Ninja",
                    "-DCMAKE_BUILD_TYPE=Release", *options], check=True)
    subprocess.run(["cmake", "--build", out, *(["--target", target] if target else [])], check=True)


def cross_tools(out, target, system, arch, sdk):
    tools = {}
    for name, tool in (("CC", "cc"), ("CXX", "c++"), ("AR", "ar"), ("RANLIB", "ranlib"), ("RC", "rc")):
        wrapper = out / name.lower()
        args = ["zig", tool]
        if name in ("CC", "CXX"):
            args.extend(["-target", target, "-Wno-date-time"])
            if sdk:
                args.extend(["-isysroot", sdk])
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(args) + ' "$@"\n')
        wrapper.chmod(0o755)
        tools[name] = str(wrapper)
    toolchain = out / "zig.cmake"
    settings = {"SYSTEM_NAME": system, "SYSTEM_PROCESSOR": arch,
                "TRY_COMPILE_TARGET_TYPE": "STATIC_LIBRARY", "C_COMPILER": tools["CC"],
                "CXX_COMPILER": tools["CXX"], "AR": tools["AR"], "RANLIB": tools["RANLIB"]}
    if system == "Windows":
        settings["RC_COMPILER"] = tools["RC"]
    if sdk:
        settings.update(OSX_SYSROOT=sdk, OSX_DEPLOYMENT_TARGET="15.0",
                        OSX_ARCHITECTURES=arch.replace("aarch64", "arm64"))
    toolchain.write_text("".join(f'set(CMAKE_{name} "{value}")\n' for name, value in settings.items()))
    return tools, toolchain


def build(work, target, workload):
    os.environ.setdefault("SOURCE_DATE_EPOCH", "1")
    jobs = os.environ.setdefault("CMAKE_BUILD_PARALLEL_LEVEL", "4")
    gns = source(work, "ValveSoftware/GameNetworkingSockets", "d534c19aa760df3fb75fd20db13ba1932b8a5463")
    pb = source(work, "protocolbuffers/protobuf", "f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c")
    pb_options = ["-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-Dprotobuf_BUILD_TESTS=OFF", "-Dprotobuf_WITH_ZLIB=OFF"]
    cmake(pb, work / "host", pb_options, "protoc")
    protoc = work / "host" / "protoc"
    session = workload == "session"
    late_pilot = workload in ("six-beacons", "session")
    credentials = work / (f"{workload}-identities" if late_pilot else "identities")
    if not credentials.exists():
        from credentials import issue

        issue(credentials, gns / "src/common/steamnetworkingsockets_messages_certs.proto", protoc, late_pilot=late_pilot)

    arch, platform = target.split("-", 1)
    system = "Darwin" if platform.startswith("macos") else "Windows" if platform == "windows-gnu" else "Linux"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip() if system == "Darwin" else None
    out = work / target
    out.mkdir(exist_ok=True)
    tools, toolchain = cross_tools(out, target, system, arch, sdk)
    cross = [f"-DCMAKE_TOOLCHAIN_FILE={toolchain}"]
    prefix = out / "prefix"
    cmake(pb, out / "protobuf", cross + pb_options + [
        "-Dprotobuf_BUILD_PROTOC_BINARIES=OFF", "-Dprotobuf_BUILD_LIBPROTOC=OFF",
        f"-DCMAKE_INSTALL_PREFIX={prefix}"], "install")
    if system == "Windows":
        crypto = ["-DUSE_CRYPTO=BCrypt", "-DUSE_CRYPTO25519=Reference"]
    else:
        openssl = source(work, "openssl/openssl", "45e844fa2a14ec92d146bd8f5778ac130b6625fb")
        ssl = out / "openssl"
        ssl.mkdir(exist_ok=True)
        config = "darwin64-" + arch.replace("aarch64", "arm64") + "-cc" if sdk else "linux-" + arch
        env = os.environ | tools
        subprocess.run(["perl", openssl / "Configure", config, "no-shared", "no-tests", "no-asm",
                        "no-module", f"--prefix={prefix}", "--libdir=lib"], cwd=ssl, env=env, check=True)
        for goal in ("build_generated", "libcrypto.a"):
            subprocess.run(["make", "-j" + jobs, goal], cwd=ssl, env=env, check=True)
        crypto = [f"-DOPENSSL_CRYPTO_LIBRARY={ssl}/libcrypto.a", f"-DOPENSSL_INCLUDE_DIR={ssl}/include",
                  f'-DCMAKE_CXX_FLAGS=-I"{openssl}/include"', f'-DCMAKE_C_FLAGS=-I"{openssl}/include"']
        if sdk:
            crypto.append(f'-DCMAKE_EXE_LINKER_FLAGS=-F"{sdk}/System/Library/Frameworks" -L"{sdk}/usr/lib"')
    options = []
    directory = "probe"
    if session:
        directory = "session-transport"
        options = ["-DOPENRELIANT_TRANSPORT_ONLY=ON"]
    elif workload:
        name = workload + "-loopback"
        zig_prefix = out / (workload + "-zig")
        subprocess.run(["zig", "build", name, f"-Dtarget={target}",
                        "--prefix", zig_prefix], cwd=HERE.parent.parent, check=True)
        library = name + ".lib" if system == "Windows" else f"lib{name}.a"
        options = [f"-DPROBE_WORKLOAD_LIBRARY={zig_prefix / 'lib' / library}"]
        directory = workload + "-probe"
    cmake(HERE, out / directory, cross + crypto + options + [
        f"-DGNS_SOURCE={gns}", f"-DPROBE_ROOT_KEY={credentials}/root.pub", f"-DPROBE_ZIG_TARGET={target}",
        f"-DProtobuf_DIR={prefix}/lib/cmake/protobuf", f"-DProtobuf_PROTOC_EXECUTABLE={protoc}"],
        "GameNetworkingSockets_s" if session else None)
    if session:
        shutil.copytree(gns / "include" / "steam", prefix / "include" / "steam", dirs_exist_ok=True)
        shutil.copyfile(out / directory / "gns" / "src" / "libGameNetworkingSockets_s.a",
                        prefix / "lib" / "libGameNetworkingSockets_s.a")
        if system != "Windows":
            shutil.copyfile(ssl / "libcrypto.a", prefix / "lib" / "libcrypto.a")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work", type=Path, help="directory for sources, tools and throwaway identities")
    parser.add_argument("target", choices=TARGETS)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--arena", dest="workload", action="store_const", const="arena", help="run headless flight")
    mode.add_argument("--six-beacons", dest="workload", action="store_const", const="six-beacons", help="run the headless late join and drop test")
    mode.add_argument("--session", dest="workload", action="store_const", const="session",
                      help="build libraries and test identities for openreliant session")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    # All targets share the host compiler and identities. A second invocation can wait.
    with (work / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        build(work, args.target, args.workload)
