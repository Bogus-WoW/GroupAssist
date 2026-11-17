-- GroupAssist: Core.lua
--
-- TankAssist and HealAssist in one addon. The core holds what both need
-- (aura and spellbook reading, your role, settings, timers, slash commands)
-- and the two modules switch on by themselves from your role:
--
--   Tank tools (Tank.lua)    loose-mob marks on nameplates and the healer
--                            drinking / low-mana lines, while you tank
--   Healer tools (Heal.lua)  "Aggro on me!" while you heal
--   Always                   party buff bar (Blessings, Fortitude, Mark of the
--                            Wild...), your own buff/consumable icons (not
--                            while healing), regen countdown, drinking
--                            call-out, tank focus button in dungeons
--
-- /ga                 overview: role, settings and all commands
-- /ga role auto|tank|heal|dps   force a role (auto reads it from the game)
-- /ta ... and /ha ... still work for the tank and healer settings.

local addonName, ns = ...

ns.PREFIX = "|cff5fd0ffGroupAssist|r: "
function ns.Print(msg) print(ns.PREFIX .. msg) end

function ns.Plain(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end
local Plain = ns.Plain

-- Calls fn safely; secret results come back as nil.
function ns.Call(fn, ...)
	if not fn then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return Plain(a), Plain(b), Plain(c) end
end
local Call = ns.Call

-- Aura data can be secret (in combat, or other units); a refusal reads as nil.
function ns.SafeAura(unit, i)
	local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
	if ok then return a end
end

--------------------------------------------------------------------------
-- Spellbook (shared by both modules)
--------------------------------------------------------------------------

ns.known = {}

function ns.ReadSpellbook()
	local known = ns.known
	wipe(known)
	if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
		local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
		for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
			local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
			if info then
				for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
					local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
					if item and item.name and not item.isPassive then known[item.name] = item.spellID or true end
				end
			end
		end
	elseif GetNumSpellTabs then
		for tab = 1, GetNumSpellTabs() do
			local _, _, offset, num = GetSpellTabInfo(tab)
			for i = offset + 1, offset + num do
				local name = GetSpellBookItemName(i, BOOKTYPE_SPELL)
				if name then known[name] = true end
			end
		end
	end
end

function ns.SpellIcon(name)
	if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(name) end
	return select(3, GetSpellInfo(name))
end

--------------------------------------------------------------------------
-- Your role, worked out once and reused until something changes
--   tank: group role Tank, or Righteous Fury / Defensive Stance / Bear Form
--   heal: in a group, role Healer, or (no role) a healing class not in a
--         tanking or damage form
-- /ga role tank|heal|dps forces it; auto reads it from the game.
--------------------------------------------------------------------------

local TANK_AURAS = { ["Righteous Fury"] = true, ["Defensive Stance"] = true, ["Bear Form"] = true, ["Dire Bear Form"] = true }
local NOT_HEALING = { ["Righteous Fury"] = true, ["Bear Form"] = true, ["Dire Bear Form"] = true,
	["Cat Form"] = true, ["Defensive Stance"] = true, ["Shadowform"] = true }
local HEAL_CLASSES = { DRUID = true, PRIEST = true, PALADIN = true, SHAMAN = true }
ns.TANK_AURAS = TANK_AURAS

local roleCache, roleTime -- {tank, heal}, GetTime() when worked out

function ns.InvalidateRole() roleCache = nil end

local function PlayerAuraNames()
	local names = {}
	for i = 1, 40 do
		local a = ns.SafeAura("player", i)
		if not a then break end
		local n = Plain(a.name)
		if n then names[n] = true end
	end
	return names
end

local function TankForm()
	if not (GetShapeshiftForm and GetShapeshiftFormInfo) then return false end
	local form = Call(GetShapeshiftForm)
	if form and form > 0 then
		local ok, _, _, _, spellID = pcall(GetShapeshiftFormInfo, form)
		spellID = ok and Plain(spellID)
		local name = spellID and C_Spell and C_Spell.GetSpellName and Call(C_Spell.GetSpellName, spellID)
		return name and TANK_AURAS[name] or false
	end
	return false
end

local function WorkOutRole()
	local forced = ns.char and ns.char.role or "auto"
	if forced == "tank" then return { tank = true, heal = false } end
	if forced == "heal" then return { tank = false, heal = IsInGroup() } end
	if forced == "dps" then return { tank = false, heal = false } end
	local auras = PlayerAuraNames()
	local role = Call(UnitGroupRolesAssigned, "player")
	local tank = role == "TANK"
	if not tank and role ~= "HEALER" and role ~= "DAMAGER" then
		for n in pairs(auras) do if TANK_AURAS[n] then tank = true break end end
		if not tank then tank = TankForm() end
	end
	local heal = false
	if IsInGroup() and not tank then
		if role == "HEALER" then
			heal = true
		elseif role ~= "DAMAGER" and role ~= "TANK" then
			local _, class = UnitClass("player")
			heal = HEAL_CLASSES[class or ""] and true or false
			for n in pairs(auras) do if NOT_HEALING[n] then heal = false break end end
		end
	end
	return { tank = tank, heal = heal }
end

-- Re-checked at most once a second, or right away after a buff, form or
-- group change.
local function Role()
	local now = GetTime()
	if not roleCache or now - roleTime > 1 then
		roleCache, roleTime = WorkOutRole(), now
	end
	return roleCache
end
function ns.Tanking() return Role().tank end
function ns.Healing() return Role().heal end

--------------------------------------------------------------------------
-- Settings
--   GroupAssistChar = { role, tank = {...}, heal = {...} }  (per character)
--   GroupAssistDB   = { blessing = { [player] = "Kings" } }  (account)
-- On first load, settings from TankAssist/HealAssist are copied over.
--------------------------------------------------------------------------

local OLD = { "TankAssist", "HealAssist" }

local function Copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = Copy(v) end
	return out
end

local function IsLoaded(name)
	local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return f and f(name) and true or false
end

local function InitSettings()
	GroupAssistChar = GroupAssistChar or {}
	GroupAssistDB = GroupAssistDB or {}
	local char, acct = GroupAssistChar, GroupAssistDB
	-- bring over the old addons' settings, once
	if not char.migrated then
		if type(TankAssistChar) == "table" then char.tank = Copy(TankAssistChar) end
		if type(HealAssistChar) == "table" then char.heal = Copy(HealAssistChar) end
		char.migrated = (type(TankAssistChar) == "table" or type(HealAssistChar) == "table") and time() or true
	end
	if not acct.migrated and type(HealAssistDB) == "table" then
		acct.blessing = Copy(HealAssistDB.blessing)
		acct.migrated = time()
	end
	char.role = char.role or "auto"
	char.tank = char.tank or {}
	char.heal = char.heal or {}
	acct.blessing = acct.blessing or {}
	ns.char, ns.acct = char, acct
end

-- The old addons can't run next to this one (their bars would double up).
-- They're switched off for this character and you're asked to reload.
local function OldAddonsLoaded()
	local loaded = {}
	for _, name in ipairs(OLD) do
		if IsLoaded(name) then loaded[#loaded + 1] = name end
	end
	return loaded
end

StaticPopupDialogs["GROUPASSIST_RELOAD"] = {
	text = "GroupAssist replaces %s.\n\nYour settings have been copied over and the old addons are switched off. Reload now to finish?",
	button1 = RELOADUI or "Reload",
	button2 = LATER or "Later",
	OnAccept = function() ReloadUI() end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function RetireOld(loaded)
	local disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
	local me = UnitName("player")
	for _, name in ipairs(loaded) do
		if disable then
			if not pcall(disable, name, me) then pcall(disable, name) end
		end
	end
	local list = table.concat(loaded, " and ")
	ns.Print(("%s %s still loaded, so GroupAssist is waiting. They're switched off now: /reload to finish. "
		.. "You can delete their folders from Interface\\AddOns afterwards."):format(list, #loaded > 1 and "are" or "is"))
	StaticPopup_Show("GROUPASSIST_RELOAD", list)
end

--------------------------------------------------------------------------
-- Modules, events and timers
--------------------------------------------------------------------------

ns.modules = {} -- filled in by Tank.lua and Heal.lua: { name, Init, Build, OnEvent, Tick, FastTick, ... }

local function Each(method, ...)
	for _, m in ipairs(ns.modules) do
		if m[method] then
			local ok, err = pcall(m[method], ...)
			if not ok then ns.lastError = m.name .. "." .. method .. ": " .. tostring(err) end
		end
	end
end
ns.Each = Each

local EVENTS = {
	"PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_FOCUS_CHANGED",
	"PLAYER_REGEN_ENABLED", "SPELLS_CHANGED", "UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED",
	"BAG_UPDATE_DELAYED", "UNIT_INVENTORY_CHANGED", "PLAYER_EQUIPMENT_CHANGED", "UNIT_POWER_UPDATE",
	"UPDATE_SHAPESHIFT_FORM", "PLAYER_ROLES_ASSIGNED",
}

ns.ready = false

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, a, ...)
	if event == "ADDON_LOADED" then
		if a == addonName then InitSettings() end
		return
	end
	if event == "PLAYER_LOGIN" then
		local old = OldAddonsLoaded()
		if #old > 0 then RetireOld(old) return end
		ns.ready = true
		for _, e in ipairs(EVENTS) do pcall(self.RegisterEvent, self, e) end
		ns.ReadSpellbook()
		Each("Init")
		Each("Build")
		C_Timer.After(2, function() Each("Refresh") end)
		-- buffs run out on their own, and drinking/mana lines change: every 2 s
		C_Timer.NewTicker(2, function() Each("Tick") end)
		-- loose-mob marks and the aggro call-out: 4 times a second, each one
		-- only does work while you're tanking or healing
		C_Timer.NewTicker(0.25, function() Each("FastTick") end)
		return
	end
	if not ns.ready then return end
	if event == "SPELLS_CHANGED" then ns.ReadSpellbook() end
	if (event == "UNIT_AURA" and a == "player") or event == "UPDATE_SHAPESHIFT_FORM"
		or event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
		ns.InvalidateRole()
	end
	Each("OnEvent", event, a, ...)
end)

--------------------------------------------------------------------------
-- Slash commands: /ga for everything, /ta and /ha for each module
--------------------------------------------------------------------------

local function ModuleByName(name)
	for _, m in ipairs(ns.modules) do if m.name == name then return m end end
end

local function Overview()
	local r = Role()
	ns.Print(("role: %s%s. Tank tools %s, healer tools %s."):format(
		r.tank and "tank" or (r.heal and "healer" or "neither tank nor healer"),
		ns.char.role ~= "auto" and (" (forced: /ga role auto to undo)") or " (read from the game)",
		r.tank and "|cff40ff40on|r" or "|cff888888off|r", r.heal and "|cff40ff40on|r" or "|cff888888off|r"))
	print("   /ga role auto|tank|heal|dps, /ga unlock | lock (moves every bar)")
	for _, m in ipairs(ns.modules) do
		if m.Help then m.Help() end
	end
	if ns.lastError then print("   last error: " .. ns.lastError) end
end

local function Guard(fn)
	return function(msg)
		if not ns.ready then
			ns.Print("waiting for a /reload (TankAssist or HealAssist is still loaded).")
			return
		end
		fn(msg or "")
	end
end

SLASH_GROUPASSIST1 = "/ga"
SLASH_GROUPASSIST2 = "/groupassist"
SlashCmdList.GROUPASSIST = Guard(function(msg)
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "role" then
		local m = rest:lower()
		if m == "healer" then m = "heal" end
		if m == "auto" or m == "tank" or m == "heal" or m == "dps" then ns.char.role = m end
		ns.InvalidateRole()
		ns.Print("role: " .. ns.char.role .. ". Usage: /ga role auto|tank|heal|dps")
		Each("Refresh")
	elseif cmd == "unlock" or cmd == "lock" then
		Each("SetLocked", cmd == "lock")
		ns.Print(cmd == "lock" and "locked." or "drag the coloured handles to move the bars. /ga lock when done.")
	elseif cmd == "tank" or cmd == "healer" then
		-- /ga tank <name> and /ga healer <name> go to the module that uses them
		local m = ModuleByName(cmd == "tank" and "Heal" or "Tank")
		if m then m.Slash(cmd .. " " .. rest) end
	else
		Overview()
	end
end)

SLASH_GROUPASSISTTANK1 = "/ta"
SLASH_GROUPASSISTTANK2 = "/tankassist"
SlashCmdList.GROUPASSISTTANK = Guard(function(msg)
	local m = ModuleByName("Tank")
	if m then m.Slash(msg) end
end)

SLASH_GROUPASSISTHEAL1 = "/ha"
SLASH_GROUPASSISTHEAL2 = "/healassist"
SlashCmdList.GROUPASSISTHEAL = Guard(function(msg)
	local m = ModuleByName("Heal")
	if m then m.Slash(msg) end
end)
