"""Post OpenReliant releases and main commits to Discord."""

import json
import os
import subprocess
import sys
from time import sleep
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def post(webhook, content):
    payload = {"content": content, "allowed_mentions": {"parse": []}}
    request = Request(
        f"{webhook}?wait=true",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "OpenReliant GitHub Actions",
        },
    )
    for attempt in range(5):
        try:
            with urlopen(request, timeout=20):
                return
        except HTTPError as error:
            with error:
                if error.code != 429 or attempt == 4:
                    sys.exit(f"Discord returned HTTP {error.code}.")
                delay = float(error.headers["Retry-After"])
            sleep(delay)
        except (URLError, TimeoutError):
            sys.exit("Could not reach Discord.")


def post_commits(webhook, repository_url):
    before = os.environ["BEFORE"]
    after = os.environ["GITHUB_SHA"]
    # A force push can leave the old tip outside the history that checkout fetches.
    if subprocess.run(
        ["git", "cat-file", "-e", before], stderr=subprocess.DEVNULL
    ).returncode:
        subprocess.run(["git", "fetch", "--no-tags", "origin", before], check=True)
    # Read the full push range. The push event caps its list of commits.
    log = subprocess.check_output([
        "git", "log", "--topo-order", "--reverse", "-z", "--format=%H%x00%s",
        f"{before}..{after}",
    ]).decode("utf-8", errors="replace")
    fields = log.split("\0")[:-1]
    for commit, subject in zip(fields[::2], fields[1::2], strict=True):
        post(webhook, f"[{commit[:7]}]({repository_url}/commit/{commit}) {subject[:500]}")


def post_release(webhook, repository_url):
    tag = os.environ["TAG"]
    release_url = f"{repository_url}/releases/tag/{quote(tag, safe='')}"
    download_page = "https://openreliant.space/#download"
    content = f"**OpenReliant {tag}**\n[Downloads]({download_page}) · [Release notes]({release_url})"
    post(webhook, content)


def main():
    webhook = os.environ.get("DISCORD_WEBHOOK")
    if not webhook:
        print("Discord webhook is not configured.")
        return
    repository_url = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
    notify = {"commits": post_commits, "release": post_release}[sys.argv[1]]
    notify(webhook, repository_url)


if __name__ == "__main__":
    main()
