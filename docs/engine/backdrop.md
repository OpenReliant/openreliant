# Backdrop

What lies behind a mission, as the hardware renderers draw it. Everything is centred on the camera and drawn on the background layer, except the lens flares, which go on the overlay layer ([Rendering](rendering.md#frame)).

| Element | From | Drawn |
|---|---|---|
| Sky dome | `starref12.tga` | Untextured, opaque |
| Nebula | `neb01` to `neb07` | Textured, unlit, added |
| Stars | `space.tga` | Points and streaks, added |
| Dust | Random | Points and streaks, added |
| Sun | `sunlayer1` to `sunlayer3` | Sprites, added |
| Lens flares | `sunflare1` to `sunflare4` | Sprites, added |

`backdrop_create` (`0x004A4E70`) and `nebula_create` (`0x00498B30`) build them at start-up; `backdrop_frame` (`0x004A5CD0`) and `nebula_frame` (`0x00498E10`) add them to the scene each frame. The dome is the one opaque object, so it is drawn first and the rest add over it. [`src/engine/game/backdrop.zig`](../../src/engine/game/backdrop.zig) and [`nebula.zig`](../../src/engine/game/nebula.zig) port the functions below.

## Sky dome

A band of 15 by 8 vertices around the camera (`nebula_dome`, `0x00498810`). For column `c` and row `r`, with `u = c / 14` and `v = r / 7`:

- position: `(sin 2πu, 5 * (v - 0.5), cos 2πu)`, scaled to a length of 5000, so the band stops about 22 degrees short of either pole;
- colour: the pixel of `starref12.tga` at `(255u, 255v)`, rounded down, top row first, over 256.

Each row of quads is one strip of triangles, split along the diagonal from each quad's first corner to the one below its next. The mesh holds no texture coordinates, normals or bounds. Its object has flags `0x800`, so none is culled, `0x1000`, so it is not tested against the view and is always clipped, and `0x80000`, so each vertex takes the object's own colour and no light reaches it. `backdrop_place` turns it with the sun marker ([Placement](#placement)). The software renderer builds a different dome.

## Nebula

A patch of 11 by 11 vertices on a sphere of radius 5000 (`sky_patch_create`, `0x00498EA0`), 90 degrees across each way, or 72 for nebula 5, with the texture across it once. Across the columns a vertex turns evenly from -45 to 45 degrees about `X`, down the rows about `Y`; `u = c / 10`, `v = r / 10`. Each quad is two triangles, split along the diagonal from column `c`, row `r` to column `c + 1`, row `r + 1`, and none is culled. Its orientation is the nebula marker's, or a yaw of -90 degrees without one, which faces it toward `-X`.

**Improvement:** a nebula's texture, 256 texels across in 16-bit colour, spans the patch, about eight pixels a texel at 1080p. OpenReliant magnifies it with a smooth cubic filter rather than the sharp one it gives the other textures, so that the texels' grid gives way to soft cloud ([Renderer](../port/renderer.md)); `--filter original` and `--original` magnify it bilinearly, as the original does.

A script picks the nebula with `SetEnvironmentFXNebula` (0 to 6), which takes effect at the next jump or on `UpdateEnvironmentFXState` (`nebula_select`, `0x00498D00`). Each nebula also colours the fill lights:

| Nebula | Texture | Fill light |
|---|---|---|
| 0 | `neb01` | 0.24, 0.5, 1 |
| 1 | `neb02` | 0, 1, 0.8 |
| 2 | `neb03` | 0.33, 0.46, 1 |
| 3 | `neb04` | 0.74, 1, 0.32 |
| 4 | `neb05` | 0, 0.75, 1 |
| 5 | `neb06` | 0.92, 0.66, 0.33 |
| 6 | `neb07` | 0, 1, 1 |

Nebula 0 is shown until a script picks another. The nebula asked for (`nebula_requested`,
`0x0058A6B8`) stays from one mission to the next, as does the one shown. OpenReliant keeps the
request with the space (`environfx.Environment`) and shows it on `UpdateEnvironmentFXState`; the
jumps that apply it are not ported yet.

## Stars

`space.tga` is a 360-pixel square map of half the sky, half a degree to a pixel, with a grey star on black at each pixel that is not black. It is cut into 100 fields of 36 by 36 pixels. Field row `i`, column `j` is centred on the axis at polar angle `θ = 9 + 18i` degrees from `+Y` and azimuth `φ = 9 + 18j` degrees from `+X` toward `+Z`:

```
axis = (cos φ sin θ, cos θ, sin φ sin θ)
```

A star at pixel `(x, y)` of its field lies at `(sin b, sin a, 1)` in the field's frame, `a` and `b` being `x - 18` and `y - 18` half degrees: the pixel's row gives `x` and its column `y`. The field's frame is turned about `Y`, then `X`, to face the axis (`mat3_look_at`, `0x004C1940`). A star takes the pixel's bytes as the file stores them, blue first, and the driver draws the first as red, so the map's few tinted stars show with red and blue swapped. The fields cover the half of the sky where `z` is positive; a field behind the camera is drawn mirrored through it, so they cover the other half too.

Each frame (`stars_project`, `0x004C5380`):

- a field is drawn only while its axis, or its opposite, is within a cosine of 0.6 of the view axis;
- a star is drawn only while its direction is within a cosine of 0.6 of the view axis this frame and last, and of 0.7 in one of them;
- a star moving more than a pixel since last frame is a line back to where it was, the tail at half brightness, cut to 0.1 view units (position over depth, before the viewport's scale); otherwise a point;
- its brightness is `1 / (100m + 1)`, `m` its motion in view units, `|dx| + |dy|`.

After a camera cut, `backdrop_reset_streaks` (`0x004A5C80`) stops the next frame drawing streaks: `camera_set_view` calls it on every switch, and `mission_frame` once the view differs from the last frame's (`camera_view_last`, `0x00539A64`).

## Dust

200 motes in a cube of side 8191, placed by the C runtime's `rand`, grey at half brightness. They are fixed in the world, repeating every 8192 units: each frame a mote is placed within 4096 of the camera on each axis. Its brightness is `16 * (0.25 - d² / 8191²) / (100m + 1)`, clamped to 0 to 1, with `d` its distance, so motes fade out by 4096 away. They streak like stars,
but while the player's ship jumps in (`0x005E82F0`, [Jumps](jump.md#jump-in)) their streaks are cut
to a quarter as long, 0.025 view units (`0x004DC424`).

## Sun and lens flares

The sun's direction is `(1, -0.5, 0.2)`, normalized, until a sun marker aims it ([Placement](#placement)). The sun and the flares are sprites (see [Rendering](rendering.md#sprites)), textured, coloured grey and added. `backdrop_frame` sizes each to reach its texture's width and height times `z / 768` from its centre, with `z` its depth, then scales the sun's: on screen a sprite reaches its texture's size times the view's scale over 768, in pixels, whatever the distance.

| Sprite | Size | Drawn | Grey |
|---|---|---|---|
| `sunlayer1` | 0.5 | Always | 1 |
| `sunlayer3` | 2 | While the sun's visibility is above 0.5 | `0.15f + 0.1` below `f = 0.8`, `0.3f` from there |
| `sunlayer2` | 2 | While `f` is above 0; hardware renderers only | `min(2f, 1)` |

`f` is the flares' brightness, `(0.5 + 0.05v) * (1 - min(1, s))`, with `s` the sun's offset from the middle of the view in view units, position over depth, and `v` its visibility. The greys are set only while `f` is above 0. The sun's visibility is its distance in pixels from the nearest edge of the screen, at most 10 and 0 off it, less again for each triangle of an object flagged `0x8000` that covers the sun's point on screen. It is worked out after the sprites are placed, so a frame uses the last frame's.

The six flares are drawn on the overlay layer on the line through the sun and the middle of the view, at a multiple of the sun's offset from the middle: `sunflare2` at 0.5, `sunflare1` at 0.33, `sunflare3` at 0.2, `sunflare2` at -0.2, `sunflare3` at -0.6 and `sunflare4` at -0.5, each at size 1 and grey `f`, while `f` is above 0. They show in every view but the cockpit's ahead, and in that one too while the cockpit mode is the chase view and any of the sun shows (`camera_view`, `0x00539A34`; `cockpit_mode`, `0x00539A9C`). Each sorts as if at the near plane.

### OpenReliant's sun

**Improvement:** OpenReliant draws each of the sun's and the flares' textures again, eight times finer each way, from the rings it is made of ([`backdrop/rings.zig`](../../src/engine/game/backdrop/rings.zig)), so that they stay round and crisp however large they are drawn. The sprites keep the size the game's textures give them.

- It finds the middle the texture is roundest about: of the points a quarter of a texel apart within two texels of its centre, the one about which the texels stray least from the mean of their ring.
- It measures the rings eight to a texel, by how far out each texel's centre lies. Where every texel in a ring has one colour, over half a texel or more, the ring is flat. Elsewhere a ring takes the mean of the texels within half a texel of it.
- Between two flat rings less than 1.5 texels apart lies an edge. It stands where the light the rings measure there is kept, weighted by how far out it lies, in the channel that changes most.
- A run of three or more edges of one level of a 16-bit texture each, the same way, is a gradient that rounding cut into steps. Each of its edges is smoothed out to the nearer ring's middle, and no further than four texels. Any other edge stays crisp, one texel of the finer texture wide, so a flare's bands keep their exact colours.
- For `sunlayer1` and `sunlayer2`, what is not round is added back, enlarged with a Catmull-Rom filter: the ragged rim and the rays. Each texel's difference from its ring is averaged two texels either way along its line from the middle, and kept where it is more than half a level of a 16-bit texture. What strays less, or not along a ray, is rounding and is left out.
- The result is dithered to 8 bits with interleaved gradient noise, and has every mipmap level down to a texel.

Drawn back at the game's size, each redrawn texture keeps the original's light to within about 1% in each channel.

**Improvement:** the sun's visibility reaches as far as `sunlayer1` does on the screen, its texture's width times its size times the view's scale over 768, rather than 10 pixels. The brightness `f` takes it as the same share of 10. `sunlayer3`'s grey is multiplied by the visibility's share of its most, where the game draws it whole above 0.5 and not at all below. The glow and the flares therefore dim as the sun's disc goes behind what hides it, however large the screen, rather than going out at once. Only solid polygons hide the sun: the canopies' glass, which is added, lets it through ([Renderer](../port/renderer.md#improvements)).

`--original` draws the game's textures and keeps its visibility.

## Planet atmospheres

Four of the planets have an atmosphere: a ring round the rim that glows in the planet's colour and
fades out to its edge. `create_object` (`0x00466C10`) makes one as it makes a planet of those types,
and keeps up to four in a table (`planet_atmospheres`, `0x00545868`, 0x24 bytes each: the ring, the
planet's spin, where the planet stood as it was made, which nothing reads, and its slot).
`objects_reset` loads the ring's texture, `atmos`, and empties the table as a mission starts;
`objects_free` (`0x004666B0`) lets go of the rings as it ends.

The ring is a band of 20 quads (`mesh_build_band`, `0x0044F200`): a circle of 20 vertices round the
Z axis at the radius of the planet's first part, as its scene object has it, and a second circle
like it, the texture spanning each quad once. `create_object` draws the first circle in to 0.85 of
that radius and colours it, and draws the second out to 0.95 or 1.005 and colours it black:

| Planet | Types | Colour of the inner circle | Outer circle |
|---|---|---|---|
| Neptune | `0x5F`, `0xC9` | (0.1, 0.15, 0.2) | 0.95 |
| Uranus | `0x61`, `0xCB` | (0.15, 0.2, 0.2) | 0.95 |
| Jupiter, Venus | `0x64`, `0x69`, `0xCE`, `0xD3` | (0.2, 0.2, 0.15) | 1.005 |

It is drawn over `atmos`, added by the alpha of its own colours, and never culled (object flags
`0x84800`). A branch of the same code colours the Saturns' (`0x62`, `0xCC`), but they are not among
the types that get one.

At the end of `backdrop_frame`, each planet with an atmosphere turns about its own Y by 0.0007 of a
radian for each tick since the last frame (`planets_turned_at`, `0x00595BC0`). With the hardware
renderer, and the planet not disabled, its ring stands where the planet does, turned to face the
camera, as solid as the lens flares are bright (`backdrop.flareBrightness`), on the background
layer, which the world is drawn over. The ring's radius is the part's, its farthest vertex from the
part's origin, as the ring is made. `create_object` then brings the planet's sphere to its object's
origin ([Creating an object](objects.md#creating-an-object)), so that the planet turns in place and
the ring stands round it.

**Improvement:** the atmosphere is a haze (`atmosphere.Style.haze`). The ring is made of 96 quads,
round at any size, and is there at all times: each of its vertices is as solid as the flares are
bright, or as `atmosphere.hazeAt` has it where that is more, 0.15 on the side away from the sun and
0.6 on the side toward it, and between them as the cosine goes. The planet's terminator is softer,
the sun reaching a little way round into its night side, where each pixel is lit
([Renderer](../port/renderer.md#improvements)). `--original` makes the ring of 20 quads, only as
solid as the flares are bright, and keeps the terminator hard.

**Fix:** a fifth atmosphere would write past the table; OpenReliant makes none. With the sun square
to the view, the game leaves the flares' brightness unset for the rings; OpenReliant keeps the last.
`DestroyFlightGroup` counts one atmosphere fewer for any planet of the types from `0x60` to `0x69`
and `0xCA` to `0xD3`, whether it has one or not, leaving out both Neptunes, looks for its ring
among the atmospheres before the last alone, and frees the one it finds while keeping it in the
table, which goes on drawing it; OpenReliant lets go of the planet's own and takes it out.

## Lights

`backdrop_create` makes six lights, the key lights shining from the sun and the fill lights from `(-1, 0.5, 0)`, normalized, until the markers aim them ([Placement](#placement)).

| Mask | Kind | Intensity | Colour |
|---|---|---|---|
| `0x01` | Key, directional | 1 | 1, 1, 0.8 |
| `0x02` | Fill, directional | 1 | The nebula's; 0, 0.5, 1 at first |
| `0x04` | Ambient | 1 | 0.04, 0.04, 0.04 |
| `0x08` | Key, directional | 1 | 1, 1, 0.8 |
| `0x10` | Fill, directional | 0.7 | The nebula's; 0, 0.5, 1 at first |
| `0x20` | Ambient | 1 | 0.09, 0.09, 0.09 |

A light reaches an object unless their masks share a bit. A part's object has mask `0x18` when its model lists components and `0x03` otherwise (`node_add_part`), so models that list components take the full fill light and the rest take it at 0.7; both take the key light and both ambients.

## Placement

`backdrop_place` (`0x004A5A00`) aims the backdrop from a mission's markers, as the script asks with `UpdateEnvironmentFXState`. It sets the sun's direction back to `(1, -0.5, 0.2)`, normalized, then reads the objects in the first slots, as many as the more of the mission's ships and the objects in use, each by the orientation of its renderer's frame. The last marker of each kind wins.

- **A sun marker** (type `0x3DC`) puts the sun along its backward axis: the orientation negated, whose forward axis is the sun's direction. Both key lights shine from there, and `sunlayer1`, `sunlayer2` and `sunlayer3` stand 1000 away along it. The sky dome takes the negated orientation times the transpose of the look at the default sun (`mat3_look_at`, `0x004C1940`), a reflection, which mirrors its colours.
- **A nebula marker** (type `0x3DD`) aims both fill lights along its forward axis, and the nebula's patch shown then takes its orientation. The other patch keeps its own.

Without a sun marker the sun's direction stays a unit long, and the sun's sprites, the key lights and the dome keep what the last sun marker gave them; without a nebula marker the fill lights and the patches keep theirs. The lens flares follow the sun's direction.

## Environment effects

A mission's script turns environment effects on and off by number (`SetEnvironmentFX`,
`environment_effect_set`, `0x00469C60`), a bit each: the effects on (`0x0055249C`) and those asked
for (`0x005531A4`). The game takes the effects `0x004FF748` allows, the ice field and effect 2, and
logs any other as not yet implemented. The table of effects (`0x004FF804`, 32 bytes each) gives
each whether it waits, two routines to turn it on and off, which none has, and a name: Ice Field,
Planet Bombard, then "not defined". The ice field and Planet Bombard wait: turning one on or off asks
for it, and `environment_update` turns the effects on and off as asked, at the next jump or on
`UpdateEnvironmentFXState`. Any other goes on or off at once, and what is asked for is then what is
on. Nothing reads effect 2 (`0x0046A6F0`).

The renderer's start clears the effects (`backdrop_create`, `0x00469C30`), and builds the ice field
and ten flashes for Planet Bombard (`0x0046A500`, `Boom_Mesh`, `pbang`), which nothing draws: their
frame (`0x0046A312`) is never called.

**Fix:** since nothing else clears them, an effect one mission leaves on shows in the next, the ice
field of Instant Action's last wave among them; OpenReliant clears them as each mission starts.

### The ice field

Effect 0: rocks of ice all about the camera, far off, each a triangle facing it and turning
(`0x00469DF0`). There are 200, 500 or 800 of them by the graphic detail, each a triangle a unit
across with its point at its place (`0x0046A250`), drawn with `farast2` by coordinates of its own,
lit and added by a grey of its own:

- Which of the texture's five rocks it shows, one for each fifth of a random number: a quarter of the
  texture each, or a triangle across the top middle (`0x004FF990`).
- Its grey, from a half to full.
- Where it lies, 2500 from the camera: 0.65 of them in a band 0.1 radians across, the rest in one
  0.7 across, each in one of two arcs 2.2 radians wide, a half turn apart.
- Its size: 0.94 of them 5 to 30, the rest 30 to 100.
- How fast it turns: the seven rates 0.0005 radians a tick apart, from -3 steps to 3, in turn.

While the ice field is on, `backdrop_frame` adds each rock that lies ahead of the camera, within
about 49 degrees of its axis (1625 of its 2500 along it), to the background layer after the lights
and before the star fields (`0x0046A170`): it stands at its place from the camera, facing it, turned
by its rate for each tick of the frame's time.

OpenReliant builds and draws the ice field
([`game/environfx.zig`](../../src/engine/game/environfx.zig)).

**Improvement:** OpenReliant draws every rock ahead of the camera, so that the field fills the whole
view however wide it is, and no rock appears or vanishes within it as the view turns; the game's cone
leaves the corners of the view bare, and the sides of a wide one. `--original` draws only the rocks
in the game's cone.
