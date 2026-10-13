# OpenReliant's icon

The letters OR in Newtown, the face of the website's headings and of OpenReliant's menus: the O in
the website's off-white (`#e8eaf0`) and the R in its orange (`#f08a2c`). They stand on the
website's dark sky: `#07080c`, with a warm glow from the top right (`#3a1d0c`), a blue one from the
bottom left (`#101a3a`) and a few faint stars, which fade out at the smaller sizes.

| File | What it is |
|---|---|
| `openreliant.svg` | The source, 1024 by 1024. The letters are Newtown's outlines, so it needs no font. |
| `openreliant-16.png` to `openreliant-1024.png` | The icon at 16, 32, 48, 64, 128, 256, 512 and 1024 pixels. |
| `openreliant.ico` | For Windows: 16, 20, 24, 32, 40, 48 and 64 pixels as bitmaps, and 256 as a PNG. |
| `openreliant.icns` | For macOS: 16, 32, 128, 256 and 512 points, each at 1x and 2x. |

`openreliant.exe` and `sltool.exe` carry the `.ico`
([`build_resources.zig`](../../src/tools/build_resources.zig)), and Windows shows it for the files,
the game's window and its taskbar button. On macOS and Linux, the game gives its window the 256 and
512 pixel PNGs, which macOS shows in the Dock ([`icon.zig`](../../src/openreliant/icon.zig)).

`make icon` makes the PNGs, the `.ico` and the `.icns` from the SVG again
([`icon.sh`](../../scripts/icon.sh)). It needs `rsvg-convert` (librsvg), `icotool` (icoutils) and
macOS's `iconutil`.

## Credits and licence

Newtown is by Roger White, from Roger's Fonts, and is in the public domain
([deps/newtown](../../deps/newtown/README.md)). The icon is OpenReliant's own work, under the
[Mozilla Public License 2.0](../../LICENSE) like the rest of the repository outside `docs/`.
