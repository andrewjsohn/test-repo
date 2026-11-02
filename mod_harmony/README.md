# Mod Harmony

A small client-only Don't Starve Together mod that patches how these mods work together:

- Auto Combat (3829345300)
- Equipment Master (3123028409)
- auto_dodger (3760823838)
- Better Lag Compensation (3813222728)
- ActionQueue RB3 (2873533916)
- Auto Explore (3826759911)
- hit-and-run (3014188454), for its arrow keys only

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
| Auto Combat or Equipment Master fights with the pickaxe | A pickaxe and an axe hit equally hard, and both mods keep the first of equal weapons they find. | When either one picks a pickaxe for a fight and you carry an axe that hits as hard, the axe goes in your hands instead. A pick/axe, a stronger pickaxe, and a pickaxe you equip yourself are left alone. |
| Night light is a torch even with a lantern in your bag | Equipment Master and Auto Actions take the first light they find. | In the dark, a torch a helper equips for light is swapped for a lantern with fuel. A torch you equip yourself, or one used to set fires in a fight, is left alone. |
| Shift+click a boulder with Auto Combat on and nothing is mined | With no enemy, Auto Combat asks for your weapon every frame. Mod Harmony's own axe rule told it a pickaxe isn't good enough while you carry an axe that hits as hard, and the 0.1.7 tool hold only started for equips it recognised, so the pickaxe went back before the first swing. | While Auto Combat has nothing to fight, any tool in your hands (pickaxe, axe, shovel, hammer, net) stays there, however it got there. Once a fight starts, Auto Combat uses your real weapon if it hits harder than the tool. |
| Shift+click a tree, boulder or anything to hammer with Auto Combat on and nothing happens unless the right tool is already in hand | Auto Combat turns movement prediction off while it runs. ActionQueue then sends each Shift+click straight to the server and skips the step where Auto Actions swaps in the right tool. | With prediction off, Mod Harmony equips the tool Auto Actions picked for that click first, and the click waits (up to about a second) until it is in your hands. |
| A pickaxe left in hand stays in a fight even though you carry an axe | If neither Auto Combat nor Equipment Master swaps it in, nothing else did. | While Auto Combat fights and a tool is in your hands, Mod Harmony equips the better item itself: your real weapon if it hits harder, otherwise the axe instead of a pickaxe. A hands item you picked yourself in the last couple of seconds is left alone. |
| The lantern goes away for the whole fight in the dark | Auto Combat's walking item is the fastest hands item, never a light, so a fight in the dark is all weapon. Auto Actions' light in the dark and Equipment Master's night light then try to put the lantern back mid-fight. | In the dark, Auto Combat's walking item is your lantern: weapon to attack, lantern to dodge and close in, and the lantern stays when there's nothing to fight. While Auto Combat attacks, Auto Actions' and Equipment Master's dark light wait. |
| F and Auto Combat hit the spider den while spiders bite you | A den counts as a hostile creature, and it is usually the closest one. | F takes nearby spiders first and leaves a den alone unless you started on it with Ctrl+F (then holding F keeps going). Auto Combat and hit-and-run fight every spider in reach first and the den last. |
| Dodges cut too close on spider webbing | auto_dodger works out how far you can run from your gear only. Webbing slows you to 60%. | auto_dodger counts your real speed on webbing (Webber excepted), and dodges keep 0.5 more distance there. |
| A Marotter's bite lands while Auto Combat kites | The bite lands half a second after it starts, and auto_dodger shrinks the danger circle by how far it thinks you can run in that time. | The bite's danger circle stays at its full reach (plus the usual ping margin) for the whole wind-up. |
| Arrow keys do more than zoom the camera | hit-and-run uses Up for kiting mode, Down for its own auto dodge, and Left/Right for its range, on top of Observer Camera's zoom. | While those hit-and-run keys are still set to arrows, they do nothing, so the arrows only move the camera. A key you move elsewhere in hit-and-run's settings keeps working. |
| Auto Dodge on while Auto Combat is off | auto_dodger turns itself on when the game loads and toggles on Z, separately from Auto Combat. | Auto Dodge is kept on exactly while Auto Combat runs and off otherwise, so turning Auto Combat off leaves plain F attacks with no dodging. |
| Auto Combat misses swings, and walking swaps your weapon for a marbell | With no cane, Equipment Master's walking item is any hands item. Auto Combat asks for walking gear between swings (in Event or Auto gear mode), so the weapon keeps leaving your hands and each opening waits for it to come back. | A walking swap of the hands item is skipped unless the new item is actually faster. With a cane, walking still swaps to it. |

## Install

1. Copy the `mod_harmony` folder into
   `C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\mods\`
   so you end up with `...\mods\mod_harmony\modinfo.lua`.
2. Start the game, open Mods, and enable **Mod Harmony (Andrew's helper)** under the client mods.
3. Optional: open its settings to switch fixes on or off, set the ping padding, or match Auto Explore's key if you changed it from F1.

It loads after the mods it patches (priority -100), so mod order doesn't matter.

## Not covered

- **Animal Tracker and Cane Kiting both use O.** These are plain key settings, so change one of them in its mod settings rather than patching it here.
- **Z no longer toggles Auto Dodge by itself** while "Dodge follows Auto Combat" is on, because the dodge always matches Auto Combat. Turn that switch off to get Z back.

## Testing status

This hasn't been run in game yet. The Lua parses cleanly, and every hook is based on the code of the versions installed on 2026-10-31 and 2026-11-02. If something misbehaves, turn on **Debug log** in its settings. The helper then logs what it does to `client_log.txt` under the `[mod_harmony]` tag. With the log on, it also writes `trace:` lines (every change of what's in your hands while Auto Combat is on, and gear swaps and moves sent while ActionQueue works or Auto Combat fights, with the mods they came from) and a `hit:` line for every hit you take while Auto Combat runs (what was near you, whether you were dodging, your speed, webbing).
