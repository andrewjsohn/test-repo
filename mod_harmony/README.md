# Mod Harmony

A small client-only Don't Starve Together mod that patches how these mods work together:

- Auto Combat (3829345300)
- Equipment Master (3123028409)
- auto_dodger (3760823838)
- Better Lag Compensation (3813222728)
- ActionQueue RB3 (2873533916)
- Auto Explore (3826759911)

It doesn't change any of those mods' files. It wraps a few of their functions when the game loads, and every fix can be switched off on its own.

## What it fixes

| Problem | Cause | What Mod Harmony does |
| --- | --- | --- |
| Ham Bat snaps back over the Lazy Explorer or cane | When Auto Combat has no target, it decides to keep what you hold, but it never clears its earlier "weapon" request. It keeps re-equipping the weapon a tenth of a second after any swap. | Keeping now really clears the old request. A hands item you equip yourself is left alone for a short while (2 s by default). |
| Dodges start late and stop right at the edge | auto_dodger sizes each attack's danger circle without any allowance for ping, then parks you 0.1 past the edge. | While an attack is winding up, its danger circle grows by your ping × your run speed, plus a margin (0.5 by default). Auto Combat's own danger filter still runs first. |
| Frozen swing when ActionQueue chops or mines | Better Lag Compensation only keeps predicting swings while a key is held, and ActionQueue never holds one. | Better Lag Compensation's swing prediction is switched off while ActionQueue is working, then back on. |
| Auto Explore keeps walking after F1 | Its stop never reaches the server, so you finish walking to its last target. | Pressing the key while it is running sends the server a stop right away. |
| Gliding with a frozen pose while exploring | Auto Explore's clicks go straight to the server and skip your game's movement prediction. | Each explore step is also shown on your screen, like a normal click, so you walk normally. |
| Auto Explore pulls you around in fights | Nothing pauses it. | It pauses while auto_dodger is dodging, hit-and-run has a target, ActionQueue is working, or a creature nearby is targeting you. It resumes on its own afterwards. |
| Walking swaps your lantern for another item in caves or at night | Equipment Master swaps in its walking item every time you start walking, and only puts a light back after you are already in the dark. | In caves and on dark nights, a walking swap that would take off your only light is skipped. A miner hat or other light still lets it swap. |

## Install

1. Copy the `mod_harmony` folder into
   `C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\mods\`
   so you end up with `...\mods\mod_harmony\modinfo.lua`.
2. Start the game, open Mods, and enable **Mod Harmony (Andrew's helper)** under the client mods.
3. Optional: open its settings to switch fixes on or off, set the ping padding, or match Auto Explore's key if you changed it from F1.

It loads after the mods it patches (priority -100), so mod order doesn't matter.

## Not covered

- **Animal Tracker and Cane Kiting both use O.** These are plain key settings, so change one of them in its mod settings rather than patching it here.
- **Up/Down arrow keys** belong to the hit-and-run mod (kiting mode and its own auto dodge). You can rebind them in that mod's in-game settings.

## Testing status

This hasn't been run in game yet. The Lua parses cleanly, and every hook is based on the code of the versions installed on 2026-10-31. If something misbehaves, turn on **Debug log** in its settings. The helper then logs what it does to `client_log.txt` under the `[mod_harmony]` tag.
