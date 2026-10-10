# The editor link

Digital Anvil's own mission editor and script debugger, which never shipped, could drive the
original while it ran. The two share a block of named memory: the editor replaces the loaded
mission's tables, moves and remakes its ships, pauses the mission, and stops, steps and runs the
script, and the game reports where the script stopped. Nothing public speaks this link.

LordBlacksun decoded the link ([#539](https://github.com/OpenReliant/openreliant/issues/539)), and
the disassembly bears out what follows.

## The block

`editor_link_open` (`0x00457630`) opens the link on the first check. It makes the block,
`CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 0xD4A08, "FileMappingObject")`
(`editor_link_create`, `0x00457B90`, the name at `0x004F0F3C`), which opens the editor's block where
the editor made it first; maps a view of it (`MapViewOfFile` with `FILE_MAP_ALL_ACCESS`,
`0x00457BB0`); zeroes both message counts, so that the messages either side posted before are lost;
and flushes the counts (`FlushViewOfFile`, `0x00457BE0`). A view that can't be mapped stops the game
("file map creation error"). Each check maps a view of its own, as `mission_script_start` gives it
none, and never lets it go, nor does `editor_link_open` let go of its own; a check that can't map one
reads through a null pointer. `editor_link_send` lets go of the view it maps (`editor_link_unmap`,
`0x00457BD0`).

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | Messages from the editor waiting |
| `0x02` | 2 | Messages from the game waiting |
| `0x04` | 1 | Open: the game reads nothing while it is 0, and sets it to 1 as it posts a message into an empty outbox |
| `0x08` | 32 x 8 | The editor's messages |
| `0x108` | | The editor's payloads, at the offsets its messages give |
| `0x40108` | 32 x 8 | The game's messages |
| `0x40208` | | The game's payloads, at the offsets its messages give |
| `0x80208` | 0x4C each | The mission's ships as the editor keeps them, which tag `0x00` reads |

A message is 8 bytes: its tag (`u16`), its payload's size (`u16`) and its payload's offset (`u32`),
counted from the start of the payloads. `editor_link_post` (`0x00457A80`) posts a message after the
last one waiting, its payload after the last payload, and flushes the view after the count, the
message and the payload. With its sixth argument set, it leaves out a tag that is waiting already;
the game's own messages leave it clear, so each is posted.

## When the game reads it

Only `mission_script_start` (`0x0045CBC0`) reads the editor's messages, through `editor_link_check`
(`0x00457670`). Nothing else in the executable calls the check or the read, and no pointer to either
is kept, so a hold set later in the mission is never released.

A check that finds messages takes them one by one and acts on each (`editor_link_read`,
`0x00457730`), counting the editor's count down to 0, and takes the editor as there
(`editor_absent`, `0x004F634C`, cleared) with no misses counted. A check that finds none counts a
miss (`editor_link_misses`, `0x0052A1D4`); on the 513th in a row it takes the editor as gone and
forgets the ship it picked. While the editor is there, a check where `vm_clock` is a multiple of 5
and the script is neither held nor released (`vm_hold` 0) sends tag `0x1B`. `WinMain` sets
`editor_absent` as the game starts, and `mission_script_start` before its first check, so with no
editor the game sends nothing and its script never stops.

## The script's start

`mission_script_start` lifts the editor's pause (`editor_paused`, `0x00537581`), clears the hold
(`vm_hold`, `0x005373F8`) and the step (`vm_step_mode`, `0x00537582`, to -1), forgets the picked
ship and the misses, and sets `editor_absent`. Then:

1. it checks the link, waits a fifth of a second (`Sleep(200)`), and checks it again
   (`0x0045CC95`);
2. it runs each start part (`0x0045CCCD`): the part runs at once on a new thread (`part_run`), then
   the game checks the link and waits a millisecond, and while the script is held or released
   (`vm_hold` not 0) it does all three again, the part running again from its start on yet another
   thread.

So the game waits on the editor while it holds a start part, the window with it. Each time round,
the part's statements before the stop run again, and a new thread stops at the same byte.

## From the editor

`editor_link_read` sends each tag to its case through a jump table (`editor_link_cases`,
`0x004579BC`), and stops the game on a tag past `0x17` (`fatal_error`, "unidentified comms
request").

| Tag | Payload | What the game does |
|---|---|---|
| `0x00` | None | Sets each mission ship's runtime place and angles from the ships the editor keeps at `0x80208` in the block, `0x4C` bytes each (`editor_ships_place`, `0x004520A0`): `runtime_position` from the record's `+0x08`, and `runtime_yaw`, `runtime_pitch` and `runtime_roll` from its halfwords at `+0x20`, `+0x2C` and `+0x3C`, which aren't where a mission ship keeps them. **Unknown:** the rest of the editor's record |
| `0x01` | `object_id` (`u32`), then the place at `+0x08`, three floats | Places the object of each mission ship with that `object_id` there, then builds the curves again (`editor_ship_move`, `0x0045A6D0`, `curves_rebuild`) |
| `0x02` | 50 halfwords | Sets the counts of the mission's tables ([The tables' counts](#the-tables-counts)), then frees every thread (`editor_table_counts`, `0x0045A730`, `vm_threads_reset`) |
| `0x03` to `0x05`, `0x07` to `0x0E` | A table | Copies the table over the loaded mission's ([The table copies](#the-table-copies)) |
| `0x06` | The ships, `0x4C` bytes each | Copies some fields of each mission ship (`editor_ships_copy`, `0x0045AD80`): `object_id`, `name` with the halfword after it, `flight_group`, `kind`, `launch_from` to `launch_gate`, `formation_point` with the halfword after it, `marker_curve` with the two bytes after it, and `marker_at`. The places, the angles, the pilots and the flags stay as they are |
| `0x0F` | None | Binds the mission's tables again (`mission_bind_tables`) |
| `0x10` | The first part changed (`u32`), then how many were added (`i16`), or removed where negative | Renumbers the script timers' parts ([The timers' parts](#the-timers-parts)) |
| `0x11` | A ship, `0x4C` bytes | Retires the object at the index that `ship_index` (`0x004531C0`) works out from the payload's own address (`editor_ship_remove`, `0x0045A800`). That address lies in the block, not among the mission's ships, so the index isn't the ship's (**Unverified:** what the editor meant to send) |
| `0x12` | A ship, `0x4C` bytes | Retires an object as `0x11` does, then makes a ship from the payload's record (`editor_ship_remake`, `0x0045A820`, `mission_ship_create`) |
| `0x13` | None | Nothing |
| `0x14` | A mission ship's index (`u32`) | Where the ship has an object, places the player's ship four of the object's radii (`0x004DC424`) back from the ship's runtime place along the world's Z axis, and turns it to look at the ship (`editor_view_ship`, `0x0045A850`) |
| `0x15` | 8 bytes | Run control ([Run control](#run-control)) |
| `0x16` | A mission ship's index (`u16`) | Picks the ship (`editor_picked_ship`, `0x0052A1D8`), which nothing reads |
| `0x17` | 32 bytes | Keeps them at `0x005270E4`, which nothing reads |

### The table copies

`editor_table_copy` (`0x0045A770`) copies as many bytes as the table's count times its record's
size from the payload, whatever the payload's size, over the table:

| Tag | Table | Record |
|---|---|---|
| `0x03` | The script (`mission_script`) | 2 bytes |
| `0x04` | The parts | `0x1C` bytes |
| `0x05` | The triggers | `0x30` bytes |
| `0x07` | The flight groups | `0x14` bytes |
| `0x08` | The objects | 8 bytes |
| `0x09` | The script's flags (section 10) | 1 byte, for each of the script's bytes, rounded up to a multiple of 4 (`script_flags_size`, `0x00457B70`, `align4`) |
| `0x0A` | The squads | `0x0C` bytes |
| `0x0B` | The squads' members | `0x0C` bytes |
| `0x0C` | The formations | 8 bytes |
| `0x0D` | The formations' points | `0x10` bytes |
| `0x0E` | The curves | `0x44` bytes |

The tables lie in the mission's image, so a count larger than the file's fills the room the
mission's sections reserve beyond their records ([The mission file](../formats/dte.md)).

### The tables' counts

`editor_tables` (`0x004EE970`) lists 50 tables, 16 bytes each:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | The table's address |
| `0x04` | 2 | Its record's size |
| `0x06` | 2 | Its capacity, in records |
| `0x08` | 4 | Its count's address, or 0 |
| `0x0C` | 4 | **Unknown:** 1 in each entry used |

Tag `0x02` sets each count from the halfword at the same place in its payload, where the entry has a
count's address. Five do: the ships (512 at most), the flight groups (256), the objects (896), the
triggers (1024) and the parts (256). A sixth entry names `0x00525700`, with records of `0x34` bytes
and no count; the rest are empty. The script's timers keep their count (`vm_timer_count`).

### The timers' parts

Tag `0x10` hands each of the script's timers to `index_renumber` (`0x00451440`), which renumbers a
record's index as records are added or removed at a place. A timer whose part comes before the
first one changed keeps it. Where parts were removed, a timer whose part is the first one changed is
left with none (`index_set_none`, `0x00451510`). The others move by the count (`index_shift`,
`0x00451570`), unless they hold none. Its other modes set the index of a removed record to the
count, or move a record from one place to another (`index_move`, `0x004514B0`), for callers other
than the link.

### Run control

`editor_run_control` (`0x0045A900`) acts on its payload's first word, and does nothing past 4:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | The command: 0 pauses the mission or lets it go on; 1, 2 and 3 release the script with that step; 4 runs a part |
| `0x04` | 4 | For 0, the pause in its low byte (`editor_paused`, 0 to go on); for 4, the part's index |

Commands 1 to 3 set `vm_hold` to -1 and `vm_step_mode` to the command, but command 1 does nothing
while the script is neither held nor released. Command 4 runs the part at once on a new thread
(`part_run`), whatever its index.

## From the game

| Tag | Payload |
|---|---|
| `0x1A` | The script stopped: the offset in the script of the byte it stopped before (`u32`) |
| `0x1B` | `vm_first_finished` (`u32`): whether the thread pool's first thread has finished |

## Stopping and stepping

While the editor is there, `vm_run` (`0x0045C980`) checks before each instruction
(`0x0045C995` to `0x0045CA52`), by the instruction's offset in the script:

1. Before a byte whose flag in the script's flags (section 10) has bit 0 set, the thread stops,
   unless the editor released the script to run on (step 1). That release passes the byte: the
   hold and the step clear, and the instruction runs.
2. With no step (-1), the instruction runs.
3. With the script released, the hold clears and the step begins: a run on ends, and a step over
   notes the running block's end (`vm_block_end`) in the thread's `+0x14` and clears
   `vm_step_returned` (`0x00537414`). The instruction runs.
4. Otherwise, an instruction that starts a statement stops the thread (`vm_starts_statement`,
   `0x004575C0`: opcodes `0x16` to `0x1A`, `0x21` to `0x25`, `0x37` to `0x3A`, `0x4A`, `0x4D` and
   `0x4E`). A step over stops only once the running block's end is the one noted again, or a part
   has returned (`vm_step_returned`, which `vm_return` sets as a call returns).

A thread stops by setting the hold (`vm_hold` 1), sending tag `0x1A`, and returning with the thread
at that instruction. A run that ends as its thread yields while the editor steps into or over
statements releases the hold again (`0x0045CAD3`), so that the next thread to run takes the step
on. A thread that finishes ends the step.

| Step | Then |
|---|---|
| 1 | Runs on, past the byte it stopped before, to the next flagged byte |
| 2 | Stops before the next instruction that starts a statement |
| 3 | Steps over: stops before the next statement of the same block, or of the block a return goes back to |

## What the hold and the pause stop

| Where | While the script is held (`vm_hold` 1) | While the editor pauses the mission (`editor_paused`) |
|---|---|---|
| `process_mission` (`0x0045A570`) | The threads, the timers and the watches wait; the ships still take their objects' places | |
| `vm_clock_tick` (`0x00458910`) | The script's clock doesn't tick | |
| `mission_frame` (`0x0049288E`) | With the editor there, the frame leaves out its work after the check of `mission_over`: the ships take their objects' places, and nothing more is done or drawn | The same |
| `timer_callback` (`0x004A6F80`) | With the editor there, the script clock's timer (`vm_clock_timer`, `0x0052A1E4`) passes | No timer runs its routine: the game's ticks (`tick_timer`), the script's clock and the speech's stream all stop |

`mission_run`'s loop runs a game tick for each of the timer's ticks whatever `mission_frame` does, so
during a hold the simulation goes on, the ships flying on with the controls their orders last set,
while a pause stops it with the timer.

With an editor linked, `window_suspend` (`0x004A8260`) and `window_proc`'s restore (`0x004A8471`)
leave the window as it is, so that the game plays on, its sound too, while the editor has the focus.

## In OpenReliant

OpenReliant carries the original's messages over a TCP connection in place of the block, and acts on
them as the original does, with the improvements and fixes below. The code keeps the parts apart, so
that another game on the engine can link its own editor:

- `engine/link.zig`: the link, which no game owns: the messages' framing, whether an editor is there,
  and OpenReliant's own messages.
- `vm/editor.zig`: what the script VM keeps for the editor, which `vm/machine.zig` stops and steps
  by.
- `game/mission/editor.zig`: StarLancer's tags, as a table of each tag's name, its case in the
  original, and what OpenReliant does with it; and the session that works on each mission.
- `platform/link.zig`: the transport.

### The connection

With `--editor-link`, OpenReliant listens on this computer's own address, 127.0.0.1, at port 22539,
or the port `--editor-link-port` gives ([Configuration](../guide/configuration.md)). It takes one
editor at a time; another that connects waits until the first goes. An editor is there for as long
as it stays connected.

Each message is an 8-byte header, little-endian, then its payload:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | The tag |
| `0x02` | 2 | 0 |
| `0x04` | 4 | The payload's size |

The original's tags keep their payloads. A payload larger than the original's block, `0xD4A08`
bytes, drops the connection, as does an editor that sends more than four of those while the game
takes none.

OpenReliant's own tags follow the original's, from `0x100`. Each payload is text, a `key=value` line
for each field, but the mission's file:

| Tag | Message | Payload | Sent |
|---|---|---|---|
| `0x100` | Hello | `protocol` (1), `openreliant` (its version), `game` (`StarLancer`), `vm` (the script VM's dialect, `starlancer`) | By the game, as an editor connects |
| `0x101` | Mission started | `number`, `file` (such as `mission1.dte`) | By the game, as a mission's script starts, and to an editor that connects while one plays |
| `0x102` | Mission ended | None | By the game, as the mission ends |
| `0x103` | Get mission | None | By the editor, for `Mission file` |
| `0x104` | Mission file | The mission's file as the game runs it, its globals as they stand | By the game, right after `Mission started`, and as the editor asks |
| `0x105` | Get state | None | By the editor, for `State` |
| `0x106` | State | The script's state, below | By the game, as the editor asks |

`State` gives, a line each:

| Key | Value |
|---|---|
| `clock` | The script's clock, in seconds |
| `hold`, `step`, `paused` | The editor's hold (`held`, `released` or `none`), its step (`run_on`, `into`, `over` or `none`), and its pause (1 or 0) |
| `first_finished` | Whether the thread pool's first thread has finished (1 or 0) |
| `thread.N.at` | Where thread `N`, by its slot, is in the script, as an offset; `none` outside it |
| `thread.N.depth`, `thread.N.wake`, `thread.N.interrupted` | Its call depth, the clock value it waits for (0 for none), and whether it waits for its trigger (1 or 0) |
| `thread.N.trigger` | The trigger that started it, where one did |
| `global.N` | Global `N`'s value |
| `variable.NAME` | The game's variable `NAME`, such as `mission_over`; one with no name by its number, where it isn't 0 |

Values are the script's words, unsigned.

### What it does

- OpenReliant acts on tags `0x09` (the flags), `0x13` and `0x15` (run control), and passes over
  `0x16` and `0x17`, whose bytes nothing reads. It logs the other tags, the editor's live changes to
  the mission, once each, and passes over them
  ([#1057](https://github.com/OpenReliant/openreliant/issues/1057)). It sends tags `0x1A` and `0x1B`.
- The editor's messages wait while no mission plays, as the original's wait in its block for the
  next mission's start. Each attempt reads the mission's file again, so the flags last for one
  attempt: an editor sends them again once the file comes with each `Mission started`, a fifth of a
  second before the start parts run.
- The link opens as the game starts, so that an editor waiting for the game is there before the
  first mission's script starts.
- The script's start waits on the editor as the original's does, drawing nothing until the editor
  releases the start part.
- The hold and the pause stop what they stop in the original. OpenReliant counts the game's ticks
  for the script's clock, and leaves out a hold's ticks; and while the editor pauses the mission,
  the timer's ticks pass unrun, the sound's fades stopping with them. The game's ticks count from
  the end of the mission's start, as `mission_run` counts them (`0x00494148`), so that the time a
  held start part took isn't run as game ticks.
- With an editor connected, the game's window going inactive pauses nothing.

**Improvements:**

- OpenReliant reads the editor's messages every frame, so that a hold during the mission can be
  released, and the editor hears of the first thread once for each fifth second of the script's
  clock.
- OpenReliant sends the editor the mission's file and the script's state, where the original's
  editor had its own copy of the mission and its debugger only heard where the script stopped.
- As the editor goes, the script is let go: its hold, its step and the editor's pause clear. The
  original keeps the script held, waiting for good.
- The script's start waits for the editor only while one is there, where the original waits a fifth
  of a second at every mission's start.
- A tag past `0x17` is logged and passed over, where the original stops the game.
- While the editor holds the script or pauses the mission, OpenReliant still draws the frame, with
  the frame's work left out.

**Fixes:**

- Once the editor releases a start part it holds, the part's thread runs on from where it stopped,
  where the original runs the part again on a new thread each time round.
- The original takes a byte of `script_b` as a byte of the script, and reads its flag from past the
  flags. OpenReliant takes it as unflagged.
- A table copy takes no more than the payload, and stops at the next section's start.
- Run control's part runs only where its index is within the mission's parts, where the original
  reads past the parts' table.

### Writing a client

`openreliant debug` is a small client ([Debugging mission scripts](../guide/debugging.md)). Another
works the same way:

1. Connect to 127.0.0.1 at the port, and read `Hello`.
2. On `Mission file`, which comes right after `Mission started`, send tag `0x09` with the script's
   flags within a fifth of a second: a byte for each of the script's bytes, rounded up to a
   multiple of 4, with bit 0 set on each byte to stop before. The statements end at the opcodes
   `vm_starts_statement` gives (above), which a step stops before.
3. On tag `0x1A`, the script is held before the byte at the offset it gives: send tag `0x15` with 1
   to run on, 2 to step into the next statement, or 3 to step over it; or with 0 and 1 to pause the
   mission, and 0 and 0 to let it go on.
4. Send `Get state` for the script's threads, globals and variables.
