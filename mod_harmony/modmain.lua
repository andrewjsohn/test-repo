-- Mod Harmony: glue between Auto Combat, Equipment Master, auto_dodger,
-- Better Lag Compensation, ActionQueue RB3 and Auto Explore.
--
-- Every patch is defensive: it checks that the other mod is loaded and has
-- the function it expects, wraps instead of replacing, and fails quietly
-- (with a debug log line) when something is missing.

local G = GLOBAL

-- A mod's environment only carries a few Lua basics (tonumber is not one of
-- them), so take every builtin used below from the real global table.
local tonumber, tostring, type, ipairs, print, math =
    G.tonumber, G.tostring, G.type, G.ipairs, G.print, G.math

local CFG = {
    fix_gear_fight = GetModConfigData("fix_gear_fight") ~= false,
    manual_equip_grace = tonumber(GetModConfigData("manual_equip_grace")) or 2,
    fix_dodge_timing = GetModConfigData("fix_dodge_timing") ~= false,
    dodge_ping_scale = tonumber(GetModConfigData("dodge_ping_scale")) or 1,
    dodge_extra_margin = tonumber(GetModConfigData("dodge_extra_margin")) or 0.5,
    fix_queue_freeze = GetModConfigData("fix_queue_freeze") ~= false,
    fix_explore = GetModConfigData("fix_explore") ~= false,
    explore_key = GetModConfigData("explore_key") or "KEY_F1",
    explore_fight_radius = tonumber(GetModConfigData("explore_fight_radius")) or 12,
    debug_log = GetModConfigData("debug_log") == true,
}

local OWNER = "mod_harmony"
local AUTO_EXPLORE_ID = "3826759911"
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
    local speed_fn = G.rawget(G, "AutoDodger_GetSpeed")
    local speed = speed_fn ~= nil and SafeCall("dodger speed", speed_fn) or BASE_SPEED
    if type(speed) ~= "number" or speed <= 0 then speed = BASE_SPEED end
    local pad = PingSeconds() * CFG.dodge_ping_scale * speed + CFG.dodge_extra_margin
    if pad > MAX_DODGE_PAD then pad = MAX_DODGE_PAD end
    if pad > 0 then
        posdata.radius = radius + pad
    end
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

local explore_patched = false
local function PatchAutoExplore()
    if explore_patched or not CFG.fix_explore then return end
    orig_send = G.rawget(G, "SendRPCToServer")
    if type(orig_send) ~= "function" then return end
    explore_patched = true

    G.rawset(G, "SendRPCToServer", function(code, action, x, z, target, isreleased, controlmods,
                                            noforce, mod_name, platform, ...)
        if code == G.RPC.LeftClick and action == G.ACTIONS.WALKTO.code and target == nil
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
    Log("patched SendRPCToServer for Auto Explore")
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
-- Wiring
------------------------------------------------------------------------------
local function InstallAll()
    PatchAutoCombatEquip()
    PatchAutoDodger()
    PatchAutoExplore()
end

InstallAll() -- most mods set their globals at load time

AddComponentPostInit("playercontroller", function(self, inst)
    -- Manual hands equips from the inventory. ThePlayer may not be set yet
    -- when the component is added, so check whose controller it is per call.
    local old_use = self.RemoteUseItemFromInvTile
    if type(old_use) == "function" then
        self.RemoteUseItemFromInvTile = function(pc, buffaction, item, ...)
            if CFG.fix_gear_fight and pc.inst == Player() and buffaction ~= nil and buffaction.action == G.ACTIONS.EQUIP
                and item ~= nil and item.replica ~= nil and item.replica.equippable ~= nil
                and item.replica.equippable:EquipSlot() == G.EQUIPSLOTS.HANDS then
                SafeCall("manual equip", OnManualHandsEquip)
            end
            return old_use(pc, buffaction, item, ...)
        end
    end
end)

AddPlayerPostInit(function(player)
    player:DoTaskInTime(0, function()
        if player ~= Player() then return end
        InstallAll() -- catch anything that registered late
        BindExploreKey()
        player:DoPeriodicTask(G.FRAMES, function()
            SafeCall("queue freeze", UpdateQueueFreeze, player)
        end)
        Log("ready: gear", gear_patched, "dodge", dodge_patched, "explore", explore_patched)
    end)
end)
