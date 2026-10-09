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
| Give lines of speech, briefings and Enriquez's scenes as WAV or MP3 recordings, which play as recorded | [Lines](modding.md#lines) | |

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
| Say lines on the radio, to add chatter or voice a mission that has none | [The radio](scripting.md#the-radio) | |
| Set the state of a mission's objectives, for a mission whose script doesn't | [A mission's objectives](scripting.md#a-missions-objectives) | |
| Set the player's target and the mission's primary target, such as the next component to destroy | [The player's target](scripting.md#the-players-target) | |
| Add game modes to the main menu, with rules of their own | [Game modes](scripting.md#game-modes) | [`arena`](../../examples/mods/arena), [`interceptor`](../../examples/mods/interceptor) |
| Add campaigns, with briefing screens and movies | [Campaigns](scripting.md#campaigns) | [`campaign`](../../examples/mods/campaign) |
| Put missions into the game's own campaign, or replace its missions, with each one's briefing, carrier, objectives, date, awards, Enriquez's report and debriefing, the ITAC's news, and the rules the game applies to particular missions, through the game's rooms and saved games | [The campaign's missions](scripting.md#the-campaigns-missions), [Each mission of the campaign](scripting.md#each-mission-of-the-campaign) | |
| Change the stats and the text for a game mode's missions alone, leaving the game's campaign as it is | [Game modes](scripting.md#game-modes) | |

## Change how the game plays

| A mod can | Read | Example |
|---|---|---|
| Hook the game's functions, such as damage, shots, missile launches, orders and the mission script's commands, to change or stop them | [Hooks](scripting.md#hooks) | [`rules`](../../examples/mods/rules) |
| React to the mission's events, such as a ship destroyed or docked | [Mission and engine events](scripting.md#mission-and-engine-events) | [`rules`](../../examples/mods/rules), [`tally`](../../examples/mods/tally) |
| Change what the radio says | [Changing what the radio says](scripting.md#changing-what-the-radio-says) | [`arena`](../../examples/mods/arena), [`teapot`](../../examples/mods/teapot) |
| Run a script on each ship of a class or a type | [Object scripts](scripting.md#object-scripts) | [`wingmen`](../../examples/mods/wingmen) |
| Run a script on each missile in flight, to retarget it or set it off | [Missile scripts](scripting.md#missile-scripts) | |
| Run a script on each turret, to choose what it aims at | [Turret scripts](scripting.md#turret-scripts) | |
| Give ships orders, and add AI orders of their own | [Orders](scripting.md#orders), [Custom AI orders](scripting.md#custom-ai-orders) | [`custom-order`](../../examples/mods/custom-order), [`wingmen`](../../examples/mods/wingmen) |
| Choose the pilot who flies a ship | [Objects](scripting.md#objects) | [`bananas`](../../examples/mods/bananas) |
| Find what's near a ship, and work with positions and angles | [Where things are](scripting.md#where-things-are) | [`wingmen`](../../examples/mods/wingmen) |
| List a ship's parts and attachment points, and see which are destroyed | [A ship's parts](scripting.md#a-ships-parts) | |
| Destroy ships, or one of their components, such as a shield generator | [A ship's parts](scripting.md#a-ships-parts) | |
| Keep data with each saved game and across every game, and run timers | [Saved games](scripting.md#saved-games), [Storage](scripting.md#storage), [Timers](scripting.md#timers) | [`tally`](../../examples/mods/tally) |
| Let scripts and mods talk to each other | [Events](scripting.md#events), [Interfaces](scripting.md#interfaces) | [`wingmen`](../../examples/mods/wingmen) |

## The display, the menus and the controls

| A mod can | Read | Example |
|---|---|---|
| Draw over the flight display and the menus: text, lines, rectangles, the mod's pictures and fonts, and the game's shapes | [Drawing](scripting.md#drawing), [Pictures, shapes and fonts](scripting.md#pictures-shapes-and-fonts) | [`dvd`](../../examples/mods/dvd), [`drawing-assets`](../../examples/mods/drawing-assets) |
| Add displays to the flight display | [HUD displays](scripting.md#hud-displays) | [`arena`](../../examples/mods/arena), [`strafe-run`](../../examples/mods/strafe-run) |
| Replace, move and scale the game's HUD instruments, and read what they show | [The game's instruments](scripting.md#the-games-instruments) | [`hud-layout`](../../examples/mods/hud-layout) |
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

These are planned, each in an issue:

- Sounds, music and movies in today's formats, and lines of speech in FLAC, Ogg Vorbis or Opus
  ([#496](https://github.com/OpenReliant/openreliant/issues/496))
- The landing, the chapters' news, the wing's pilots and the ITAC's squadrons by mission number,
  and the KILLBOARD's pilots ([#1011](https://github.com/OpenReliant/openreliant/issues/1011),
  [#1008](https://github.com/OpenReliant/openreliant/issues/1008))
- Campaigns of more than 28 missions ([#987](https://github.com/OpenReliant/openreliant/issues/987))
- Post effects that read the scene's depth ([#633](https://github.com/OpenReliant/openreliant/issues/633))
- KTX2 files with Basis Universal data ([#637](https://github.com/OpenReliant/openreliant/issues/637))
- The loadout's panels and the power ball at any size
  ([#509](https://github.com/OpenReliant/openreliant/issues/509))
- Outline fonts for the loadout panels' text and the flight display's small fonts
  ([#520](https://github.com/OpenReliant/openreliant/issues/520))
- The game's models exported with all their detail levels and parts
  ([#697](https://github.com/OpenReliant/openreliant/issues/697))
- A mission source format, and a visual mission and script builder
  ([#608](https://github.com/OpenReliant/openreliant/issues/608),
  [#360](https://github.com/OpenReliant/openreliant/issues/360))
- Starting a mission partway with the state its earlier parts set
  ([#577](https://github.com/OpenReliant/openreliant/issues/577))
