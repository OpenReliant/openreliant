# Modding

OpenReliant plays mods: files that stand in for the game's own, or add to them, without changing
the game's files. A mod replaces a model, a picture of the interface, a sound, a piece of music, a
line of speech, a pilot's face, a movie, a mission or a stats table alike, with a file of the same
name as the one it replaces.

**Improvement:** the original reads its own files alone.

## Where mods go

Mods go in a folder named `mods` in the game's folder, beside `resource.hog`. Each mod is one of:

- **an archive**, a `.hog` file of the game's own format ([`.HOG` archives](../formats/hog.md)),
  as `sltool hog pack` makes one; or
- **a folder** of files, for a mod while it is being made. Its files lie in the folder itself: a
  folder within it is left out, as `sltool hog pack` leaves it.

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

`--no-mods` plays the game's own files alone.

## How a mod's file stands in

A mod's file stands in for every file of the game's of the same name, wherever the game keeps it:
the members of its archives and its loose files. Names match whatever their case, and by the file's
name alone, without its folders: a mod's `New_Pensive.wav` replaces `music\New_Pensive.wav`. A file
of a name the game has none of adds one, for a mission or a model of the mod's own to use. Where the
game keeps a name in several places, it keeps copies of one file there, such as the stats tables,
which lie both loose and in `resource.hog`, or one picture saved twice. Where an archive repeats a
name, the game reads the first, and the mod's file stands in for that one.

| What | Where the game keeps it | For example |
|---|---|---|
| Models | `resource.hog` | `USA_Coyote.SHP` |
| Pictures, fonts and sprites of the interface | `resource.hog`, `CD1.HOG`, `CD2.HOG` | `brd2cd.tga`, `FONT.FNT`, `medal1.spr` |
| Sound banks | `resource.hog`, `CD1.HOG`, `CD2.HOG` | `betty.fat` |
| Music | `music\` | `New_Pensive.wav` |
| Speech | `ms_speech\msspeech.hog` | `ABRT_001` |
| Pilots' faces | `pilots\pilots.hog` | `45Tigers_Moose_D.fm8` |
| Movies | the game's folder, `interface\`, `inter\`, `CD1.HOG`, `CD2.HOG` | `New_nms.bik`, `int.bik` |
| Missions | `missions\`, `resource.hog` | `mission1.dte` |
| Stats tables | the game's folder | `shipstats.bin` |

`sltool hog ls <archive>` lists an archive's members by name, and `sltool hog extract` copies them
out. Names are flat, so a mod gives the files it adds a prefix of its own, which keeps them apart
from another mod's.

A mod's files are in the game's own formats, which the [developer documentation](../README.md)
describes, but for the pictures and fonts below: textures and the interface's pictures, in PNG at
any size, and the interface's fonts, in TrueType or OpenType. Files in today's formats come later:
glTF models ([#359](https://github.com/vdmkenny/openreliant/issues/359)), and sounds, music,
speech and movies ([#496](https://github.com/vdmkenny/openreliant/issues/496)).

## Textures

The textures of the models and the effects come from the texture cache, `tcachehw.dat`
([Texture caches](../formats/tcache.md)), each by a name without an extension, such as `yank_2`, the
Coyote's hull. A mod replaces one with a PNG picture of its name, `yank_2.png`, at any size, with
alpha of its own where it needs it. `sltool tcache ls tcachehw.dat` lists the names and sizes, and
`sltool tcache extract tcachehw.dat palette.tga textures yank_2` writes a texture out as a PNG
picture of its own size and name, the template for its replacement.

- A picture is made for the model's own texture coordinates, which the cache's texture shows: the
  same layout at more pixels. The whole picture covers what the whole texture covers, so its art
  stays where the template has it.
- Keep the template's proportions, at a whole multiple of its size: a 256x128 texture takes 1024x512
  or 2048x1024. A picture of other proportions is stretched over the model alike, its art with it.
- OpenReliant makes its mipmaps as it loads it, each level half the last down to a pixel, in linear
  light and weighted by alpha, so that a picture needs none of its own.
- A side longer than 8192 pixels is halved until it fits, since every GPU takes that much.
- A 4096x4096 picture takes about 85 MB of the GPU's memory with its mipmaps, and as much of the
  computer's; 2048x2048 suits a fighter.

**Improvement:** the original reads the cache's images alone, at most 256x256.

## Material maps

A picture may come with the maps today's tools paint beside it, which light its surface as the
material it is, a metal or a paint, rough or polished, in the metallic way glTF 2.0, Blender and
most engines share:

| File | Holds |
|---|---|
| `yank_2_normal.png` | The surface's normals, as OpenGL's normal maps hold them: green toward the picture's top |
| `yank_2_orm.png` | Occlusion, roughness and metallic in red, green and blue, as glTF packs them |
| `yank_2_occlusion.png`, `yank_2_roughness.png`, `yank_2_metallic.png` | Each alone, in grey, where no `_orm` map packs them |

Each map is the size of its picture, and either may be missing: a normal map alone bends the light
over the surface's details, and a material map alone gives it its highlights. Where a map lacks, the
surface is flat, unshaded by occlusion, rough or not metallic. Maps are linear values, not colours,
and their mipmaps are made as such: the normals' means a unit long again, each level keeping in
alpha how far the normals it stands for spread, so a normal map's own alpha is not read.

Where each pixel is lit, OpenReliant then lights the surface as its maps describe: the normal map
bends each pixel's normal, in the texture's own frame on the surface, worked out without tangents in
the models, and shades the ambient light the further it tilts the normal from the surface's own, so
that its grooves and edges show on the side away from the lights too; the material map gives the
highlights each light makes, by how rough the surface is and how metallic, metal tinting them with
its own colour, in place of the original's highlight pass; it reflects what surrounds the ship, the
sky and the nebula, blurred as rough as the surface is, so that smooth glass reflects the nebula
clearly at glancing angles and polished metal shows it everywhere; and occlusion shades the ambient
light and the reflections. Where the normal map's details are finer than a pixel, the surface looks
rougher by as much as they spread, as Toksvig's method makes it, rather than its highlights
sparkling. The base picture should hold the surface's own colour, with no shading painted in, or the
light shows twice. VIDEO's MATERIALS and `--no-materials` turn the maps off, as `--original` does.

A metal's base colour is how much light it reflects, its highlights and its reflections tinted with
it: real metals reflect half of the light and more, steel about 56 percent and aluminium about 91,
which is about 180 to 255 in sRGB. A metal painted darker reflects too little to show; its dirt and
wear go in the roughness map, or in a non-metal part of the metallic map, rather than in a darker
colour.

**Improvement:** the original lights every surface alike, with its highlight pass on top.

## The interface

The interface draws its shapes from sprite sets ([`.SPR` sprites](../formats/spr.md)): the flight
display's from `HUDHARD.SPR`, each screen's from a set of its own, and each ship's schematic, which
the display shows of the player's ship and of the target, from a set such as `ARCHSCEM.SPR`. Behind
the screens it shows TGA pictures. A mod replaces either with a PNG picture at any size.

### Shapes

A mod replaces a shape with a PNG picture named as `sltool spr extract` names the shape's: the set's
name, `_`, the shape's place in the set in three digits at least, and `.png`, such as
`HUDHARD_127.png`, the targeting cluster's arc. The extracted picture is the template for its
replacement:

```bash
sltool hog extract resource.hog files           # the sprite sets, among the rest
sltool spr ls files/HUDHARD.SPR                 # each shape's place in the set and its size
sltool spr extract files/HUDHARD.SPR shapes     # each shape as a picture of its own size and name
```

- **Size and proportions.** A picture is drawn over the rectangle the template covers, whatever its
  own size. Keep the template's proportions, at a whole multiple of its size: the 68x141 arc takes
  a 272x564 picture at four times. A picture of other proportions is stretched to the rectangle.
- **Layout.** The game places a shape by that rectangle, so the art stays where the template has
  it: art moved within the picture moves on the screen, and art past the template's edges is
  squeezed into them, so the template's margins are all the room there is. Shapes drawn over one
  another keep their layouts together: a ship's schematic, shape 0, and the hits on its four
  quadrants, shapes 1 to 4, which flash over it; a gauge's unlit shape and the lit one drawn over
  it as far as its level, such as the speed's, `HUDHARD_185.png` and `HUDHARD_184.png`.
- **One picture, several places.** The game draws some shapes mirrored, such as the targeting
  cluster's right arc, which is the left one turned about, and others at several places; one picture
  serves them all. A shape it draws in several colours is a shape for each colour, each with its own
  picture.
- **Alpha and colour.** The template is clear around the shape, and a picture keeps its own alpha,
  soft edges included. It is drawn in its own colours, dimmed where the game dims the shape, such as
  a menu item that can't be used.
- **How large.** The flight display and the pause menu are drawn for a 1024x768 window, and the
  front end's screens, the briefing's, the ITAC's and the loadout's for 640x480, each grown to the
  window by whichever side has less room, as the table shows. A picture as many times the
  template's size as the window draws it is sharp: four times suits the flight display up to
  3840x2160 and the screens up to 2560x1440. A larger one gains nothing, and costs memory and the
  time to read it, which the first frame to draw its shape waits for.

| Window | The flight display and the pause menu | The front end's screens |
|---|---|---|
| 1920x1080 | 1.4 times | 2.25 times |
| 2560x1440 | 1.9 times | 3 times |
| 3840x2160 | 2.8 times | 4.5 times |

### Pictures

The pictures behind the screens, the ITAC's, the briefing's door and the loading screens are TGA
files, as is the loadout's backdrop. A mod replaces one with a PNG picture of its name,
`sl_splash2.png` for `interface\sl_splash2.tga`, at any size.

- **Size and proportions.** A picture is drawn as high as the screen, keeping its proportions, and
  centred across it. The game's are 4:3, 640x480 but for the loading screens' larger copies, and a
  4:3 picture, such as 1280x960, 2560x1920 or 2880x2160, covers the screen as they do.
- **Widescreen.** A wider picture reaches past the screen's sides into a wider window: a 16:9
  picture, such as 1920x1080 or 3840x2160, fills a 16:9 window, where the game's leave bars at the
  sides. Its middle 4:3, 1440x1080 of 1920x1080, stands behind the screen, whose shapes, buttons
  and text stay where the game lays them out, so the art they sit on belongs in the middle; the
  sides are for the scenery around it. A narrower window cuts the sides off, and a wider one than
  the picture shows bars beyond it.
- **Opaque.** A picture is drawn opaque, its alpha left out, as the game's own are.

A few TGA pictures are read for their pixels, at their own size. A PNG stands in for one of these at
that size alone, and one of another size is left out, which the log says
([#509](https://github.com/vdmkenny/openreliant/issues/509)):

| Picture | Size | What it is |
|---|---|---|
| `fpanels.tga` | 256x256 | The loadout's panels |
| `powerball.tga` | 256x256 | The flight display's power ball |
| `space.tga` | 360x360 | The star map |
| `starref12.tga` | 256x256 | The colours of the sky |

**Improvement:** the original draws its interface from its own pictures, at their own size, and
stretches its backgrounds over the screen.

### Fonts

The interface writes its text in bitmap fonts made for the 640x480 screens
([`.fnt` fonts](../formats/fnt.md)). A mod replaces one drawn in one colour with a TrueType or
OpenType font of its name, `optfnt.ttf` or `optfnt.otf` for `interface\optfnt.fnt`, drawn at the
window's resolution ([Outline fonts](../formats/fnt.md#outline-fonts)):

| Font | What it writes |
|---|---|
| `optfnt.fnt` | The large text of the front end, the pause menu and the loading screens: titles and labels |
| `smlfnt2.fnt` | Their small text: the buttons, the lists and OpenReliant's version |
| `itacbig.fnt` | The ITAC's large text, and the CD player's and the simulator pod's titles |
| `itacsml.fnt` | The ITAC's small text |
| `font_01.fnt` | The main menu's developers' text |

- **Layout.** The game lays its text out by the bitmap font's widths, which stay. Each character of
  the mod's font is drawn in the place the bitmap font gives it, centred on where the bitmap's
  glyph has its ink, with its capitals as tall as the bitmap's, so a font of other proportions
  still fits each screen.
- **Characters.** The game's text is in Windows code page 1252. A character the font has no glyph
  for is drawn from the bitmap font.
- **Built in.** OpenReliant draws the first four in Newtown, a public domain font in the style of
  Handel Gothic, the original's face. A mod's font comes before Newtown, and a mod's own `.fnt`
  before both.
- **Licence.** A font goes out with the mod, so its licence has to allow that.

The fonts drawn through palettes, the loadout's and the flight display's, keep their glyphs
([#520](https://github.com/vdmkenny/openreliant/issues/520)).

**Improvement:** the original draws its text in its bitmap fonts, at 640x480.

## The order of the mods

The mods are read in the order of their names, whatever their case, and a later mod's file stands in
for an earlier mod's of the same name: names such as `10-ships` and `20-music` set the order. All of
them come before the game's own files, its loose files among them, so that a mod's `mission18.dte`
replaces the loose `missions\mission18.dte` a retail install carries. A mod manager that chooses and
orders the mods in the game is [#497](https://github.com/vdmkenny/openreliant/issues/497).

## A folder's files

A folder mod holds the files as the game reads them, and reads as the archive `sltool hog pack`
makes of the folder:

- A file that holds a RefPack stream, as a member extracted with `sltool hog extract --raw` does,
  is read expanded, as the game reads a packed member. The movies and the pilots' faces, which the
  game reads as they are stored, are read as they are.
- A file's name is printable ASCII, as an archive member's is. Hidden files, such as `.DS_Store`,
  are passed over.

`sltool hog pack coyote coyote.hog` packs the folder into an archive, which stands in the same way.
The manifest and the thumbnail go into it with the rest.

## The manifest

A mod describes itself in `mod.ini`, in its archive or its folder, an ini file of the kind
`starlancer.ini` is:

```ini
[Mod]
Name=Coyote HD
Version=1.0
Author=Someone
Description=The Coyote, modelled again.
Url=https://example.com/coyote-hd
```

Each key is optional, and found whatever its case. `Url` is the mod's page on the web, where a
player finds it and its updates. The game asks for no file of this name, so the archive stays one
the original reads, and the manifest stands in for none of the game's files.

## The thumbnail

A mod may carry a picture of itself, `mod.png`, in its archive or its folder, which a mod manager
shows ([#497](https://github.com/vdmkenny/openreliant/issues/497)). It is a PNG file of any size; a
4:3 picture, such as 320x240, suits the game's screens. Like the manifest, it is the mod's own.

## Checksums

An archive may come with a checksum file beside it, its name with `.sha256` added, as `sha256sum`
writes one: the archive's SHA-256 digest in hexadecimal, two spaces and the archive's name. As the
mod loads, OpenReliant reads the archive through and leaves the mod out where its digest is not the
one the file gives, since the archive is then damaged or not the one the checksum was made for.
`sltool hog pack <folder> <archive> --checksum` writes one beside the archive it packs, and
`sha256sum -c music.hog.sha256` checks one by hand. A folder mod has none.

## What OpenReliant says

As it starts, `openreliant` lists each mod it plays with, in its order, by its manifest's name
where it has one, then each of its files: what it replaces, the game's file, texture, shape,
picture or font or an earlier mod's file, or the file it adds. As a font opens, it says which
outline font draws it.

```text
info(mods): music.hog matches music.hog.sha256
info(mods): mod 1 of 2: Coyote HD 1.0, by Someone (coyote)
info(mods): coyote replaces USA_Coyote.SHP
info(mods): mod 2 of 2: music.hog
info(mods): music.hog replaces New_Pensive.wav
info(mods): music.hog adds msc_theme.wav
info(fonts): optfnt.fnt is drawn in Newtown
```

`openreliant missions` lists and checks the missions the mods hold, `mod` in the file column, and
takes `--no-mods` too.

Mods that add to how the game plays, with scripts and new records as OpenMW's do, are
[#498](https://github.com/vdmkenny/openreliant/issues/498).
