# What mods can do

This page lists what mods can do in OpenReliant. Each line links to where the feature is explained,
and to an example mod that shows it, where there is one. [Modding](modding.md) and
[Scripting](scripting.md) explain the features in full, and [`examples/mods`](../../examples/mods)
holds the examples, with comments in their files.

A mod is a folder or an archive in the game folder's `mods` folder ([A first mod](modding.md#a-first-mod)).
It never changes the game's files on disk, and players turn mods on and off, and set their order, on
the mods screen ([The mods screen](modding.md#the-mods-screen)).

## Replace the game's files

| A mod can | Read | Example |
|---|---|---|
| Replace any of the game's files by its name: a model, a sound bank, a piece of music, a line of speech, a face, a movie, a mission or a stats table | [How files are replaced](modding.md#how-files-are-replaced) | [`trent`](../../examples/mods/trent) |
| Add files under new names, for its own models, missions and scripts to use | [How files are replaced](modding.md#how-files-are-replaced) | [`teapot`](../../examples/mods/teapot) |
| Replace a piece of music, which loops back where the game's does | [Music](modding.md#music) | |
| Replace the pilots' faces and the lines they say | [Faces and voices](modding.md#faces-and-voices) | [`trent`](../../examples/mods/trent) |

## Change the look

| A mod can | Read | Example |
|---|---|---|
| Replace textures with PNG pictures of any size, or with DDS and KTX2 files compressed already | [Textures](modding.md#textures) | |
| Give surfaces normal, material and glow maps, lit as today's games light them | [Material maps](modding.md#material-maps) | |
| Draw the ships differently in the loadout | [Textures in the loadout](modding.md#textures-in-the-loadout) | |
| Replace the interface's shapes, sharp at any window size | [Shapes](modding.md#shapes) | |
| Replace the screens' backgrounds, widescreen ones included | [Pictures](modding.md#pictures) | |
| Replace the interface's fonts with TrueType or OpenType fonts | [Fonts](modding.md#fonts) | |
| Change how surfaces are lit, with GLSL surface and lighting functions | [Surface and lighting functions](scripting.md#surface-and-lighting-functions) | [`cel-shading`](../../examples/mods/cel-shading) |
| Draw post effects over the frame | [Post effects](scripting.md#post-effects) | [`crt`](../../examples/mods/crt) |
| Replace OpenReliant's own shaders | [Replacing OpenReliant's shaders](scripting.md#replacing-openreliants-shaders) | |

## Add ships, weapons and pilots

| A mod can | Read | Example |
|---|---|---|
| Add ship types, based on one of the game's or on none, with their own model, cockpit, display pictures and engine sound, offered on the loadout | [Ship types](modding.md#ship-types) | [`teapot`](../../examples/mods/teapot), [`interceptor`](../../examples/mods/interceptor) |
| Add guns, with their own shots, sounds and muzzle flashes | [Guns](modding.md#guns) | [`bananas`](../../examples/mods/bananas) |
| Add missiles, with their own models, offered on the loadout | [Missiles](modding.md#missiles) | [`bananas`](../../examples/mods/bananas) |
| Add pilots, with their own faces and voices | [Pilots](modding.md#pilots) | [`bananas`](../../examples/mods/bananas) |
| Build models from OBJ or glTF files, and export the game's models as glTF | [Models](modding.md#models) | [`teapot`](../../examples/mods/teapot), [`bananas`](../../examples/mods/bananas) |
| Change the stats of every ship, gun, missile and pilot, and the game's text | [The records](scripting.md#the-records) | [`balance`](../../examples/mods/balance), [`trent`](../../examples/mods/trent) |

## Missions and game modes

| A mod can | Read | Example |
|---|---|---|
| Replace missions, or add new ones, in the standard `.DTE` format | [Missions](modding.md#missions) | |
| Start a mission partway, or watch any of its ships, to check it | [Checking a mission](modding.md#checking-a-mission) | |
| Run scripts with one mission | [Kinds of scripts](scripting.md#kinds-of-scripts) | |
| Add game modes to the main menu, with rules of their own | [Game modes](scripting.md#game-modes) | [`arena`](../../examples/mods/arena), [`interceptor`](../../examples/mods/interceptor) |
| Add campaigns, with briefing screens and movies | [Campaigns](scripting.md#campaigns) | [`campaign`](../../examples/mods/campaign) |

## Change how the game plays

| A mod can | Read | Example |
|---|---|---|
| Hook the game's functions, such as damage, shots, missile launches and orders, to change or stop them | [Hooks](scripting.md#hooks) | [`rules`](../../examples/mods/rules) |
| React to the mission's events, such as a ship destroyed or docked | [Mission and engine events](scripting.md#mission-and-engine-events) | [`rules`](../../examples/mods/rules), [`tally`](../../examples/mods/tally) |
| Change what the radio says | [Changing what the radio says](scripting.md#changing-what-the-radio-says) | [`arena`](../../examples/mods/arena), [`teapot`](../../examples/mods/teapot) |
| Run a script on each ship of a class or a type | [Object scripts](scripting.md#object-scripts) | [`wingmen`](../../examples/mods/wingmen) |
| Give ships orders, and add AI orders of their own | [Orders](scripting.md#orders), [Custom AI orders](scripting.md#custom-ai-orders) | [`custom-order`](../../examples/mods/custom-order), [`wingmen`](../../examples/mods/wingmen) |
| Choose the pilot who flies a ship | [Objects](scripting.md#objects) | [`bananas`](../../examples/mods/bananas) |
| Find what's near a ship, and work with positions and angles | [Where things are](scripting.md#where-things-are) | [`wingmen`](../../examples/mods/wingmen) |
| Keep data with each saved game and across every game, and run timers | [Saved games](scripting.md#saved-games), [Storage](scripting.md#storage), [Timers](scripting.md#timers) | [`tally`](../../examples/mods/tally) |
| Let scripts and mods talk to each other | [Events](scripting.md#events), [Interfaces](scripting.md#interfaces) | [`wingmen`](../../examples/mods/wingmen) |

## The display, the menus and the controls

| A mod can | Read | Example |
|---|---|---|
| Draw over the flight display and the menus: text, lines, rectangles, the mod's pictures and fonts, and the game's shapes | [Drawing](scripting.md#drawing), [Pictures, shapes and fonts](scripting.md#pictures-shapes-and-fonts) | [`dvd`](../../examples/mods/dvd), [`drawing-assets`](../../examples/mods/drawing-assets) |
| Add displays to the flight display | [HUD displays](scripting.md#hud-displays) | [`arena`](../../examples/mods/arena), [`strafe-run`](../../examples/mods/strafe-run) |
| Add screens, and replace the front end's | [Screens](scripting.md#screens), [Replacing a screen](scripting.md#replacing-a-screen) | [`main-menu`](../../examples/mods/main-menu), [`strafe-run`](../../examples/mods/strafe-run) |
| Add camera views | [Camera views](scripting.md#camera-views) | [`strafe-run`](../../examples/mods/strafe-run) |
| Hear the keys and the game's controls, and add controls the player binds on the controls screen | [Keys and actions](scripting.md#keys-and-actions) | [`custom-order`](../../examples/mods/custom-order), [`strafe-run`](../../examples/mods/strafe-run) |
| Play the game's sounds and music, and Betty's lines | [Sound](scripting.md#sound) | |
| Offer a page of options on the mods screen | [Options](scripting.md#options) | [`wingmen`](../../examples/mods/wingmen) |

## Tools for mod makers

| Tool | Read |
|---|---|
| `sltool`, which extracts the game's files, and builds models, face films, lines and archives | [Tools](modding.md#tools) |
| Starting and checking a mission from the command line | [Checking a mission](modding.md#checking-a-mission) |
| A console in the game, and scripts that reload as they're saved | [The console](scripting.md#the-console), [Reloading](scripting.md#reloading) |
| Completion and type checks in an editor | [Editors](scripting.md#editors) |
| Lines and text drawn in the world, to see what a script does | [Debug drawing](scripting.md#debug-drawing) |
| The log, which says what each mod's files do | [Log messages](modding.md#log-messages) |
| Packing a mod into one archive, with a checksum and a thumbnail | [Sharing a mod](modding.md#sharing-a-mod) |

## Not yet

These are planned, each in an issue of the
[modding milestone](https://github.com/OpenReliant/openreliant/milestone/19):

- Sounds, music, speech and movies in today's formats
  ([#496](https://github.com/OpenReliant/openreliant/issues/496))
- Scripts on missiles and turrets ([#587](https://github.com/OpenReliant/openreliant/issues/587))
- Hooks on more of the game's functions ([#581](https://github.com/OpenReliant/openreliant/issues/581))
- Campaigns that go through the game's rooms, ITAC and saved games
  ([#641](https://github.com/OpenReliant/openreliant/issues/641))
- Changing a mod's options from the pause menu
  ([#600](https://github.com/OpenReliant/openreliant/issues/600))
- The scripting console in the rooms and the briefing
  ([#589](https://github.com/OpenReliant/openreliant/issues/589))
- Post effects that read the scene's depth ([#633](https://github.com/OpenReliant/openreliant/issues/633))
- KTX2 files with Basis Universal data ([#637](https://github.com/OpenReliant/openreliant/issues/637))
- The loadout's panels and the power ball at any size
  ([#509](https://github.com/OpenReliant/openreliant/issues/509))
- Outline fonts for the loadout panels' text and the flight display's small fonts
  ([#520](https://github.com/OpenReliant/openreliant/issues/520))
- A mod manager, to import, order and configure mods
  ([#497](https://github.com/OpenReliant/openreliant/issues/497))
- The game's models exported with all their detail levels and parts
  ([#697](https://github.com/OpenReliant/openreliant/issues/697))
- A mission source format, and a visual mission and script builder
  ([#608](https://github.com/OpenReliant/openreliant/issues/608),
  [#360](https://github.com/OpenReliant/openreliant/issues/360))
- Starting a mission partway with the state its earlier parts set
  ([#577](https://github.com/OpenReliant/openreliant/issues/577))
