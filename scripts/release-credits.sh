#!/usr/bin/env bash
# usage: release-credits.sh < notes > credited-notes
#
# Credits the contributors in a release's notes as release-please writes them. Each change's line
# links the commit it came in with; the line gets the handle of whoever opened the pull request
# merged as that commit, unless that is the repository's owner or a bot, or the line names them
# already. Every other line passes as it is, and so does a change whose pull request can't be
# looked up, with a warning.
#
#   gh release view v0.6.0 --json body --jq .body | scripts/release-credits.sh
set -euo pipefail

# A change's line: `* ... ([abc1234](https://github.com/<owner>/<repo>/commit/<sha>)) ...`.
change='^\* .*\]\(https://github\.com/([^/]+)/([^/]+)/commit/([0-9a-f]{40})\)'

lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $change ]]; then
        owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} sha=${BASH_REMATCH[3]}
        # The author of the pull request merged as the commit, where that is a person.
        if author=$(gh api "repos/$owner/$repo/commits/$sha/pulls" \
            --jq '[.[] | select(.merged_at != null)][0].user | select(. != null and .type == "User") | .login'); then
            if [[ -n $author && $(lower "$author") != $(lower "$owner") && $(lower "$line") != *"@$(lower "$author")"* ]]; then
                line="$line @$author"
            fi
        else
            echo "release-credits.sh: no pull request found for $sha" >&2
        fi
    fi
    printf '%s\n' "$line"
done
