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

Client only. Every fix has its own switch below.
]]
author = "Claude for Andrew"
version = "0.1.2"
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
    onoff("debug_log", "Debug log", "Print what the helper does to client_log.txt", false),
}
