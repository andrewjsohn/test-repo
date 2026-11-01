# Attack Queue (Updated)

A client-only update of **Attack Queue** (Steam Workshop
[2059280386](https://steamcommunity.com/sharedfiles/filedetails/?id=2059280386),
by eXiGe, the original author, and Tony) for the current Don't Starve Together build.
The original stopped working with current game updates.

## What it does

| Input | Effect |
| --- | --- |
| Shift + F | Lock on to the nearest enemy (within the lock-on range) and keep attacking it until it dies. |
| Ctrl + Shift + F | Same, but force attack, so neutral mobs count. Your allies and other players' followers are never picked. |
| Shift + left-drag (with ActionQueue RB3) | Mobs inside the box are queued as attacks and fought one by one, nearest first, before any trees, rocks or pickups the box also caught. |
| Ctrl + Shift + drag/click (with ActionQueue RB3) | Neutral mobs are selected too (force attack). |
| Shift + click (without ActionQueue) | Toggle a mob in the queue. Shift + double-click queues every mob of that kind nearby. Releasing the click starts the queue. |
| Move, Space, inspect, or click the world without Shift | Stops the attack queue. |

Other behaviour kept from the original:

- When your weapon breaks mid-fight, another of the same kind is equipped from
  your inventory, backpack or open containers. If none is found and crafting is
  allowed, it crafts one when you have the materials.
- Playing a pan flute stops the queue.
- Targets are highlighted while queued and unhighlighted when done.

## What changed from the original

- **Swings use the game's own predicted attack** (`PlayerController:DoAction`
  with an `ATTACK` buffered action and a `LeftClick` RPC), not a raw
  `AttackButton` RPC every three frames. The old way left the server's attack
  control held, showed no local swing with lag compensation on, and flooded the
  server.
- **A target is done when it is dead or gone**, not when `CanTarget` turns
  false. `CanTarget` is briefly false right after each hit in the current game,
  which made the original stop after one swing.
- **ActionQueue RB3 integration** uses RB3's own hooks (`AddAction`,
  `GetAction`, `GetClosestTarget`, `SendActionAndWait`) instead of a second
  selection system, so boxes and highlights stay RB3's and enemies are fought first.
- **Better Lag Compensation**: its movement prediction is paused while a fight
  is running and restored a moment after, the same way Mod Harmony does for
  ActionQueue.
- **Auto ReEquip Weapon**: when that mod is enabled, weapon re-equip is left to it
  (configurable).
- Target rules match the current game's own attack rules (hostile or targeting
  you for plain attacks; never allies; others' followers only with force).
- Lua globals come from `GLOBAL`, as the current mod environment requires.

The butterfly special case and the old ActionQueue PICKUP remove/re-add trick
were dropped; RB3 no longer needs them.

## Options

Queue key, lock-on range, ActionQueue box attacks, Shift + click queue
(Auto/On/Off), re-equip (Auto/On/Off), craft new weapon, debug log.

Keep the queue key the same as ActionQueue's key (Shift by default).

## Tested

A mock of the DST client runtime (Lua 5.1) loads `modinfo.lua` and
`modmain.lua`, together with the real ActionQueue RB3 4.4 code in both load
orders, and checks lock-on, kill-until-dead, force attack, interrupts,
re-equip, the RB3 box flow and the BLC toggle. It has **not** been run in the
real game yet: server acceptance, animations with BLC, ranged weapons, boats
and controller input are untested.

## Install

Copy this folder to
`Steam/steamapps/common/Don't Starve Together/mods/attack_queue_updated`, then
enable **Attack Queue (Updated)** under Mods > Client Mods. Leave the old
Attack Queue (2059280386) disabled.
