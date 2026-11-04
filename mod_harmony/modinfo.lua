name = "Mod Harmony (Andrew's helper)"
description = [[
Makes Auto Combat, Equipment Master, auto_dodger, Better Lag Compensation,
ActionQueue RB3 and Auto Explore play nicely together.

- Auto Combat stops forcing your weapon back when it has nothing to fight.
- A weapon or tool you equip by hand is respected for a few seconds.
- auto_dodger starts dodges earlier on a laggy connection and stops a bit
  further from the edge of an attack.
- ActionQueue chopping and mining no longer freezes the swing animation.
- Auto Explore stops the moment you press its key, walks with a normal
  walking animation, and pauses during fights and ActionQueue work.
- Walking in caves or at night never swaps away your only light.
- Walking only swaps your weapon out for something that is actually
  faster, so Auto Combat has it in hand when it swings.
- Auto Combat and Equipment Master fight with your axe before a pickaxe
  or shovel, and a spear before a marbell. A tool still in hand when a
  fight starts makes way for the weapon.
- In the dark, helpers light your way with a lantern instead of a torch.
- A tool in your hands (a Shift+click with Auto Actions, say) stays there
  while Auto Combat has nothing to fight. In a fight, your real weapon.
- With Auto Combat on, ActionQueue's Shift+click still swaps in the right
  tool (Auto Combat turns movement prediction off, which skipped it).
- A tree or rock queued with Shift+click alongside pickups is no longer
  dropped when you hold the wrong tool: the queue waits for the pickup
  to finish, then switches tools and walks over.
- Spider dens come last: F takes the spiders first and leaves a den alone
  unless you start on it with Ctrl+F; Auto Combat fights spiders first.
- On spider webbing, dodging counts on your slower speed.
- Auto Combat leaves lava larvae alone while Dragonfly is close, and keeps
  swinging at full speed.
- A Marotter's quick bite is dodged from its full reach.
- In the dark, Auto Combat swaps weapon and lantern (or torch): weapon to
  attack, light to dodge and close in. Other helpers' lights wait meanwhile.
- Turning Auto Combat off at night leaves your light in your hands.
- While ActionQueue works, Shift+click and Shift+drag still add trees,
  rocks and the like that need a tool you aren't holding (a marbell in
  hand included), and other helpers stop swapping your tool out between
  queued targets.
- Hounds are given more room after their bite, and werepigs are kited.
- The arrow keys only zoom the camera; hit-and-run's arrow keys are off.
- Auto Dodge is on exactly while Auto Combat is on.
- A helper mod's error while picking an attack target or walking no longer
  crashes the game; it is written to the log with where it happened.
- With Auto Combat off, a Shift+click chop queue no longer stalls when
  you stand still between swings.
- Other mods' Chinese text that was translated before shows in English,
  even after a Steam update puts the Chinese back (new text stays as is).

Client only. Every fix has its own switch below.
]]
author = "Claude for Andrew"
version = "0.2.3"
api_version = 10
dst_compatible = true
client_only_mod = true
all_clients_require_mod = false
-- Load after every mod it patches (they all use priority 0 or higher).
priority = -100

local function onoff(name, label, hover, default)
    return {
        name = name,
        label = label,
        hover = hover,
        options = {
            { description = "On", data = true },
            { description = "Off", data = false },
        },
        default = default,
    }
end

configuration_options = {
    onoff("fix_gear_fight", "Fix gear tug-of-war",
        "Auto Combat lets go of its old 'weapon' request when it decides to keep what you hold", true),
    {
        name = "manual_equip_grace",
        label = "Respect manual equip for",
        hover = "After you equip something in your hands yourself, Auto Combat leaves your hands alone this long",
        options = {
            { description = "Off", data = 0 },
            { description = "1 second", data = 1 },
            { description = "2 seconds", data = 2 },
            { description = "3 seconds", data = 3 },
            { description = "5 seconds", data = 5 },
        },
        default = 2,
    },
    onoff("fix_dodge_timing", "Lag-aware dodging",
        "Grows each attack's danger circle by how far you move during one ping, so dodges start in time", true),
    {
        name = "dodge_ping_scale",
        label = "Ping padding",
        hover = "How much of your ping to add to each danger circle",
        options = {
            { description = "50%", data = 0.5 },
            { description = "100%", data = 1 },
            { description = "150%", data = 1.5 },
        },
        default = 1,
    },
    {
        name = "dodge_extra_margin",
        label = "Extra edge margin",
        hover = "Extra distance to keep from the edge of an attack, on top of the ping padding",
        options = {
            { description = "None", data = 0 },
            { description = "0.25", data = 0.25 },
            { description = "0.5", data = 0.5 },
            { description = "1", data = 1 },
        },
        default = 0.5,
    },
    onoff("fix_queue_freeze", "Fix frozen chop/mine swing",
        "Turns off Better Lag Compensation's swing prediction while ActionQueue is working", true),
    onoff("fix_explore", "Fix Auto Explore",
        "Instant stop, normal walking animation, and pause during fights", true),
    onoff("keep_light", "Keep your light in the dark",
        "In caves and at night, walking never swaps your only light (lantern, torch, miner hat) for another item", true),
    onoff("walk_only_faster", "Walk swaps only when faster",
        "Walking swaps your hands item only for one that makes you faster (a cane), so your weapon stays in hand", true),
    onoff("prefer_axe", "Axe, pickaxe, shovel; spear before marbell",
        "When Auto Combat or Equipment Master picks a tool or marbell to fight with, use your axe over a pickaxe or shovel, your pickaxe over a shovel, and a spear over a marbell", true),
    onoff("prefer_lantern", "Lantern before torch",
        "In the dark, when a helper equips a torch for light and you carry a lantern with fuel, the lantern is used instead", true),
    onoff("keep_tools", "Tools stay in hand between fights",
        "While Auto Combat has nothing to fight, a tool in your hands stays there. In a fight, Auto Combat uses your real weapon if it hits harder", true),
    onoff("queue_tools", "Shift+click switches tools",
        "With Auto Combat on, the tool Auto Actions picks for a Shift+click is equipped before the click. After pickups, a queued tree or rock waits until you're idle instead of being dropped. Targets that need a tool you carry but don't hold (a marbell in hand too) can still be queued", true),
    onoff("queue_keep_tool", "Keep the queue's tool in hand",
        "While ActionQueue works with a tool, Auto Actions and Equipment Master don't swap it for another item (a Lazy Explorer, bare hands) between queued targets", true),
    onoff("dragonfly_first", "Dragonfly first, larvae later",
        "While Dragonfly is within 15 of you, Auto Combat leaves lava larvae alone and keeps hitting her. Farther away it clears them as before", true),
    onoff("kite_lantern", "Lantern while kiting in the dark",
        "In the dark, Auto Combat uses your lantern (or a torch if you have no lantern) to dodge and close in, and your weapon to attack. Auto Actions' and Equipment Master's dark light wait while it attacks", true),
    onoff("keep_light_on_stop", "Keep your light when Auto Combat stops",
        "In the dark, turning Auto Combat off leaves your lantern or torch in your hands instead of switching to your weapon", true),
    onoff("hound_spacing", "More room after a hound bite",
        "Hit-and-run starts dodging a hound's bite a little sooner, and both it and auto_dodger keep you out a few frames longer after the bite", true),
    onoff("werepig_kiting", "Kite werepigs",
        "Hit-and-run and auto_dodger treat a werepig's lunge like the Frankenpig's, so you dodge it instead of standing in it", true),
    onoff("spider_dens_last", "Spider dens last",
        "F takes nearby spiders before a den and only hits a den you started on with Ctrl+F. Auto Combat fights spiders first, then the den", true),
    onoff("web_slow", "Dodge knows webbing slows you",
        "On spider webbing, dodging counts on your real (slower) speed and keeps a bit more distance", true),
    onoff("marotter_spacing", "Marotter spacing",
        "A Marotter's quick bite is dodged from its full reach instead of a shrinking circle", true),
    onoff("free_arrow_keys", "Arrow keys only zoom",
        "Turns off hit-and-run's arrow keys (kiting mode, its auto dodge, range) so the arrows only move the camera", true),
    onoff("dodge_follows_combat", "Dodge follows Auto Combat",
        "Auto Dodge is turned on when Auto Combat starts and off when it stops, and stays that way", true),
    {
        name = "explore_key",
        label = "Auto Explore key",
        hover = "Set this to the same key as Auto Explore's own toggle key",
        options = {
            { description = "F1", data = "KEY_F1" },
            { description = "F2", data = "KEY_F2" },
            { description = "G", data = "KEY_G" },
        },
        default = "KEY_F1",
    },
    {
        name = "explore_fight_radius",
        label = "Pause explore near enemies",
        hover = "Pause Auto Explore while a creature this close is targeting you",
        options = {
            { description = "Off", data = 0 },
            { description = "8", data = 8 },
            { description = "12", data = 12 },
            { description = "16", data = 16 },
        },
        default = 12,
    },
    onoff("translate_mods", "English for other mods",
        "Shows other mods' translated text in English even after a Steam update brings the Chinese back. New text from an update stays as it is", true),
    onoff("debug_log", "Debug log", "Print what the helper does to client_log.txt", false),
}
