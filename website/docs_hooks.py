"""MkDocs hook for the website's docs: a link from a page under docs/ to a file outside it, such
as a source file, goes to that file on GitHub, and one past the repository's root, such as
../../milestones from the README, to that page of the repository on GitHub."""

import posixpath
import re

REPOSITORY = "https://github.com/OpenReliant/openreliant"
LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")


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
