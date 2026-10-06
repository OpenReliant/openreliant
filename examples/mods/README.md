# Example mods

These mods are scripting examples for mod makers. Each one shows how a part of OpenReliant's
scripting API works ([Scripting](../../docs/guide/scripting.md)), with comments in its scripts and
shaders. They are not supported mods: they aren't balanced or tested for play, and they can change
or go away in any release. Copy one as a starting point for your own mod.

| Mod | What it shows |
|---|---|
| [`arena`](arena) | A game mode with its own rules and HUD, which skips the simulator's radio talk (`radio_say`) |
| [`balance`](balance) | Changing the game's records from a load script |
| [`bananas`](bananas) | A new gun with its own shot picture, sound and muzzle flash, a missile with a model built from OBJ, a pilot with a voice, a ship that carries them, and a pilot set by a script |
| [`campaign`](campaign) | A campaign with a briefing screen and a movie |
| [`cel-shading`](cel-shading) | A lighting function and a surface function (`openreliant.shaders`) |
| [`crt`](crt) | A post effect (`openreliant.postprocessing`) |
| [`custom-order`](custom-order) | Registering an AI order |
| [`drawing-assets`](drawing-assets) | Drawing a mod's pictures, the game's shapes and fonts |
| [`dvd`](dvd) | A menu script that draws over the menus |
| [`interceptor`](interceptor) | A new ship type, based on the Predator, flown in a game mode |
| [`main-menu`](main-menu) | A main menu of the mod's own in place of the game's |
| [`rules`](rules) | Hooks on the game's functions |
| [`strafe-run`](strafe-run) | A custom order with a HUD display, a chase camera and rebindable actions |
| [`tally`](tally) | Storage kept with each saved game and across every game |
| [`teapot`](teapot) | A ship type with a model of its own, built from OBJ (`sltool shp from-obj`), and its own cockpit, display pictures and engine sound, offered on the loadout screen |
| [`trent`](trent) | Face films that replace a pilot's by name, built with `sltool fm8 encode`, and the pilot renamed in the game's text from a load script |
| [`wingmen`](wingmen) | Object scripts, events, interfaces and a mod's options page |

To try one, copy its folder into the `mods` folder of your game directory
([Modding](../../docs/guide/modding.md)). Each example's name on the mods screen starts with
`Example:`.

[What mods can do](../../docs/guide/what-mods-can-do.md) lists every modding feature with the example
that shows it.
