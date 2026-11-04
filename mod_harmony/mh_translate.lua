-- Mod Harmony: English display text for other mods.
--
-- Steam updates put other mods' Chinese text back. Instead of editing their
-- files again, this swaps any Chinese text that was translated before for its
-- English version at the moment it is drawn on screen (every Text widget:
-- menus, mod settings, hover hints, speech, chat lines, popups).
-- Only text listed in mh_translations.lua is changed; new text a mod adds
-- later stays as it is. Mod files, setting keys and saved values are never
-- touched, because only what is drawn changes.
local G = GLOBAL
local type, ipairs, tostring = G.type, G.ipairs, G.tostring
local string, table, pcall, print = G.string, G.table, G.pcall, G.print
local find, sub = string.find, string.sub

local ok_data, DATA = pcall(G.require, "mh_translations")
if not ok_data or type(DATA) ~= "table" then
    print("[Mod Harmony] translations: could not load mh_translations (" .. tostring(DATA) .. ")")
    return
end

-- Chinese text: UTF-8 lead bytes 0xE3-0xE9 (U+3000-U+9FFF, characters and
-- Chinese punctuation) and full-width forms such as ？ and ！ (U+FF00-U+FFEF).
local CJK_PAT = "[\227-\233]"
local FULLWIDTH_PAT = "\239[\188-\191]"
local FMT_PAT = "%%[%-+ #0]*%d*%.?%d*[cdiouxXeEfgGqs%%]"

local function has_cjk(s)
    return find(s, CJK_PAT) ~= nil or find(s, FULLWIDTH_PAT) ~= nil
end

local function cjk_count(s)
    local n = 0
    for _ in string.gmatch(s, "[\227-\233][\128-\191][\128-\191]") do n = n + 1 end
    for _ in string.gmatch(s, "\239[\188-\191][\128-\191]") do n = n + 1 end
    return n
end

local function plain_replace(s, from, to)
    local out, i = {}, 1
    while true do
        local a, b = find(s, from, i, true)
        if not a then break end
        out[#out + 1] = sub(s, i, a - 1)
        out[#out + 1] = to
        i = b + 1
    end
    if i == 1 then return s end
    out[#out + 1] = sub(s, i)
    return table.concat(out)
end

local function split_fmt(s)
    local parts, i = {}, 1
    while true do
        local a, b = find(s, FMT_PAT, i)
        if not a then break end
        parts[#parts + 1] = sub(s, i, a - 1)
        i = b + 1
    end
    parts[#parts + 1] = sub(s, i)
    return parts
end

local exact, frags, singles = {}, {}, {}
local seen = {}
local function add_frag(zh, en)
    if zh == "" or seen[zh] or not has_cjk(zh) then return end
    seen[zh] = true
    if cjk_count(zh) == 1 and #zh <= 4 then
        singles[#singles + 1] = { zh, en }
    else
        frags[#frags + 1] = { zh, en }
    end
end
for _, p in ipairs(DATA) do
    local zh, en = p[1], p[2]
    if type(zh) == "string" and type(en) == "string" then
        if exact[zh] == nil then exact[zh] = en end
        add_frag(zh, en)
        -- Text built with string.format: also match the pieces between the
        -- format codes when both sides have the same codes in the same order.
        if find(zh, FMT_PAT) then
            local zp, ep = split_fmt(zh), split_fmt(en)
            if #zp == #ep then
                for k = 1, #zp do add_frag(zp[k], ep[k]) end
            end
        end
    end
end
-- Longest first, so a whole phrase wins over a piece of it.
table.sort(frags, function(a, b) return #a[1] > #b[1] end)

local memo, memo_n = {}, 0
local function translate(s)
    local r = memo[s]
    if r then return r end
    r = exact[s]
    if r == nil then
        r = s
        for k = 1, #frags do
            local f = frags[k]
            if find(r, f[1], 1, true) then
                r = plain_replace(r, f[1], f[2])
                if not has_cjk(r) then break end
            end
        end
        -- One-character words (on/off and the like) only when hardly any
        -- Chinese is left, so other Chinese text isn't cut into pieces.
        if has_cjk(r) and cjk_count(r) <= 2 then
            for k = 1, #singles do
                local f = singles[k]
                if find(r, f[1], 1, true) then r = plain_replace(r, f[1], f[2]) end
            end
        end
        -- Built from translated pieces only when nothing Chinese is left.
        -- Otherwise this is text that was never translated (new text from an
        -- update, say), and it stays exactly as the mod wrote it.
        if has_cjk(r) then r = s end
    end
    if memo_n > 4000 then memo, memo_n = {}, 0 end
    memo[s] = r
    memo_n = memo_n + 1
    return r
end

local function tr(s)
    if type(s) == "string" and has_cjk(s) then
        local ok, r = pcall(translate, s)
        if ok and type(r) == "string" then return r end
    end
    return s
end

local Text = G.require("widgets/text")
if Text == nil or Text.SetString == nil then
    print("[Mod Harmony] translations: Text widget not found, nothing patched")
    return
end
if not Text._mh_translate then
    Text._mh_translate = true
    local old_set = Text.SetString
    Text.SetString = function(self, str, ...)
        return old_set(self, tr(str), ...)
    end
    for _, name in ipairs({ "SetTruncatedString", "SetMultilineTruncatedString" }) do
        local old = Text[name]
        if type(old) == "function" then
            Text[name] = function(self, str, ...)
                return old(self, tr(str), ...)
            end
        end
    end
end
G.ModHarmonyTranslate = tr
print("[Mod Harmony] translations: " .. #DATA .. " texts loaded (" .. #frags .. " phrases, " .. #singles .. " one-character words)")
