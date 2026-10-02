# Loadout

The loadout screen (`loadout.cpp`, `0x00441AA0` to `0x0044B870`) is a hologram the briefing runs between the mission's movie and Enriquez's last word ([Briefing](briefing.md)). A disc lies before the camera with the ships the pilot may fly on an arc round its rim; the chosen ship turns slowly above it; panels with the ship's name and figures, and six buttons, stand round it. All of it spins in out of the disc's glow as the loadout begins. Clicking a ship on the arc flies it up to the chosen spot as the chosen one flies back. On the missile page the other ships sink into the disc and the missiles rise out of it, the chosen ship turns belly up, and a missile clicked flies to one of its hardpoints ([The missile page](#the-missile-page)). View Internal Guns sweeps a glowing plane across the chosen ship, which turns into its guns as the plane passes ([The internal guns view](#the-internal-guns-view)). Exit Loadout Computer spins it all away again, and the ship chosen, with the missiles on its racks, is the one the pilot flies. It is built on GenILib's 3D interface ([GenILib's 3D interface](#genilibs-3d-interface)).

## In the code

- [`interface/loadout/loadout.zig`](../../src/engine/interface/loadout/loadout.zig): the loadout's life, its frames, the ship page, the selection, the missile page, the internal guns view and the exit.
- [`hologram.zig`](../../src/engine/interface/loadout/hologram.zig): the hologram's pieces and where they stand: the panels, the buttons, the ship clipper and the hardpoints' markers, the disc's mesh, the lights, the slots of the disc, and where a point of a missile hardpoint stands.
- [`racks.zig`](../../src/engine/interface/loadout/racks.zig): the chosen ship's racks: which rack a missile takes, which missiles stay offered, and what the loadout leaves the campaign and the mission of them.
- [`anims.zig`](../../src/engine/interface/loadout/anims.zig): its animations.
- [`tables.zig`](../../src/engine/interface/loadout/tables.zig): its tables in the executable: the ships and missiles it offers, the rows its panels show, what the tier and the rank open, its text's colours, and where its objects stand.
- [`bars.zig`](../../src/engine/interface/loadout/bars.zig): the ships' and missiles' figures ([The figures](#the-figures)).
- [`panels.zig`](../../src/engine/interface/loadout/panels.zig): the panels' textures ([The panels](#the-panels)).
- [`genilib/interf/i3d.zig`](../../src/engine/genilib/interf/i3d.zig): GenILib's 3D interface.
- The briefing's part is in [`game/interface/briefing.zig`](../../src/engine/game/interface/briefing.zig), and the loop that runs it and draws its frames in [`openreliant/rooms.zig`](../../src/openreliant/rooms.zig).

## Not ported yet

- A view nothing opens (`0x0044A470`): it turns the ship's panel behind a portal, sinks the ships and turns the two scrollers round, with its own Move Clip Point and Rotate Scroll Button (`0x00448EF0`, `0x00448FF0`) and the panel's clip object (`0x00523E7C`). Every call of it (`0x00449E3F`, `0x0044760F`, `0x004476B0`, `0x00447CA3`) waits on a flag (`0x00524974`) nothing sets, so it never runs.
- The loadout kept across a change of display (`video_screen`, `0x0042F1FE` to `0x0042F237`), whose screen is not ported ([#400](https://github.com/OpenReliant/openreliant/issues/400)).

## GenILib's 3D interface

`C:\lancer\GenILib\interf.cpp` (`0x00426A30` to `0x004282C6`) is the in-house library the loadout's hologram is made of. The cursor's code (`0x00424460`, `0x004244E0`) and the tree's scaling (`0x00428300` to `0x00428390`) lie beside it and are its own.

- **Objects** (`I3DOBJECT`, `0x48` bytes, `i3dobject_create`, `0x00426A30`) each stand for a scene object or a game object's tree of parts, with a tooltip of up to 29 characters, callbacks for the left button's press and release and for the pointer's coming onto them and leaving them, and flags for whether they are shown, clickable, and on the overlay's layer. The pointer finds an object by its projected triangles (`i3dobject_hit`, `0x00426E20`; `point_in_triangle`, `0x00427080`), a tree's within its screen rectangle first (`i3dobject_rect_update`, `0x004271C0`). A hidden object is found as a shown one is.
- **Animations** (`I3DANIM`, `0x5C` bytes) run from frame to frame (`I3DFRAME`, `0x34` bytes), each frame easing its object's place, angles and scale from its key (`I3DKEYINFO`, `0x2C` bytes) to the next frame's, over its length in milliseconds (`i3dframe_step`, `0x004276A0`). They play once, again and again, or there and back, forward or back; a callback runs each step, one once the first frame has come a share of the way, and one at the end (`i3dframe_end`, `0x004279B0`). A tree is scaled by the ratio of the new scale to the last it was given (`node_tree_scale`, `0x00428320`).
- **The interface** (`IINTERFACE`, `0x60` bytes, `iinterface_create`, `0x00427BD0`) steps its animations each frame (`iinterface_frame`, `0x00427C40`) and, unless it is busy, follows the pointer (`iinterface_pointer`, `0x00427EA0`): the first clickable object under it takes the press, the pressed one the release, and with no button down the object under it becomes the hovered one. Its 3D cursor, a small lit pointer (`cursor_create`, `0x00424460`), stands 1.5 before the camera at the pointer's place, turned with the camera and spinning once every 1200 ms. `iinterface_scene` (`0x004281E0`) puts its objects in the scene, and a stack of functions (`ifuncstack_push`, `0x00428290`; `ifuncstack_run`, `0x004282E0`) holds what to do as an animation ends.

## The loadout's life

| Step | Function | What it does |
|---|---|---|
| Load | `loadout_load` (`0x00441AA0`), as the briefing loads, but for mission 29 | Raises the campaign's tier to the highest the missions before this one reach (`mission_tiers`, `0x005009D8`: 1 after the 11th, 2 after the 19th, 3 after the 21st); works out the ships' and the missiles' figures; reads `palette3.tga` and `ldsmp.fat`; loads each ship's model with its green textures and makes the ships the tier or the rank offers, all but the chosen one scaled down to the arc's share of their size; loads the missiles' models with their red textures and makes their icons and the Ship Missile objects; reads the backdrop, `fpanels.tga` and the fonts; makes the disc, its glow, the panels and the buttons, places them, and builds their animations and each ship's and missile's sinking. |
| Enter | `loadout_enter` (`0x00442720`), once the movie into the hologram has played | Brings the near plane in to 1, shows the backdrop, sets the lights, places the ships, starts `loadout.ut` in mission 1, and starts the intro (`loadout_intro`, `0x00444830`) with the first button's appearing. |
| Frame | `loadout_frame` (`0x004433C0`), each pass of the briefing's loop | Steps the interface, fades the red light, turns the chosen ship, and plays sound 7 as the pointer comes onto another object; returns false once the loadout has ended. |
| Resume | `loadout_resume` (`0x00443760`), after the in-game options' BACK | Builds the page's background again and frees the interface. |
| Leave | `loadout_leave` (`0x00442CC0`) | Writes what the loadout leaves the mission ([What it leaves](#what-it-leaves-the-mission)), and ends its speech and sounds. |

### The ships offered

The loadout offers the first ships of its table, from the Predator on, as many as the campaign's tier or the pilot's rank opens, the more of the two (`loadout_ships_create`, `0x00444760`), and they stand in the middle slots of the arc:

- **The tier** (`campaign_tier`, `0x00562DF0`) opens 4, 7, 10 or 12 ships (`0x004EA408`). The loadout raises it as it loads to the highest the missions before this one bring (`mission_tiers`, `0x005009D8`): 1 from mission 12, 2 from mission 20, 3 from mission 22. The mission is flown at that tier, which arms its fighters' default missiles.
- **The rank** (`pilot_rank`, `0x00562DEC`) opens 4 to 12 ships (`0x004EA418`). The end of a mission the pilot comes through promotes the pilot by the kills over the campaign, never down (`mission_end_record`, `0x00475A90`): ranks 1 to 8 at 35, 72, 115, 150, 200, 255, 275 and 300 kills (`rank_kills`, `0x005009F4`). Nothing is recorded where the player's ship was destroyed, the ejected pilot captured, or the script rated the mission a total failure. A new pilot starts at rank 0.

The ship the loadout starts on is the Shroud in mission 23, the Predator in mission 1, and the campaign's saved one otherwise (`loadout_reset`, `0x004439D0`). In mission 23 only the Shroud is shown or can be clicked.

**Fix:** a saved ship the loadout does not offer, as a campaign begun again at an earlier mission leaves it, leaves the game without the chosen ship's object, which it then writes to. OpenReliant starts on the Predator.

## The scene

The camera stands at (-2.8, -6.5, -16.85), turned by (-0.368, 0.067, 0.03) (`loadout_placements`, `0x0044B5E0`), over the front end's screen with the renderer's projection, its near plane at 1. The objects the placements name (`0x004EA520`) stand where they say:

| Object | Size | Texture | Place | Angles |
|---|---|---|---|---|
| Disc | 20 across, four quarters | `plate-nw` to `plate-se` | (1.5, 3.75, 1.45) | (-pi/2, 0, 0), lying flat |
| Disc Glow | 10 across | `hologlow` | (1, 5.1, -3.8) | (-1.766, 0, 0) |
| PnlShipInfo | 9.332 across and down, two-sided | the ship's figures, front and back | (-8.6, -2.6, 0) | |
| PnlShipName | 8.999 by 0.667, two-sided | the name panels', `v` 0.090 to 0.180 | (-3.9, -7.9, 0) | |
| PnlPageTitle | 9.999 by 0.833, two-sided | the name panels', `v` 0 to 0.094 | (-8, -8.7, 0) | |
| BtnExit, BtnShips, BtnMissiles, BtnGuns | 2.333 by 1.667 | parts of the name panels' art | (10, -8.35, 0), (10, -5.8, 0), (10, -3.8, 0), (10, -1.8, 0) | |
| BtnDefault, BtnRemoveAll | 2.333 by 1.667 | parts of the name panels' art | (4.2, -8.35, 0), (6.7, -8.35, 0) | |

Every panel is a square (`panel_create`, `0x00444980`) drawn unlit and added, each texture coordinate half a texel of 256 on; a two-sided panel shows its back texture on its other face, turned round. The buttons are made at a ten-thousandth of their size and grow as they appear, so that Use Default Loadout and Remove All Missiles, which appear with the missile page alone, are not seen on the ship page. Two more panels, the scrollers, stand at (-9, 1.2, 0) and (-9, 1.7, 0) facing away from the camera, and so are never seen. The ship clipper, a two-sided square of `hologlow` 14 across (`0x0044408C`), is put away until the internal guns view sweeps it across the ship.

The ships stand on slots of the disc (`ships_place`, `0x004493B0`; `slot_place`, `0x00449690`): the chosen spot at (23, -23, -6), and twelve on the arc from (-98, -23, -1) round the front to (96, -23, -1) (`slots_set`, `0x004497F0`), across and down scaled by 0.078125, turned with the disc and from its centre. A ship on the arc faces away from the disc's axis, at 0.19444 of its own scale; the chosen one floats 6 above the disc at its own, turning about Y once every four seconds, tilted back by 0.75 (`ship_spin`, `0x00447160`). Each ship's scale is its own (`0x004EA2D8`, 0.006 to 0.01). A portal in the disc's plane clips what sinks below it (`0x00449200`).

The ships' models load with the `g` texture prefix, the missiles' and the gunships' with `r` (`loadout_ship_models`, `0x00524976`), and every group of a ship's finest mesh is made one pass, lit and opaque (`0x00445FE0`). The loadout gives each part the level of detail it wants whatever the distance (`0x0044B2F0`, `0x0044B340`): the finest for the chosen ship, and for the ships on the arc while they move, a coarser one by the graphic detail, the finest at high.

The loadout's textures are indexed into `palette3.tga` ([Texture caches](../formats/tcache.md)), which the loadout gives the device as it loads and enters (`loadout_palette`, `0x004436B0`): the ships come out green, the missiles red. OpenReliant decodes the loadout's textures with it.

| Light | Kind | Place or direction | Intensity | Colour | Reaches |
|---|---|---|---|---|---|
| Loadout green light | point | (15, -15, -10), range 100000 | 2 | white | the ships |
| Loadout red light | point | the same | twice its level, fading | (1, 0.6, 1) | the missiles on the ship |
| Loadout Ambient light | ambient | | 0.2 | green | everything |
| Loadout cursor light | directional, turned (0.5, 0.5, 0.5) | | 1 | (0.4, 1, 0.4), green on the software renderer | the cursor |

A fifth, Loadout bgreen light, is made and never put in the scene. What a light reaches is by its mask against the objects' (`srlight.Light.reaches`): the ships' parts take `0xFFFD`, the cursor `0xFFEF`, and a gunship's parts drawn in lines `0xFFFB`, the bgreen light's, so that the ambient light alone reaches them.

## The intro and the ship page

The intro (`loadout_intro`) makes the interface busy, scales each ship to a thousandth of the size it will stand at, and starts:

| Animation | Object | Time | What it does |
|---|---|---|---|
| Spin Disc (`0x004461E0`) | the disc | 2000 ms | from the glow's place, 2 nearer the camera, a turn behind about Z and a thousandth of its size, to its own; the ships follow it each step |
| Glow Appears (`0x00446510`) | the glow | 2000 ms | grows from a thousandth |
| Ship zooms with disc (`0x00446310`) | each ship | 2000 ms | grows a thousand times, easing in |
| The panels' zoom (`0x00442514` on) | the three panels | 2000 ms | from the glow's place and a turn about Y, growing evenly |
| Button Appears (`0x004463E0`) | each of the first four buttons | 500 ms each | out of the glow with a turn about Y; a fifth of the way in, the next one starts |

The hum, sound 0, loops 12 quarter tones down, and sound 3 plays. As the disc has spun in (`0x004466C0`), the ship page is built: the ships clipped by the disc, the still part of the page grabbed as the device's background (`capture_background`, `0x00446180`), the chosen ship, the panels and the buttons shown before it, the cursor made, and the interface freed.

**Improvement:** the game renders the still part, the disc, its glow and the ships on the arc, once whenever a page is built, and grabs the frame as the device's background, drawn behind every frame after at 640 by 480. OpenReliant keeps the objects it would have grabbed and draws them each frame, at the window's resolution.

## Choosing a ship

A ship on the arc pressed (`0x00447C00`) is selected unless a selection is still flying (`ship_select`, `0x00447E20`). The red light fades out; the ships but the old and the new are grabbed as the background; the new ship can no longer be clicked and the old one can again. The panels' fronts are drawn with the old ship and their backs with the new, turned front on, and then flip over about X in 1500 ms (Flip Shipinfo, `0x004484A0`, `0x004485A0`), showing the new ship. The new ship flies from its slot to the chosen spot and the old one back to its slot, each in 1500 ms (Select Ship, `0x00448160`; Deselect Ship, `0x00448320`); sound 8 plays, and the interface is busy until they arrive. The old ship's missiles are taken off first (`racks_clear`, `0x0044AEE0`); the chosen ship's turn starts again as it arrives, and it takes the tier's missiles at once, glowing in with the red light (`0x00446EF0`, [The racks](#the-racks)). With the internal guns view open, the view closes first and opens again as the new ship arrives ([The internal guns view](#the-internal-guns-view)).

## The missile page

Missile Loadout's release (`0x00447630`) turns to the missile page (`page_switch`, `0x00449D90`), once the internal guns view has closed where it is open ([The internal guns view](#the-internal-guns-view)). The interface is busy, the missiles the tier offers are shown (`missiles_available`) and the ships on the arc can no longer be clicked, the backdrop stands behind the live disc and its glow, and Use Default Loadout and Remove All Missiles fly out of the glow. Then, each starting the next:

| Step | Animation | What it does |
|---|---|---|
| The ships sink | Sink Ship (`anim_sink_ship`, `0x004486A0`), each ship on the arc in turn | 2 down into the disc over 800 ms, easing in, the disc's portal clipping it; 0.07 of its way the next ship sinks (`sink_ship_share`, `0x00446610`) |
| The missiles rise | Sink Missile (`anim_sink_missile`, `0x004487F0`) played back, from the last missile | each missile's icon, put on its slot of the arc for the tier (`missiles_place`, `0x00449590`) and 2 down, rises the same way; the last ship to sink starts the last missile as it passes its share |
| The ship turns over | Ship to Belly Up (`anim_belly_up`, `0x00448950`), at once | the chosen ship turns from its spin's angles to (-pi/2, pi, 0) over 1000 ms, eased by the cosine, showing the camera its underside |
| The markers | Zoom Hardpoint (`0x00448A40`), each marker in turn | as the ship has turned over, a marker is made for each of its missile hardpoints (`markers_make`, `0x0044A750`), and grows from a thousandth of its size over 400 ms, starting the next a fifth of its way |

As the first missile has risen (`missiles_risen`, `0x00446950`), the page's objects are shown and the interface is free (`missile_page_show`, `0x00446B90`).

A marker (`marker_create`, `0x00444BB0`) is a square 0.7 by 1.12 of `hpoints` over its whole texture, 0.05 along the hardpoint's Y axis from it and 0.3 nearer the camera, facing the camera, on the overlay, blended onto what lies behind and white whatever the lights, its faces sorted 10 nearer. It is shown while its rack holds nothing, and its tooltip is Hardpoint.

A missile's icon is the missile's model loaded with its red textures, lit and opaque at 0.007, reached by the green and the ambient lights. Each missile the tier offers has its slot of the arc (`loadout_missile_slots`, `0x004EA480`), and its icon is shown and clickable while fewer than its limit are on the ship or flying to it or back: three Jack Hammers, any number of the rest (`missiles_available`, `0x0044B870`).

### Fitting the missiles

- **A missile's icon pressed** (`missile_icon_press`, `0x004472B0`): a copy of the missile, unlit and added (`missile_flight_create`, `0x00445D80`), flies from the icon to the first empty hardpoint after as many empty ones as copies already fly, over 1000 ms, its place and angles eased by the cosine (Attach Missile, `anim_attach_missile`, `0x00448B10`), with sound 4. As it arrives (`0x00446C90`), the missile is hung on the first empty rack (`rack_fit`, `0x0044AAC0`), its marker put away, and the copy goes. At most 20 copies fly at once.
- **A missile on the ship pressed** (`0x004473B0`): a copy flies back from its hardpoint to its icon, with sound 5, and the rack is emptied at once (`rack_empty`, `0x0044AE40`), its marker shown again.
- **Use Default Loadout** (`racks_default`, `0x00449CA0`): every rack emptied, and each hardpoint's missile for tier 0, whatever the campaign's tier, flown to it as a press of its icon flies it.
- **Remove All Missiles** (`0x00447560`): every rack emptied at once, and every marker shown.

A missile on the ship is a tree of its model at 0.8 of the ship's scale (`missile_object_create`, `0x0044AFA0`), standing on its centre of mass at its hardpoint, turned as the hardpoint is, and reached by the red and the ambient lights alone (mask `0xFFFE`); it grows and shrinks with the ship. A Ship Missile object (`0x00524228`), one for each of up to twelve racks, stands for it: clickable, the missile's name its tooltip.

The pointer onto a missile's icon, or on the missile page onto a missile on the ship (`missile_hover`, `0x00447CC0`), draws the missile on the info panel's back ([The panels](#the-panels)) and turns the panel to show it at once, its front drawn with what it showed before. Each frame on the missile page, every icon is lit but the one under the pointer, and a missile on the ship under the pointer is unlit (`0x004435C3`). The icons and the missiles on the ship share their models' meshes, so every missile of the kind under the pointer lights up with it.

**Fix:** the game frees the data of a missile flying back to its icon as its flight begins, and counts it by what the freed memory holds. OpenReliant counts it as the missile it is.

### The racks

The ship page hangs missiles on the chosen ship at once as it is built, the red light fading in on them from nothing (`0x00446918`): in the first mission and in mission 23, each missile hardpoint's missile for the campaign's tier (`racks_fit_tier`, `0x00449AD0`); otherwise the campaign's saved racks, each hardpoint in turn taking the next (`racks_fit_saved`, `0x00449BB0`). The missile a hardpoint names for a tier is its word for the tier read whole ([Model files](../formats/shp.md)), where the flight takes its low half; a word past the loadout's ten missiles, which no shipped ship has, leaves the rack empty, where the game reads beyond its tables.

The racks are those of the chosen ship's missile hardpoints, in the order the flight fits them ([Missiles](missiles.md#the-loadout)). The Ship Missile objects and the markers' zooms reach twelve; no shipped ship has more than eight missile hardpoints.

**Fix:** where the saved ship is one the loadout does not offer, OpenReliant starts on the Predator ([The ships offered](#the-ships-offered)) and fits it the tier's missiles, where the saved racks are another ship's.

### Back to the ship page

Ship Selection's release (`0x004475D0`) turns back to the ship page (`0x00449DB8`): the interface is busy; the ships on the arc can be clicked again, at the coarse level; the markers zoom away one after another, and the ship turns back from belly up after the last (`belly_up_back`, `0x00446E90`), or at once where it has none; the missiles sink one after another, and each missile's end shows the ships and starts the first on the arc rising again, so that they rise after the last missile has sunk; as the last ship has risen, the ship page is built again (`ship_page_rebuild`, `0x004469A0`). The info panel's front is drawn with the chosen ship and flips back to it, and the two buttons fly back into the glow.

## The internal guns view

View Internal Guns' release (`0x00447670`) opens the internal guns view, or closes it where it is open (`guns_view_toggle`, `0x0044A110`). On the missile page it turns back to the ship page first, and the view opens once the page is built.

Each ship has a gunship (`gunships_create`, `0x004447C0`; `gunship_object_create`, `0x00445CC0`): a tree of the ship's gun model (`+0xFC` of its record, `predator_gun.SHP` for the Predator), loaded with the `r` texture prefix, standing at the origin, and scaled to its ship's own scale as the loadout enters (`0x00442BD0`). Its parts are reached by the green light, but those whose finest mesh begins with a line, which the ambient light alone reaches (`gunship_light_masks`, `0x004460E0`), and each has a faint green of its own, (0, 0.03, 0), which its lights add to (`node_tree_colour`, `0x00449310`). Its object is not clickable, and is put away until the view shows it. The game makes the gunships of all twelve ships; OpenReliant makes those of the ships offered, the only ones the view shows.

Opening, the interface is busy and the gunship is put where the chosen ship stands, turned as it is. Two portals are set where the sweep starts, 5.5 back along X from the ship's place: `gun portal1` on the gunship, facing along X, and `gun portal2` on the ship, facing back along it. They are made as the loadout enters (`0x00442C81`, `0x00442C95`) and put in the scene each frame (`0x00443657`, `0x00443667`). Then:

- The ship clipper sweeps from there 11 along X over 1500 ms (Move Clip Point, `0x00448DF0`), its place eased by the cosine and its size rising from a thousandth to its whole half way, then falling back. Each step (`0x004490E0`) shows the clipper, the gunship and the ship, moves both portals to the plane, facing along X and back, and turns the plane across X. The gunship shows behind the plane and the ship ahead of it, so that the ship turns into its guns as the plane passes.
- The info panel's front is drawn with the ship's figures and its back with its guns ([The panels](#the-panels)), turned front on and flipped over in 1500 ms, and sound 10 plays.
- As the sweep ends (`0x00446E30`), the interface is free and the clipper is put away, and the ship too, leaving the gunship. While the view is open the gunship turns with the ship's turn, which goes on while the interface is busy (`ship_spin`, `0x00447235`).

Closing plays the sweep back from the same start, and the info panel flips from the guns to the figures, with sound 10. At its end the gunship is put away, the view is closed and the ship is clipped by the disc's portal again. What waits on the interface's function stack then runs:

- Ship Selection's release closes the view (`0x004475F5`).
- A ship on the arc pressed closes it, and the ship is selected once it has closed; the view waits under the selection (`stack_guns_view`, `0x00449AA0`) and opens again as the new ship arrives (`0x00447C00`, `0x00446F57`). The chosen ship pressed does nothing.
- Missile Loadout turns to the missile page once the view has closed (`0x00449DB9`).
- Exit Loadout Computer exits once the view has closed (`0x00447767`).

**Fix:** the game makes the ship clipper clickable, as it makes every panel, and the pointer finds it though it is put away. Standing at the origin at its whole size until the view first sweeps it, it covers the chosen ship and takes the pointer from the hardpoints' markers, which come after it, so that their tooltip shows only once the view has been opened. OpenReliant's is not clickable.

## The exit

Exit Loadout Computer's release (`0x004476F0`), once the interface is free, runs `loadout_exit` (`0x00447730`): the speech stops, the ships on the arc and the disc are shown live again and the portal clips no more, the markers and the missiles' icons are put away, and everything plays back into the glow, the disc and the ships easing out: the ships' zooms, the panels' zooms, the buttons one after another, on the missile page its two as well, the glow and the disc's spin. The chosen ship is kept in the campaign's saved loadout (`0x00562F18`), the hum ends and sound 2 plays. As the disc has spun away, sound 6 plays and the next frame ends the loadout.

**Fix:** as the disc spins away, the game turns the chosen ship by whatever angles its stack held, the ship's before it on the arc: the chosen spot gives none (`slot_place` with no facing). OpenReliant leaves it turned as it was.

## The pointer, the tooltip and the sounds

The loadout reads only Escape and O ([Briefing](briefing.md)). The pointer is GenILib's: the left button selects and presses, and a button pressed sinks 0.2 from the camera with sound 1 until it is released. While the interface is free, the render hook (`0x0044B200`) writes the tooltip of the object under the pointer, but the chosen ship's, centred at (320, 458) in `ld_handel.fnt` through the text remap: a ship's name, or a button's label.

**Improvement:** the tooltip is drawn from Newtown, or a mod's font, at the window's resolution, in the green its letters are drawn in, on the black edge the game's text stands on ([Outline fonts](../formats/fnt.md#outline-fonts)). The panels, which draw their text into their own pictures, keep the font's glyphs ([#520](https://github.com/OpenReliant/openreliant/issues/520)).

The sounds are `ldsmp.fat`'s, in the middle:

| Sound | Volume | When |
|---|---|---|
| 0 | 40, looping, 12 quarter tones down | the hum, from the intro to the exit |
| 1 | 40 | a button pressed |
| 2 | 127 | Exit Loadout Computer |
| 3 | 127 | the intro |
| 4 | 40 | a missile flying to a hardpoint |
| 5 | 40 | a missile flying back to its icon |
| 6 | 127 | the loadout's end |
| 7 | 40 | the pointer onto another object |
| 8 | 40 | another ship selected |
| 10 | 127 | the internal guns view opening or closing |

In mission 1, `loadout.ut` from `speech_hog` is said as the loadout enters, and Exit Loadout Computer blinks twice a second from 15 to 25 seconds in. The in-game options pause the speech and end every sound, the hum's among them; BACK resumes the speech.

**Fix:** the game never plays the hum again after the in-game options, and the hologram is silent for the rest of the loadout. OpenReliant starts it again as BACK returns to the loadout, unless the exit has ended it.

## The panels

The panels' textures are 256 by 256 (`panels.zig`), their text written into them as VFX writes it into a pane (`hud.drawTextInto`), each coverage level of the font in the palette3 colour a remap gives it:

- **The name panels** (`panel_title_draw`, `0x00444D60`): `fpanels.tga`'s art, with SHIPS AND LOADOUT at (17, 4) and the ship's name in capitals at (17, 28), in `ld_handel.fnt` through the text remap the other way round (`0x00523D64`), black edged in green. The buttons take their art from the same texture.
- **The ship's figures** (`loadout_draw_stats`, `0x00444F20`): the class and the access at (2, 12) and (2, 32); eight rows from y 57, 15 apart, each labelled at x 2 and showing a number and its suffix, or ten segments with as many filled as the figure, at x 180; and the ship's specials in capitals, wrapped at (2, 180), in `handels.fnt` through the text remap (`0x004EA308`), a green ramp.
- **A missile** (`missile_info_draw`, `0x004456F0`), on the missile page: its name in capitals at (2, 12) and its description in capitals wrapped at (2, 32), 252 wide, 15 a line, six lines at most; its four rows from y 127, 15 apart, as the ship's are, a dash for a figure of -1 and for every row of the fuel pod; and CLICK MISSILE and TO ATTACH TO SHIP centred at x 128, y 195 and 210, in the same font and colours.
- **The ship's guns** (`guns_draw`, `0x00445490`), in the internal guns view: from the top, each kind of its guns, up to four, with how many it has in capitals (`%s X %d`), 20 apart, at x 2; and under each but a rear turret its description, wrapped 252 wide, 15 a line, 20 lines at most, with 10 more below it: its power, kind, range, rate and drain run together in the strings' own case (`%s%s%s%s%s`), a comma in place of the drain of a gun that drains none. It is in the same font and colours.

The panels are added, so their black is clear and the room shows through.

### The figures

`loadout_load` works out each ship's figures as it loads (`bars.zig`): speed, acceleration, agility, shield power, shield recharge and armour as bars of 3 to 10 segments, placing each ship's figure between the least and the most of the fighters the ITAC lists (`loadout_ship_bars_init`, `0x00426600`; `range_scale`, `0x004504F0`), its afterburner fuel in seconds, and its crew. The missiles' figures are worked out the same way, and the missile page's info panel shows them.

**Fix:** `loadout_missile_bars_init` fills eleven missile records of the loadout's ten, the eleventh past its table into the chapters' movies' records (`0x004EE640` to `0x004EE64F`). OpenReliant fills ten.

## What it leaves the mission

`loadout_leave` writes the chosen ship and its racks to the player's slot of `player_loadouts` (`0x00588400`): the ship type, then each of the 20 racks' missile type, -1 where it holds none and 10 for the fuel pod (`0x00442D8C`). It writes the racks to the campaign's saved loadout too (`0x00562F1A`), in its own numbering, -1 for none.

`create_object` makes the player's ship of the ship type, and fits its racks with the types in turn outside the simulator and mission 25's first part (`0x00467690`); a re-arm fits them again (`cmd_ReplenishWeapons`, `0x0045A055`; the Nanny's, `order_dock`, `0x00407A5F`, [#320](https://github.com/OpenReliant/openreliant/issues/320)). Where the mission starts without its briefing (`skip_briefing`), the ship is fitted by the tier instead. The flight's fitting ends at the first rack that holds nothing, so a rack left empty leaves every rack after it empty in flight too ([Missiles](missiles.md#the-loadout)).

**Fix:** OpenReliant flies every missile the loadout hung, each on the hardpoint the loadout showed it on, and leaves the hardpoints of the empty racks bare ([#451](https://github.com/OpenReliant/openreliant/issues/451)).

OpenReliant flies the chosen ship with its racks, at the tier the loadout raised the campaign's to; `--ship` still overrides the ship, which is then fitted by the tier. The campaign's saved loadout is kept for the session, the campaign's saving not being ported ([#74](https://github.com/OpenReliant/openreliant/issues/74)).
