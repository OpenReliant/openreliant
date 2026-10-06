#!/usr/bin/env bash
# usage: doctor.sh <root> <jdk-home> <ghidra-home> <ghidra-platform> <ghidra-user-dir> <zig> <project.gpr> <zig-version>
#
# Reports which parts of the environment are in place. Read-only; always exits 0.
set -uo pipefail

root=$1 jdk_home=$2 ghidra_home=$3 platform=$4 user_dir=$5 zig=$6 gpr=$7 zig_version=$8

check() { # check <label> <command...>
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  \033[32mok\033[0m       %s\n' "$label"
    else printf '  \033[31mmissing\033[0m  %s\n' "$label"; fi
}

native() { [[ -x "$ghidra_home/Ghidra/Features/Decompiler/build/os/$platform/decompile" ||
              -x "$ghidra_home/Ghidra/Features/Decompiler/os/$platform/decompile" ]]; }

echo "toolchain"
check "zig ($("$zig" version 2>/dev/null || echo '?'))"   "$zig" version
check "zig is $zig_version, as build.zig.zon asks"         test "$("$zig" version 2>/dev/null)" = "$zig_version"
check "uv (ghydra CLI + MCP bridge)"                       command -v uv
check "JDK at tools/jdk"                                   "$jdk_home/bin/java" -version
check "Ghidra at ${ghidra_home#"$root"/}"                  test -x "$ghidra_home/ghidraRun"
check "Ghidra decompiler for $platform"                    native
check "Ghydra plugin installed"                            test -f "$user_dir/Extensions/Ghydra/lib/Ghydra.jar"
check "Ghydra plugin enabled in the CodeBrowser"           grep -q eu.starsong.ghidra.GhydraPlugin "$user_dir/tools/_code_browser.tcd"
check "ghydra CLI at tools/venv"                           "$root/tools/venv/bin/ghydra" --version

echo "game"
disc() { [[ -f "$root/game/discs/disc$1.bin" || -f "$root/game/discs/disc$1.zip" ]]; }
both_discs() { disc 1 && disc 2; }
check "disc images (game/discs/disc<N>.bin or .zip)"       both_discs
check "disc contents (game/cd1, game/cd2)"                 test -f "$root/game/.stamp-cd1" -a -f "$root/game/.stamp-cd2"
check "installed files (game/install)"                     test -f "$root/game/.stamp-install"

echo "ghidra project"
check "${gpr#"$root"/}"                                    test -f "$gpr"
for stamp in "$(dirname "$gpr")"/.imported-*; do
    [[ -e "$stamp" ]] && printf '  \033[32mok\033[0m       imported group: %s\n' "${stamp##*.imported-}"
done
exit 0
