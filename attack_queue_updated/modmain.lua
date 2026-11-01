-- Attack Queue (Updated)
-- Based on Attack Queue by eXiGe (original author) and Tony, Workshop 2059280386.
-- Rewritten for the current game: swings go through the game's own predicted
-- attack (BufferedAction + preview), the queue ends when the target is dead
-- rather than when it is briefly untargetable, and ActionQueue's box selection
-- can queue enemies ahead of everything else.

local G = GLOBAL

-- The mod environment only exposes a few Lua builtins, so take the rest from GLOBAL.
local pairs, ipairs, next, type, tostring, print, pcall, setmetatable =
    G.pairs, G.ipairs, G.next, G.type, G.tostring, G.print, G.pcall, G.setmetatable
local select, unpack, coroutine = G.select, G.unpack, G.coroutine

if G.TheNet ~= nil and G.TheNet:IsDedicated() then return end

local TheInput = G.TheInput
local TheSim = G.TheSim
local ACTIONS = G.ACTIONS
local EQUIPSLOTS = G.EQUIPSLOTS
local FRAMES = G.FRAMES
local RPC = G.RPC
local BufferedAction = G.BufferedAction
local SendRPCToServer = G.SendRPCToServer
local GetTime = G.GetTime
local Sleep = G.Sleep

local CONTROL_PRIMARY = G.CONTROL_PRIMARY
local CONTROL_SECONDARY = G.CONTROL_SECONDARY
local CONTROL_ATTACK = G.CONTROL_ATTACK
local CONTROL_FORCE_ATTACK = G.CONTROL_FORCE_ATTACK

-------------------------------------------------------------------------------
-- Settings

local function Config(name, default)
    local value = GetModConfigData(name)
    if value == nil then return default end
    return value
end

local ACTION_KEY = G.rawget(G, Config("key", "KEY_LSHIFT")) or G.KEY_LSHIFT
local NEAREST_RANGE = Config("nearest_range", 40)
local AQ_DRAG = Config("aq_drag", true)
local OWN_SELECT = Config("own_select", "auto")
local REEQUIP = Config("reequip", "auto")
local CRAFT = Config("craft", true)
local DEBUG = Config("debug", false)

local DOUBLE_CLICK_TIME = 0.3
local DOUBLE_CLICK_RANGE = 40
local MAX_CHASE_DIST = 60          -- left-click RPCs farther than 64 are dropped by the server
local UNTARGETABLE_GIVEUP = 3      -- seconds a target may stay untargetable (burrowed, flying) before we move on
local NO_PREDICT_RESEND = 0.3      -- resend gap without movement prediction
local CONTROLMODS_FORCE_ATTACK = 2 -- bit for CONTROL_FORCE_ATTACK in PlayerController:EncodeControlMods
local HIGHLIGHT = {0.35, 0.05, 0.05}

local function dbg(...)
    if not DEBUG then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    print("[AttackQueue] " .. G.table.concat(parts, " "))
end

local function ModEnabled(name)
    local index = G.KnownModIndex
    if index == nil or index.IsModEnabled == nil then return false end
    local ok, enabled = pcall(index.IsModEnabled, index, name)
    return ok and enabled or false
end

-- Auto ReEquip Weapon already swaps in a spare; doing it twice can swap back and forth.
local REEQUIP_ON = REEQUIP == "on" or (REEQUIP == "auto" and not ModEnabled("workshop-604196908"))

-------------------------------------------------------------------------------
-- State

local player, pc   -- ThePlayer and its playercontroller, set in the postinit
local aq           -- ActionQueue's actionqueuer component, when that mod is running

local queue = {}   -- entity -> force flag; targets waiting for our own session
local marked = {}  -- entities we keep highlighted
local session      -- our own lock-on run: {thread = task, current = ent}
local aq_target    -- target our engine is fighting inside ActionQueue's thread
local last_click = {time = 0}

local function InGame()
    return player ~= nil and player:IsValid() and player.HUD ~= nil and not player.HUD:HasInputFocus()
end

local function IsForcePressed()
    return TheInput:IsControlPressed(CONTROL_FORCE_ATTACK)
end

local function IsActionKeyDown()
    return TheInput:IsKeyDown(ACTION_KEY)
end

-------------------------------------------------------------------------------
-- Target checks

local function IsDead(ent)
    if G.IsEntityDead ~= nil then
        return G.IsEntityDead(ent)
    end
    local health = ent.replica ~= nil and ent.replica.health or nil
    return health ~= nil and health:IsDead()
end

local function IsAlive(ent)
    return ent ~= nil and ent:IsValid() and not ent:HasTag("INLIMBO") and not IsDead(ent)
end

-- Same hostility rule the game uses for the attack key without force attack.
local function IsHostileTo(target)
    if player.HostileTest ~= nil then
        return player:HostileTest(target)
    elseif target.HostileToPlayerTest ~= nil then
        return target:HostileToPlayerTest(player)
    end
    return target:HasTag("hostile")
end

-- Can we fight this creature now? force = Ctrl held (force attack).
local function IsEnemy(target, force)
    if player == nil or target == nil or target == player or not target:IsValid() then
        return false
    end
    if target:HasTag("INLIMBO") or target:HasTag("wall") or target.replica == nil then
        return false
    end
    local combat = player.replica.combat
    local target_combat = target.replica.combat
    if combat == nil or target_combat == nil or IsDead(target) then
        return false
    end
    if not combat:CanTarget(target) or combat:IsAlly(target) then
        return false
    end
    if force or target_combat:GetTarget() == player then
        return true
    end
    if not IsHostileTo(target) then
        return false
    end
    -- Other players' followers need force attack, like in the base game.
    local follower = target.replica.follower
    local leader = follower ~= nil and follower:GetLeader() or nil
    if leader ~= nil and leader:HasTag("player") and leader ~= player then
        return false
    end
    return true
end

local function FindNearest(force)
    local x, y, z = player.Transform:GetWorldPosition()
    local best, best_dsq
    for _, ent in ipairs(TheSim:FindEntities(x, y, z, NEAREST_RANGE, {"_combat"}, {"INLIMBO", "wall", "playerghost"})) do
        if IsEnemy(ent, force) then
            local dsq = player:GetDistanceSqToInst(ent)
            if best_dsq == nil or dsq < best_dsq then
                best, best_dsq = ent, dsq
            end
        end
    end
    return best
end

-------------------------------------------------------------------------------
-- Highlights

local function Mark(ent)
    if ent == nil or not ent:IsValid() then return end
    marked[ent] = true
    if ent.components.highlight == nil then
        ent:AddComponent("highlight")
    end
    ent.components.highlight:Highlight(HIGHLIGHT[1], HIGHLIGHT[2], HIGHLIGHT[3])
end

local function Unmark(ent)
    if not marked[ent] then return end
    marked[ent] = nil
    if ent:IsValid() and ent.components.highlight ~= nil then
        ent.components.highlight:UnHighlight()
    end
end

AddComponentPostInit("highlight", function(self, inst)
    local UnHighlight = self.UnHighlight
    self.UnHighlight = function(self, ...)
        if marked[inst] then return end -- keep queued targets lit when the mouse moves off
        return UnHighlight(self, ...)
    end
end)

-------------------------------------------------------------------------------
-- Better Lag Compensation's swing prediction only runs while a button is held,
-- and a queue holds none, which can freeze the swing pose. Turn it off while we
-- attack and back on shortly after we stop (even if our thread is killed).

local future_off_by_us = false
local last_engine_tick = -1

local function FutureModule()
    local loaded = G.package ~= nil and G.package.loaded or nil
    local future = loaded ~= nil and loaded["blc/future"] or nil
    return type(future) == "table" and future or nil
end

local function SuspendFuture()
    last_engine_tick = GetTime()
    local future = FutureModule()
    if future ~= nil and future.enabled then
        future.enabled = false
        future_off_by_us = true
    end
end

local function FutureWatchdog()
    if future_off_by_us and GetTime() - last_engine_tick > 0.35 then
        local future = FutureModule()
        if future ~= nil then
            future.enabled = true
        end
        future_off_by_us = false
    end
end

-------------------------------------------------------------------------------
-- Weapon replacement

local weapon = {item = nil, prefab = nil, lost_at = nil, crafted = false, last_try = 0}
local weapon_watched = setmetatable({}, {__mode = "k"})

local function FindSpare(prefab)
    local inventory = player.replica.inventory
    local containers = {inventory}
    local body = inventory:GetEquippedItem(EQUIPSLOTS.BODY)
    if body ~= nil and body.replica.container ~= nil then
        containers[#containers + 1] = body.replica.container
    end
    local open = inventory:GetOpenContainers()
    if open ~= nil then
        for container in pairs(open) do
            if container ~= body and container.replica ~= nil and container.replica.container ~= nil then
                containers[#containers + 1] = container.replica.container
            end
        end
    end
    for _, container in ipairs(containers) do
        for _, item in pairs(container:GetItems()) do
            if item ~= nil and item.prefab == prefab and item:IsValid() then
                return item
            end
        end
    end
end

local function UpdateWeapon()
    local inventory = player.replica.inventory
    if inventory == nil then return end
    local hand = inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    if hand ~= nil then
        if hand ~= weapon.item then
            weapon.item, weapon.prefab, weapon.lost_at, weapon.crafted = hand, hand.prefab, nil, false
            if not weapon_watched[hand] then
                weapon_watched[hand] = true
                player:ListenForEvent("onremove", function(item)
                    if weapon.item == item then
                        weapon.item = nil
                        weapon.lost_at = GetTime()
                    end
                end, hand)
            end
        end
        return
    end

    -- Hands are empty. Only act if the weapon broke during this fight.
    if weapon.lost_at == nil or weapon.prefab == nil or inventory:GetActiveItem() ~= nil then return end
    local now = GetTime()
    if now - weapon.lost_at > 10 then
        weapon.lost_at = nil
        return
    end
    if now - weapon.last_try < 0.3 then return end
    weapon.last_try = now

    if REEQUIP_ON or weapon.crafted then
        local spare = FindSpare(weapon.prefab)
        if spare ~= nil then
            dbg("equipping spare", weapon.prefab)
            inventory:UseItemFromInvTile(spare)
            return
        end
    end

    -- Give Auto ReEquip Weapon a moment first when it is the one swapping.
    if CRAFT and not weapon.crafted and (REEQUIP_ON or now - weapon.lost_at > 1)
        -- ActionQueue turns crafting with its key held into repeat crafting.
        and not (aq ~= nil and IsActionKeyDown()) then
        local builder = player.replica.builder
        local recipe = G.AllRecipes ~= nil and G.AllRecipes[weapon.prefab] or nil
        if builder ~= nil and recipe ~= nil and builder:CanBuild(weapon.prefab) then
            weapon.crafted = true
            local skin = G.Profile ~= nil and G.Profile:GetLastUsedSkinForItem(weapon.prefab) or nil
            dbg("crafting", weapon.prefab)
            builder:MakeRecipeFromMenu(recipe, skin)
        end
    end
end

-------------------------------------------------------------------------------
-- Attack engine

-- One swing through the game's own path: a predicted attack with the RPC
-- sent from preview_cb, the same way a left click on the target does it.
local function SwingAt(target)
    local act = BufferedAction(player, target, ACTIONS.ATTACK)
    if pc.ismastersim then
        player.components.combat:SetTarget(nil)
        pc:DoAction(act)
        return true
    end
    if pc:IsBusy() then return false end

    local x, _, z = target.Transform:GetWorldPosition()
    local platform, px, pz = pc:GetPlatformRelativePosition(x, z)
    local function send()
        SendRPCToServer(RPC.LeftClick, ACTIONS.ATTACK.code, px, pz, target, true,
            CONTROLMODS_FORCE_ATTACK, nil, ACTIONS.ATTACK.mod_name, platform, platform ~= nil)
    end

    if pc.locomotor == nil then
        act.non_preview_cb = send -- no movement prediction: the server does the walking
        pc:DoAction(act)
    elseif pc:CanLocomote() then
        act.preview_cb = send
        pc:DoAction(act)
    else
        send() -- can't predict right now (paused prediction); let the server swing
    end
    return true
end

local function ReadyToSwing(target, last_send)
    local isenabled = pc:IsEnabled()
    if not isenabled or pc:IsBusy() then
        return false
    end
    local now = GetTime()
    if now - last_send < 2 * FRAMES then
        return false
    end
    local buffered = player:GetBufferedAction()
    local pending = buffered ~= nil and buffered.action == ACTIONS.ATTACK and buffered.target == target
    if player.sg ~= nil then
        if player.sg:HasStateTag("attack") and pc:GetCombatTarget() == target then
            return false -- mid-swing: wait for the swing to release, like holding the attack key
        end
        if pending then
            -- Walking to it, or waiting on the server. Retry if we seem stuck idle.
            return player.sg:HasStateTag("idle") and now - last_send > 1
        end
        return true
    end
    -- No local stategraph (movement prediction off): go by the server's tags.
    if player:HasTag("attack") then
        return false
    end
    if player:HasTag("moving") and now - last_send < 1.5 then
        return false
    end
    return now - last_send >= NO_PREDICT_RESEND
end

-- Keep attacking target until it is dead or gone. Runs inside a thread.
-- keep_going() returning false ends it early.
local function AttackUntilDone(target, force, keep_going)
    local last_send = -1
    local untargetable_since
    dbg("lock on", target, target.prefab, force and "(force)" or "")
    while true do
        if player == nil or not player:IsValid() or player:HasTag("playerghost") then
            return "no player"
        end
        if keep_going ~= nil and not keep_going() then
            return "stopped"
        end
        if not IsAlive(target) then
            dbg("target dead", target)
            return "dead"
        end
        SuspendFuture()
        UpdateWeapon()

        local combat = player.replica.combat
        if combat ~= nil and combat:IsAlly(target) then
            return "ally"
        elseif combat == nil or not combat:CanTarget(target) then
            -- Briefly untargetable mid-fight is normal; only give up if it lasts.
            untargetable_since = untargetable_since or GetTime()
            if GetTime() - untargetable_since > UNTARGETABLE_GIVEUP then
                dbg("giving up, untargetable", target)
                return "untargetable"
            end
        else
            untargetable_since = nil
            if player:GetDistanceSqToInst(target) > MAX_CHASE_DIST * MAX_CHASE_DIST then
                dbg("giving up, too far", target)
                return "too far"
            end
            if ReadyToSwing(target, last_send) and SwingAt(target) then
                last_send = GetTime()
            end
        end
        Sleep(FRAMES)
    end
end

-------------------------------------------------------------------------------
-- Our own session (Shift + F, and Shift + click when ActionQueue is not running)

local function ClosestQueued()
    local best, best_dsq
    for ent, force in pairs(queue) do
        if IsAlive(ent) then
            local dsq = player:GetDistanceSqToInst(ent)
            if best_dsq == nil or dsq < best_dsq then
                best, best_dsq = ent, dsq
            end
        else
            queue[ent] = nil
            Unmark(ent)
        end
    end
    return best, best and queue[best]
end

local function StopSession(reason)
    local s = session
    if s == nil then return end
    session = nil
    dbg("stop", reason)
    for ent in pairs(queue) do
        Unmark(ent)
    end
    queue = {}
    if s.thread ~= nil and coroutine.running() ~= s.thread.co then
        pcall(s.thread.SetList, s.thread, nil)
    end
end

local function StartSession()
    if session ~= nil or player == nil then return end
    if aq ~= nil and aq.action_thread ~= nil then
        aq:ClearActionThread()
    end
    local s = {}
    session = s
    s.thread = player:StartThread(function()
        while session == s and player ~= nil and player:IsValid() do
            local target, force = ClosestQueued()
            if target == nil then break end
            s.current = target
            AttackUntilDone(target, force, function() return session == s end)
            if session ~= s then return end
            queue[target] = nil
            Unmark(target)
        end
        if session == s then
            StopSession("queue empty")
        end
    end)
end

local function QueueTarget(ent, force)
    if queue[ent] == nil then
        queue[ent] = force or false
        Mark(ent)
    end
end

-------------------------------------------------------------------------------
-- Shift + F / Ctrl + Shift + F

TheInput:AddControlHandler(CONTROL_ATTACK, function(down)
    if not down or not InGame() or not IsActionKeyDown() or session ~= nil then return end
    local force = IsForcePressed()
    local target = FindNearest(force)
    if target == nil then
        dbg("no target in range", NEAREST_RANGE, force and "(force)" or "")
        return
    end
    QueueTarget(target, force)
    StartSession()
end)

-------------------------------------------------------------------------------
-- Shift + click queue (used when ActionQueue is not there to handle clicks)

local function OwnSelectOn()
    if OWN_SELECT == "on" then return true end
    if OWN_SELECT == "off" then return false end
    return aq == nil
end

TheInput:AddControlHandler(CONTROL_PRIMARY, function(down)
    if not InGame() or not OwnSelectOn() or not IsActionKeyDown() then return end
    if not down then
        if session == nil and next(queue) ~= nil then
            StartSession()
        end
        return
    end
    if TheInput:GetHUDEntityUnderMouse() ~= nil or pc.placer_recipe ~= nil or pc.deployplacer ~= nil then return end

    local now = GetTime()
    if now - last_click.time < DOUBLE_CLICK_TIME and last_click.prefab ~= nil then
        local x, y, z = last_click.pos:Get()
        for _, ent in ipairs(TheSim:FindEntities(x, y, z, DOUBLE_CLICK_RANGE, {"_combat"}, {"INLIMBO", "wall"})) do
            if ent.prefab == last_click.prefab and IsEnemy(ent, last_click.force) then
                QueueTarget(ent, last_click.force)
            end
        end
        last_click.prefab = nil
        return
    end

    local force = IsForcePressed()
    for _, ent in ipairs(TheInput:GetAllEntitiesUnderMouse()) do
        if ent:IsValid() and IsEnemy(ent, force) then
            if queue[ent] ~= nil then
                queue[ent] = nil
                Unmark(ent)
            else
                QueueTarget(ent, force)
            end
            last_click = {prefab = ent.prefab, pos = ent:GetPosition(), time = now, force = force}
            return
        end
    end
    last_click.prefab = nil
end)

-------------------------------------------------------------------------------
-- ActionQueue (RB3 and other Reborn builds with the same component API)

local function HookActionQueue(component)
    if component == nil or component._attackqueue_hooked then return end
    component._attackqueue_hooked = true
    aq = component
    dbg("ActionQueue found")
    if not AQ_DRAG then return end

    local force_selected = setmetatable({}, {__mode = "k"})

    -- 1. Let its selection box and clicks pick up enemies (walls still count, as before).
    if type(component.AddAction) == "function" then
        component.AddAction("allclick", "ATTACK", function(target)
            return target:HasTag("wall") or IsEnemy(target, IsForcePressed())
        end)
    end

    -- 2. Remember which targets were picked with force attack (Ctrl) held.
    local SelectEntity = component.SelectEntity
    component.SelectEntity = function(self, ent, ...)
        if ent ~= nil and IsForcePressed() and IsEnemy(ent, true) and not IsEnemy(ent, false) then
            force_selected[ent] = true
        end
        return SelectEntity(self, ent, ...)
    end
    local DeselectEntity = component.DeselectEntity
    component.DeselectEntity = function(self, ent, ...)
        if ent ~= nil then force_selected[ent] = nil end
        return DeselectEntity(self, ent, ...)
    end

    -- 3. A selected enemy keeps its attack even after Ctrl is let go.
    local GetAction = component.GetAction
    component.GetAction = function(self, target, rightclick, pos)
        local act, rc = GetAction(self, target, rightclick, pos)
        if act == nil and target ~= nil and self.selected_ents[target] ~= nil
            and IsEnemy(target, force_selected[target] or false) then
            return BufferedAction(self.inst, target, ACTIONS.ATTACK), false
        end
        return act, rc
    end

    -- 4. Enemies come before every other selected object.
    local GetClosestTarget = component.GetClosestTarget
    component.GetClosestTarget = function(self)
        local best, best_dsq
        for ent in pairs(self.selected_ents) do
            if ent:IsValid() and IsEnemy(ent, force_selected[ent] or false) then
                local dsq = self.inst:GetDistanceSqToInst(ent)
                if best_dsq == nil or dsq < best_dsq then
                    best, best_dsq = ent, dsq
                end
            end
        end
        return best or GetClosestTarget(self)
    end

    -- 5. An attack on a creature runs our engine until it is dead.
    local SendActionAndWait = component.SendActionAndWait
    component.SendActionAndWait = function(self, act, rightclick, target, ...)
        if act ~= nil and act.action == ACTIONS.ATTACK and target ~= nil
            and not target:HasTag("wall") and target.replica ~= nil and target.replica.combat ~= nil then
            aq_target = target
            AttackUntilDone(target, force_selected[target] or false, function()
                return self.action_thread ~= nil
            end)
            aq_target = nil
            return
        end
        return SendActionAndWait(self, act, rightclick, target, ...)
    end
end

-------------------------------------------------------------------------------
-- Player setup, interruptions

local interrupt_controls = {}
for control = G.CONTROL_INSPECT, G.CONTROL_MOVE_RIGHT do
    interrupt_controls[control] = true -- inspect, action (Space) and the four move controls
end
local mouse_controls = {[CONTROL_PRIMARY] = true, [CONTROL_SECONDARY] = true}

AddComponentPostInit("playercontroller", function(self, inst)
    if inst ~= G.ThePlayer then return end
    StopSession("new player")
    player, pc, aq = inst, self, nil
    queue, marked = {}, {}
    weapon.item, weapon.prefab, weapon.lost_at = nil, nil, nil

    local OnControl = self.OnControl
    self.OnControl = function(self, control, down, ...)
        if down and session ~= nil and InGame() then
            if interrupt_controls[control] then
                StopSession("control " .. tostring(control))
            elseif mouse_controls[control] and TheInput:GetHUDEntityUnderMouse() == nil and not IsActionKeyDown() then
                StopSession("click")
            end
        end
        return OnControl(self, control, down, ...)
    end

    inst:DoPeriodicTask(0.25, FutureWatchdog)

    -- ActionQueue adds its component in its own playercontroller postinit,
    -- which may run before or after this one.
    local tries = 0
    local finder
    finder = inst:DoPeriodicTask(0.5, function()
        tries = tries + 1
        local component = inst.components.actionqueuer
        if component ~= nil then
            HookActionQueue(component)
        end
        if component ~= nil or tries >= 20 then
            finder:Cancel()
        end
    end, 0)
end)

-- Playing the pan flute puts targets to sleep; stop as the original did.
AddClassPostConstruct("components/inventory_replica", function(self, inst)
    local UseItemFromInvTile = self.UseItemFromInvTile
    self.UseItemFromInvTile = function(self, item, ...)
        if item ~= nil and item.prefab == "panflute" and inst == player then
            StopSession("pan flute")
        end
        return UseItemFromInvTile(self, item, ...)
    end
end)

-- For other client mods (e.g. Mod Harmony) that want to know when we are attacking.
G.AttackQueueUpdated = {
    IsActive = function() return session ~= nil or aq_target ~= nil end,
    GetTarget = function() return (session ~= nil and session.current) or aq_target end,
    Stop = function() StopSession("external") end,
}
