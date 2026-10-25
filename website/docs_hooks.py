"""MkDocs hooks for the website's docs.

- A link from a page under docs/ to a file outside it, such as a source file, goes to that file on
  GitHub, and one past the repository's root, such as ../../milestones from the README, to that
  page of the repository on GitHub.
- Each page but the first gets a description for search engines and link previews: the start of
  its text, as plain text (main.html).
- Each page's date in the sitemap is the day git last changed its file (sitemap.xml), so search
  engines see which pages changed. Without git's whole history, the sitemap gives no dates.
"""

import html
import os
import posixpath
import re
import subprocess

REPOSITORY = "https://github.com/OpenReliant/openreliant"
LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
# A paragraph or an item of a list, and a tag within one.
TEXT = re.compile(r"<(p|li)(?:\s[^>]*)?>(.*?)</\1>", re.S)
TAG = re.compile(r"<[^>]+>")

# The longest description, about what a search result shows, and the shortest that is cut at the
# end of a sentence rather than at a word. A description cut at a word ends in an ellipsis.
LONGEST_DESCRIPTION = 160
SHORTEST_DESCRIPTION = 80
ELLIPSIS = "..."


def on_pre_page(page, **_):
    page.update_date = last_change(page.file.abs_src_path)
    return page


def on_page_markdown(markdown, page, **_):
    base = posixpath.dirname("docs/" + page.file.src_uri)

    def rewrite(match):
        target = match.group(2)
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#") or target.startswith("/"):
            return match.group(0)
        path, _, anchor = target.partition("#")
        resolved = posixpath.normpath(posixpath.join(base, path))
        if resolved == "docs" or resolved.startswith("docs/"):
            return match.group(0)
        if resolved.startswith("../"):
            url = f"{REPOSITORY}/{resolved.lstrip('./')}"
        else:
            url = f"{REPOSITORY}/blob/main/{resolved}"
        return match.group(1) + url + (f"#{anchor}" if anchor else "") + match.group(3)

    return LINK.sub(rewrite, markdown)


def on_page_content(content, page, **_):
    if not page.is_homepage and "description" not in page.meta:
        text = ""
        for match in TEXT.finditer(content):
            text = " ".join((text + " " + html.unescape(TAG.sub("", match.group(2)))).split())
            # A text that leads into a list goes on with its items.
            if len(text) >= SHORTEST_DESCRIPTION and not text.endswith(":"):
                break
        if text:
            page.meta["description"] = shortened(text)
    return content


def shortened(text):
    """`text` as a description: whole where it fits, else cut after its last sentence that fits,
    or at a word."""
    if len(text) <= LONGEST_DESCRIPTION:
        return text
    end = text.rfind(". ", 0, LONGEST_DESCRIPTION) + 1
    if end >= SHORTEST_DESCRIPTION:
        return text[:end]
    fits = text[: LONGEST_DESCRIPTION - len(ELLIPSIS)]
    return fits[: fits.rfind(" ")].rstrip(",;:") + ELLIPSIS


def git(*arguments):
    """What git prints for `arguments`, run in the website's folder; None where it fails."""
    try:
        return subprocess.run(
            ["git", *arguments], cwd=os.path.dirname(os.path.abspath(__file__)),
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


# Whether git has the repository's whole history. A shallow clone takes every file as changed in
# its one commit.
WHOLE_HISTORY = git("rev-parse", "--is-shallow-repository") == "false"


def last_change(path):
    """The day git last changed the file at `path`, such as 2026-10-24; None where git can't say."""
    if not WHOLE_HISTORY:
        return None
    return git("log", "-1", "--format=%cs", "--", path) or None
