# Example mods

These mods are scripting examples for mod makers. Each one shows how a part of OpenReliant's
scripting API works ([Scripting](../../docs/guide/scripting.md)), with comments in its scripts and
shaders. They are not supported mods: they aren't balanced or tested for play, and they can change
or go away in any release. Copy one as a starting point for your own mod.

| Mod | What it shows |
|---|---|
| [`balance`](balance) | Changing the game's records from a load script |
| [`cel-shading`](cel-shading) | A lighting function and a surface function (`openreliant.shaders`) |
| [`crt`](crt) | A post effect (`openreliant.postprocessing`) |
| [`custom-order`](custom-order) | Registering an AI order |
| [`drawing-assets`](drawing-assets) | Drawing a mod's pictures, the game's shapes and fonts |
| [`dvd`](dvd) | A menu script that draws over the menus |
| [`rules`](rules) | Hooks on the game's functions |
| [`strafe-run`](strafe-run) | A custom order with a HUD display, a chase camera and rebindable actions |
| [`tally`](tally) | Storage kept with each saved game and across every game |
| [`wingmen`](wingmen) | Object scripts, events, interfaces and a mod's options page |

To try one, copy its folder into the `mods` folder of your game directory
([Modding](../../docs/guide/modding.md)). Each example's name on the mods screen starts with
`Example:`.
