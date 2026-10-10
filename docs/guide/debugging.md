# Debugging mission scripts

`openreliant debug` stops a mission's script at breakpoints, steps through it a statement at a
time, and shows where it stopped and what it holds. It talks to the game over the editor link, the
link the original kept with Digital Anvil's own mission editor and script debugger
([The editor link](../engine/editor-link.md)), so the game has to be started with `--editor-link`.

It's a small debugger that shows what the link can do. A full mission editor and debugger is a
project of its own, which talks to the game over the same link.

## Starting it

Start the debugger in a terminal:

```bash
openreliant debug
```

Then start the game with `--editor-link`, here with mission 0, OpenReliant's sandbox:

```bash
openreliant --editor-link --mission 0
```

The debugger waits for the game, and for it again once it goes. The game listens only on this
computer's own address, at port 22539; `--editor-link-port` changes the game's, and the debugger's
`--port` its own ([Configuration](configuration.md)).

## A session

A breakpoint set before the game starts stops the mission's start part. `list` then shows the part,
with its statements numbered, `>` where the script stopped and `*` at each breakpoint:

```text
Waiting for a game at 127.0.0.1:22539. Type help for the commands.
(debug) break 0
Breakpoint 1, 0:1: for the next mission
Connected to StarLancer, OpenReliant x.y.z.
Mission 0 starts (mission0.dte).
1 of 1 breakpoints are in its script.
Stopped at 4, statement 1 of part 0, (F)Start:
       4  21 03       command   CreateFlightGroup
(debug) list
part 0, (F)Start
           2  2d 01       push_flight_group   1
>*   1     4  21 03       command   CreateFlightGroup
           6  2d 00       push_flight_group   0
     2     8  21 03       command   CreateFlightGroup
...
(debug) step
Stopped at 8, statement 2 of part 0, (F)Start:
       8  21 03       command   CreateFlightGroup
(debug) delete
The breakpoints are gone.
(debug) continue
```

## Commands

| Command | What it does |
|---|---|
| `parts [<text>]` | Lists the mission's parts, or those whose names hold the text |
| `list [<part>]` | Shows a part's instructions, its statements numbered; without a part, the routine the script stopped in |
| `break <part>[:<n>]` | Stops before statement `n` of a part, its first by default |
| `break @<offset>` | Stops before the byte at that offset in the script |
| `breaks` | Lists the breakpoints, and where each stops in the mission playing |
| `delete [<n>]` | Removes breakpoint `n`, or all of them |
| `continue`, `c` | Lets the script run on to the next breakpoint |
| `step`, `s` | Runs to the next statement |
| `next`, `n` | Runs to the next statement, past the parts it calls |
| `pause`, `resume` | Pauses the mission, or lets it go on |
| `run <part>` | Runs a part at once, on a new thread |
| `where` | Shows where the script stopped |
| `state` | Shows the script's clock, its threads and the mission's globals, and the game's variables that aren't 0 |
| `quit`, `q` | Quits, letting the script go |

A part is named by its number, or by its name or a piece of it in any case, as `parts` lists them.

## Breakpoints and statements

A statement ends with the instruction the script stops before: a store, a command, a call, a
conditional branch, a return or a spawn, after the instructions that push its operands. `list`
numbers the statements at those instructions, and `break <part>:<n>` stops before the `n`th.

Breakpoints stay set from one mission to the next. As a mission starts, the game sends the debugger
the mission's file, and the debugger places the breakpoints in its script before the start parts
run, so a breakpoint set before the game starts can stop them. Each attempt at a mission reads its
file again, and the breakpoints are placed again for it. A breakpoint whose part the mission doesn't
have waits for one that has it.

`step` and `next` work from where the script stopped. From a running script, they stop at the next
statement any thread runs.

## While the script is stopped

As in the original, a stopped script holds up the mission's own work: the ships' orders, the
controls, the script's other threads, its timers and its clock wait, and the ships fly on as their
orders last left them. `pause` stops the whole mission, ships and all. A stopped start part holds up
the mission's start, and the game shows its loading screen until the script runs on.

The game keeps playing while the debugger's window has the focus. Quitting the debugger lets the
script go.
