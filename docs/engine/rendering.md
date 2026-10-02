# Rendering

How the hardware renderer draws models. Surrender's library in the payload culls, projects and
lights each mesh; its Direct3D 7 driver, `srd3d.dll`, turns materials into render states and draws.
The software renderer, `srddraw.dll`, is not covered here.

[`src/engine/game/srofiles.zig`](../../src/engine/game/srofiles.zig) states the rule from shading to
material; [`src/engine/surrender/srd3d/srd3d.zig`](../../src/engine/surrender/srd3d/srd3d.zig) the
driver's blend factors, depth rule and highlight textures;
[`src/engine/surrender/surrenderlib/srclip.zig`](../../src/engine/surrender/surrenderlib/srclip.zig)
the clipper.

## Frame

`sr_render` (`0x004C78A0`) draws a frame through `sr_draw_layers` (`0x004C7960`):

1. The driver clears to black and to depth 0, and begins the scene.
2. For each layer in turn, each object in the layer's list goes through the payload's pipeline for
   its type, then to the driver. Opaque groups are drawn at once; blended ones are deferred.
3. The layer's deferred polygons are sorted farthest first (`depth_sort`, `0x004C7B30`) and drawn:
   every first pass, then the second passes.
4. The scene ends.

| Layer | Depth test | Depth writes |
|---|---|---|
| 0 | Off | Off |
| 1 | On | Opaque passes only |
| 2 | Off | Off |

Depth is reversed: a vertex's depth is `sqrt(1 / z)`, scaled, with `z` its distance along the
view; the test passes on greater or equal, and the buffer clears to 0. The driver culls nothing.

| Object type | Pipeline |
|---|---|
| 1, a mesh | `SR_meshpipe_init` (`0x004C75C0`) |
| 4, a set of sprites | `SR_bmopipe_init` (`0x004CE4D0`) |
| 7, a star field | `stars_project` (`0x004C5380`) |

**Unknown:** types 5 and 6 (`0x004CE830`, `0x004CE7B0`).

A frame's meshes may take 19999 vertices and 19999 polygons between them (`0x005E82F4`, `0x005E82F8`): `SR_meshpipe_init` leaves out a mesh that would take either count past that. Each layer is drawn from what went into it last, so it is what went in first that is left out ([Renderer](../port/renderer.md#improvements)).

The device's render states are set once, with the display mode (`D3D_set_screen_mode`,
`0x10004840`, or `D3D_set_screen_mode_windowed`, `0x10003C20`); afterwards the driver changes only
the depth states and the blending. Anti-aliasing, of the scene or of edges, is off, and no setting
turns it on. Dithering is on, textures are perspective-correct, and there is no alpha test and no
fog.

## Meshes

`mesh_build` (`0x004A3040`) makes a part's mesh for each level of detail as `model_load`
(`0x004A44D0`) loads the model:

- A run of consecutive faces with the same mode, sub-mode and material is a group, with a material
  of its own. A mesh holds up to 20 groups; a level with more stops the game.
- A fan's records become one polygon when `fan_merges` (`0x004A2FD0`) finds each later record's
  normal within a dot product of 0.999 of the first's: the first record's corners, then each later
  record's last. Other records stay polygons of three corners, keeping their fan or strip encoding
  and the count of records still to come, by which the driver draws them together.
- A mode-1 face becomes a polygon of two corners, a line, for each edge its edge mask leaves unset,
  each with the face's plane. It counts one polygon more than it makes; the spare polygons stay
  empty, in no group, and count only toward the frame's limit.
- Every other polygon's plane is that of its first three corners (`SR_mesh_calc_poly_normals`,
  `0x004C3CA0`). A polygon keeps its face's `0x01` and `0x02` flags and a third of its sort bias.
- Texture coordinates are per corner. On a part flagged `0x80`, with `Lmaps` on, the second pass
  takes the first's.
- Each material that a face of mode 3 or above uses has its texture looked up by name
  (`texture_require`, `0x00494A30`): after `g` while the loadout screen loads the ships, after `r`
  while it loads the missiles and guns, and as it is in flight. The light map is `l` and the name.
  A name the cache lacks stops the game.
- The bounding box, and the radius, the farthest vertex's distance from the origin, come from the
  vertices (`SR_mesh_find_bounding_box`, `0x004C3F10`). `mesh_texel_areas` (`0x004C4090`) finds
  each textured polygon's area in texels, which only the software driver reads.

At the finest level, the faces the part's tree nodes and face groups list are renumbered to the
polygons that merging leaves.

The part's object gathers flags from the meshes of its levels:

| Flag | When |
|---|---|
| `0x100` lit, `0x8000` hides the sun | Always |
| `0x400` coordinates from the normals for the second pass | A face of mode 7 or 8, with `Lmaps` on |
| `0x10000` geomorph positions, `0x20000` geomorph normals | Part flags `0x20` and `0x10`: every level but the last also holds each vertex's counterpart in the next |
| `0x40000` baked colours | Part flag `0x40`: the mesh holds a colour for each vertex |
| `0x80000` colours of its own | The model's header flag `0x02`, or a ship type's model while `multiplayer_mission` (`0x00582E8C`) is set |

For those last models `model_load` also builds a second set of meshes, whose groups' first passes
blend by alpha, and a third, one group textured by coordinates from the normals and added
(`cloak_mesh_build`, `0x004A3CB0`), for the [cloak](cloak.md). **Unverified:** that
`multiplayer_mission` marks the multiplayer maps; missions 81 to 85 and 87 set it.

The material is 16 bytes (`Material` in
[`srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig)):

| Off | Field |
|---|---|
| `0x00` | `1` when a second pass is drawn over the first |
| `0x02` | Texture coordinates, per pass: `0` none, `1` the mesh's, `2` made each frame, from the normals or the object's own |
| `0x04` | Lit, per pass: coloured by the vertex lighting, else by white |
| `0x06` | Blend, per pass |
| `0x08` | Texture, per pass. Below 8, one of the driver's highlight textures |

## Shading modes

A face's mode, the low nibble of its shading (see [`.SHP`](../formats/shp.md#face-tag-0x03)), gives
its material:

| Mode | Texture | Lit | Blend | Second pass |
|---|---|---|---|---|
| `0` | None | Yes | Off | |
| `1` | None, as lines | Yes | Off | |
| `2` | None | Yes | Add | |
| `3` | Material | No | Off | |
| `4` | Material | No | Add | |
| `5` | Material | No | Alpha | |
| `6` | Material | Yes | Off | Light map |
| `7` | Material | Yes | Off | Highlight |
| `8`, `10` | Material | Yes | Add | |

Other modes leave the material zero: untextured, unlit, opaque. A mode-1 face becomes a line for
each edge its edge mask leaves unset.

The second passes need `Lmaps`, in the settings' `Device` section, to be 1, as it is by default
(`light_maps`, `0x005D5618`), which the settings screen's LIGHT MAPS sets
([Video](front-end.md#video)):

- **Light map**, on parts flagged `0x80` and on the hardware renderers only: the texture named `l`
  and the material's name, by the mesh's coordinates, unlit, added.
- **Highlight**: highlight texture *n*, *n* the face's sub-mode, 0 to 7, by coordinates from the
  normals, lit, added.

## Passes

A textured pass's colour and alpha are the texture's times the vertex colour's; an untextured
pass's are the vertex colour's. An unlit pass's vertex colour is white.

| Blend | Source factor | Destination factor |
|---|---|---|
| `0` off | Blending off | |
| `1` add | One | One |
| `2` premultiplied | One | One minus source alpha |
| `3` alpha | Source alpha | One minus source alpha |
| `4` add alpha | Source alpha | One |

On two card types the driver makes `2`'s destination factor, or `4`'s source factor, one.

When the device can, the driver draws both passes at once, to the same effect. Textures are sampled
bilinearly from the nearest mip level, and wrap.

A blended polygon's sort key is the mean depth of its vertices along the view, plus a third of its
face's sort bias (`0x40` in the face record).

## Culling

The payload drops the polygons facing away (`mesh_cull`, `0x004C6280`). A polygon faces the camera
when the camera lies on the side of its plane its normal points to; the normal is
`(v1 - v0) x (v2 - v0)`, or `(v2 - v0) x (v1 - v0)` for an odd strip member, in the model's frame. A
line keeps its face's plane.

Face flags, where the mesh has any, are tested against the object's face mask, all ones from
creation:

| Flag | With the mask's bit set |
|---|---|
| `0x01` | Hidden. The fighters close their body and cockpit where the two parts meet with such faces, which show once a pilot ejects ([Ejection](ejection.md#the-pod)) |
| `0x02` | Never culled |

An object with flag `0x800` is not culled.

## Clipping

As the payload turns a mesh's vertices into the camera's frame (`mesh_transform_clipped`,
`0x004C6710`), it notes the planes of the view volume each lies outside: the near plane alone for
a vertex short of it, else whichever of left or right and of top or bottom. A polygon whose
corners all lie outside one plane is dropped; one with any corner outside a plane is clipped by the
driver, a triangle of its fan at a time (`clip_triangle`, `0x1000BEB0`, from `srClip.cpp`):

1. The triangle is cut by each plane its polygon's corners lie outside, in the order near, left,
   right, top, bottom.
2. Each vertex a cut makes notes the planes it lies outside, the near plane and the sides alike
   (`SR_clip_vertex_set_clip_flags`, `0x1000C700`), and each of them whose turn is still to come
   cuts the triangle too. A cut through the near plane that lands off the screen is so cut again by
   the sides.
3. The vertices left are projected, each kept within the viewport.

A vertex's attributes, its colour and both passes' coordinates, are interpolated along the edge it
is made on.

A mesh object flagged `0x2` is also cut by its portal (`+0xAC`). A portal is a scene object of kind 8 (`portal_create`, `0x004C50D0`) holding a plane: a normal in its own frame (`+0xB8`) through its position. Every polygon of a flagged object gets the portal's clip code (`0x20`, set in `0x004C5FB0`), and the clipper cuts by the portal last, after the view's planes (`portal_clip`, `0x004CCF30`; `0x1000C7C0` in the driver). The cut keeps the side the normal points away from. Before it draws the layers, `sr_draw_layers` moves each portal in the scene (list 4) into the camera's frame (`portal_transform`, `0x004CE9F0`); a portal left out of the scene keeps the plane it last had. A portal with corners (flag `0x200`) cuts by a polygon instead, but the game only makes single planes (flag `0x100`), for a capital ship's split ([Effects](effects.md#splits)).

## Lighting

Colours are per vertex (`mesh_light`, `0x004C7060`), then interpolated across each polygon. A
vertex's colour is the sum, each channel then clamped to 1, of:

1. The object's own colour, and each ambient light's colour times its intensity.
2. The part's baked colours, where it has them.
3. Each point light within reach (`SR_mesh_pointlight`, `0x004CDE40`): its colour times its
   intensity, the cosine between the normal and the direction to the light, and `(1 - r / R)^2`,
   with `r` the distance and `R` the light's intensity times its range (light `+0xCC`).
4. Each directional light (`SR_mesh_dirlight`, `0x004CE120`): its colour times its intensity and the
   normal's dot product with the light's forward axis, where that is positive.

Point and directional lights add no alpha. A light reaches an object unless their light masks
share a bit; an object whose mask is all ones takes no lights. OpenReliant adds the point and
directional lights for each pixel instead, as many as its shader takes, with the same sums
([Renderer](../port/renderer.md#improvements)).

## Engine glows

An attachment of kind 2 becomes a node of kind 2 (`node_mount`, `0x00499A10`), which draws one of
seven glow meshes scaled by the attachment's three sizes: across, up, and along its length. The
code lies in `environfx.cpp`, in the stretch the linker gave it between `Create.cpp`'s and
`erayfx.cpp`'s.

The Predator carries two, at the back of its hull either side of the centre line, each 120 across,
60 up and 440 long. A capital ship's glows burn the player's ship flying into them
([Effects](effects.md#engine-exhaust)).

### The meshes

`engine_glows_build` (`0x00469620`) makes all seven at start-up, into `engine_glow_meshes`, and
takes the fourteen flare textures they wear into `engine_glow_flares`. A glow picks its own by its
attachment's id, clamped to between 1 and 7, so an attachment naming none of them draws the first.

Each mesh is four quads of sixteen vertices (`engine_glow_mesh_build`, `0x00469400`): one across
the nozzle, with corners at plus and minus one on X and Y, and three blades 60 degrees apart, each
running from the nozzle to one unit along Z, so the plume shows from any side. A blade is one quad
crossing the axis, so it stands for two, and a sixth of a turn between them spreads the three
evenly. The nozzle wears the kind's `matflarea` texture and the blades its `matflareb` one,
both added to what stands behind them and unlit. Their texture coordinates span 0.04 to 0.99, a
little inside the texture's edges, and each polygon is biased ten nearer so that a glow draws in
front of the hull it sits on. Nothing gives the quads their planes, so none of them is ever culled
by facing away.

A muzzle's flash is the same shape, stretched to its own size ([Guns](guns.md#muzzle-flashes)); the
port builds both from one plume (`environfx.plumeMesh`).

**Improvement:** the blades stand a sixth of a turn apart exactly, where the game rounds it to
1.0472.

### What a glow burns

`node_draw` scales that unit mesh by the attachment's sizes each frame, the length by how hard the
ship is burning: `mission_frame` hands `object_draw` the ship's `last_throttle` times
`engines_intact`, so a plume shortens as its engines are shot away.

A glow of attachment id 7 burns its full length whatever the throttle, and never flickers. The
rest take the throttle itself, negated where the attachment's Z axis and its length point the same
way, since such a glow reaches forward and so burns on reverse thrust alone; one that comes to
nothing is left out. A burning glow is then flickered by `rand` to between 0.8 and 1 of its length.

The Ripper is the exception, and `node_draw` names its parts outright: while it flies forward it
draws only `Ripper_l_thrust` and `Ripper_r_thrust`, and while it backs up only its four
`Ripper_Back_pincer` parts, whose plumes burn the other way.

OpenReliant builds the meshes and draws the glows in `engine/game/environfx.zig` and
`engine/game/objects.zig`. Not ported: the Ripper's rule, which needs the motion routines it tells
its states apart by.

## What is too far off to draw

`node_draw` leaves out an object, and everything hanging from it, once its radius no longer covers
a pixel: it compares the distance from the camera against the object's radius times the screen's
scale across (`srapi.Projection.scale`, the screen's width less a tenth of a pixel times the
projection's factor), times the object's own `visibility`. The radius over the distance, times that
scale, is how many pixels across the object is drawn, so the test is one pixel of it.

`object_alloc` and `create_object` both leave `visibility` at 1, so nothing in the shipped game
sees further or less far than its size gives it.

## Static lights

A model carries its own lights as attachments, and the loader bakes them into vertex colours once
rather than lighting them each frame. An attachment counts as one while its kind is `light`, its
brightness is above zero and it does not blink, which is both of its blink values being zero
(`static_lights_mark`, `0x004A4070`). Its `id` is its colour: 0 blue, 1 green, 2 yellow, 3 red, and
nothing at all beyond, so a light of any further id adds no colour.

Parts fall into two classes by their `damaged` flag, and a light shines only on the parts of its
own class, so a component's damaged model is lit separately from its intact one. Every part of a
class that holds a light takes baked colours for all of its levels, which is what the part flag
`has_static_light` marks (`static_lights_bake`, `0x004A4310`).

A mission's `DisableLights` (`cmd_DisableLights`, `0x00459070`) puts a ship's lights out, or on
again: it sets or clears the object's `lights_disabled`, which leaves its light nodes undrawn, and
walks its nodes from the root (`0x00459090`), clearing or setting the renderer object's flag
`0x40000` on each part whose record holds `has_static_light`, which shows the mesh's baked colours.
The static lights go out and come back with the rest. Mission 4 lights its two satellites so
(`Stork1Sat1`, `Stork1Sat2`).

**Improvement:** OpenReliant leaves the steady lights out of the bake, and makes each one shine as
a real light, like a blinking light (`objects.Model.Light.cast`): in the colour the bake gives it
(none past red), with the same reach and falloff. It lights every pixel of a hull smoothly, on
moving parts as well as fixed ones, and lights whatever stands nearby, other ships as well as both
classes of its own model's parts. The GPU device lights each pixel with the 64 lights nearest the
camera, and the pipeline lights the vertices with any others. Steady lights keep their own reach:
the longer reach and the thrown-back light of the launch hangar's beacons apply to blinking lights
only ([Launches](launch.md#in-openreliant)). `--original`, `--baked-lights` and the REAL LIGHTS
setting bake them as the original does (`srofiles.Settings.real_lights`).

`mesh_light` takes an object's own colours (flag `0x80000`) in place of its mesh's baked colours, so
a model that can cloak, whose parts have colours of their own for the [cloak](cloak.md), never shows
its static lights: of the shipped models, the Basilisk's red light at its tail. **Fix:** OpenReliant
adds the mesh's baked colours to the object's own; their alpha is nothing, so the cloak's
see-through hull stays as clear.

Drawing a light is another matter. `node_mount_light` (`0x00499730`) makes up to two nodes of each
light attachment, and `node_draw` (`0x0049A8C0`) draws them at the light's place on the part that
carries it:

- Node kind 3, for an attachment whose width (`size[0]`) is above zero: a set of two sprites. The
  flare, the sprite attachment kind 4 id 0 names, grows with how far off it is, up to six thousand
  units, so that it stays worth seeing at a distance: at its largest it reaches seven times the
  attachment's height (`size[1]`) either side of its centre. It takes half its light's colour, full
  within a thousand units and fading to a tenth by fifteen thousand, staying there beyond. The
  lamp, the sprite kind 4 id 1 names, has a material of its own and reaches 0.3 times the height
  either side, in a paler colour. Both are drawn 2.25 times the width nearer than they stand, for
  sorting and for the depth test.
- Node kind 5, for an attachment that blinks and has a brightness: a point light of its colour, its
  brightness and its range, with mask 0, so it reaches every object that takes lights. A steady
  light casts none, since the loader bakes it into the meshes instead. In the software renderer
  there is none for an object of type 13, the Yamato.

The drawing takes more ids than the baking does: 0 blue, 1 green, 2 yellow, 3 red, 4 cyan and 5
white, with the lamp paler: (0.2, 0.5, 1), (0.5, 1, 0.5), (1, 1, 0.5), (1, 0.5, 0.2), (0.5, 1, 1)
and white. A light of id 4 or 5 is therefore drawn in its own colour but bakes nothing, since the
baking knows only the first four.

A light blinks by its two blink values, the first how long it stays on and the second how long it
stays off. Its clock runs ten to the tick, from the mission's clock plus the object's own offset
(`+0x634`), less its `blink_phase`, and is taken modulo the two together as an unsigned number.
Past its on time it fades over 200 of its clock and then stays out; a light with no blink values
is always on. Nothing of it is drawn, and it casts nothing, while the fade is at 0 or less; the
lamp goes out once the fade is below 0.9, while the flare keeps fading.

Each light adds to a vertex what a point light would (`static_light_bake`, `0x004A4130`): its
colour times its brightness, the cosine between the vertex's normal and the direction to the light,
and `(1 - r / R)^2`, with `R` the brightness times the range. So a vertex at the light's own reach
takes nothing, and the colour stops at white. The radius is the same `R` the point lights above
use, and the falloff the same shape, applied once at load instead of every frame.

## Sprites

A set of sprites (`sprite_set_create`, `0x004C4DB0`) shares one material. Each sprite has a centre,
a half width and a half height, a colour, and texture coordinates 0 to 1 across and down; its
pipeline draws it facing the camera, reaching its half size to either side of its centre.

## Coordinates from the normals

For a pass whose coordinates come from the normals (`mesh_sphere_map`, `0x004C7360`), with `n` the
vertex normal turned into the camera's frame: `u = 0.5 + 0.5 * n.x`, `v = 0.5 + 0.5 * n.y`.

An object made with flag `0x200000` carries texture coordinates of its own for the first pass,
at `+0x114`, and with `0x400000` for the second, at `+0x118` (`mesh_object_create`).
`SR_meshpipe_init` takes them in place of the generated ones.

## The cockpit

The mission's start (`0x004934F0`) loads the player's ship's cockpit frame model
([`main.zig`](../../src/engine/game/main.zig)'s `player_ships`) and makes an object of it
(`0x005883F4`): a part for each of the model's, every level's distance pushed out to 1048576, each
part's object flagged `0x1000`, so it is neither tested against the view nor given a level by
distance and always clipped, and reached by the lights of masks without bits 1 and 4 (`0x12`). The
object's origin moves to its centre of mass as its parts are linked, and its root hangs from the
camera's frame, where `camera_frame` moves it ([`camera.md`](camera.md)).

In view 0, in cockpit mode 1, under the hardware renderers, `mission_frame` adds three objects to
layer 2, so they are drawn over the world, sorted by depth: the radar's backing, unless DISPLAY
KILLS is held; the model's second part, the pilot's hands; and its first, the cockpit's frame. A
model with more parts has the rest left out: the Phoenix's has a third, its base.

The radar's backing (`0x005883BC`) is a quad the start builds by hand: from 65 left of the middle
of the screen to 67 right, and 32 either side of the radar's height, 68 above the foot, with the
`radaralpha` texture, a black disc, on it by coordinates of its own (flag `0x200000`), coloured
by its own colours, black at three quarters (flag `0x40000`), and blended by alpha, never culled.
The start unprojects its corners to 1000 in front of the camera, and the object stands in the
camera's own frame, so it keeps its place on the screen.

**Improvement:** OpenReliant measures the backing's corners in the display's pixels from where the
radar stands, and works them out again each frame, so it stays under the radar as the display is
scaled.

## Highlight textures

The driver makes eight 64x64 grey textures at start-up (`make_highlight`, `0x10001620`), brightest
at the centre. For texel `(x, y)`, with `d` its distance from the centre in half-widths, the vector
`((2x - 64) / 64, (2y - 64) / 64)`, and `e` 1.01, 2.01, 5.01 or 10.01 for index 0 to 3:

- `I = ((P * (1 - d))^e + 0.4) / 1.4` inside the circle, `0.4 / 1.4` outside it, where
  `P = (e + 1)^(1 / e)`;
- `v = 200 * I`, rounded; for indices 4 to 7, those of 0 to 3 times seven tenths;
- grey `(v - 200) / 3`, alpha `3 * v / 2`, each clamped to 0 to 255.

The highlight pass is added, so only the grey shows. OpenReliant skips it for mod textures with a
material map, since the map's highlights replace it ([Renderer](../port/renderer.md#improvements)).
