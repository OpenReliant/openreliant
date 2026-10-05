"""Writes a copy of a TrueType font that browsers accept: Newtown (deps/newtown) for the website.

Browsers check a web font with OTS, which refuses Newtown as it is: its maxp table gives maxZones
as 3, where the format allows 1 or 2, and its cmap's offsets point past its glyphs. fontTools reads
the font and writes every table again in the form the format sets, with maxZones at 2. FreeType,
which the game draws the font with, accepts the original file.

    pip install fonttools
    python3 .github/scripts/web_font.py deps/newtown/Newtown.ttf website/fonts/Newtown.ttf
"""

import sys

from fontTools.ttLib import TTFont

# The most zones a maxp table may give: the glyph zone and the twilight zone.
MAX_ZONES = 2


def main(source, target):
    font = TTFont(source)
    # fontTools writes again only the tables it has read; read them all.
    for tag in font.keys():
        font[tag]
    font["maxp"].maxZones = min(font["maxp"].maxZones, MAX_ZONES)
    font.save(target)


if __name__ == "__main__":
    main(*sys.argv[1:])
