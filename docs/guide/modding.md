# Modding

OpenReliant supports mods: files that replace or add to the game's files, without changing the
game's files on disk. A mod can replace a model, an interface picture, a sound, a piece of music, a
line of speech, a pilot's face, a movie, a mission or a stats table. Each file in a mod replaces the
game file with the same name.

**Improvement:** the original can't load mods.

## Where mods go

Mods go in a folder called `mods` in the game folder, next to `resource.hog`. Each mod is either:

- **an archive**: a `.hog` file in the game's format ([`.HOG` archives](../formats/hog.md)), which
  `sltool hog pack` can make; or
- **a folder** of files, which is handy while you're working on a mod. The files must be directly in
  the folder: subfolders are ignored, just as `sltool hog pack` ignores them.

```text
StarLancer/
  resource.hog
  mods/
    coyote/
      mod.ini
      mod.png
      USA_Coyote.SHP
    music.hog
    music.hog.sha256
```

`--no-mods` starts the game without any mods.

`sltool`, which packs and unpacks archives and reads the game's other files, is included with
`openreliant` in each release ([Builds and releases](../port/platform.md#builds-and-releases)).

## How files are replaced

A file in a mod replaces every game file with the same name, wherever the game keeps it: inside its
archives or as a loose file. Names are matched ignoring case, and only the file name counts, not the
folder: a mod's `New_Pensive.wav` replaces `music\New_Pensive.wav`. A file with a name the game
doesn't use is added, so the mod's new missions or models can use it. Where the game has the same
name in several places, such as the stats tables, which exist both as loose files and in
`resource.hog`, or a picture that was saved twice, those are copies of the same file. Where an
archive has the same name twice, the game reads the first one, and that's the one the mod replaces.

| What | Where the game keeps it | For example |
|---|---|---|
| Models | `resource.hog` | `USA_Coyote.SHP` |
| Interface pictures, fonts and sprites | `resource.hog`, `CD1.HOG`, `CD2.HOG` | `brd2cd.tga`, `FONT.FNT`, `medal1.spr` |
| Sound banks | `resource.hog`, `CD1.HOG`, `CD2.HOG` | `betty.fat` |
| Music | `music\` | `New_Pensive.wav` |
| Speech | `ms_speech\msspeech.hog` | `ABRT_001` |
| Pilots' faces | `pilots\pilots.hog` | `45Tigers_Moose_D.fm8` |
| Movies | the game folder, `interface\`, `inter\`, `CD1.HOG`, `CD2.HOG` | `New_nms.bik`, `int.bik` |
| Missions | `missions\`, `resource.hog` | `mission1.dte` |
| Stats tables | the game folder | `shipstats.bin` |

`sltool hog ls <archive>` lists the files in an archive, and `sltool hog extract` extracts them.
Names have no folders, so give the files your mod adds a unique prefix to keep them from clashing
with another mod's files.

Mod files use the game's formats, which the [developer documentation](../README.md) describes, with
two exceptions covered below: textures and interface pictures can be PNG files of any size, and
interface fonts can be TrueType or OpenType. Support for modern formats is planned: glTF models
([#359](https://github.com/OpenReliant/openreliant/issues/359)), and sounds, music, speech and
movies ([#496](https://github.com/OpenReliant/openreliant/issues/496)).

## Textures

Model and effect textures come from the texture cache, `tcachehw.dat` ([Texture
caches](../formats/tcache.md)). Each has a name without an extension, such as `yank_2`, the Coyote's
hull. To replace a texture, add a PNG file with its name, `yank_2.png`, at any size, with an alpha
channel if it needs one. `sltool tcache ls tcachehw.dat` lists the names and sizes, and `sltool
tcache extract tcachehw.dat palette.tga textures yank_2` saves a texture as a PNG with its name and
original size, which you can use as a template.

- A picture must follow the model's texture coordinates, so keep the layout of the template, just
  with more pixels. The whole picture covers the same area as the whole original texture.
- Keep the template's proportions and use a whole multiple of its size: a 256x128 texture becomes
  1024x512 or 2048x1024. A picture with other proportions is stretched over the model.
- OpenReliant generates the mipmaps when it loads the picture (each level half the size of the last,
  down to one pixel, computed in linear light and weighted by alpha), so you don't need to provide
  them.
- A side longer than 8192 pixels is halved until it fits, since every GPU supports that size.
- A 4096x4096 picture uses about 85 MB of GPU memory with its mipmaps, and as much main memory.
  2048x2048 is enough for a fighter.

**Improvement:** the original only uses the textures in its cache, at most 256x256.

## Material maps

A texture can come with the extra maps that modern tools produce, which describe the surface's
material, such as metal or paint, rough or polished. They follow the metallic workflow used by glTF
2.0, Blender and most engines:

| File | Contents |
|---|---|
| `yank_2_normal.png` | The surface normals, in OpenGL's convention: green points to the top of the picture |
| `yank_2_orm.png` | Occlusion, roughness and metallic in the red, green and blue channels, as in glTF |
| `yank_2_occlusion.png`, `yank_2_roughness.png`, `yank_2_metallic.png` | The same three as separate greyscale pictures, if there's no `_orm` map |

Each map must be the same size as its texture, and either kind can be left out: a normal map on its
own adds surface detail to the lighting, and a material map on its own gives the surface its
highlights. Without a map, the surface is treated as flat, without occlusion, rough and
non-metallic. Maps hold linear values, not colours, and their mipmaps are computed that way. For
normal maps, each mipmap level renormalizes the normals and stores in its alpha channel how much the
normals it averages spread out, so the alpha channel of a normal map is ignored.

OpenReliant lights each pixel according to the maps:

- The normal map tilts each pixel's normal. The models have no tangents, so OpenReliant works out
  the texture's directions on the surface for each pixel. Ambient light gets darker the more the
  normal is tilted away from the surface, so grooves and edges also show on the side facing away
  from the lights.
- The material map sets the highlights each light makes, from the surface's roughness and metalness,
  and metals tint them with their colour. This replaces the original's highlight pass.
- Surfaces reflect their surroundings, the sky and the nebula, blurred according to the roughness:
  smooth glass reflects the nebula clearly at glancing angles, and polished metal reflects it
  everywhere.
- Occlusion darkens the ambient light and the reflections.
- Where the normal map has details smaller than a pixel, the surface looks correspondingly rougher
  (Toksvig's method), instead of its highlights sparkling.

The base texture should hold only the surface's colour, with no shading painted in, or the lighting
will show twice. The MATERIALS setting under VIDEO and `--no-materials` turn the maps off, as
`--original` does.

For metals, the base colour sets how much light the metal reflects, and tints its highlights and
reflections. Real metals reflect at least half the light: steel about 56 percent and aluminium about
91, which is about 180 to 255 in sRGB. A metal painted darker than that reflects too little to look
right. Put dirt and wear in the roughness map, or make those areas non-metallic in the metallic map,
instead of darkening the colour.

**Improvement:** the original lights every surface the same way, with a highlight pass on top.

## The interface

The interface draws its graphics from sprite sets ([`.SPR` sprites](../formats/spr.md)): the flight
display from `HUDHARD.SPR`, each screen from its own set, and each ship's schematic (shown on the
display for the player's ship and the target) from a set such as `ARCHSCEM.SPR`. The screen
backgrounds are TGA pictures. A mod can replace either with a PNG picture of any size.

### Shapes

To replace a shape, add a PNG named the way `sltool spr extract` names it: the set's name, `_`, the
shape's number in the set with at least three digits, and `.png`. For example, `HUDHARD_127.png` is
the targeting cluster's arc. Use the extracted picture as a template:

```bash
sltool hog extract resource.hog files           # the sprite sets, among other files
sltool spr ls files/HUDHARD.SPR                 # each shape's number and size
sltool spr extract files/HUDHARD.SPR shapes     # each shape as a picture at its original size
```

- **Size and proportions.** A picture is drawn over the same rectangle as the original shape,
  whatever its size. Keep the template's proportions and use a whole multiple of its size: the
  68x141 arc becomes 272x564 at four times the size. A picture with other proportions is stretched
  to fit.
- **Layout.** The game positions shapes by that rectangle, so keep the art where the template has
  it: art moved within the picture moves on screen, and art outside the template's edges gets
  squeezed in. The template's margins are all the room there is. Shapes drawn on top of each other
  must keep matching layouts: a ship's schematic (shape 0) and the hit markers on its four quadrants
  (shapes 1 to 4), which flash over it; or a gauge's unlit shape and the lit shape drawn over it up
  to the current level, such as the speed gauge, `HUDHARD_185.png` and `HUDHARD_184.png`.
- **One picture, several places.** The game draws some shapes mirrored, such as the targeting
  cluster's right arc, which is the left one flipped, and some in several places. One picture covers
  all of them. A shape the game draws in several colours is a separate shape for each colour, each
  with its own picture.
- **Alpha and colour.** The template is transparent around the shape, and the picture's alpha
  channel is used, including soft edges. Pictures keep their colours, but are dimmed where the game
  dims the shape, such as a menu item that can't be selected.
- **Resolution.** The flight display and the pause menu are designed for a 1024x768 window, and the
  menus, briefing, ITAC and loadout screens for 640x480. Each is scaled to fit the window, as in the
  table below. A picture is sharp when it's as many times larger than the template as the window
  scales it: four times is enough for the flight display up to 3840x2160 and for the 640x480 screens
  up to 2560x1440. Larger pictures gain nothing, and cost memory and loading time, which delays the
  first frame that shows them.

| Window | Flight display and pause menu | 640x480 screens |
|---|---|---|
| 1920x1080 | 1.4 times | 2.25 times |
| 2560x1440 | 1.9 times | 3 times |
| 3840x2160 | 2.8 times | 4.5 times |

### Pictures

The screen backgrounds, the ITAC's pictures, the briefing door and the loading screens are TGA
files, as is the loadout's backdrop. To replace one, add a PNG with its name, such as
`sl_splash2.png` for `interface\sl_splash2.tga`, at any size.

- **Size and proportions.** A picture is scaled to the screen's height, keeping its proportions, and
  centred horizontally. The game's pictures are 4:3, mostly 640x480 (the loading screens have larger
  versions), so a 4:3 picture such as 1280x960, 2560x1920 or 2880x2160 covers the screen the same
  way.
- **Widescreen.** A wider picture extends past the sides of the screen in a wider window: a 16:9
  picture, such as 1920x1080 or 3840x2160, fills a 16:9 window, where the game's pictures leave bars
  at the sides. Its middle 4:3 area (1440x1080 of 1920x1080) sits behind the screen, whose shapes,
  buttons and text stay where the game puts them, so put the important art in the middle and use the
  sides for scenery. A narrower window cuts off the sides, and a window wider than the picture shows
  bars beyond it.
- **Opaque.** Pictures are drawn without their alpha channel, like the original pictures.

A few TGA pictures are read pixel by pixel at their original size. A PNG replaces one of these only
if it has the same size; otherwise it's skipped, with a message in the log
([#509](https://github.com/OpenReliant/openreliant/issues/509)):

| Picture | Size | What it is |
|---|---|---|
| `fpanels.tga` | 256x256 | The loadout's panels |
| `powerball.tga` | 256x256 | The flight display's power ball |
| `space.tga` | 360x360 | The star map |
| `starref12.tga` | 256x256 | The sky colours |

**Improvement:** the original only draws its interface pictures at their original size, and
stretches its backgrounds to fit the screen.

### Fonts

The interface uses bitmap fonts made for 640x480 ([`.fnt` fonts](../formats/fnt.md)). A mod can
replace one with a TrueType or OpenType font with the same name, `optfnt.ttf` or `optfnt.otf` for
`interface\optfnt.fnt`, which is drawn at the window's resolution ([Outline
fonts](../formats/fnt.md#outline-fonts)):

| Font | Used for |
|---|---|
| `optfnt.fnt` | Large text in the menus, the pause menu and the loading screens: titles and labels |
| `smlfnt2.fnt` | Small text in the same places: buttons, lists and OpenReliant's version |
| `itacbig.fnt` | The ITAC's large text, and the titles of the CD player and the simulator pod |
| `itacsml.fnt` | The ITAC's small text |
| `blufont.fnt` | The flight display's text: readouts, clock, windows and objectives |
| `ld_handel.fnt` | The loadout's tooltip |
| `font_01.fnt` | The developers' text on the main menu |

- **Layout.** The game lays out text using the bitmap font's character widths, which don't change.
  Each character of the mod's font is drawn where the bitmap font would put it, centred on the inked
  part of the bitmap glyph, with capitals as tall as the bitmap font's, so a font with other
  proportions still fits each screen.
- **Characters.** The game's text uses Windows code page 1252. Characters the font doesn't have are
  drawn from the bitmap font.
- **Colour.** The flight display's font and the loadout tooltip's font are drawn through palettes. A
  mod's font for them is drawn in the colour of the bitmap font's letters, and glyphs the bitmap
  font draws in other colours, such as symbols, keep their bitmaps.
- **Weight and outline.** A mod's font is drawn at its normal weight. Each character gets a black
  outline one bitmap pixel wide, like the text in the original.
- **Built in.** OpenReliant draws all text except the developers' text with Newtown, a public domain
  font in the style of Handel Gothic, the original's typeface, with strokes as heavy as the bitmap
  font's. A mod's font takes priority over Newtown, and a `.fnt` file in a mod over both.
- **Licence.** The font is distributed with the mod, so its licence must allow that.

The loadout's panels, which draw their text into their own pictures, and the flight display's small
fonts, used for target ranges and the radio menu, still use their bitmaps
([#520](https://github.com/OpenReliant/openreliant/issues/520)).

**Improvement:** the original draws text with its bitmap fonts at 640x480.

## Load order

Mods are loaded in alphabetical order of their names, ignoring case, and a later mod's file replaces
an earlier mod's file with the same name. Use names such as `10-ships` and `20-music` to set the
order. Mods take priority over all of the game's files, including loose files, so a mod's
`mission18.dte` replaces the loose `missions\mission18.dte` in a retail install. A mod manager to
choose and order mods in the game is planned
([#497](https://github.com/OpenReliant/openreliant/issues/497)).

## Folder mods

A folder mod holds files as the game reads them, and is read the same way as the archive `sltool hog
pack` would make from it:

- A file that contains RefPack-compressed data, such as a file extracted with `sltool hog extract
  --raw`, is decompressed when read, like a compressed archive member. Movies and pilots' faces,
  which the game reads uncompressed, are read as they are.
- File names must be printable ASCII, like archive member names. Hidden files, such as `.DS_Store`,
  are ignored.

`sltool hog pack coyote coyote.hog` packs the folder into an archive, which works the same way. The
manifest and the thumbnail are included with the other files.

## The manifest

A mod describes itself in `mod.ini`, in its archive or folder, an ini file like `starlancer.ini`:

```ini
[Mod]
Name=Coyote HD
Version=1.0
Author=Someone
Description=The Coyote, remodelled.
Url=https://example.com/coyote-hd
OpenReliant=0.7
```

Every key is optional, and keys can be written in any case. `Url` is the mod's web page, where
players can find it and its updates. `OpenReliant` is the OpenReliant version the mod needs:
OpenReliant skips mods that need a newer version and says so in the log. The game never reads a file
called `mod.ini`, so the archive still works with the original, and the manifest doesn't replace any
game file. A mod's scripts are listed in a `[Scripts]` section ([Scripts](#scripts)).

## The thumbnail

A mod can include a picture of itself, `mod.png`, in its archive or folder, for a mod manager to
show ([#497](https://github.com/OpenReliant/openreliant/issues/497)). It's a PNG of any size; a 4:3
picture such as 320x240 suits the game's screens. Like the manifest, it doesn't replace any game
file.

## Checksums

An archive can have a checksum file next to it: the archive's name plus `.sha256`, in the format
`sha256sum` writes (the archive's SHA-256 hash in hexadecimal, two spaces, and the archive's name).
When the mod loads, OpenReliant checks the archive against it, and skips the mod if they don't
match, since the archive is then damaged or isn't the one the checksum was made for. `sltool hog
pack <folder> <archive> --checksum` writes a checksum file next to the archive it makes, and
`sha256sum -c music.hog.sha256` checks one by hand. Folder mods don't have checksums.

## Scripts

Mods can include scripts written in [Luau](https://luau.org), a version of Lua. This version of
OpenReliant runs **load scripts**, which change the game's records at startup: the ship, gun,
missile and pilot stats, and the game's text. Scripts that change how the game plays come in later
versions ([#498](https://github.com/OpenReliant/openreliant/issues/498)).
[`examples/mods/balance`](../../examples/mods/balance) is a complete example.

**Improvement:** the original has no scripting apart from its mission scripts.

### Adding a script

Put the script in the mod as a file ending in `.luau`, and list it in `mod.ini` under `[Scripts]`:

```ini
[Mod]
Name=Balance
OpenReliant=0.7

[Scripts]
Load=balance.luau
```

To run several scripts, separate them with commas: `Load=ships.luau, guns.luau`. They run in that
order. Scripts are ordinary files of the mod: a folder mod keeps them next to `mod.ini`, and `sltool
hog pack` packs them into the archive. Set `OpenReliant=0.7` or later, since older versions of
OpenReliant don't run scripts.

Later versions will run other kinds of scripts, such as `Global`, `Player` and `Menu`. This version
skips those and says so in the log.

### When load scripts run

Load scripts run once at startup, before the main menu. Mods run in load order ([Load
order](#load-order)), and each mod's scripts in the order they're listed, so a later mod sees the
changes of the earlier ones.

A script can return an `on_records_loaded` handler, which runs after all mods' load scripts have
finished. It's useful for checking the final values:

```lua
local records = require("openreliant.records")

return {
    engine_handlers = {
        on_records_loaded = function()
            print("Laser Cannon range:", records.guns.laser_cannon.range)
        end,
    },
}
```

`print` writes to OpenReliant's log, prefixed with the mod's folder name.

### The records

`require("openreliant.records")` returns the game's records:

| Table | Contents | First number | Names |
|---|---|---|---|
| `ships` | Ship stats, `shipstats.bin` | 0 | The ship types OpenReliant has names for, such as `predator` |
| `guns` | Gun stats, `gunstats.bin` | 1 | `laser_cannon`, `pulse_cannon` and the rest |
| `missiles` | Missile stats, `missilestats.bin` | 0 | `screamer`, `raptor` and the rest |
| `pilots` | Pilot stats, `pilotstats.bin` | 0 | |
| `text` | The game's text, `language.dll`, by string id | 1 | |
| `itac_text` | The ITAC's text, `itaclang.dll`, by string id | 1 | |

Look records up by number or by name, and use the field names from the [stat
tables](../formats/stats.md):

```lua
local records = require("openreliant.records")

records.guns.laser_cannon.damage.hull = 30   -- by name
records.ships[12].max_speed *= 1.1           -- by number
records.pilots[66].skill = "high"            -- enums use names
records.text[568] = "Laser Cannon Mk II"     -- text is a string

for number, missile in records.missiles do  -- every record, in order
    missile.lock_time *= 0.8
end
```

- **Changing several fields at once:** assign a table to the record. Only the fields in the table
  change. With a `template` record, the record is first copied from the template: `records.guns[2] =
  { template = records.guns[1], speed = 5 }`.
- **Checks:** a wrong field name or a value of the wrong type is an error, so typos don't go
  unnoticed. Integer fields take whole numbers, and enum fields take their names, such as
  `"medium"`, or a number.
- **Text** is UTF-8. Characters the game can't show become `?`.
- **Limits:** records can't be removed, because missions refer to them by number, and adding new
  records isn't supported yet ([#560](https://github.com/OpenReliant/openreliant/issues/560)).

### Other scripts and packages

`require("name")` runs another script from the same mod and returns what it returns, so a mod can
split its code into several files. Each script runs once, however often it's required, and has its
own global variables.

`require("openreliant.core")` gives `core.version`, the OpenReliant version. Other packages come in
later versions, and requiring one now gives an error that says so.

### What scripts can't do

Scripts run in a sandbox:

- They can't open files, use the network or run programs: Luau's `io`, `os` and `package` libraries
  aren't there.
- Each call into a load script may run for at most 1 second, and each mod's scripts may use at most
  64 MiB of memory.
- `math.random` returns the same numbers on every computer, so every player gets the same records.

If a script fails, OpenReliant logs the error with the file and line, undoes that script's changes,
and carries on with the next one.

### Editors

Any text editor works. [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) adds completion and
error checking to VS Code and other editors. Definitions of OpenReliant's packages for it are
planned ([#556](https://github.com/OpenReliant/openreliant/issues/556)).

## Log messages

At startup, `openreliant` lists each mod it loads, in order, by its manifest name if it has one,
followed by what each of its files does: which game file, texture, shape, picture or font it
replaces, which earlier mod's file it replaces, or which file it adds. When a font is loaded, it
says which outline font draws it.

```text
info(mods): music.hog matches music.hog.sha256
info(mods): mod 1 of 2: Coyote HD 1.0, by Someone (coyote)
info(mods): coyote replaces USA_Coyote.SHP
info(mods): mod 2 of 2: music.hog
info(mods): music.hog replaces New_Pensive.wav
info(mods): music.hog adds msc_theme.wav
info(fonts): optfnt.fnt uses Newtown, with strokes 0.002 em wider
info(scripts): balance: ran balance.luau
info(scripts): balance: the Laser Cannon hits shields for 10 and hulls for 10
```

`openreliant missions` lists and checks the missions in the mods too, showing `mod` in the file
column, and also accepts `--no-mods`.

Scripts that change how the game plays, and new records, are planned for later versions
([#498](https://github.com/OpenReliant/openreliant/issues/498)).
