#!/usr/bin/env bash
# usage: check-mission-guide.sh <sltool> <mission1.dte> <guide.md>
#
# Makes the change to the game's mission 1 that the guide to writing missions
# (docs/guide/missions.md) shows as a diff: decompiles the mission, changes the source as the diff
# says, builds the mission again, checks it as `sltool dte check` does, and checks that it
# decompiles to the changed source.
# The guide can't hold the game's mission, only the diff, so this keeps the diff in step with what
# `sltool dte decompile` writes. `make check-missions` runs it.
set -euo pipefail
sltool=$1 mission=$2 guide=$3

# The guide's diff, then the lines it starts from and the lines it ends with.
hunk=$(awk '/^```diff$/ { inside = 1; next } /^```$/ { inside = 0 } inside' "$guide")
if [[ -z $hunk ]]; then
    echo "FAILED: $guide shows no diff"
    exit 1
fi
before=$(sed -n 's/^[ -]//p' <<< "$hunk")
after=$(sed -n 's/^[ +]//p' <<< "$hunk")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$sltool" dte decompile "$mission" > "$work/mission1.mission.luau"
# The lines before the change must stand in the source once, as whole lines, and the lines after it
# take their place.
if ! BEFORE=$before AFTER=$after awk '
    { text = text "\n" $0 }
    END {
        text = text "\n"
        before = "\n" ENVIRON["BEFORE"] "\n"
        at = index(text, before)
        if (at == 0 || index(substr(text, at + 1), before) != 0) exit 1
        rest = substr(text, at + length(before))
        printf "%s%s\n%s", substr(text, 2, at - 1), ENVIRON["AFTER"], rest
    }' "$work/mission1.mission.luau" > "$work/changed.mission.luau"; then
    echo "FAILED: the lines of the diff in $guide aren't in mission 1's source once"
    exit 1
fi
"$sltool" dte build "$work/changed.mission.luau" "$work/mission1.dte"
"$sltool" dte check "$work/mission1.dte" > /dev/null
if ! "$sltool" dte decompile "$work/mission1.dte" | cmp -s - "$work/changed.mission.luau"; then
    echo "FAILED: mission 1 built with the diff in $guide doesn't decompile to the changed source"
    exit 1
fi
echo "the change to mission 1 that $guide shows builds"
