#!/usr/bin/env bash
# usage: check-files.sh [--staged]
#
# Fails when a file from the game, or one that looks like it, is in the repository or about to
# enter it: the files git tracks, as `make check-files` and CI check them, or with --staged those
# the next commit holds, as the pre-commit hook does. Each file is read where it lies.
#
# A file fails when it lies in one of the git-ignored directories for the game's files, has the
# extension of one of the game's file types or of what the extractors write (except the example
# mods' manifests, `mod.ini`), starts with the signature of an executable, archive, image, sound or
# document, holds binary data anywhere but the compiled shaders, or is over 1 MiB.
set -euo pipefail
# Bytes as they are, which the signatures and the binary data are told by.
export LC_ALL=C

mode=${1:-}
case $mode in
    "" | --staged) ;;
    *) echo "usage: $0 [--staged]" >&2; exit 2 ;;
esac
cd "$(git rev-parse --show-toplevel)"

# The only binary files the repository holds: the compiled shaders, and the font OpenReliant
# carries built in, which is no file of the game's (deps/newtown/README.md).
allowed_binary='^(src/platform/shaders/[^/]+\.spv|deps/newtown/Newtown\.ttf)$'
game_dirs='^(game|references|tools|ghidra/projects|ghidra/export)/'
game_types='hog|shp|spr|dte|fat|fnt|frc|tga|bik|icd|exe|dll|m3d|asi|ccb|cab|bin|dat|iso|cue|mdf|mds|nrg|img|wav|mp3|ogg|png|jpg|jpeg|gif|bmp|pcx|ppm|obj|pdf|rtf|doc|ini|sav|zip'
# Files of OpenReliant's own that share an extension with the game's: the example mods' manifests.
own_files='^examples/mods/[^/]+/mod\.ini$'
max_size=$((1024 * 1024))

failed=0
fail() { # fail <path> <reason>
    printf '  %s: %s\n' "$1" "$2" >&2
    failed=1
}

# Every file to check, one a line.
paths() {
    case $mode in
        "") git ls-files ;;
        --staged) git diff --cached --name-only --diff-filter=ACMR ;;
    esac
}

# Each path first, by where it lies and its extension, whatever its case; then the files that lie
# in the working tree, a tracked file taken out of it leaving nothing to read.
files=()
while IFS= read -r path; do
    [[ -n $path ]] || continue
    shopt -s nocasematch
    if [[ $path =~ $game_dirs ]]; then
        fail "$path" "lies in a directory kept for the game's files"
    elif [[ $path =~ \.($game_types)$ && ! $path =~ $own_files ]]; then
        fail "$path" "has the extension of one of the game's files or of what the extractors write"
    elif [[ -f $path ]]; then
        files+=("$path")
    fi
    shopt -u nocasematch
done < <(paths)

# Their sizes, in their order, from one count of them all, less its total.
sizes=()
if ((${#files[@]})); then
    while read -r size _; do
        sizes+=("$size")
    done < <(wc -c -- "${files[@]}" | head -n "${#files[@]}")
fi

for ((at = 0; at < ${#files[@]}; at++)); do
    path=${files[at]}
    if ((sizes[at] > max_size)); then
        fail "$path" "is over 1 MiB"
        continue
    fi
    # Its first four bytes, or as many as come before a NUL.
    IFS= read -r -n 4 -d '' start <"$path" || true
    case $start in
        MZ*) fail "$path" "starts like a Windows executable" ;;
        BIGF) fail "$path" "starts like a BIGF archive" ;;
        $'\x10\xfb'*) fail "$path" "starts like RefPack-compressed data" ;;
        RIFF) fail "$path" "starts like a RIFF file, a sound or a video" ;;
        BIK*) fail "$path" "starts like a Bink video" ;;
        $'\x89PNG' | $'\xff\xd8\xff'* | GIF8) fail "$path" "starts like an image" ;;
        OggS | ID3*) fail "$path" "starts like a sound" ;;
        $'PK\x03\x04' | MSCF | $'\xd0\xcf\x11\xe0' | %PDF) fail "$path" "starts like an archive or a document" ;;
        # A NUL anywhere: reading up to one finds it before the end.
        *) if ! [[ $path =~ $allowed_binary ]] && IFS= read -r -d '' _ <"$path"; then
               fail "$path" "holds binary data"
           fi ;;
    esac
done

if ((failed)); then
    echo "These look like the game's files, or work derived from them, which never go in the" >&2
    echo "repository. OpenReliant reads the game's files from the player's own installation." >&2
    exit 1
fi
