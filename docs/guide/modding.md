# Modding

OpenReliant supports mods: files that replace or add to the game's files, without changing the
game's files on disk. A mod can:

- **replace** any game file, such as a model, an interface picture, a sound, a piece of music, a
  line of speech, a pilot's face, a movie, a mission or a stats table. Each file in a mod replaces
  the game file with the same name ([How files are replaced](#how-files-are-replaced)).
- **improve the look** with larger textures, material maps, sharper interface pictures and outline
  fonts ([Textures](#textures), [The interface](#the-interface)).
- **add** ship types, guns, missiles and pilots, with models of their own built from OBJ files
  ([New ships, guns, missiles and pilots](#new-ships-guns-missiles-and-pilots),
  [Models from OBJ](#models-from-obj)).
- **run scripts** that change the game's records, react to what happens in a mission, draw over the
  display, add game modes and campaigns, and add shader effects ([Scripts](#scripts)).

**Improvement:** the original can't load mods.

## A first mod

1. Make a folder in the game folder's `mods` folder, such as `mods/my-mod`.
2. Add a manifest, `mod.ini`, which names the mod on the mods screen ([The manifest](#the-manifest)):

   ```ini
   [Mod]
   Name=My Mod
   Version=1.0
   Author=Me
   Description=A new main menu theme.
   ```

3. Put the files the mod replaces or adds in the same folder, such as a `New_Pensive.wav` that
   replaces the main menu's music.
4. Start `openreliant`. The log lists each mod and what each of its files does
   ([Log messages](#log-messages)), and GAME OPTIONS, MODS turns mods on and off
   ([The mods screen](#the-mods-screen)).

[`examples/mods`](../../examples/mods) holds example mods, each showing one part of modding with
comments in its files. Copy one as a starting point.

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

A piece of music is a WAV file, 16-bit PCM or IMA ADPCM, at any rate. Where the game's piece loops
back to a point partway through, so does the mod's, at the same moment of the music whatever its
format: make it the same length as the game's, or at least as long as its loop point, to keep the
loop where the game has it.

`sltool hog ls <archive>` lists the files in an archive, and `sltool hog extract` extracts them.
Names have no folders, so give the files your mod adds a unique prefix to keep them from clashing
with another mod's files.

Mod files use the game's formats, which the [developer documentation](../README.md) describes, with
two exceptions covered below: textures and interface pictures can be PNG files of any size, and
interface fonts can be TrueType or OpenType. `sltool shp from-obj` and `sltool shp from-gltf` turn
an OBJ or glTF file into a model in the game's format ([Models from OBJ](#models-from-obj),
[Models from glTF](#models-from-gltf)). Support for modern sounds, music, speech and movies is
planned ([#496](https://github.com/OpenReliant/openreliant/issues/496)).

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
- 2048x2048 is enough for a fighter.

### Compression

Where the GPU takes compressed textures, as desktop GPUs do, OpenReliant compresses mods' pictures
as today's games do: colours, material maps and emissive maps in BC7, normal maps in BC5. A
4096x4096 picture then
takes about 21 MB of GPU memory with its mipmaps, a quarter of the 85 MB it takes uncompressed, and
the computer lets go of its own copy once the GPU holds it.

- Compressing a large picture takes a few seconds, once. The result is kept in the game folder's
  `cache/textures`, one file for each texture, and later starts read it in a moment. A changed
  picture, or another texture detail, compresses again. The folder can be deleted at any time.
- A normal map keeps only two channels, x and y, in BC5 and uncompressed alike, so the extra value
  OpenReliant keeps for each normal map pixel (how much the normals spread out, which widens the
  highlights on fine details) moves to the material map's alpha channel.
- A 16-bit normal map is compressed from its 16 bits, which keeps more of a shallow slope than an
  8-bit picture can ([16-bit normal maps](#16-bit-normal-maps)).
- `TextureCompression=0` in `starlancer.ini`, or `--uncompressed-textures`, keeps the pictures as
  they are ([Configuration](configuration.md)).

A picture or a map can also come compressed already, in a DDS (`.dds`) or KTX2 (`.ktx2`) file with
the same name, which OpenReliant looks for before the PNG file: `yank_2.dds`, `yank_2_normal.dds`.
It reads a single 2D picture with its mipmaps, in BC1, BC3, BC5 or BC7, or uncompressed 8-bit RGBA,
without KTX2's supercompression. Its colours are taken as sRGB-encoded, as a PNG's are.

- A compressed file draws as it is, so it starts as fast as a cached one. Give it its mipmaps:
  OpenReliant can't make them from compressed pixels.
- Beside a compressed picture, a normal map in BC5 and a material map in BC7 are used as they are,
  and a PNG map is compressed to match. A map in another format is left out, which the log says.
- A compressed picture needs a GPU that takes its format. Elsewhere, such as with the software
  device, it is left out, and the cache's own texture is drawn.

**Improvement:** the original only uses the textures in its cache, at most 256x256.

### Textures in the loadout

The loadout draws the ships in green and the missiles and guns in red. The game keeps a green and a
red copy of each ship texture, named with a `g` or an `r` in front: `gyank_2` and `ryank_2` for
`yank_2`. You don't need to make them. Where your mod gives a picture but no copy, OpenReliant makes
the copy from the picture, in the same shades as the game's own copies. To draw something else in
the loadout, give the copy as a picture of its own, such as `gyank_2.png`. A picture that comes
compressed already, in a DDS or KTX2 file, can't be turned green, so give its copies as files too.

## Material maps

A texture can come with the extra maps that modern tools produce, which describe the surface's
material, such as metal or paint, rough or polished. They follow the metallic workflow used by glTF
2.0, Blender and most engines:

| File | Contents |
|---|---|
| `yank_2_normal.png` | The surface normals, in OpenGL's convention: green points to the top of the picture |
| `yank_2_orm.png` | Occlusion, roughness and metallic in the red, green and blue channels, as in glTF |
| `yank_2_occlusion.png`, `yank_2_roughness.png`, `yank_2_metallic.png` | The same three as separate greyscale pictures, if there's no `_orm` map |
| `yank_2_emissive.png` | The light the surface gives off by itself, such as glowing vents or lit windows, in colour, as glTF's emissive texture: black where it gives off none |

Each map must be the same size as its texture, and any of them can be left out: a normal map on its
own adds surface detail to the lighting, a material map on its own gives the surface its
highlights, and an emissive map on its own makes parts of it glow. Without a map, the surface is
treated as flat, without occlusion, rough, non-metallic and giving off no light. Normal and material
maps hold linear values, not colours, and their mipmaps are computed that way. An emissive map holds
colours, like the texture itself. For normal maps, each mipmap level renormalizes the normals and
keeps how much the normals it averages spread out, so the alpha channel of a normal map is ignored.

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
- The emissive map's colour is added once the pixel is lit: on the dark side of a ship it shows as
  painted, and on the lit side it brightens the surface. Keep it dark and soft for a gentle glow; a
  bright emissive map washes the surface out. The loadout draws its ships and weapons without their
  emissive maps.

The base texture should hold only the surface's colour, with no shading painted in, or the lighting
will show twice. The MATERIALS setting under VIDEO and `--no-materials` turn the maps off, as
`--original` does.

For metals, the base colour sets how much light the metal reflects, and tints its highlights and
reflections. Real metals reflect at least half the light: steel about 56 percent and aluminium about
91, which is about 180 to 255 in sRGB. A metal painted darker than that reflects too little to look
right. Put dirt and wear in the roughness map, or make those areas non-metallic in the metallic map,
instead of darkening the colour.

**Improvement:** the original lights every surface the same way, with a highlight pass on top, and
only its light maps make a surface glow.

### 16-bit normal maps

A normal map can be a 16-bit PNG, as Blender, Substance and most baking tools can write it.
OpenReliant keeps its 16 bits: a very shallow slope, such as a gently curved plate or a soft dent,
then lights smoothly instead of in bands. An 8-bit normal map has only 256 steps in each direction,
so a slope that changes by less than a step across many pixels comes out in stripes.

- Uncompressed, the normal map's x and y stay at 16 bits on the GPU, which takes no more memory
  than an 8-bit normal map.
- Compressed, OpenReliant makes the BC5 blocks from the 16-bit values. BC5 holds values between
  its 8-bit endpoints finer than 8 bits, so a shallow slope keeps much of its smoothness.
- Only normal maps are read at 16 bits. Other 16-bit pictures are read at 8 bits, which is all
  that colours, material maps and emissive maps need.

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
`mission18.dte` replaces the loose `missions\mission18.dte` in a retail install.

### The mods screen

GAME OPTIONS has a MODS button, right of ABOUT OPENRELIANT, which opens the mods screen. It lists the
mods in the `mods` folder, with what each one's manifest says of it. A check box turns a mod on or
off, and the arrows beside the list move the chosen mod up or down the load order. The mods load from
the top down, so a mod replaces the files of the mods above it. REFRESH reads the `mods` folder
again, to find mods you've added or removed while the screen is open.

- CANCEL CHANGES puts the mods back as they were when you opened the screen.
- OPTIONS opens the page of options the chosen mod offers, if its scripts declare one
  ([Options](scripting.md#options)). The mod's scripts read what you set; the values are kept in
  its storage file, `storage\<mod>.data`.
- The changes take effect the next time OpenReliant starts. RESTART TO APPLY shows while the screen's
  list differs from what's loaded.

The screen keeps the order and which mods are off in `starlancer.ini` in the game's folder, in its
own section, one line for each mod: the mod's name in the `mods` folder, and 1 if it's on or 0 if
it's off. The lines are in load order:

```ini
[OpenReliantMods]
10-ships=1
coyote=0
20-music=1
```

The mods the section doesn't list are on, and load after the listed ones, in the order of their names.
Only 0 turns a mod off. To go back to loading every mod in the order of its name, delete the section.
You can also edit it by hand.

- A mod whose name has an equals sign, starts with a bracket or has spaces at either end can't be
  listed. It stays on and loads with the unlisted mods.
- The screen lists up to 255 mods, and leaves out the ones that need a newer OpenReliant
  ([The manifest](#the-manifest)).
- `--no-mods` loads none, and keeps the screen shut.
- A screenshot taken with `--screenshot` follows the section too, so it loads only the mods that
  are on.

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

Keys are optional and can be written in any case. `Url` is the mod's web page, where players can
find it and its updates. `OpenReliant` is the OpenReliant version the mod needs: OpenReliant skips a
mod that needs a newer version and says so in the log. The original never reads a file called
`mod.ini`, so the archive still works with it, and the manifest doesn't replace any game file.

A mod's scripts are listed in the sections `[Scripts]` and `[Missions]` ([Scripts](#scripts)), and
what it adds in sections such as `[ShipTypes]`
([New ships, guns, missiles and pilots](#new-ships-guns-missiles-and-pilots)).

## New ships, guns, missiles and pilots

A mod can add ship types, guns, missiles and pilots. Each one is based on one of the game's (a
ship type can also have no base, see [Ship types without a base](#ship-types-without-a-base)):

- It starts with a copy of its base's stats, which a load script can change
  ([The records](scripting.md#the-records)).
- It behaves like its base wherever the game treats that base specially. A ship type based on the
  Phoenix carries the Nova Cannon, and a missile based on the Havoc sets off a shockwave.

The manifest lists each kind in a section of its own, and describes each entry in a section named
after it:

```ini
[Guns]
banana_gun=

[Gun banana_gun]
Base=pulse_cannon
Name=Banana Gun
```

What all four have in common:

- `Base` is the game's record the new one is based on, by OpenReliant's name for it, such as
  `predator` or `pulse_cannon`, or by its number. Guns, missiles and pilots need one.
- `Name` is what the game calls it, such as on the flight display. Without it, it takes its base's
  name.
- When it starts, OpenReliant numbers what the mods add after the game's own records, mod by mod in
  load order, so the numbers depend on which mods are on. Scripts therefore use names: the mod's
  folder name or its archive's name without `.hog`, a colon, and the name in the manifest, such as
  `bananas:banana_gun` for the gun `banana_gun` of the mod in the folder `bananas` or in
  `bananas.hog`.
- The number after a name in the list is the number the mod's own files, such as its missions and
  models, use for it. When OpenReliant loads one of the mod's files, it replaces that number with the
  one it gave, so the files stay in the game's formats. Leave the number empty when the mod's files
  don't use it. Files from other mods or from the game can't use what the mod adds.
- An entry with a mistake, such as a base that isn't one of the game's, is left out, and the log says
  why.

| Kind | List section | Its own section | First number | Most the mods add | Numbered in the mod's |
|---|---|---|---|---|---|
| Ship types | `[ShipTypes]` | `[ShipType name]` | 256 | 732 | missions' ships |
| Guns | `[Guns]` | `[Gun name]` | 16 | 240 | models' gun muzzles |
| Missiles | `[Missiles]` | `[Missile name]` | 11 | 245 | models' missile hardpoints, for every loadout tier |
| Pilots | `[Pilots]` | `[Pilot name]` | 194 | 61 | missions' ships' pilots |

[`examples/mods/interceptor`](../../examples/mods/interceptor) adds a faster Predator under a name
of its own, [`examples/mods/bananas`](../../examples/mods/bananas) a gun, a missile, a pilot and a
ship that carries them, and [`examples/mods/teapot`](../../examples/mods/teapot) a ship with a model
of its own, made from an OBJ file ([Models from OBJ](#models-from-obj)).

**Improvement:** the original's ship types, guns, missiles and pilots are its own.

### Ship types

```ini
[ShipTypes]
teapot=300

[ShipType teapot]
Base=predator
Model=teapot.shp
Schematic=teapotscem.spr
Name=Teapot
Guns=banana_gun
Missiles=banana
Cockpit=temg_frm.shp
WireFrame=teapotwire
WingIcon=teapoticon
EngineSound=kettle.wav
```

- A ship type uses its base's cockpit, engine sound and display pictures, except for the ones it
  gives itself.
- `Model` is the type's model, a `.shp` file in the mod or the game ([`.SHP`
  models](../formats/shp.md)). It can be one of the game's models under the new type's own stats.
- `Schematic` is the sprite set the display shows the ship in, as the player's ship and as a target.
  Without it, the type shows its base's. Where the mod has no file of that name, the type takes the
  base's sprite set as a template, and the mod's pictures named after the schematic draw over its
  shapes ([Shapes](#shapes)): `teapotscem_000.png` is the ship, and `teapotscem_001.png` to
  `teapotscem_004.png` the hit markers of its four quadrants, which otherwise stay the base's.
- `Guns` is the gun every gun of the model fires, and `Missiles` the missile every hardpoint holds,
  whatever the model names: one of the game's by its name, one a mod adds by its qualified name, or
  one this mod adds by its own name.

A ship type based on one of the twelve ships the player can fly, or without a base, is offered on
the loadout screen too, after the game's ships:

- `Tier` is the campaign tier from which it is offered, 0 at the start to 3 after mission 21.
  Without it, it is offered from the start of the campaign.
- Its name and its model are its own, drawn in green (see
  [Textures in the loadout](#textures-in-the-loadout)), and shown as large as its base whatever
  its model's size. The bars on its panel show its own stats, measured against the game's fighters.
- `Class`, `Access` and `Crew` set what the panel says about it. `Class` is one of `light`,
  `light_medium`, `medium`, `heavy`, `advanced_heavy`, `prototype_medium` and `prototype_light`,
  `Access` one of `bronze`, `silver`, `gold` and `platinum`, and `Crew` a number. Without them, the
  panel shows its base's. Its specials and guns are its base's.
- `GunsModel` is the model the guns view shows in place of the ship, a `.shp` file in the mod or the
  game, in the same units as `Model`. Make it as the game's are, such as `predator_gun.shp`: the hull
  in lines, which only the ambient light reaches, and the guns as solid parts. Without it, the guns
  view shows its base's gun model.
- The arc holds twelve ships. When the game's ships leave no room, the mods' ship types that don't
  fit aren't offered, and the log says so.
- A saved game keeps a mod's ship type as its base, so that the original can still load it.
  OpenReliant keeps the mod's own beside the save ([Saved games](../formats/save.md#in-openreliant)),
  and puts it back when the save is loaded with the mod still on.

When the player flies it, it can also give:

- `Cockpit`, the model of the cockpit's frame, a `.shp` file in the mod or the game, such as the
  Tempest's `temg_frm.shp`.
- `WireFrame`, the name of the pictures the gunnery display shows the ship as, in place of its
  base's wire frame: `teapotwire_000.png` is the ship, and `teapotwire_001.png` on the ship with
  its first, second and later group of guns lit, which the display shows over it for a ship of more
  than one group. Each is drawn over the base's wire frame's rectangle, so make them all the same
  size, in the shape of the base's: the Predator's is 92 by 108 of the display's pixels, and a
  picture at two or four times that keeps it sharp. A picture left out keeps the base's shape.
- `WingIcon`, the name of the picture the wing's window shows the ship as, `teapoticon_000.png`,
  drawn over the base's icon's rectangle.
- `EngineSound`, a WAV file, PCM or IMA ADPCM, that loops as the engine's sound, pitched and
  loudened by the throttle as the base's is. Give it whole cycles of each tone, so that its loop
  doesn't click.
- `BlindFire` and `SpectralShields`, `yes` or `no`, whether it carries blind fire and spectral
  shields. Without them, it carries what its base carries. The loadout lists them with its specials.

#### Ship types without a base

A ship type can leave out `Base`. It then behaves like no ship the game treats specially:

- Its stats start as a copy of the Predator's, which a load script can change
  ([The records](scripting.md#the-records)). The loadout shows it at the Predator's size.
- It carries blind fire or spectral shields only if `BlindFire` or `SpectralShields` says so.
- On the loadout's panel, it is `light`, `bronze` and has a crew of 1, unless `Class`, `Access` and
  `Crew` say otherwise.
- The loadout reads its guns and specials from its model: each kind of gun its gun muzzles fire,
  or the gun `Guns` names, up to four kinds; the Nova Cannon if it fires one; the cloaking device
  if the model can cloak; and reverse thrust if an engine glow points forward. Without a
  `GunsModel`, the guns view shows its own model, all in red.
- Its cockpit, engine sound and display pictures are the Predator's unless it gives its own.
- A saved game keeps it as the Predator.

### Guns

```ini
[Guns]
banana_gun=

[Gun banana_gun]
Base=pulse_cannon
Name=Banana Gun
Shot=banana_shot.png
ShotSize=40
Sound=boing.wav
Flash=banana_shot.png
FlashSize=300
```

A gun uses its base's shots, flashes and sounds, except for the ones it gives itself:

- `Shot` is a picture in the mod, which each shot is drawn as: one flare of it, facing the camera,
  fading with the shot's life. It is found as the mods' textures are, by its name without the
  extension, so a PNG, DDS or KTX2 file works. Give it a transparent background.
- `ShotSize` is how far the picture reaches from the shot's middle in each direction. The default
  is 60, the size of the Pulse Cannon's flare.
- `Sound` is a WAV file in the mod, PCM or IMA ADPCM, that each shot makes in place of its base's.
  It is heard as its base's sound is: as far, as loud, and following the shot.
- `Flash` is a picture in the mod, which the muzzle flash is drawn with as each shot leaves the
  gun, in place of its base's flares: across the muzzle and in three blades along the flash, added
  to what's behind it, shrinking away as its base's does. It is found as `Shot` is. Black is
  see-through, so draw it on black. Where flashes light the ship, its light takes the picture's
  colour.
- `FlashSize` is how far the flash reaches forward of the muzzle, its width keeping its base's
  proportions. The default is its base's flash, 600 for the guns based on the fighters' guns.

A gun whose `Sound` is missing from the mod, or isn't a WAV file, is left out, and the log says so.
A model gives each gun muzzle a gun type by number, so a mod's own model fires the mod's guns by the
numbers in `[Guns]`. A ship type can also fire one with `Guns`, whatever its model says.

### Missiles

```ini
[Missiles]
banana=

[Missile banana]
Base=bandit
Name=Banana
Model=banana.shp
Description=A homing banana. It locks on slowly, but nothing outruns it.
Tier=0
```

A missile uses its base's trail, sounds and flight display picture. What `Model` is depends on the
base:

- For a base that hangs on a rail (the Havoc, the Jack Hammer, the Bandit, the Vagabond and the
  Imp), `Model` is the missile that hangs on the hardpoint and launches from it.
- For a base that hangs in a pod (the Screamer, the Raptor, the Solomon and the Hawk), `Model` is
  the missile that flies out of the pod, and `Pod` is the pod that hangs on the hardpoint. Without
  `Pod`, the base's pod is used.

A mod's own model can hold the missile on its hardpoints, and a ship type can carry it with
`Missiles`.

The loadout screen offers it on its missile page too, with the game's missiles:

- `Tier` is the campaign tier from which it is offered, 0 at the start to 3 after mission 21, else
  its base's. A missile based on the torpedo, which the loadout never offers, isn't offered.
- `Description` is the text on its panel. Without it, the panel shows its base's text. The panel's
  figures are its own, measured against the game's missiles, and a ship carries as many of it as of
  its base.
- Its icon on the arc is the model that hangs on the hardpoint: `Model`, or `Pod` for a base that
  hangs in a pod, else its base's loadout model. Its red copy is made from its picture (see
  [Textures in the loadout](#textures-in-the-loadout)).
- The arc has twelve places, and the game's missiles take five to ten of them by the tier. The
  mods' missiles take the free places in the order the mods load; the log says when some don't
  fit.
- A saved game keeps a mod's missile on a rack as its base, so that the original can still load it.
  OpenReliant keeps the mod's own beside the save, and puts it back when the save is loaded with
  the mod still on.

### Pilots

```ini
[Pilots]
trooper=

[Pilot trooper]
Base=21
Name=Trooper
Voice=rus
```

A pilot uses its base's face and voice on the radio, except for the ones it gives itself. `Base` is
a pilot's number in `pilotstats.bin`. A mission gives its ships' pilots by number, so a mod's own
missions use the mod's pilots by the numbers in `[Pilots]`. A script can set the pilot of any ship
([Objects](scripting.md#objects)), as the `bananas` example does.

- `Talking`, `Laughing` and `Dying` name the face films the radio's window plays as the pilot speaks,
  laughs and dies: a film of the game's, such as `45volntrs_plt` from `pilots.hog`, or a `.fm8`
  file in the mod. The film every pilot shares in the 45th's place stays the game's.
- `Voice` is the prefix of the file names of the pilot's lines. The pilot uses it on either side,
  in place of its base's two voices. It can be one of the game's, such as `ban` for Bandit's or
  `rus` for the Coalition's, or a new one whose lines the mod gives as files with those names, such
  as `trpres_001.ut`.

`sltool fm8 encode <frames-dir> <film.fm8>` makes a face film of the PNG files in a folder, in the
order of their names, at 15 frames a second. A face is 120 by 100 pixels; a pixel less than half
opaque becomes the colour the radio's window draws see-through. The film keeps every colour where
the frames have 256 or fewer, and picks 256 for them otherwise, the see-through colour kept as it
is. `sltool fm8 extract` gives a film of the game's as frames to start from.

`sltool speech encode <line.wav> <name.ut>` makes a line from a WAV file, which it mixes to mono at
22,050 Hz, the rate the radio plays at. Name the lines after the pilot's `Voice`, as the game's are.

## Models from OBJ

`sltool shp from-obj` builds a model for a mod from a Wavefront OBJ file, which Blender and most
modelling tools export, with nothing of the game's in it:

```bash
sltool shp from-obj teapot.obj teapot.shp --two-sided
```

Each object in the file becomes a part of the model according to its name, written in any case. A
suffix such as `.001`, which modelling tools add to copies, is ignored:

| Object | What it becomes |
|---|---|
| `cockpit` | The cockpit, a part of its own, which leaves the ship as the pilot's pod when the pilot ejects |
| `gun_muzzle:<gun type>` | Where a gun fires from, a gun of that type, by its number in `gunstats.bin` (1, the Laser Cannon, without one) |
| `missile:<missile>` | A missile hardpoint, holding that missile type for every loadout tier (0 without one) |
| `engine_glow:<glow>` | An engine's glow, burning backward from the middle of its box: the box's width and height are the plume's, half its length how far the plume reaches at full throttle. The number picks one of the game's seven glows; the player's ships use 1 |
| `light:<colour>` | A light: a sprite as large as its box, which lights nothing round it |
| `eject_point` | Where the pilot's pod is thrown up from, on the cockpit where there is one |
| `launch_point`, `dock_point` | Where a ship launches from or docks |
| `jump_trail` | Where one of the trails streams from when the ship jumps |
| `jump_light` | Where one of the lights flashes along the hull when the ship jumps |
| anything else | The body |

An attachment sits at the middle of its object's corners, and is as large as their bounding box, so
a small box or a single triangle is enough to mark one. In the teapot's OBJ file, each gun muzzle,
engine glow and missile hardpoint is one triangle:

```text
o Teapot
usemtl teapot
f 1/1/1 2/2/2 7/7/7
...
o cockpit
usemtl teapot
f 501/501/501 507/507/507 506/506/506
...
o gun_muzzle:1
f 801 802 803
o engine_glow:0
f 807 808 809
o missile:0
f 813 814 815
o eject_point
f 825 826 827
```

- **Textures.** Each face of the body and the cockpit takes the texture its `usemtl` names, by the
  texture's name without its extension, such as `teapot` for `teapot.png` in the mod. A face without
  a `usemtl` is drawn untextured. The `.mtl` file isn't read.
- **Normals.** A vertex uses the normal the file gives it. Without one, it gets the average of the
  normals of the faces around it.
- **Options.** `--two-sided` draws every face from behind as well, for a model with open edges.
  `--cloak` adds the meshes a ship needs to cloak. `--density` sets how heavy each part is for its
  size: the default, 0.1, makes a ship about as heavy as the Predator at the Predator's size.
- **Axes.** The file is read as Blender exports it, with Y up and the nose toward +Z. `sltool shp
  obj` exports the game's models the same way, so a game model exported and built again comes back
  in the same place.
- **Size.** A part holds at most 65,535 vertices and 65,535 triangles, the format's limit, and
  `sltool` stops with an error past it. The game's fighters have a few hundred triangles; OpenReliant
  draws tens of thousands, but each one costs time in every frame, shadows included.
- **What is generated.** Each part gets one level of detail, a collision tree of boxes around its
  faces, and a mass as though it filled its bounding box. A model without `jump_trail` objects gets
  a jump trail at each engine glow, so that each engine streams one when the ship jumps.

[`examples/mods/teapot`](../../examples/mods/teapot) builds its ship this way, and
[`examples/mods/bananas`](../../examples/mods/bananas) its missile.

## Models from glTF

`sltool shp from-gltf` builds a model for a mod from a glTF 2.0 file, the format Blender and most
modelling tools export and most model sites offer. It reads a `.gltf` file with its buffers in files
beside it or inside it, or a binary `.glb` file:

```bash
sltool shp from-gltf viper.gltf mods/viper/viper.shp --scale 2
```

The model is built as from an OBJ file ([Models from OBJ](#models-from-obj)), with the same names
and options:

- **Nodes.** Each node with a mesh becomes an object of its name, and each node without a mesh or
  children, such as Blender's empty, marks an attachment or a jump point by its name, such as
  `gun_muzzle:1`. A marker is a cube two units across, scaled, turned and moved as its node is, so
  scale an engine glow's marker along its length to give its plume that length. Every node's
  transform is applied, and `--scale` scales the whole model.
- **Materials.** Each material becomes a texture called after the model and its number, such as
  `viper_0.png` for `viper.shp`, written beside the model with its maps ([Material
  maps](#material-maps)): its colour, its colour texture times its colour where it has one; its
  roughness and metalness, from its textures and values; its normal map; and its emissive map where
  it glows, `KHR_materials_emissive_strength` included. Every map takes the colour texture's size.
  Textures must be PNG files; any other is left out, and the log says so.
- **What isn't read.** Animations, skins, morph targets, cameras, lights, sparse accessors, a second
  set of texture coordinates, and the extensions beyond the emissive strength. A file that requires
  an extension other than `KHR_materials_emissive_strength`, `KHR_materials_specular` or
  `KHR_texture_transform`, which it can be drawn without, isn't read.

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

Mods can include scripts written in [Luau](https://luau.org), a version of Lua, which OpenReliant
runs while you play. [Scripting](scripting.md) explains them step by step, starting from a first
script, and the [scripting reference](reference.md) lists everything they can use. In short:

- **Load scripts** run once at startup and change the game's records: the stats of ships, guns,
  missiles and pilots, and the game's text.
- **Global scripts** run for the whole game, and **mission scripts** while their mission runs. They
  react to what happens in the game, and change it, through hooks on the game's functions and
  events.
- **Object scripts** run on each ship of a class or a type, such as every fighter, while it's in
  the mission.
- **Player and menu scripts** draw over the flight display and the menus, and react to the keys.
  Menu scripts can also replace the front end's screens, and add game modes and campaigns to the
  main menu's GAME MODES ([Menus, game modes and campaigns](scripting.md#menus-game-modes-and-campaigns)).

A mod lists its scripts in its manifest:

```ini
[Scripts]
Load=balance.luau
Global=rules.luau

[Missions]
mission2.dte=escort.luau
```

Scripts are ordinary files of the mod: a folder mod keeps them next to `mod.ini`, and `sltool hog
pack` packs them into the archive. The shaders of a mod's post effects and functions, files
ending in `.frag` or `.glsl`, are kept the same way ([Post effects](scripting.md#post-effects)).
Neither scripts nor shaders replace game files, but a mod's `device.glsl`, `bloom.glsl` or
`shadow.glsl` can replace OpenReliant's own shader
([Replacing OpenReliant's shaders](scripting.md#replacing-openreliants-shaders)).
[`examples/mods`](../../examples/mods) holds example mods for mod makers, which show how the
scripting works and aren't supported mods.

**Improvement:** the original has no scripting apart from its mission scripts.

## Log messages

At startup, `openreliant` lists each mod it loads, in order, by its manifest name if it has one,
followed by what each of its files does: which game file, texture, shape, picture or font it
replaces, which earlier mod's file it replaces, or which file it adds. A mod that the mods screen
has turned off is listed as off, and none of it is used. When a font is loaded, it says which
outline font draws it.

```text
info(mods): music.hog matches music.hog.sha256
info(mods): mod 1 of 2: Coyote HD 1.0, by Someone (coyote)
info(mods): coyote replaces USA_Coyote.SHP
info(mods): mod 2 of 2: music.hog
info(mods): music.hog replaces New_Pensive.wav
info(mods): music.hog adds msc_theme.wav
info(mods): the mod old-ships is off
info(fonts): optfnt.fnt uses Newtown, with strokes 0.002 em wider
info(scripts): balance: ran balance.luau
info(scripts): balance: the Laser Cannon hits shields for 10 and hulls for 10
```

A script's messages and errors follow its mod's name, as above;
[Scripting](scripting.md#when-something-goes-wrong) explains the common ones.

`openreliant missions` lists and checks the missions in the mods too, showing `mod` in the file
column, and also accepts `--no-mods`.
