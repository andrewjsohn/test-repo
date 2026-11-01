name = "Attack Queue (Updated)"
description = [[
An update of Attack Queue (Workshop 2059280386) for the current game.

- Hold the queue key (Shift) and press Attack (F): lock on to the nearest
  enemy and keep attacking it until it dies.
- Hold Ctrl as well (Ctrl + Shift + F): force attack, so neutral creatures
  count too (never your own followers or allies).
- With ActionQueue: Shift + left-drag a box over mobs and they are queued as
  attacks, fought one by one before any other selected object.
- Without ActionQueue: Shift + click mobs to queue them, Shift + double-click
  to queue every mob of that kind nearby, release Shift + click to start.
- When your weapon breaks mid-fight it equips another of the same kind, or
  crafts one if you allow it.
- Moving, pressing Space, or clicking the world without Shift stops it.

Swings go through the game's own predicted attack, so they animate normally
with lag compensation on.
]]
author = "eXiGe (original author), Tony; updated by Claude for Andrew"
version = "2.0.0"
forumthread = ""

icon_atlas = "modicon.xml"
icon = "modicon.tex"

api_version = 10
dst_compatible = true
client_only_mod = true
all_clients_require_mod = false
-- Load after ActionQueue so its component exists when we look for it.
priority = -10

local key_names = {
    {"LShift", "LSHIFT"}, {"RShift", "RSHIFT"}, {"LAlt", "LALT"}, {"RAlt", "RALT"},
    {"LCtrl", "LCTRL"}, {"RCtrl", "RCTRL"}, {"Tab", "TAB"}, {"Capslock", "CAPSLOCK"},
    {"Z", "Z"}, {"X", "X"}, {"C", "C"}, {"G", "G"}, {"H", "H"}, {"J", "J"},
    {"K", "K"}, {"L", "L"}, {"N", "N"}, {"Y", "Y"},
}
local keylist = {}
for i = 1, #key_names do
    keylist[i] = {description = key_names[i][1], data = "KEY_" .. key_names[i][2]}
end

local onoff = {
    {description = "On", data = true},
    {description = "Off", data = false},
}

configuration_options =
{
    {
        name = "key",
        label = "Queue key",
        hover = "Hold this with Attack (F) to lock on, or with clicks to queue targets.\nKeep it the same as ActionQueue's key for box selection.",
        options = keylist,
        default = "KEY_LSHIFT",
    },
    {
        name = "nearest_range",
        label = "Lock-on range",
        hover = "How far Shift + F looks for the nearest target.",
        options = {
            {description = "5", data = 5},
            {description = "10", data = 10},
            {description = "20", data = 20},
            {description = "30", data = 30},
            {description = "40", data = 40},
            {description = "60", data = 60},
        },
        default = 40,
    },
    {
        name = "aq_drag",
        label = "ActionQueue box attacks",
        hover = "ActionQueue's Shift + drag box also selects enemies, and they are fought first.",
        options = onoff,
        default = true,
    },
    {
        name = "own_select",
        label = "Shift + click queue",
        hover = "Queue targets with Shift + click.\nAuto turns this off when ActionQueue is running, since it already handles clicks.",
        options = {
            {description = "Auto", data = "auto"},
            {description = "On", data = "on"},
            {description = "Off", data = "off"},
        },
        default = "auto",
    },
    {
        name = "reequip",
        label = "Re-equip broken weapon",
        hover = "Equip another weapon of the same kind when yours breaks mid-fight.\nAuto turns this off when Auto ReEquip Weapon is enabled.",
        options = {
            {description = "Auto", data = "auto"},
            {description = "On", data = "on"},
            {description = "Off", data = "off"},
        },
        default = "auto",
    },
    {
        name = "craft",
        label = "Craft new weapon",
        hover = "If no spare weapon is found, craft the same weapon when you have the materials.",
        options = onoff,
        default = true,
    },
    {
        name = "debug",
        label = "Debug log",
        hover = "Write [AttackQueue] lines to client_log.txt.",
        options = onoff,
        default = false,
    },
}
