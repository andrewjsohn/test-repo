-- Mod Harmony: glue between Auto Combat, Equipment Master, auto_dodger,
-- Better Lag Compensation, ActionQueue RB3 and Auto Explore.
--
-- Every patch is defensive: it checks that the other mod is loaded and has
-- the function it expects, wraps instead of replacing, and fails quietly
-- (with a debug log line) when something is missing.

local G = GLOBAL

-- A mod's environment only carries a few Lua basics (tonumber is not one of
-- them), so take every builtin used below from the real global table.
local tonumber, tostring, type, ipairs, pairs, print, math, string, table =
    G.tonumber, G.tostring, G.type, G.ipairs, G.pairs, G.print, G.math, G.string, G.table

local CFG = {
    fix_gear_fight = GetModConfigData("fix_gear_fight") ~= false,
    manual_equip_grace = tonumber(GetModConfigData("manual_equip_grace")) or 2,
    fix_dodge_timing = GetModConfigData("fix_dodge_timing") ~= false,
    dodge_ping_scale = tonumber(GetModConfigData("dodge_ping_scale")) or 1,
    dodge_extra_margin = tonumber(GetModConfigData("dodge_extra_margin")) or 0.5,
    fix_queue_freeze = GetModConfigData("fix_queue_freeze") ~= false,
    fix_explore = GetModConfigData("fix_explore") ~= false,
    keep_light = GetModConfigData("keep_light") ~= false,
    walk_only_faster = GetModConfigData("walk_only_faster") ~= false,
    free_arrow_keys = GetModConfigData("free_arrow_keys") ~= false,
    prefer_axe = GetModConfigData("prefer_axe") ~= false,
    dodge_follows_combat = GetModConfigData("dodge_follows_combat") ~= false,
    prefer_lantern = GetModConfigData("prefer_lantern") ~= false,
    keep_tools = GetModConfigData("keep_tools") ~= false,
    kite_lantern = GetModConfigData("kite_lantern") ~= false,
    spider_dens_last = GetModConfigData("spider_dens_last") ~= false,
    web_slow = GetModConfigData("web_slow") ~= false,
    marotter_spacing = GetModConfigData("marotter_spacing") ~= false,
    queue_tools = GetModConfigData("queue_tools") ~= false,
    dragonfly_first = GetModConfigData("dragonfly_first") ~= false,
    explore_key = GetModConfigData("explore_key") or "KEY_F1",
    explore_fight_radius = tonumber(GetModConfigData("explore_fight_radius")) or 12,
    debug_log = GetModConfigData("debug_log") == true,
}

local OWNER = "mod_harmony"
local AUTO_EXPLORE_ID = "3826759911"
local AUTO_ACTIONS_ID = "651419070"
local MAX_DODGE_PAD = 3
local DEFAULT_PING_MS = 150
local BASE_SPEED = 6

local function Log(...)
    if CFG.debug_log then
        print("[mod_harmony]", ...)
    end
end

local function SafeCall(what, fn, ...)
    local ok, a, b = G.pcall(fn, ...)
    if not ok then
        print("[mod_harmony] error in " .. what .. ":", a)
        return nil
    end
    return a, b
end

local function Player()
    return G.rawget(G, "ThePlayer")
end

-- Round-trip ping in seconds. Reuses Better Lag Compensation's reader when it
-- is loaded, otherwise asks TheNet the same way it does.
local function PingSeconds()
    local util = G.package.loaded["blc/util"]
    if util ~= nil and type(util.Ping) == "function" then
        local ms = SafeCall("blc ping", util.Ping)
        if type(ms) == "number" then
            return ms / 1000
        end
    end
    local net = G.rawget(G, "TheNet")
    if net == nil then
        return DEFAULT_PING_MS / 1000
    end
    local ok, host = G.pcall(function() return net:GetIsServer() end)
    if ok and host then
        return 0
    end
    for _, name in ipairs({ "GetAveragePing", "GetPing" }) do
        local ok2, v = G.pcall(function() return net[name](net) end)
        if ok2 and type(v) == "number" and v >= 0 then
            return v / 1000
        end
    end
    return DEFAULT_PING_MS / 1000
end

------------------------------------------------------------------------------
-- 1. Auto Combat vs Equipment Master: the gear tug-of-war
--
-- Auto Combat's brain asks for "keep" when it has no target and you already
-- hold a speed item. Equip:Request("keep") returns early, so the previous
-- "fight" request stays in force and Equip:Update keeps re-equipping the
-- weapon a tenth of a second after Equipment Master (or you) swapped it.
-- Here "keep" really means keep: the old request is dropped.
------------------------------------------------------------------------------
local gear_patched = false
local function PatchAutoCombatEquip()
    if gear_patched or not CFG.fix_gear_fight then return end
    local ac = G.rawget(G, "AutoCombat")
    local Equip = ac ~= nil and ac.Equip or nil
    if Equip == nil or type(Equip.Request) ~= "function" then return end
    gear_patched = true

    local old_request = Equip.Request
    Equip.Request = function(self, want, ...)
        if want == "keep" and self.want ~= nil then
            Log("Auto Combat: keep, dropping old request", tostring(self.want))
            self.want = nil
            self.confirmed = nil
            self.empty_confirmed = nil
            self.pending_hands = nil
            self.tries = 0
        end
        return old_request(self, want, ...)
    end
    Log("patched Auto Combat Equip.Request")
end

-- A hands item you equip yourself (right-click in the inventory) is left alone
-- for a short grace period.
local function OnManualHandsEquip()
    if CFG.manual_equip_grace <= 0 then return end
    local ac = G.rawget(G, "AutoCombat")
    local Equip = ac ~= nil and ac.Equip or nil
    if Equip == nil or type(Equip.Override) ~= "function" then return end
    if ac.state == nil or not ac.state.running then return end
    Equip:Override("keep", CFG.manual_equip_grace, G.GetTime())
    if type(Equip.Request) == "function" then
        Equip:Request("keep", nil, G.GetTime())
    end
    Log("manual equip: Auto Combat keeps hands for", CFG.manual_equip_grace, "s")
end

------------------------------------------------------------------------------
-- 2. auto_dodger: ping-aware danger circles
--
-- auto_dodger shrinks an attack's danger circle during the wind-up by how far
-- you could run before it lands, with no allowance for ping, and parks you
-- 0.1 past the edge. We grow each creature danger by (ping x run speed) plus
-- a small margin through its filter_danger hook. Auto Combat also uses that
-- hook (one owner per name), so SetHook/RemoveHook are wrapped and both run.
------------------------------------------------------------------------------
local dodge_patched = false
local inner_filter, inner_owner = nil, nil

-- Spider webbing (ground creep) slows you to 60% unless you are Webber.
-- auto_dodger works out how far you can run from your gear alone, so on
-- webbing it thought you were faster than you are.
local WEB_SLOW = 0.6
local WEB_EXTRA_MARGIN = 0.5
local function OnWeb(player)
    if player == nil or player.Transform == nil or player:HasTag("spiderwhisperer") then return false end
    local world = G.rawget(G, "TheWorld")
    local creep = world ~= nil and world.GroundCreep or nil
    if creep == nil or type(creep.OnCreep) ~= "function" then return false end
    local x, y, z = player.Transform:GetWorldPosition()
    local ok, on = G.pcall(creep.OnCreep, creep, x, 0, z)
    return ok and on == true
end

-- Quick bites (a Marotter's lands half a second after it starts) leave no
-- time to run out of a circle that auto_dodger has already shrunk, so their
-- danger circle stays at the bite's full reach for the whole wind-up.
local FULL_REACH_BITES = { otter = true }
local function FullReach(ent)
    local combat = ent.replica ~= nil and ent.replica.combat or nil
    local range = combat ~= nil and combat:GetAttackRangeWithWeapon() or nil
    if type(range) ~= "number" or range <= 0 then return nil end
    local player = Player()
    local body = player ~= nil and type(player.GetPhysicsRadius) == "function" and player:GetPhysicsRadius(0) or 0.5
    return range + body + 0.5
end

local function PadDanger(posdata)
    if posdata == nil or posdata.zone ~= nil or posdata.ent == nil then
        return -- only creature attacks; strategy zones keep their own shapes
    end
    -- Only pad an attack that is actually winding up. The "standing too close"
    -- circles stay as they are, or padding them could stop melee entirely.
    local source = posdata.source
    local anim = source ~= nil and source.atkanim or nil
    local ent_anim = posdata.ent.AnimState
    if type(anim) ~= "string" or ent_anim == nil or not ent_anim:IsCurrentAnimation(anim) then
        return
    end
    local radius = posdata.radius
    if type(radius) ~= "number" or radius <= 0 then return end
    if CFG.marotter_spacing and FULL_REACH_BITES[posdata.ent.prefab] then
        local reach = FullReach(posdata.ent)
        if reach ~= nil and reach > radius then radius = reach end
    end
    local speed_fn = G.rawget(G, "AutoDodger_GetSpeed")
    local speed = speed_fn ~= nil and SafeCall("dodger speed", speed_fn) or BASE_SPEED
    if type(speed) ~= "number" or speed <= 0 then speed = BASE_SPEED end
    local pad = PingSeconds() * CFG.dodge_ping_scale * speed + CFG.dodge_extra_margin
    if CFG.web_slow and OnWeb(Player()) then pad = pad + WEB_EXTRA_MARGIN end
    if pad > MAX_DODGE_PAD then pad = MAX_DODGE_PAD end
    if pad < 0 then pad = 0 end
    posdata.radius = radius + pad
end

local function CompositeFilter(posdata)
    if inner_filter ~= nil then
        local ok, r = G.pcall(inner_filter, posdata)
        if not ok then
            print("[mod_harmony] filter_danger hook error:", r)
        elseif r == true then
            return true -- the other mod says ignore this danger
        end
    end
    PadDanger(posdata)
    return nil
end

local function PatchAutoDodger()
    if dodge_patched or not CFG.fix_dodge_timing then return end
    local set = G.rawget(G, "AutoDodger_SetHook")
    local remove = G.rawget(G, "AutoDodger_RemoveHook")
    if type(set) ~= "function" or type(remove) ~= "function" then return end
    dodge_patched = true

    G.rawset(G, "AutoDodger_SetHook", function(name, fn, owner)
        if name == "filter_danger" and fn ~= CompositeFilter then
            if type(fn) ~= "function" then return false end
            inner_filter, inner_owner = fn, owner
            return set("filter_danger", CompositeFilter, OWNER)
        end
        return set(name, fn, owner)
    end)

    G.rawset(G, "AutoDodger_RemoveHook", function(name, owner)
        if name == "filter_danger" then
            if owner == nil or owner == inner_owner then
                inner_filter, inner_owner = nil, nil
            end
            set("filter_danger", CompositeFilter, OWNER) -- keep the padding
            return true
        end
        return remove(name, owner)
    end)

    set("filter_danger", CompositeFilter, OWNER)
    Log("patched auto_dodger hooks")
end

-- auto_dodger's run speed (it also feeds Auto Combat's boss scripts) counts
-- the webbing under you.
local web_patched = false
local function PatchWebSpeed()
    if web_patched or not CFG.web_slow then return end
    local fn = G.rawget(G, "AutoDodger_GetSpeed")
    local dbg = G.rawget(G, "debug")
    if type(fn) ~= "function" or dbg == nil or type(dbg.getupvalue) ~= "function" then return end
    local dodger = nil
    for i = 1, 20 do
        local name, v = dbg.getupvalue(fn, i)
        if name == nil then break end
        if type(v) == "table" and type(G.rawget(v, "GetSpeed")) == "function" then
            dodger = v
            break
        end
    end
    if dodger == nil then return end
    web_patched = true
    local old = dodger.GetSpeed
    dodger.GetSpeed = function(self, ...)
        local speed = old(self, ...)
        if type(speed) == "number" and OnWeb(Player()) then
            return speed * WEB_SLOW
        end
        return speed
    end
    Log("patched auto_dodger speed (webbing slows you)")
end

------------------------------------------------------------------------------
-- 3. ActionQueue vs Better Lag Compensation: frozen swing
--
-- BLC's swing prediction only keeps going while the action key is held.
-- ActionQueue never holds a key, so the prediction runs past the end and pins
-- the last frame. Switch prediction off while ActionQueue's thread runs.
------------------------------------------------------------------------------
local we_disabled_future = false

local function QueueBusy(player)
    local aq = player ~= nil and player.components ~= nil and player.components.actionqueuer or nil
    return aq ~= nil and aq.action_thread ~= nil
end

local function UpdateQueueFreeze(player)
    if not CFG.fix_queue_freeze then return end
    local future = G.package.loaded["blc/future"]
    if type(future) ~= "table" then return end
    if QueueBusy(player) then
        if future.enabled then
            future.enabled = false
            we_disabled_future = true
            Log("ActionQueue working: BLC swing prediction off")
        end
    elseif we_disabled_future then
        future.enabled = true
        we_disabled_future = false
        Log("ActionQueue done: BLC swing prediction back on")
    end
end

------------------------------------------------------------------------------
-- 4. Auto Explore: instant stop, walking animation, pause during fights
--
-- Auto Explore sends raw WALKTO clicks straight to the server. That skips the
-- client's movement prediction (so you glide with a frozen pose), its stop
-- never reaches the server, and nothing stops it in a fight. We intercept
-- only the clicks that come from Auto Explore's own file.
------------------------------------------------------------------------------
local explore_paused = false
local EXPLORE_ACTIVE_WINDOW = 2.5 -- its loop tries a step at least every ~1.7 s
-- Times of Auto Explore's latest step attempt, and the one before it in an
-- earlier frame. Steps we pause still count: they show it is switched on.
local last_attempt_time = -math.huge
local prev_attempt_time = -math.huge

local function CalledFromAutoExplore()
    local dbg = G.rawget(G, "debug")
    if dbg == nil or dbg.getinfo == nil then return false end
    for level = 3, 6 do
        local info = dbg.getinfo(level, "S")
        if info == nil then break end
        local src = info.source
        if type(src) == "string" and src:find(AUTO_EXPLORE_ID, 1, true) then
            return true
        end
    end
    return false
end

local function OtherModMoving(player)
    local dodging = G.rawget(G, "AutoDodger_IsDodging")
    if dodging ~= nil and SafeCall("dodging", dodging) then return true end
    -- Hit-and-run's thread runs the whole time it is switched on, so only
    -- count it while it actually has a target.
    local har = G.rawget(G, "HitAndRun")
    local har_ent = type(har) == "table" and G.rawget(har, "ent") or nil
    if har_ent ~= nil and har_ent.IsValid ~= nil and har_ent:IsValid() then return true end
    if QueueBusy(player) then return true end
    return false
end

local function EnemyEngaged(player)
    local r = CFG.explore_fight_radius
    if r <= 0 then return false end
    local x, y, z = player.Transform:GetWorldPosition()
    -- Your own combat target can linger after a fight, so it only counts
    -- while it is alive and close.
    local combat = player.replica ~= nil and player.replica.combat or nil
    local target = combat ~= nil and combat:GetTarget() or nil
    if target ~= nil and target:IsValid() and not target:HasTag("isdead")
        and target:GetDistanceSqToPoint(x, y, z) <= r * r then
        return true
    end
    local ents = G.TheSim:FindEntities(x, y, z, r, { "_combat" }, { "INLIMBO", "player", "playerghost" })
    for _, ent in ipairs(ents) do
        local c = ent.replica ~= nil and ent.replica.combat or nil
        if c ~= nil and not ent:HasTag("isdead") and c:GetTarget() == player then
            return true
        end
    end
    return false
end

-- Returns pause, stop_first. Another mod already steering you needs no stop
-- from us; with nobody steering, the current explore walk is cut short.
local function ExploreShouldPause(player)
    if OtherModMoving(player) then return true, false end
    if EnemyEngaged(player) then
        local ac = G.rawget(G, "AutoCombat")
        local steering = ac ~= nil and ac.state ~= nil and ac.state.running
        return true, not steering
    end
    return false, false
end

local orig_send = nil

local function StopWalkingNow()
    local player = Player()
    if player == nil or orig_send == nil then return end
    local pc = player.components.playercontroller
    if pc ~= nil and pc.locomotor ~= nil then
        SafeCall("locomotor stop", function() pc.locomotor:Stop() end)
        SafeCall("locomotor clear", function() pc.locomotor:Clear() end)
    end
    -- A walk to where you already stand ends the server's current walk.
    local x, _, z = player.Transform:GetWorldPosition()
    orig_send(G.RPC.LeftClick, G.ACTIONS.WALKTO.code, x, z)
    Log("sent stop")
end

-- Show the walk on screen the way a normal click does, before the server
-- moves you, so you get a walking animation instead of a glide.
local function PreviewWalk(x, z, platform)
    local player = Player()
    if player == nil or platform ~= nil then return end
    if G.TheWorld ~= nil and G.TheWorld.ismastersim then return end
    local pc = player.components.playercontroller
    if pc == nil or pc.locomotor == nil then return end
    SafeCall("preview walk", function()
        local act = G.BufferedAction(player, nil, G.ACTIONS.WALKTO, nil, G.Vector3(x, 0, z))
        pc.locomotor:PreviewAction(act, true)
    end)
end

------------------------------------------------------------------------------
-- 5. Keep your light in the dark
--
-- Equipment Master swaps in its "walk" item (any hands item, when nothing is
-- actually faster) every time you start walking, and only re-equips a light
-- after you have already been in the dark. In caves or at night that drops
-- your lantern for something like a marbell. A walking swap that would take
-- off your only light while it is dark is skipped.
------------------------------------------------------------------------------
local walk_swap_depth = 0
local fight_swap_depth = 0
local LIGHT_TAGS = nil

local function IsLightItem(item)
    if item == nil or not item:IsValid() then return false end
    if LIGHT_TAGS == nil then
        LIGHT_TAGS = { "light", "lighter", "fire" }
        local fuel = G.rawget(G, "FUELTYPE")
        if type(fuel) == "table" then
            if fuel.CAVE ~= nil then LIGHT_TAGS[#LIGHT_TAGS + 1] = fuel.CAVE .. "_fueled" end
            if fuel.WORMLIGHT ~= nil then LIGHT_TAGS[#LIGHT_TAGS + 1] = fuel.WORMLIGHT .. "_fueled" end
        end
    end
    return item:HasOneOfTags(LIGHT_TAGS)
end

local function IsDarkHere(player)
    local world = G.TheWorld
    if world == nil then return false end
    if world:HasTag("cave") then return true end
    local state = world.state
    return state ~= nil and state.isnight and not state.isfullmoon
end

local function WouldLoseLight(item)
    local player = Player()
    if player == nil or item == nil or type(item) ~= "table" or item.replica == nil then return false end
    local equippable = item.replica.equippable
    local inventory = player.replica ~= nil and player.replica.inventory or nil
    if equippable == nil or inventory == nil then return false end
    local slot = equippable:EquipSlot()
    local current = inventory:GetEquippedItem(slot)
    if current == nil or current == item or not IsLightItem(current) or IsLightItem(item) then
        return false
    end
    for _, other_slot in pairs(G.EQUIPSLOTS) do
        if other_slot ~= slot and IsLightItem(inventory:GetEquippedItem(other_slot)) then
            return false -- another light (a miner hat, say) still covers you
        end
    end
    return IsDarkHere(player)
end

------------------------------------------------------------------------------
-- 6. Walking swaps only when they make you faster
--
-- With nothing faster than what you hold (no cane), Equipment Master's walk
-- pick is any hands item, so walking trades your weapon for, say, a marbell.
-- Auto Combat in Event or Auto gear mode asks for walking gear between swings
-- (holding at Dragonfly's edge, stepping out of a swipe), so every opening
-- starts with the weapon in your pack and Auto Combat waits for it to come
-- back before it swings. A walking swap of the hands item is skipped unless
-- the new item is actually faster. Lights are left to the rule above.
------------------------------------------------------------------------------
local function WalkMult(item)
    local ii = item ~= nil and item.replica ~= nil and item.replica.inventoryitem or nil
    if ii == nil or type(ii.GetWalkSpeedMult) ~= "function" then return 1 end
    local m = ii:GetWalkSpeedMult()
    return type(m) == "number" and m or 1
end

local function IsSlowerWalkSwap(item)
    local player = Player()
    if player == nil or item == nil or type(item) ~= "table" or item.replica == nil then return false end
    local equippable = item.replica.equippable
    local inventory = player.replica ~= nil and player.replica.inventory or nil
    if equippable == nil or inventory == nil or equippable:EquipSlot() ~= G.EQUIPSLOTS.HANDS then return false end
    local current = inventory:GetEquippedItem(G.EQUIPSLOTS.HANDS)
    if current == item then return false end
    if IsLightItem(item) and not IsLightItem(current) then return false end -- a light coming in
    return WalkMult(item) <= WalkMult(current) + 0.001
end

local skip_log_time = {}
local function LogSkip(item)
    local key = tostring(item and item.prefab)
    local now = G.GetTime()
    if skip_log_time[key] == nil or now - skip_log_time[key] > 10 then
        skip_log_time[key] = now
        Log("walk swap skipped, not faster:", key)
    end
end

local function WithWalkSwap(fn, ...)
    walk_swap_depth = walk_swap_depth + 1
    local ok, a, b, c = G.pcall(fn, ...)
    walk_swap_depth = walk_swap_depth - 1
    if not ok then G.error(a, 0) end
    return a, b, c
end

local function GuardWalkSwaps(pc)
    if not (CFG.keep_light or CFG.walk_only_faster) or pc._mod_harmony_light then return end
    pc._mod_harmony_light = true
    for _, name in ipairs({ "RemoteDirectWalking", "RemotePredictWalking" }) do
        local old = pc[name]
        if type(old) == "function" then
            pc[name] = function(...) return WithWalkSwap(old, ...) end
        end
    end
end

local function WithFightSwap(fn, ...)
    fight_swap_depth = fight_swap_depth + 1
    local ok, a, b, c = G.pcall(fn, ...)
    fight_swap_depth = fight_swap_depth - 1
    if not ok then G.error(a, 0) end
    return a, b, c
end

-- Auto Combat (event mode) and hit-and-run ask Equipment Master for walking
-- or fighting gear through an EquipItem event of type "walk" or "fight".
local function GuardWalkEvents(player)
    if not (CFG.keep_light or CFG.walk_only_faster or CFG.prefer_axe or CFG.prefer_lantern)
        or player._mod_harmony_light then return end
    player._mod_harmony_light = true
    local push = player.PushEvent
    player.PushEvent = function(inst, event, data, ...)
        if event == "EquipItem" and type(data) == "table" and type(data.type) == "string" then
            if data.type:find("walk", 1, true) then
                return WithWalkSwap(push, inst, event, data, ...)
            elseif data.type:find("fight", 1, true) then
                return WithFightSwap(push, inst, event, data, ...)
            end
        end
        return push(inst, event, data, ...)
    end
end

------------------------------------------------------------------------------
-- 7. The axe before the pickaxe
--
-- A pickaxe and an axe hit equally hard, and Auto Combat and Equipment
-- Master both keep the first of equal weapons they find, which is often the
-- pickaxe. When either of them picks a pickaxe for a fight and you carry an
-- axe that hits at least as hard, the axe is used instead. A pick/axe counts
-- as neither, and a pickaxe you equip yourself is left alone.
------------------------------------------------------------------------------
local function EachOwnedItem(fn)
    local player = Player()
    local inv = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    if inv == nil then return end
    for _, item in pairs(inv:GetEquips() or {}) do fn(item) end
    for _, item in pairs(inv:GetItems() or {}) do fn(item) end
    local bag = inv.GetOverflowContainer ~= nil and inv:GetOverflowContainer() or nil
    if bag ~= nil then
        for _, item in pairs(bag:GetItems() or {}) do fn(item) end
    end
end

local damage_cache = {}
local function ItemDamage(item)
    local key = item.prefab
    if damage_cache[key] ~= nil then
        return damage_cache[key] or nil
    end
    local d = nil
    local util = G.rawget(G, "CMP_util")
    local fov = G.rawget(G, "FunctionOrValue")
    if type(util) == "table" and type(util.GetCMP) == "function" and type(fov) == "function" then
        local ok, weapon = G.pcall(util.GetCMP, util, key, "weapon")
        if ok and type(weapon) == "table" then
            local ok2, v = G.pcall(fov, weapon.damage, weapon.inst)
            if ok2 then d = tonumber(v) end
        end
    end
    damage_cache[key] = d or false
    return d
end

local function IsHandsItem(item)
    local eq = item.replica ~= nil and item.replica.equippable or nil
    return eq ~= nil and eq:EquipSlot() == G.EQUIPSLOTS.HANDS
end

local function IsPickOnly(item)
    return item:HasTag("MINE_tool") and not item:HasTag("CHOP_tool")
end

local function IsAxeOnly(item)
    return item:HasTag("CHOP_tool") and not item:HasTag("MINE_tool")
end

-- The hardest-hitting axe you carry that hits at least as hard as this
-- pickaxe, or nil when the item isn't a pickaxe or you carry no such axe.
local function AxeInsteadOf(pick)
    if not CFG.prefer_axe or type(pick) ~= "table" or type(pick.HasTag) ~= "function"
        or not pick:IsValid() or not IsPickOnly(pick) then
        return nil
    end
    local pick_d = ItemDamage(pick)
    local best, best_d = nil, nil
    EachOwnedItem(function(item)
        if item ~= pick and item:IsValid() and IsHandsItem(item) and IsAxeOnly(item)
            and item:HasTag("weapon") and not item:HasTag("broken") then
            local d = ItemDamage(item)
            if pick_d == nil or d == nil or d >= pick_d - 0.001 then
                local score = d or 0
                if best == nil or score > best_d then
                    best, best_d = item, score
                end
            end
        end
    end)
    return best
end

local axe_log_time = -math.huge
local function LogAxe(pick, axe, who)
    local now = G.GetTime()
    if now - axe_log_time > 10 then
        axe_log_time = now
        Log(who .. ": " .. tostring(axe.prefab) .. " instead of " .. tostring(pick.prefab))
    end
end

local axe_patched = false
local function PatchAutoCombatAxe()
    if axe_patched or not CFG.prefer_axe then return end
    local ac = G.rawget(G, "AutoCombat")
    local Equip = ac ~= nil and ac.Equip or nil
    if Equip == nil or type(Equip.FindWeapon) ~= "function" then return end
    axe_patched = true

    local old_find = Equip.FindWeapon
    Equip.FindWeapon = function(...)
        local weapon = old_find(...)
        local ok, axe = G.pcall(AxeInsteadOf, weapon)
        if ok and axe ~= nil then
            LogAxe(weapon, axe, "Auto Combat")
            return axe
        end
        return weapon
    end

    -- A pickaxe already in hand counts as a weapon, so Auto Combat would keep
    -- it. While it wants to fight and an axe is there, it isn't good enough.
    local old_satisfied = Equip.Satisfied
    if type(old_satisfied) == "function" then
        Equip.Satisfied = function(self, want, ...)
            if (want or self.want) == "fight" and type(Equip.Hands) == "function" then
                local ok, axe = G.pcall(function() return AxeInsteadOf(Equip.Hands()) end)
                if ok and axe ~= nil then
                    return false
                end
            end
            return old_satisfied(self, want, ...)
        end
    end
    Log("patched Auto Combat weapon pick (axe before pickaxe)")
end

-- Equipment Master equips its fight pick inside GetAttackTarget or an
-- EquipItem "fight" event; the RPC wrapper below swaps a pickaxe for the axe.
local function GuardFightSwaps(pc)
    if not (CFG.prefer_axe or CFG.prefer_lantern) or pc._mod_harmony_fight then return end
    pc._mod_harmony_fight = true
    local old = pc.GetAttackTarget
    if type(old) == "function" then
        pc.GetAttackTarget = function(...) return WithFightSwap(old, ...) end
    end
end

------------------------------------------------------------------------------
-- 7b. The lantern before the torch
--
-- Equipment Master's night light (and Auto Actions' light in the dark) takes
-- the first light it finds, often a torch. In the dark, when a helper equips a
-- torch outside a fight and you carry a lantern with fuel, the lantern goes in
-- your hands instead. A torch you equip yourself, or one used to set something
-- on fire in a fight, is left alone.
------------------------------------------------------------------------------
local function IsFueledLantern(item)
    return item:IsValid() and IsHandsItem(item) and item:HasTag("light") and not item:HasTag("lighter")
        and not item:HasTag("fueldepleted") and not item:HasTag("broken")
end

local function LanternInsteadOf(torch)
    if not CFG.prefer_lantern or fight_swap_depth > 0 or type(torch) ~= "table"
        or type(torch.HasTag) ~= "function" or not torch:IsValid() or not torch:HasTag("torch") then
        return nil
    end
    local player = Player()
    if player == nil or not IsDarkHere(player) then return nil end
    local best = nil
    EachOwnedItem(function(item)
        if item ~= torch and IsFueledLantern(item) and (best == nil or item.prefab == "lantern") then
            best = item
        end
    end)
    return best
end

local lantern_log_time = -math.huge
local function LanternForRPC(item)
    local ok, lantern = G.pcall(LanternInsteadOf, item)
    if not ok or lantern == nil then return nil end
    local now = G.GetTime()
    if now - lantern_log_time > 10 then
        lantern_log_time = now
        Log(tostring(lantern.prefab) .. " instead of " .. tostring(item.prefab))
    end
    return lantern
end

------------------------------------------------------------------------------
-- 7c. A tool you equip to work stays in hand
--
-- With nothing to fight, Auto Combat asks for your weapon every frame, and a
-- pickaxe isn't good enough for it while an axe hits as hard (7, above). So a
-- pickaxe that Auto Actions equips for a Shift+click went straight back to
-- the weapon before the first swing. While Auto Combat runs with no enemy on
-- you, a tool equipped by anything but Auto Combat stays in hand as long as
-- you keep working with it.
------------------------------------------------------------------------------
local TOOL_TAGS = { "MINE_tool", "CHOP_tool", "DIG_tool", "HAMMER_tool", "NET_tool" }
local WORK_ACTIONS = { "MINE", "CHOP", "DIG", "HAMMER", "NET" }
local TOOL_WORK_WINDOW = 4 -- seconds a held tool waits for the next swing
local ac_equip_depth = 0
local tool_hold = nil
local work_codes = nil

local function IsToolItem(item)
    return type(item) == "table" and type(item.HasOneOfTags) == "function" and item:IsValid()
        and item:HasOneOfTags(TOOL_TAGS)
end

local function IsWorkCode(code)
    if work_codes == nil then
        work_codes = {}
        for _, name in ipairs(WORK_ACTIONS) do
            local act = G.ACTIONS[name]
            if type(act) == "table" and act.code ~= nil then work_codes[act.code] = true end
        end
    end
    return code ~= nil and work_codes[code] == true
end

-- Auto Combat's gear module, only while Auto Combat runs.
local function RunningCombatEquip()
    local ac = G.rawget(G, "AutoCombat")
    if type(ac) ~= "table" or type(ac.state) ~= "table" or not ac.state.running then return nil end
    local Equip = ac.Equip
    if type(Equip) ~= "table" or type(Equip.Override) ~= "function" then return nil end
    return Equip
end

local function HandsItem(player)
    local inv = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    return inv ~= nil and inv:GetEquippedItem(G.EQUIPSLOTS.HANDS) or nil
end

-- Ask Auto Combat to keep your hands as they are for a moment, without
-- cutting short a longer "keep" that is already running.
local function KeepHands(Equip, seconds, now)
    local o = Equip.override
    if type(o) == "table" and o.want == "keep" and type(o.until_time) == "number"
        and o.until_time >= now + seconds then
        return
    end
    Equip:Override("keep", seconds, now)
end

local function StartToolHold(item)
    if not CFG.keep_tools or not IsToolItem(item) then return end
    local Equip = RunningCombatEquip()
    local player = Player()
    if Equip == nil or player == nil or EnemyEngaged(player) then return end
    local now = G.GetTime()
    local fresh = tool_hold == nil or tool_hold.item ~= item
    tool_hold = { item = item, equip_time = now, until_time = now + TOOL_WORK_WINDOW }
    KeepHands(Equip, 0.5, now)
    if type(Equip.Request) == "function" then
        Equip:Request("keep", nil, now)
    end
    if fresh then
        Log("tool in hand: Auto Combat leaves", tostring(item.prefab), "alone while you work")
    end
end

local function NoteWork()
    if tool_hold ~= nil then
        tool_hold.until_time = math.max(tool_hold.until_time, G.GetTime() + TOOL_WORK_WINDOW)
    end
end

local function UpdateToolHold(player)
    local hold = tool_hold
    if hold == nil then return end
    local now = G.GetTime()
    local Equip = RunningCombatEquip()
    local reason = nil
    if Equip == nil then
        reason = "Auto Combat off"
    elseif not hold.item:IsValid() then
        reason = "tool gone"
    elseif EnemyEngaged(player) then
        reason = "enemy"
    elseif HandsItem(player) ~= hold.item and now - hold.equip_time > 1 then
        reason = "tool put away"
    else
        if QueueBusy(player) then
            hold.until_time = math.max(hold.until_time, now + TOOL_WORK_WINDOW)
        end
        if now > hold.until_time then reason = "done working" end
    end
    if reason ~= nil then
        tool_hold = nil
        Log("tool hold over: " .. reason)
        return
    end
    KeepHands(Equip, 0.5, now)
end

------------------------------------------------------------------------------
-- 7d. Lantern while kiting, weapon while attacking
--
-- In the dark, Auto Combat's walking item (for dodging and closing in) is
-- your lantern, so it trades weapon and lantern with every attack and every
-- dodge. While Auto Combat is attacking something, the light that Auto
-- Actions or Equipment Master equips because it got dark waits, so neither
-- pulls the lantern back in mid-swing.
------------------------------------------------------------------------------
local function KiteLantern(player)
    if not CFG.kite_lantern or player == nil or not IsDarkHere(player) then return nil end
    local held = HandsItem(player)
    if held ~= nil and IsFueledLantern(held) then return held end
    local best = nil
    EachOwnedItem(function(item)
        if IsFueledLantern(item) and (best == nil or item.prefab == "lantern") then
            best = item
        end
    end)
    return best
end

local FIGHT_RANGE = 20

local function NearbyAlive(ent, player)
    if type(ent) ~= "table" or type(ent.IsValid) ~= "function" or not ent:IsValid()
        or ent:HasTag("isdead") or ent:HasTag("INLIMBO") then
        return false
    end
    local x, y, z = player.Transform:GetWorldPosition()
    return type(ent.GetDistanceSqToPoint) ~= "function"
        or ent:GetDistanceSqToPoint(x, y, z) <= FIGHT_RANGE * FIGHT_RANGE
end

-- Auto Combat is on and has something to fight.
local function AutoCombatFighting(player)
    local ac = G.rawget(G, "AutoCombat")
    if player == nil or type(ac) ~= "table" or type(ac.state) ~= "table" or not ac.state.running then
        return false
    end
    local har = type(ac.Bridge) == "table" and ac.Bridge.hitandrun or nil
    if type(har) == "table" and type(har.GetTarget) == "function" then
        local ok, t = G.pcall(har.GetTarget)
        if ok and NearbyAlive(t, player) then return true end
    end
    local ctx = ac.state.ctx
    if type(ctx) == "table" and NearbyAlive(ctx.target, player) then return true end
    return EnemyEngaged(player)
end

local function CalledFromMod(id)
    local dbg = G.rawget(G, "debug")
    if dbg == nil or dbg.getinfo == nil then return false end
    for level = 3, 14 do
        local info = dbg.getinfo(level, "S")
        if info == nil then break end
        local src = info.source
        if type(src) == "string" and src:find(id, 1, true) then
            return true
        end
    end
    return false
end

-- A light that a helper equips because it got dark, while Auto Combat
-- attacks. Auto Combat's own swaps and walking or fighting swaps don't count.
local function IsHelperLightInFight(item)
    if not CFG.kite_lantern or ac_equip_depth > 0 or walk_swap_depth > 0 or fight_swap_depth > 0 then
        return false
    end
    if type(item) ~= "table" or type(item.HasOneOfTags) ~= "function" or not IsLightItem(item) then
        return false
    end
    local player = Player()
    return player ~= nil and HandsItem(player) ~= item and AutoCombatFighting(player)
end

local held_light_log_time = -math.huge
local function LogHeldLight(item, who)
    local now = G.GetTime()
    if now - held_light_log_time > 5 then
        held_light_log_time = now
        Log("light waits while Auto Combat attacks:", who, tostring(item and item.prefab))
    end
end

-- Equipment Master's walking swap during a fight in the dark: the lantern,
-- not its walking pick.
local kite_log_time = -math.huge
local function KiteLanternForRPC(item)
    if not CFG.kite_lantern or walk_swap_depth <= 0 or RunningCombatEquip() == nil then return nil end
    if type(item) ~= "table" or type(item.HasOneOfTags) ~= "function" or not item:IsValid()
        or not IsHandsItem(item) or IsLightItem(item) then
        return nil
    end
    local lantern = KiteLantern(Player())
    if lantern == nil or lantern == item then return nil end
    local now = G.GetTime()
    if now - kite_log_time > 10 then
        kite_log_time = now
        Log("kiting in the dark: " .. tostring(lantern.prefab) .. " instead of " .. tostring(item.prefab))
    end
    return lantern
end

local own_equip_patched = false
local function PatchAutoCombatOwnEquips()
    if own_equip_patched or not (CFG.keep_tools or CFG.kite_lantern) then return end
    local ac = G.rawget(G, "AutoCombat")
    local Equip = ac ~= nil and ac.Equip or nil
    if Equip == nil or type(Equip.EquipNow) ~= "function" then return end
    own_equip_patched = true

    -- Remember which equips are Auto Combat's own.
    local old_now = Equip.EquipNow
    Equip.EquipNow = function(...)
        ac_equip_depth = ac_equip_depth + 1
        local ok, a = G.pcall(old_now, ...)
        ac_equip_depth = ac_equip_depth - 1
        if not ok then G.error(a, 0) end
        return a
    end

    if CFG.kite_lantern and type(Equip.FindWalkItem) == "function" and type(Equip.IsWalkItem) == "function" then
        local old_find, old_is = Equip.FindWalkItem, Equip.IsWalkItem
        Equip.FindWalkItem = function(...)
            local ok, lantern = G.pcall(KiteLantern, Player())
            if ok and lantern ~= nil then return lantern end
            return old_find(...)
        end
        -- In the dark only the lantern counts as walking gear, so Auto
        -- Combat also leaves it in your hands when it has nothing to fight.
        Equip.IsWalkItem = function(item, ...)
            local ok, lantern = G.pcall(KiteLantern, Player())
            if ok and lantern ~= nil then return item ~= nil and item == lantern end
            return old_is(item, ...)
        end
        Log("patched Auto Combat walking gear (lantern while kiting in the dark)")
    end
end

local function AxeForFightRPC(item)
    if fight_swap_depth <= 0 then return nil end
    local ok, axe = G.pcall(AxeInsteadOf, item)
    if not ok or axe == nil then return nil end
    LogAxe(item, axe, "Equipment Master")
    return axe
end

local TraceRPC -- 7g, below
local send_patched = false
local function PatchSendRPC()
    if send_patched or not (CFG.fix_explore or CFG.keep_light or CFG.walk_only_faster or CFG.prefer_axe
        or CFG.prefer_lantern or CFG.keep_tools or CFG.kite_lantern) then return end
    orig_send = G.rawget(G, "SendRPCToServer")
    if type(orig_send) ~= "function" then return end
    send_patched = true

    G.rawset(G, "SendRPCToServer", function(code, action, x, z, target, isreleased, controlmods,
                                            noforce, mod_name, platform, ...)
        local self_equip = code == G.RPC.ControllerUseItemOnSelfFromInvTile and action == G.ACTIONS.EQUIP.code
        if CFG.debug_log then SafeCall("trace", TraceRPC, code, action, x) end
        if CFG.keep_tools then
            if self_equip and ac_equip_depth == 0 and walk_swap_depth == 0 and fight_swap_depth == 0 then
                SafeCall("tool hold", StartToolHold, x) -- Auto Actions' Shift+click equip
            elseif tool_hold ~= nil and code ~= G.RPC.ControllerUseItemOnSelfFromInvTile
                and (code == G.RPC.LeftClick or code == G.RPC.RightClick or code == G.RPC.ActionButton
                    or code == G.RPC.ControllerActionButton) and IsWorkCode(action) then
                NoteWork()
            end
        end
        if fight_swap_depth > 0 and code == G.RPC.ControllerUseItemOnSelfFromInvTile
            and action == G.ACTIONS.EQUIP.code then
            local axe = AxeForFightRPC(x)
            if axe ~= nil then
                local player = Player()
                local inv = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
                if inv ~= nil and inv:GetEquippedItem(G.EQUIPSLOTS.HANDS) == axe then
                    return -- the axe is already in hand
                end
                x = axe
            end
        end
        local light_swap = false
        if CFG.prefer_lantern and code == G.RPC.ControllerUseItemOnSelfFromInvTile
            and action == G.ACTIONS.EQUIP.code then
            local lantern = LanternForRPC(x)
            if lantern ~= nil then
                local player = Player()
                local inv = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
                if inv ~= nil and inv:GetEquippedItem(G.EQUIPSLOTS.HANDS) == lantern then
                    return -- the lantern is already in hand
                end
                x = lantern
                light_swap = true -- a light for a light: the walking rules below don't apply
            end
        end
        if CFG.kite_lantern and self_equip and not light_swap then
            local ok, lantern = G.pcall(KiteLanternForRPC, x)
            if ok and lantern ~= nil then
                if HandsItem(Player()) == lantern then
                    return -- the lantern is already in hand
                end
                x = lantern
                light_swap = true
            end
        end
        if CFG.kite_lantern and self_equip and SafeCall("helper light", IsHelperLightInFight, x) then
            LogHeldLight(x, "raw equip")
            return -- Equipment Master's or Auto Actions' dark light waits for the fight
        end
        if walk_swap_depth > 0 and not light_swap and code == G.RPC.ControllerUseItemOnSelfFromInvTile
            and action == G.ACTIONS.EQUIP.code then
            if CFG.keep_light then
                local ok, lose = G.pcall(WouldLoseLight, x)
                if ok and lose then
                    Log("kept light: skipped walking swap to", tostring(x and x.prefab))
                    return
                end
            end
            if CFG.walk_only_faster then
                local ok, slower = G.pcall(IsSlowerWalkSwap, x)
                if ok and slower then
                    LogSkip(x)
                    return
                end
            end
        end
        if CFG.fix_explore and code == G.RPC.LeftClick and action == G.ACTIONS.WALKTO.code and target == nil
            and CalledFromAutoExplore() then
            local player = Player()
            if player ~= nil then
                local now = G.GetTime()
                if now ~= last_attempt_time then
                    prev_attempt_time = last_attempt_time
                    last_attempt_time = now
                end
                local pause, stop_first = ExploreShouldPause(player)
                if pause then
                    if not explore_paused then
                        explore_paused = true
                        Log("Auto Explore paused")
                        if stop_first then StopWalkingNow() end
                    end
                    return -- drop this step; the explore loop tries again shortly
                end
                if explore_paused then
                    explore_paused = false
                    Log("Auto Explore resumed")
                end
                if type(x) == "number" and type(z) == "number" then
                    PreviewWalk(x, z, platform)
                end
            end
        end
        return orig_send(code, action, x, z, target, isreleased, controlmods, noforce, mod_name, platform, ...)
    end)
    Log("patched SendRPCToServer")
end

local explore_key_bound = false
local function BindExploreKey()
    if explore_key_bound or not CFG.fix_explore then return end
    explore_key_bound = true
    local key = G.rawget(G, CFG.explore_key) or G.KEY_F1
    G.TheInput:AddKeyDownHandler(key, function()
        -- Auto Explore toggles on this same key press, and the game runs the
        -- two key handlers in no fixed order. So look at its step attempts from
        -- before this frame to tell whether it was running, and decide on the
        -- next frame, once its handler has run too.
        local player = Player()
        if player == nil then return end
        local press_time = G.GetTime()
        local before = last_attempt_time < press_time and last_attempt_time or prev_attempt_time
        local was_running = press_time - before <= EXPLORE_ACTIVE_WINDOW
        player:DoTaskInTime(0, function()
            if last_attempt_time >= press_time then
                Log("Auto Explore started")
                return -- it just took its first step; leave that walk alone
            end
            explore_paused = false
            if was_running then
                last_attempt_time, prev_attempt_time = -math.huge, -math.huge
                StopWalkingNow()
            end
        end)
    end)
end

------------------------------------------------------------------------------
-- 7e. Tools stay in hand until there's something to fight
--
-- With nothing to fight, Auto Combat wants your weapon in hand. A pickaxe
-- counted as a weapon to it only while you carry no axe (7 prefers the axe),
-- so a Shift+click pickaxe went back to the weapon before the first swing.
-- Now any tool in hand (pickaxe, axe, shovel, hammer, net) is left alone
-- while Auto Combat has nothing to fight, however it got there. Once a fight
-- starts, a tool only stays if no real weapon hits harder.
------------------------------------------------------------------------------
local NOT_FIGHT_WEAPONS = { cane = true, orangestaff = true, king_cane = true, walking_stick = true,
    compass = true, vault_compass = true }

-- Auto Combat asks several times a frame; look around once per frame.
local fighting_time, fighting_value = nil, false
local function FightingNow(player)
    local now = G.GetTime()
    if fighting_time ~= now then
        fighting_time = now
        fighting_value = AutoCombatFighting(player) and true or false
    end
    return fighting_value
end

local function IdleTool(player)
    if not CFG.keep_tools or player == nil then return nil end
    local held = HandsItem(player)
    if not IsToolItem(held) or FightingNow(player) then return nil end
    return held
end

-- Your hardest-hitting weapon that is not a tool, a light or a cane.
local function BestRealWeapon()
    local best, best_d = nil, nil
    EachOwnedItem(function(item)
        if item:IsValid() and IsHandsItem(item) and item:HasTag("weapon") and not item:HasTag("broken")
            and not item:HasTag("_stackable") and not IsToolItem(item) and not IsLightItem(item)
            and not item:HasTag("lighter") and not NOT_FIGHT_WEAPONS[item.prefab] then
            local d = ItemDamage(item)
            if d ~= nil and (best_d == nil or d > best_d) then
                best, best_d = item, d
            end
        end
    end)
    return best, best_d
end

-- In a fight, the real weapon to use instead of this tool, if it hits harder.
local function WeaponOverTool(tool, player)
    if not CFG.keep_tools or player == nil or not IsToolItem(tool) or not FightingNow(player) then return nil end
    local best, best_d = BestRealWeapon()
    if best == nil then return nil end
    local tool_d = ItemDamage(tool) or 0
    if best_d > tool_d + 0.001 then return best end
    return nil
end

local tools_patched = false
local idle_tool_logged = nil
local function PatchAutoCombatTools()
    if tools_patched or not CFG.keep_tools then return end
    local ac = G.rawget(G, "AutoCombat")
    local Equip = ac ~= nil and ac.Equip or nil
    if Equip == nil or type(Equip.Request) ~= "function" or type(Equip.Satisfied) ~= "function"
        or type(Equip.FindWeapon) ~= "function" then
        return
    end
    tools_patched = true

    local old_satisfied = Equip.Satisfied
    Equip.Satisfied = function(self, want, ...)
        if (want or self.want) == "fight" then
            local player = Player()
            local ok, idle = G.pcall(IdleTool, player)
            if ok and idle ~= nil then return true end
            local ok2, better = G.pcall(WeaponOverTool, HandsItem(player), player)
            if ok2 and better ~= nil then return false end
        end
        return old_satisfied(self, want, ...)
    end

    local old_request = Equip.Request
    Equip.Request = function(self, want, ...)
        if want == "fight" then
            local ok, idle = G.pcall(IdleTool, Player())
            if ok and idle ~= nil then
                if idle_tool_logged ~= idle then
                    idle_tool_logged = idle
                    Log("tool in hand: Auto Combat leaves", tostring(idle.prefab), "alone until there's something to fight")
                end
                return old_request(self, "keep", ...) -- drops the old weapon request (1)
            end
        end
        idle_tool_logged = nil
        return old_request(self, want, ...)
    end

    local old_find = Equip.FindWeapon
    Equip.FindWeapon = function(...)
        local weapon = old_find(...)
        local ok, better = G.pcall(WeaponOverTool, weapon, Player())
        if ok and better ~= nil then return better end
        return weapon
    end
    Log("patched Auto Combat tools (tool stays in hand between fights)")
end

------------------------------------------------------------------------------
-- 7f. Spider dens last
--
-- A spider den is a hostile target to the game, to hit-and-run and to Auto
-- Combat, and it is usually the closest thing, so it got hit while spiders
-- bit you. Now:
-- - Attack (F) without force attack treats a den like a neutral creature:
--   spiders nearby come first, and a den is only hit once you've started on
--   it with Ctrl+F (then holding F keeps going, as with any creature).
-- - Auto Combat fights every spider it can reach first and the den last.
------------------------------------------------------------------------------
local DEN_PREFABS = { spiderden = true, spiderden_2 = true, spiderden_3 = true, spiderhole = true,
    spiderhole_rock = true, moonspiderden = true }
local FOE_EXCLUDE = { "INLIMBO", "player", "playerghost", "wall", "structure", "notarget", "isdead", "spiderden" }
local DEN_FOE_RANGE = 12

local function IsDen(ent)
    return type(ent) == "table" and type(ent.IsValid) == "function" and ent:IsValid()
        and (DEN_PREFABS[ent.prefab] == true or ent:HasTag("spiderden"))
end

local function ForceAttackHeld()
    local input = G.rawget(G, "TheInput")
    if input == nil then return false end
    local control = G.rawget(G, "CONTROL_FORCE_ATTACK")
    if control ~= nil and input:IsControlPressed(control) then return true end
    -- hit-and-run's own "attack anything" key (Ctrl unless changed)
    local har, util = G.rawget(G, "HitAndRun"), G.rawget(G, "MOD_util")
    if type(har) == "table" and type(util) == "table" and type(util.GetMOption) == "function"
        and type(input.IsKeyDown) == "function" then
        local ok, key = G.pcall(util.GetMOption, util, "hitandrun_ctrl_key", G.rawget(har, "ctrl_key"))
        if ok and type(key) == "number" and input:IsKeyDown(key) then return true end
    end
    return false
end

-- Creatures that aren't dens and are out to fight you, nearest first.
local function FoesNear(player, range)
    local combat = player.replica ~= nil and player.replica.combat or nil
    local x, y, z = player.Transform:GetWorldPosition()
    local list = {}
    for _, ent in ipairs(G.TheSim:FindEntities(x, y, z, range, { "_combat" }, FOE_EXCLUDE)) do
        local c = ent.replica ~= nil and ent.replica.combat or nil
        local health = ent.replica ~= nil and ent.replica.health or nil
        if c ~= nil and not IsDen(ent) and not (health ~= nil and health:IsDead())
            and (combat == nil or (combat:CanTarget(ent) and not combat:IsAlly(ent)))
            and (c:GetTarget() == player or ent:HasTag("hostile")) then
            list[#list + 1] = { ent = ent, d = ent:GetDistanceSqToPoint(x, y, z) }
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

local function RecentTarget(player, ent)
    local combat = player.replica ~= nil and player.replica.combat or nil
    if combat == nil then return false end
    if combat:GetTarget() == ent then return true end
    return type(combat.IsRecentTarget) == "function" and combat:IsRecentTarget(ent) == true
end

local den_log_time = -math.huge
local function LogDen(what)
    local now = G.GetTime()
    if now - den_log_time > 5 then
        den_log_time = now
        Log("spider den last:", what)
    end
end

-- The attack key's target (also hit-and-run's in its game-targeting mode).
local function GuardDenTargets(pc)
    if not CFG.spider_dens_last or pc._mod_harmony_dens then return end
    pc._mod_harmony_dens = true
    local old = pc.GetAttackTarget
    if type(old) ~= "function" then return end
    pc.GetAttackTarget = function(self, force_attack, force_target, isretarget, use_remote_predict, ...)
        local target = old(self, force_attack, force_target, isretarget, use_remote_predict, ...)
        if force_attack or not IsDen(target) or self.inst ~= Player() then return target end
        local ok, forced = G.pcall(ForceAttackHeld)
        if ok and forced then return target end
        local player = self.inst
        local ok2, foes = G.pcall(FoesNear, player, DEN_FOE_RANGE)
        if ok2 then
            for i = 1, math.min(#foes, 8) do
                local t = old(self, false, foes[i].ent, false, use_remote_predict, ...)
                if t ~= nil and not IsDen(t) then
                    LogDen("attack key took " .. tostring(t.prefab) .. " over the den")
                    return t
                end
            end
        end
        if RecentTarget(player, target) then return target end
        LogDen("attack key skipped the den (Ctrl+F hits it)")
        return nil
    end
end

local dens_patched = false
local function PatchSpiderDens()
    if dens_patched or not CFG.spider_dens_last then return end
    local har = G.rawget(G, "HitAndRun")
    local ac = G.rawget(G, "AutoCombat")
    local brain = type(ac) == "table" and ac.Brain or nil
    if type(har) ~= "table" or type(har.GetClosestTarget) ~= "function" then return end
    dens_patched = true

    -- hit-and-run's own pick
    local old_closest = har.GetClosestTarget
    har.GetClosestTarget = function(self, ...)
        local target = old_closest(self, ...)
        if not IsDen(target) then return target end
        local ok, forced = G.pcall(ForceAttackHeld)
        if ok and forced then return target end
        local player = Player()
        if player == nil then return target end
        local ok2, foes = G.pcall(FoesNear, player, DEN_FOE_RANGE)
        if ok2 and foes[1] ~= nil then
            LogDen("hit-and-run took " .. tostring(foes[1].ent.prefab) .. " over the den")
            return foes[1].ent
        end
        local running = type(ac) == "table" and type(ac.state) == "table" and ac.state.running
        if running or RecentTarget(player, target) then return target end
        return nil
    end

    -- Auto Combat keeps a locked target; a den lock gives way to any spider.
    if type(brain) == "table" and type(brain.LockTarget) == "function" then
        local old_lock = brain.LockTarget
        brain.LockTarget = function(self, ent, ...)
            local locked = old_lock(self, ent, ...)
            if not IsDen(locked) then return locked end
            local ok, forced = G.pcall(ForceAttackHeld)
            if ok and forced then return locked end
            local player = Player()
            local ok2, foes = G.pcall(FoesNear, player, DEN_FOE_RANGE)
            if ok2 and foes[1] ~= nil then
                LogDen("Auto Combat took " .. tostring(foes[1].ent.prefab) .. " over the den")
                self.locked_target = foes[1].ent
                return foes[1].ent
            end
            return locked
        end
    end
    Log("patched spider dens (spiders first)")
end

------------------------------------------------------------------------------
-- 7g. Trace lines (debug log only)
--
-- While Auto Combat is on: every change of what's in your hands. While
-- ActionQueue works or Auto Combat fights: every gear swap and every move or
-- stop sent to the server, with the mods it came from. In fights: every hit
-- you take, with what was near you. These show where the next Shift+click,
-- weapon or kiting problem comes from.
------------------------------------------------------------------------------
local TRACE_LIMIT = 40
local trace_count = 0
local trace_queue = false
local trace_fight = false
local trace_hands = nil
local trace_health = nil
local rpc_names, action_names = nil, nil

local function NameIn(tbl, value)
    if type(tbl) ~= "table" then return tostring(value) end
    for k, v in pairs(tbl) do
        if v == value or (type(v) == "table" and v.code == value) then return tostring(k) end
    end
    return tostring(value)
end

local function CallerMods()
    local dbg = G.rawget(G, "debug")
    if dbg == nil or dbg.getinfo == nil then return "?" end
    local seen, list = {}, {}
    for level = 3, 24 do
        local info = dbg.getinfo(level, "S")
        if info == nil then break end
        local src = type(info.source) == "string" and info.source or ""
        local mod = src:match("mods[/\\]([^/\\]+)")
        if mod ~= nil and mod ~= modname and not seen[mod] then
            seen[mod] = true
            list[#list + 1] = mod
        end
    end
    return #list > 0 and table.concat(list, ",") or "game"
end

local function Trace(...)
    if trace_count >= TRACE_LIMIT then return end
    trace_count = trace_count + 1
    Log("trace:", ...)
end

local function TracingWork(player)
    return CFG.debug_log and player ~= nil and RunningCombatEquip() ~= nil
        and (QueueBusy(player) or FightingNow(player))
end

local TRACE_RPCS = { "ControllerUseItemOnSelfFromInvTile", "UseItemFromInvTile", "EquipActionItem",
    "SwapEquipWithActiveItem", "TakeActiveItemFromEquipSlot", "StopWalking", "PredictWalking",
    "DirectWalking", "DragWalking", "AttackButton", "ControllerAttackButton", "LeftClick", "RightClick" }
local trace_rpc_set = nil

function TraceRPC(code, action, x)
    local player = Player()
    if not TracingWork(player) then return end
    if trace_rpc_set == nil then
        trace_rpc_set = {}
        for _, name in ipairs(TRACE_RPCS) do
            local c = G.RPC[name]
            if c ~= nil then trace_rpc_set[c] = name end
        end
    end
    local name = trace_rpc_set[code]
    if name == nil then return end
    if (name == "LeftClick" or name == "RightClick") and IsWorkCode(action) then return end -- the work itself
    local item = type(x) == "table" and x or (type(action) == "table" and action or nil)
    local what = item ~= nil and item.prefab ~= nil and tostring(item.prefab) or ""
    local act = (name == "LeftClick" or name == "RightClick" or name == "ControllerUseItemOnSelfFromInvTile")
        and NameIn(G.ACTIONS, action) or ""
    Trace("sent", name, act, what, "from", CallerMods())
end

local function UpdateTrace(player)
    if not CFG.debug_log or player == nil then return end
    local ac = G.rawget(G, "AutoCombat")
    local ac_on = type(ac) == "table" and type(ac.state) == "table" and ac.state.running == true
    local busy = QueueBusy(player)
    if busy and not trace_queue and ac_on then
        trace_count = 0
        Trace("queue started, hands", tostring(HandsItem(player) and HandsItem(player).prefab))
    elseif not busy and trace_queue and ac_on then
        Trace("queue ended, hands", tostring(HandsItem(player) and HandsItem(player).prefab),
            "fighting", tostring(AutoCombatFighting(player)))
    end
    trace_queue = busy

    -- fights with Auto Combat on get their own trace lines
    local fighting = ac_on and FightingNow(player)
    if fighting and not trace_fight then
        trace_count = 0
        Trace("fight started, hands", tostring(HandsItem(player) and HandsItem(player).prefab))
    elseif not fighting and trace_fight then
        Trace("fight over, hands", tostring(HandsItem(player) and HandsItem(player).prefab))
    end
    trace_fight = fighting

    local held = HandsItem(player)
    if held ~= trace_hands then
        if ac_on then
            local Equip = ac.Equip
            Trace("hands", tostring(trace_hands and trace_hands.prefab), "->", tostring(held and held.prefab),
                "AC wants", tostring(type(Equip) == "table" and Equip.want or nil),
                "fighting", tostring(AutoCombatFighting(player)))
        end
        trace_hands = held
    end

    -- hits taken while Auto Combat runs
    local health = player.replica ~= nil and player.replica.health or nil
    local pct = health ~= nil and type(health.GetPercent) == "function" and health:GetPercent() or nil
    if type(pct) == "number" then
        if ac_on and trace_health ~= nil and pct < trace_health - 0.001 then
            local max = type(health.Max) == "function" and health:Max() or 100
            local x, y, z = player.Transform:GetWorldPosition()
            local near = {}
            for _, ent in ipairs(G.TheSim:FindEntities(x, y, z, 8, { "_combat" }, { "INLIMBO", "player" })) do
                if #near >= 4 then break end
                local c = ent.replica ~= nil and ent.replica.combat or nil
                near[#near + 1] = string.format("%s %.1f%s", tostring(ent.prefab),
                    math.sqrt(ent:GetDistanceSqToPoint(x, y, z)), c ~= nil and c:GetTarget() == player and " (on you)" or "")
            end
            local dodging = G.rawget(G, "AutoDodger_IsDodging")
            local speed = G.rawget(G, "AutoDodger_GetSpeed")
            local ok_s, s = G.pcall(function() return speed ~= nil and speed() or nil end)
            Log(string.format("hit: lost %.0f health (now %.0f%%), dodging %s, speed %s, webbing %s, near: %s",
                (trace_health - pct) * max, pct * 100,
                tostring(dodging ~= nil and SafeCall("dodging", dodging) or false),
                ok_s and s ~= nil and string.format("%.1f", s) or "?", tostring(OnWeb(player)),
                #near > 0 and table.concat(near, ", ") or "nothing"))
        end
        trace_health = pct
    end
end

------------------------------------------------------------------------------
-- 7h. Shift+click tools (with Auto Combat on, and after pickups)
--
-- Auto Combat turns movement prediction off while it runs. ActionQueue then
-- sends each Shift+click straight to the server and skips the step where
-- Auto Actions swaps in the right tool, so a Shift+click only worked with
-- the right tool already in hand. With prediction off, the tool Auto Actions
-- picked for the click is equipped here first, and the click waits (up to
-- about a second) until it is in hand.
------------------------------------------------------------------------------
local QUEUE_TOOL_WAIT = 1.2
local queue_tool_logged = nil

-- The tool this queued click needs that isn't in your hands yet.
local function QueueToolFor(aq, act)
    if not CFG.queue_tools or type(act) ~= "table" or type(act.action) ~= "table" then return nil end
    local pc = aq.inst ~= nil and aq.inst.components ~= nil and aq.inst.components.playercontroller or nil
    if pc == nil or pc.ismastersim or pc.locomotor ~= nil then
        return nil -- prediction on: Auto Actions equips it itself
    end
    local tool = act.invobject
    local id = act.action.id
    if not IsToolItem(tool) or type(id) ~= "string" or not tool:HasTag(id .. "_tool") then return nil end
    local inv = aq.inst.replica ~= nil and aq.inst.replica.inventory or nil
    if inv == nil or inv:GetEquippedItem(G.EQUIPSLOTS.HANDS) == tool then return nil end
    if inv.GetActiveItem ~= nil and inv:GetActiveItem() == tool then return nil end
    return tool, inv
end

local function SendToolEquip(tool)
    G.SendRPCToServer(G.RPC.ControllerUseItemOnSelfFromInvTile, G.ACTIONS.EQUIP.code, tool)
end

-- A queued tree or rock you hold the wrong tool for only gets its chop or
-- mine from Auto Actions, which builds it from the game's "walk to" click.
-- The game offers that click only while you stand idle or walk. Pickups end
-- the moment you stop moving, so the next target is checked mid pickup
-- animation, gets no action at all, and ActionQueue drops it. When that
-- happens, the queue waits here (up to two seconds) until you're idle and
-- asks again.
local QUEUE_IDLE_WAIT = 2
local LEFT_WORK_TAGS = { "CHOP_workable", "MINE_workable", "HACK_workable" }
local RIGHT_WORK_TAGS = { "DIG_workable", "HAMMER_workable" }
local queue_idle_logged = false

local function ReadyForWalkTo(inst)
    local sg = inst.sg
    return (sg == nil or sg:HasStateTag("moving") or sg:HasStateTag("idle"))
        and (inst:HasTag("moving") or inst:HasTag("idle"))
end

local function InActionThread(aq)
    local co = G.coroutine ~= nil and G.coroutine.running ~= nil and G.coroutine.running() or nil
    local task = aq.action_thread
    return co ~= nil and type(task) == "table" and task.co == co
end

local function ShouldWaitForIdle(aq, target, rightclick)
    if not CFG.queue_tools or type(G.Sleep) ~= "function" then return false end
    if target == nil or type(target.HasTag) ~= "function" or not target:IsValid() then return false end
    if aq.inst == nil or not aq.inst:IsValid() or ReadyForWalkTo(aq.inst) then return false end
    if not InActionThread(aq) then return false end -- only the running queue, never the selection
    for _, tag in ipairs(rightclick and RIGHT_WORK_TAGS or LEFT_WORK_TAGS) do
        if target:HasTag(tag) then return true end
    end
    return false
end

local function StillBusy(aq, target)
    return target:IsValid() and aq.inst:IsValid() and not ReadyForWalkTo(aq.inst)
end

local queue_tools_patched_on = nil
local function PatchQueueTools(player)
    if not CFG.queue_tools or player == nil then return end
    local aq = player.components ~= nil and player.components.actionqueuer or nil
    if aq == nil or queue_tools_patched_on == aq or type(aq.SendAction) ~= "function" then return end
    queue_tools_patched_on = aq
    local old_send = aq.SendAction
    aq.SendAction = function(self, act, ...)
        local tool, inv = SafeCall("queue tool", QueueToolFor, self, act)
        if tool ~= nil then
            SafeCall("queue tool", SendToolEquip, tool)
            if queue_tool_logged ~= tool.prefab then
                queue_tool_logged = tool.prefab
                Log("Shift+click with Auto Combat on: equipped", tostring(tool.prefab), "for", tostring(act.action.id))
            end
            -- ActionQueue runs this in its own thread, so it can wait here
            -- (no pcall around the wait: a thread can't pause inside one).
            local co = G.coroutine ~= nil and G.coroutine.running ~= nil and G.coroutine.running() or nil
            if co ~= nil and type(G.Sleep) == "function" then
                local start = G.GetTime()
                local resent = false
                while tool:IsValid() and inv:GetEquippedItem(G.EQUIPSLOTS.HANDS) ~= tool
                    and G.GetTime() - start < QUEUE_TOOL_WAIT do
                    if not resent and G.GetTime() - start > 0.5 then
                        resent = true
                        SafeCall("queue tool", SendToolEquip, tool) -- you may have been busy
                    end
                    G.Sleep(G.FRAMES)
                end
            end
        end
        return old_send(self, act, ...)
    end
    if type(aq.GetAction) == "function" then
        local old_get = aq.GetAction
        aq.GetAction = function(self, target, rightclick, ...)
            local act, rc = old_get(self, target, rightclick, ...)
            if act ~= nil or not SafeCall("queue wait", ShouldWaitForIdle, self, target, rightclick) then
                return act, rc
            end
            -- outside pcall, as above
            local start = G.GetTime()
            while G.GetTime() - start < QUEUE_IDLE_WAIT and SafeCall("queue wait", StillBusy, self, target) do
                G.Sleep(G.FRAMES)
            end
            act, rc = old_get(self, target, rightclick, ...)
            if act ~= nil and not queue_idle_logged then
                queue_idle_logged = true
                Log("Shift+click: waited until idle, then", tostring(type(act.action) == "table" and act.action.id),
                    tostring(target.prefab))
            end
            return act, rc
        end
    end
    Log("patched ActionQueue clicks (tools equip with Auto Combat on, wrong-tool targets wait for idle)")
end

------------------------------------------------------------------------------
-- 7i. The better weapon in a fight
--
-- When Auto Combat fights while a tool is still in your hand and you carry
-- something better for the fight (a real weapon that hits harder, or the axe
-- instead of a pickaxe), it is equipped here, in case Auto Combat or
-- Equipment Master doesn't swap it in. A hands item you picked yourself in
-- the last couple of seconds is left alone.
------------------------------------------------------------------------------
local FIGHT_FIX_INTERVAL = 0.5
local fight_fix_time = -math.huge
local fight_fix_logged = nil

local function UpdateFightWeapon(player)
    if not (CFG.prefer_axe or CFG.keep_tools) or player == nil then return end
    local Equip = RunningCombatEquip()
    if Equip == nil or not FightingNow(player) then return end
    local now = G.GetTime()
    if now - fight_fix_time < FIGHT_FIX_INTERVAL then return end
    if Equip.want ~= "fight" then return end -- dodging or walking gear
    if QueueBusy(player) then return end -- a Shift+click or Shift+drag in progress
    local o = Equip.override
    if type(o) == "table" and type(o.until_time) == "number" and now < o.until_time then
        return -- your own pick, or one of Auto Combat's boss scripts
    end
    local held = HandsItem(player)
    if not IsToolItem(held) then return end
    local better = WeaponOverTool(held, player)
    if better == nil and CFG.prefer_axe then better = AxeInsteadOf(held) end
    if better == nil or better == held then return end
    fight_fix_time = now
    ac_equip_depth = ac_equip_depth + 1 -- not a tool you picked to work with
    local ok, err = G.pcall(SendToolEquip, better)
    ac_equip_depth = ac_equip_depth - 1
    if not ok then G.error(err, 0) end
    if fight_fix_logged ~= held.prefab .. ">" .. better.prefab then
        fight_fix_logged = held.prefab .. ">" .. better.prefab
        Log("fight: " .. tostring(better.prefab) .. " instead of " .. tostring(held.prefab))
    end
end

------------------------------------------------------------------------------
-- 7j. Dragonfly first: lava larvae left alone while Dragonfly is near
--
-- Auto Combat's Dragonfly script clears lava larvae (lavae) within 12 of you
-- before anything else, and its counter-attack takes any of them within
-- 5.5. While Dragonfly herself is within DRAGONFLY_NEAR of you, both leave
-- the larvae alone and the swings stay on Dragonfly. Farther away (say while
-- she spits larvae from across the arena), the larvae are fought as before.
-- auto_dodger still dodges them.
------------------------------------------------------------------------------
local DRAGONFLY_NEAR = 15
local LARVA = "lavae"
local dragonfly_patched = false
local dragonfly_logged = -math.huge

local function DragonflyNear(ctx)
    local player = Player()
    if player == nil or not player:IsValid() then return false end
    local t = type(ctx) == "table" and ctx.target or nil
    if t ~= nil and t.prefab == "dragonfly" and t:IsValid() then
        return player:GetDistanceSqToInst(t) <= DRAGONFLY_NEAR * DRAGONFLY_NEAR
    end
    local x, y, z = player.Transform:GetWorldPosition()
    for _, ent in ipairs(G.TheSim:FindEntities(x, y, z, DRAGONFLY_NEAR, { "epic" }, { "INLIMBO" })) do
        if ent.prefab == "dragonfly" then return true end
    end
    return false
end

local function SkipLarva(ctx)
    local ok, near = G.pcall(DragonflyNear, ctx)
    if not (ok and near) then return false end
    local now = G.GetTime()
    if now - dragonfly_logged > 10 then
        dragonfly_logged = now
        Log("Dragonfly within " .. DRAGONFLY_NEAR .. ": lava larvae left alone")
    end
    return true
end

local function IsLarvaBehavior(b)
    if type(b) ~= "table" or b.name ~= "clear_minions" or type(b.run) ~= "function" then return false end
    for _, prefab in ipairs(type(b.prefabs) == "table" and b.prefabs or {}) do
        if prefab == LARVA then return true end
    end
    return false
end

local function WrapLarvaBehaviors(list)
    for _, b in ipairs(type(list) == "table" and list or {}) do
        if IsLarvaBehavior(b) and not b.mh_dragonfly_first then
            b.mh_dragonfly_first = true
            local old_run = b.run
            b.run = function(self, ctx, ...)
                if SkipLarva(ctx) then return nil end
                return old_run(self, ctx, ...)
            end
        end
    end
end

local function PatchDragonfly()
    if dragonfly_patched or not CFG.dragonfly_first then return end
    local ac = G.rawget(G, "AutoCombat")
    local strat = type(ac) == "table" and ac.Strategy or nil
    local def = type(strat) == "table" and type(strat.by_prefab) == "table" and strat.by_prefab.dragonfly or nil
    local brain = type(ac) == "table" and ac.Brain or nil
    if type(def) ~= "table" or type(brain) ~= "table" or type(brain.Retaliate) ~= "function" then return end
    dragonfly_patched = true

    -- 1. the "clear larvae first" step of the Dragonfly script
    WrapLarvaBehaviors(def.behaviors)
    for _, ph in ipairs(type(def.phases) == "table" and def.phases or {}) do
        WrapLarvaBehaviors(ph.behaviors)
        WrapLarvaBehaviors(ph._with_minion)
    end

    -- 2. the last check before a swing
    def.combat = def.combat or {}
    local old_can = def.combat.can_attack
    def.combat.can_attack = function(ctx, ent, ...)
        if ent ~= nil and ent.prefab == LARVA and SkipLarva(ctx) then return false end
        if old_can ~= nil then return old_can(ctx, ent, ...) end
    end

    -- 3. Auto Combat's counter-attack on anything that comes at you
    local old_ret = brain.Retaliate
    brain.Retaliate = function(self, ctx, now, filter, ...)
        if type(ctx) == "table" and type(ctx.target) == "table" and ctx.target.prefab == "dragonfly" then
            local inner = filter
            filter = function(ent)
                if ent ~= nil and ent.prefab == LARVA and SkipLarva(ctx) then return false end
                return inner == nil or inner(ent)
            end
        end
        return old_ret(self, ctx, now, filter, ...)
    end
    Log("patched Auto Combat Dragonfly (lava larvae left alone while she's within " .. DRAGONFLY_NEAR .. ")")
end

------------------------------------------------------------------------------
-- 8. Arrow keys only zoom the camera
--
-- hit-and-run binds all four arrow keys (Up: kiting mode, Down: its own auto
-- dodge, Left/Right: its range) through the base library's key handlers,
-- which look the key up with MOD_util:GetMOption on every press. Observer
-- Camera uses the arrows to zoom. While one of those hit-and-run keys is
-- still set to an arrow, it reads as unbound, so only the camera reacts. A
-- key you move to something else in hit-and-run's settings keeps working.
------------------------------------------------------------------------------
local ARROW_OPTIONS = { hitandrun_up = true, hitandrun_down = true, hitandrun_add = true, hitandrun_reduce = true }
local arrows_patched = false
local function FreeArrowKeys()
    if arrows_patched or not CFG.free_arrow_keys then return end
    local util = G.rawget(G, "MOD_util")
    if type(util) ~= "table" or type(util.GetMOption) ~= "function" then return end
    arrows_patched = true
    local arrow = {}
    for _, name in ipairs({ "KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT" }) do
        local k = G.rawget(G, name)
        if k ~= nil then arrow[k] = true end
    end
    local old = util.GetMOption
    util.GetMOption = function(self, key, default, ...)
        local v = old(self, key, default, ...)
        if ARROW_OPTIONS[key] and v ~= nil and arrow[v] then
            return false
        end
        return v
    end
    Log("arrow keys left to the camera")
end

------------------------------------------------------------------------------
-- 9. Auto Dodge follows Auto Combat
--
-- auto_dodger turns itself on at load and on Z, and Auto Combat only turns it
-- on while it runs. Here it is simply kept the same as Auto Combat: on while
-- Auto Combat runs, off while it doesn't.
------------------------------------------------------------------------------
local function SyncDodgeWithCombat()
    if not CFG.dodge_follows_combat then return end
    local ac = G.rawget(G, "AutoCombat")
    local set = G.rawget(G, "AutoDodger_SetEnabled")
    local is_on = G.rawget(G, "AutoDodger_IsEnabled")
    if type(ac) ~= "table" or type(set) ~= "function" or type(is_on) ~= "function" then return end
    local want = type(ac.state) == "table" and ac.state.running == true
    if (is_on() and true or false) ~= want then
        set(want)
        Log("Auto Dodge " .. (want and "on" or "off") .. " to match Auto Combat")
    end
end

------------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------------
local function InstallAll()
    PatchAutoCombatEquip()
    PatchAutoCombatAxe()
    PatchAutoCombatOwnEquips()
    PatchAutoCombatTools() -- after the axe patch, so it is asked first
    PatchAutoDodger()
    PatchWebSpeed()
    PatchSpiderDens()
    SafeCall("dragonfly", PatchDragonfly)
    PatchSendRPC()
    FreeArrowKeys()
end

InstallAll() -- most mods set their globals at load time

AddComponentPostInit("playercontroller", function(self, inst)
    -- Equipment Master wraps these walking calls first (it loads before us),
    -- so this wrapper sees its gear swaps happen inside them.
    GuardWalkSwaps(self)
    GuardFightSwaps(self)
    GuardDenTargets(self)

    -- Manual hands equips from the inventory. ThePlayer may not be set yet
    -- when the component is added, so check whose controller it is per call.
    local old_use = self.RemoteUseItemFromInvTile
    if type(old_use) == "function" then
        self.RemoteUseItemFromInvTile = function(pc, buffaction, item, ...)
            if pc.inst == Player() and buffaction ~= nil and buffaction.action == G.ACTIONS.EQUIP
                and item ~= nil and item.replica ~= nil and item.replica.equippable ~= nil
                and item.replica.equippable:EquipSlot() == G.EQUIPSLOTS.HANDS then
                -- Auto Actions' light in the dark comes this way too, like
                -- your own right-click; only its light waits for a fight.
                if SafeCall("helper light", IsHelperLightInFight, item) and CalledFromMod(AUTO_ACTIONS_ID) then
                    LogHeldLight(item, "Auto Actions")
                    return
                end
                if CFG.fix_gear_fight then
                    SafeCall("manual equip", OnManualHandsEquip)
                end
                SafeCall("tool hold", StartToolHold, item)
            end
            return old_use(pc, buffaction, item, ...)
        end
    end
end)

AddPlayerPostInit(function(player)
    player:DoTaskInTime(0, function()
        if player ~= Player() then return end
        InstallAll() -- catch anything that registered late
        SafeCall("queue tools", PatchQueueTools, player)
        BindExploreKey()
        GuardWalkEvents(player)
        player:DoPeriodicTask(G.FRAMES, function()
            SafeCall("queue freeze", UpdateQueueFreeze, player)
            SafeCall("queue tools", PatchQueueTools, player)
            SafeCall("tool hold", UpdateToolHold, player)
            SafeCall("fight weapon", UpdateFightWeapon, player)
            SafeCall("dragonfly", PatchDragonfly)
            SafeCall("trace", UpdateTrace, player)
        end)
        if CFG.dodge_follows_combat then
            SafeCall("dodge sync", SyncDodgeWithCombat)
            player:DoPeriodicTask(0.1, function()
                SafeCall("dodge sync", SyncDodgeWithCombat)
            end)
        end
        Log("ready: gear", gear_patched, "axe", axe_patched, "dodge", dodge_patched, "rpc", send_patched,
            "arrows", arrows_patched, "tools/kite", own_equip_patched, "tools", tools_patched,
            "dens", dens_patched, "web", web_patched, "queue tools", queue_tools_patched_on ~= nil,
            "dragonfly", dragonfly_patched)
    end)
end)
