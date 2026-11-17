-- GroupAssist: Heal.lua (was HealAssist)
--
--   * Party buff bar: one icon for the next party member (you included)
--     missing one of your buffs (or with under 3 min left; 30 s for
--     Blessings). Left-click casts it, then it moves on. Out of combat only.
--       Druid:   Mark of the Wild on everyone, Thorns on the tank
--       Priest:  Fortitude on everyone, Divine Spirit on mana users,
--                Shadow Protection if you turn it on
--       Mage:    Arcane Intellect on mana users
--       Paladin: one Blessing each, picked by class; right-click to choose
--   * Mana regen countdown after you spend mana (the five second rule)
--   * Drinking call-out in party chat when you sit down to drink
--   * Focus the tank: a "Focus: <tank>" button in dungeons
--     (/click GroupAssistFocusButton to bind it)
--   * "Aggro on me!" in party chat, while you heal
--
-- /ha tank <name> | auto, /ha drink on|off, /ha drinkmsg <text>,
-- /ha aggro on|off, /ha aggrocheck, /ha shadowprot on|off, /ha unskip

local addonName, ns = ...

local ICON = 30
local FSR = 5              -- seconds without spending mana before regen resumes
local REFRESH_LONG = 180   -- long buffs: suggest again with less than this left
local REFRESH_SHORT = 30   -- short buffs (Blessings): ...or this
local MANA_CLASSES = { PRIEST = true, MAGE = true, WARLOCK = true, SHAMAN = true, PALADIN = true, DRUID = true, HUNTER = true }

local Print, Plain, Call = ns.Print, ns.Plain, ns.Call
local M = { name = "Heal" }
ns.modules[#ns.modules + 1] = M
local db       -- GroupAssistChar.heal (per character)
local acct     -- GroupAssistDB (account: per-player Blessing choices)
local skipped = {} -- this session: [unitName .. ":" .. key] or [key] = true

--------------------------------------------------------------------------
-- Auras
--------------------------------------------------------------------------

local SafeAura = ns.SafeAura

-- name -> { mine, left, duration } for one unit; nil if it can't be read
local function UnitBuffs(unit)
	local out, now = {}, GetTime()
	for i = 1, 40 do
		local a = SafeAura(unit, i)
		if not a then break end
		local name = Plain(a.name)
		if name then
			local exp, dur = Plain(a.expirationTime), Plain(a.duration)
			-- mine = true/false, or nil when the caster can't be read
			local src = Plain(a.sourceUnit)
			local mine
			if src ~= nil then mine = (src == "player") end
			local cur = out[name]
			if not cur or mine then
				out[name] = { mine = mine, left = (exp and exp > 0) and (exp - now) or nil, duration = dur }
			end
		end
	end
	return out
end

local known = ns.known
local SpellIcon = ns.SpellIcon

local function InRange(spell, unit)
	local r
	if C_Spell and C_Spell.IsSpellInRange then
		r = Call(C_Spell.IsSpellInRange, spell, unit)
	elseif IsSpellInRange then
		r = Call(IsSpellInRange, spell, unit)
	end
	if r == nil then return true end -- can't tell (e.g. yourself): assume yes
	return r == true or r == 1
end

--------------------------------------------------------------------------
-- Group and tank
--------------------------------------------------------------------------

local function GroupUnits()
	local units = { "player" }
	if not IsInRaid() then
		for i = 1, 4 do
			if UnitExists("party" .. i) then units[#units + 1] = "party" .. i end
		end
	end
	return units
end

local TANK_AURAS = ns.TANK_AURAS

-- unit token of the tank (not you), or nil
local function FindTank()
	local units = {}
	for i = 1, 4 do
		if UnitExists("party" .. i) then units[#units + 1] = "party" .. i end
	end
	if db.tank and db.tank ~= "auto" then
		for _, u in ipairs(units) do
			if Call(UnitName, u) == db.tank then return u end
		end
	end
	for _, u in ipairs(units) do
		if Call(UnitGroupRolesAssigned, u) == "TANK" then return u end
	end
	for _, u in ipairs(units) do
		local buffs = UnitBuffs(u)
		for name in pairs(buffs) do
			if TANK_AURAS[name] then return u end
		end
	end
	return nil
end

-- For buffs: the tank may be you (Thorns on yourself, a tank Blessing).
local function BuffTank()
	if ns.Tanking() then return "player" end
	return FindTank()
end

--------------------------------------------------------------------------
-- Buffs you can give
--------------------------------------------------------------------------

-- who = "all" | "mana" | "tank"; same = buffs that already cover it
local CLASS_BUFFS = {
	DRUID = {
		{ key = "motw", spell = "Mark of the Wild", who = "all", same = { "Gift of the Wild" } },
		{ key = "thorns", spell = "Thorns", who = "tank" },
	},
	PRIEST = {
		{ key = "fort", spell = "Power Word: Fortitude", who = "all", same = { "Prayer of Fortitude" } },
		{ key = "spirit", spell = "Divine Spirit", who = "mana", same = { "Prayer of Spirit" } },
		{ key = "shadow", spell = "Shadow Protection", who = "all", same = { "Prayer of Shadow Protection" }, option = "shadowprot" },
	},
	MAGE = {
		{ key = "ai", spell = "Arcane Intellect", who = "mana", same = { "Arcane Brilliance" } },
	},
	PALADIN = {
		{ key = "blessing", blessing = true, who = "all" },
	},
}

-- Blessing order per class (first one you know and nobody else has given wins)
local BLESSING_PREFS = {
	WARRIOR = { "Might", "Kings" },
	ROGUE = { "Might", "Kings" },
	HUNTER = { "Kings", "Wisdom", "Might" },
	MAGE = { "Wisdom", "Kings" },
	WARLOCK = { "Wisdom", "Kings" },
	PRIEST = { "Wisdom", "Kings" },
	SHAMAN = { "Wisdom", "Kings", "Might" },
	DRUID = { "Wisdom", "Kings" },          -- caster/healer form
	DRUID_FERAL = { "Might", "Kings" },     -- in Cat or Bear Form
	PALADIN = { "Wisdom", "Kings", "Might" }, -- best guess: can't tell Holy from Ret
	TANK = { "Kings", "Sanctuary", "Might" },
}
ns.BLESSING_PREFS = BLESSING_PREFS
local BLESSINGS = { "Might", "Wisdom", "Kings", "Salvation", "Sanctuary", "Light" }

local function HasBlessingType(buffs, t)
	local b = buffs["Blessing of " .. t] or buffs["Greater Blessing of " .. t]
	return b
end

-- The Blessing type to give this unit, or nil if it's covered.
-- Returns type, reason ("missing" / "expiring" / "replace")
local function PickBlessing(unit, buffs, isTank)
	local _, class = UnitClass(unit)
	local name = Call(UnitName, unit)
	local list
	local override = name and acct.blessing[name]
	if override then
		list = { override }
	elseif isTank then
		list = BLESSING_PREFS.TANK
	elseif class == "DRUID" and (buffs["Cat Form"] or buffs["Bear Form"] or buffs["Dire Bear Form"]) then
		list = BLESSING_PREFS.DRUID_FERAL
	else
		list = BLESSING_PREFS[class] or { "Kings", "Might", "Wisdom" }
	end
	-- One of your Blessings already up and fresh: fine as long as it's the
	-- one we'd choose, or nothing better is free.
	for _, t in ipairs(list) do
		if known["Blessing of " .. t] then
			local b = HasBlessingType(buffs, t)
			if not b then
				return t, "missing"
			elseif b.mine ~= false then
				-- yours (or can't tell): refresh when it runs low
				if b.left and b.left < REFRESH_SHORT then return t, "expiring" end
				return nil
			end
			-- another paladin's: try the next type
		end
	end
	return nil
end

local function Threshold(b)
	if b and b.duration and b.duration > 0 and b.duration <= 600 then return REFRESH_SHORT end
	return REFRESH_LONG
end

-- Every (buff, unit) still needed, in group order. Each entry:
-- { unit, name, class, spell, key, why }
local function Needed()
	local _, myClass = UnitClass("player")
	local list = CLASS_BUFFS[myClass]
	local out = {}
	if not list then return out end
	local tank = BuffTank()
	for _, u in ipairs(GroupUnits()) do
		local name = Call(UnitName, u)
		local _, class = UnitClass(u)
		if name and not Call(UnitIsDeadOrGhost, u) and Call(UnitIsConnected, u) ~= false then
			local buffs = UnitBuffs(u)
			local isTank = tank and Call(UnitIsUnit, u, tank)
			for _, b in ipairs(list) do
				local applies = b.who == "all" or (b.who == "mana" and MANA_CLASSES[class or ""])
					or (b.who == "tank" and isTank)
				if b.option and not db[b.option] then applies = false end
				if applies and not skipped[b.key] and not skipped[name .. ":" .. b.key] then
					if b.blessing then
						local t, why = PickBlessing(u, buffs, isTank)
						if t then
							out[#out + 1] = { unit = u, name = name, class = class, spell = "Blessing of " .. t, key = b.key, why = why, blessing = t }
						end
					elseif known[b.spell] then
						local have = buffs[b.spell]
						local covered = false
						for _, s in ipairs(b.same or {}) do
							if buffs[s] then covered = true end
						end
						local why
						if not have and not covered then
							why = "missing"
						elseif have and have.mine ~= false and have.left and have.left < Threshold(have) then
							why = "expiring"
						end
						if why then
							out[#out + 1] = { unit = u, name = name, class = class, spell = b.spell, key = b.key, why = why }
						end
					end
				end
			end
		end
	end
	return out
end

-- Does the party bar handle this for your class? Tank.lua asks so your own
-- buff icons don't repeat it. what = "blessing" or a list of spell names.
function ns.PartyCovers(what)
	if not what then return false end
	local _, class = UnitClass("player")
	for _, b in ipairs(CLASS_BUFFS[class] or {}) do
		if not (b.option and not (db and db[b.option])) then
			if what == "blessing" then
				if b.blessing then return true end
			elseif type(what) == "table" and b.spell then
				for _, s in ipairs(what) do if s == b.spell then return true end end
			end
		end
	end
	return false
end

--------------------------------------------------------------------------
-- The buff bar: one secure button showing the next buff to cast
--------------------------------------------------------------------------

local bar, handle, button, label, focusBtn, fsrFrame, fsrHandle
local pending = false
local current -- the suggestion on the button
local Update -- defined below; forward-declared so the menu callbacks reach it

local function ClassColor(class, text)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	return c and ("|c" .. c.colorStr .. text .. "|r") or text
end

local function ShowMenu()
	local s = current
	if not s then return end
	local function Skip(k) skipped[k] = true; Update() end
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(button, function(_, root)
			root:CreateTitle(s.spell .. " on " .. s.name)
			if s.blessing then
				for _, t in ipairs(BLESSINGS) do
					if known["Blessing of " .. t] then
						root:CreateButton((acct.blessing[s.name] == t and "* " or "") .. "Always " .. t .. " for " .. s.name, function()
							acct.blessing[s.name] = t
							Update()
						end)
					end
				end
				if acct.blessing[s.name] then
					root:CreateButton("Automatic for " .. s.name, function()
						acct.blessing[s.name] = nil
						Update()
					end)
				end
			end
			root:CreateButton("Skip " .. s.name .. " this session", function() Skip(s.name .. ":" .. s.key) end)
			root:CreateButton("Skip " .. (s.blessing and "Blessings" or s.spell) .. " this session", function() Skip(s.key) end)
		end)
	else
		Skip(s.name .. ":" .. s.key)
		Print(("skipped %s on %s this session. /ha unskip brings it back."):format(s.spell, s.name))
	end
end

function Update() -- fills in the forward declaration above ShowMenu
	if not bar then return end
	if InCombatLockdown() then pending = true return end
	pending = false
	local list = Needed()
	-- first one in range; the rest are counted
	local pick
	for _, s in ipairs(list) do
		if InRange(s.spell, s.unit) then pick = s break end
	end
	current = pick
	if pick then
		button:SetAttribute("type1", "spell")
		button:SetAttribute("spell1", pick.spell)
		button:SetAttribute("unit1", pick.unit)
		button.icon:SetTexture(SpellIcon(pick.spell) or 134400)
		local more = #list - 1
		label:SetText(ClassColor(pick.class, pick.name) .. (pick.why == "expiring" and " |cffffd100(expiring)|r" or "")
			.. (more > 0 and ("|cff888888  +" .. more .. "|r") or ""))
		button:Show()
	else
		button:SetAttribute("type1", nil)
		button:Hide()
		label:SetText(#list > 0 and ("|cff888888" .. #list .. " to buff, out of range|r") or "")
	end
end

--------------------------------------------------------------------------
-- Focus the tank (one click per dungeon)
--------------------------------------------------------------------------

local focusUnit

local function UpdateFocus()
	if not focusBtn then return end
	if InCombatLockdown() then pending = true return end
	local inst, kind = IsInInstance()
	local tank = (inst and kind == "party") and FindTank() or nil
	if tank and not Call(UnitIsUnit, "focus", tank) then
		focusUnit = tank
		focusBtn:SetAttribute("type1", "focus")
		focusBtn:SetAttribute("unit1", tank)
		local _, class = UnitClass(tank)
		focusBtn.text:SetText("Focus: " .. ClassColor(class, Call(UnitName, tank) or "tank"))
		focusBtn:Show()
	else
		focusUnit = nil
		focusBtn:SetAttribute("type1", nil)
		focusBtn:Hide()
	end
end

--------------------------------------------------------------------------
-- Your mana, when the client lets addons read it (it often doesn't:
-- current mana can be a "secret" value). nil, nil when it can't be read.
--------------------------------------------------------------------------

local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0

local function ReadMana()
	local cur, max = Call(UnitPower, "player", MANA), Call(UnitPowerMax, "player", MANA)
	if type(cur) == "number" and type(max) == "number" and max > 0 then return cur, max end
end

--------------------------------------------------------------------------
-- Mana regen countdown (the "five second rule")
--------------------------------------------------------------------------

local fsrStart

local function SpellCostsMana(spellID)
	if not (C_Spell and C_Spell.GetSpellPowerCost) then return true end
	local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
	if not ok or type(costs) ~= "table" then return true end
	for _, c in ipairs(costs) do
		local t, cost = Plain(c.type), Plain(c.cost)
		if t == 0 and cost and cost > 0 then return true end
	end
	return false
end

-- Runs every frame only while the countdown is up: StartFSR attaches it and
-- it detaches itself when the countdown ends.
local function FSRUpdate(self)
	if not db.locked then return end -- unlocked: leave the preview up for placing
	local left = fsrStart and (FSR - (GetTime() - fsrStart)) or 0
	local cur, max = ReadMana()
	if left <= 0 or (cur and max and cur >= max) then
		fsrStart = nil
		self.bar:Hide()
		self:SetScript("OnUpdate", nil)
		return
	end
	self.bar:SetValue(left)
	self.bar.text:SetText(("Regen in %.1f"):format(left))
	self.bar:Show()
end

--------------------------------------------------------------------------
-- Drinking call-out: "Drinking" in party chat when you sit down to drink,
-- once per drink, out of combat, in a group. (No time estimate: this client
-- doesn't let addons read your current mana.)
--------------------------------------------------------------------------

local DRINKS = { ["Drink"] = true, ["Food & Drink"] = true, ["Refreshment"] = true }
local drinking = false

local function HasDrink()
	for i = 1, 40 do
		local a = SafeAura("player", i)
		if not a then break end
		local name = Plain(a.name)
		if name and (DRINKS[name] or name:find("^Drink")) then return true end
	end
	return false
end

local function Channel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then return "INSTANCE_CHAT" end
	if IsInGroup() then return "PARTY" end
end

local function CheckDrink()
	if not HasDrink() then drinking = false return end
	if drinking then return end
	drinking = true
	if InCombatLockdown() or not db.drink then return end
	local ch = Channel()
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if ch and send then pcall(send, db.drinkMsg or "Drinking", ch) end
end

--------------------------------------------------------------------------
-- "Aggro on me!" call-out
--   While you heal in a group, mobs whose aggro you hold (read from enemy
--   nameplates) are called out in party chat after 1 second, e.g.
--   "Aggro on me! Defias Pillager x2, Defias Evoker". While any are still on
--   you it repeats every 6 seconds with the current list, so the tank knows
--   they haven't been picked up yet. /ha aggro on | off
--------------------------------------------------------------------------

local AGGRO_CONFIRM = 1  -- seconds a mob must stay on you before it's called out
local AGGRO_REPEAT = 6   -- seconds between messages while mobs stay on you
local Healing = ns.Healing

-- Names of the enemies whose aggro you hold; unnamed = how many couldn't be named
-- One readable fact about a value: "secret" when the client hides it.
local function Peek(fn, ...)
	if not fn then return nil, "missing" end
	local ok, v = pcall(fn, ...)
	if not ok then return nil, "error" end
	if issecretvalue and issecretvalue(v) then return nil, "secret" end
	return v, "ok"
end

-- Is this nameplate an enemy we should look at? Tolerates hidden answers.
local function Hostile(u)
	local atk, how = Peek(UnitCanAttack, "player", u)
	if how == "ok" then return atk and true or false end
	-- can't tell directly: anything not friendly counts
	local friend = Peek(UnitIsFriend, "player", u)
	return not friend
end

-- On you: you hold its aggro (threat level 2-3). When that's hidden (as in
-- dungeons on this client), fall back to the mob attacking you: it's in
-- combat and its target is you. The 1-second confirmation filters out
-- casters briefly targeting you.
local function OnMe(u)
	local sit, how = Peek(UnitThreatSituation, "player", u)
	if how == "ok" and sit ~= nil then return sit == 2 or sit == 3 end
	local onMe = Peek(UnitIsUnit, u .. "target", "player")
	if not onMe then return false end
	local combat, chow = Peek(UnitAffectingCombat, u)
	return chow ~= "ok" or combat and true or false
end

local function MobsOnMe()
	local names, unnamed = {}, 0
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return names, 0 end
	for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
		local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
		if u and Hostile(u) and not Peek(UnitIsDead, u) and OnMe(u) then
			local name = Peek(UnitName, u)
			if name then names[#names + 1] = name else unnamed = unnamed + 1 end
		end
	end
	return names, unnamed
end

-- /ha aggrocheck: what the client lets GroupAssist read about the enemies
-- on your screen (use it mid-fight in a dungeon)
local function AggroCheck()
	local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates() or {}
	Print(("aggro check: %d nameplate(s), in combat: %s, healing: %s, group: %s"):format(#plates,
		InCombatLockdown() and "yes" or "no", Healing() and "yes" or "no", IsInGroup() and "yes" or "no"))
	local shown = 0
	for _, plate in ipairs(plates) do
		local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
		if u and shown < 6 then
			shown = shown + 1
			local function F(fn, ...) local v, how = Peek(fn, ...) return how == "ok" and tostring(v) or how end
			print(("   %s: name=%s attackable=%s threat=%s its target is me=%s in combat=%s -> on me: %s"):format(u,
				F(UnitName, u), F(UnitCanAttack, "player", u), F(UnitThreatSituation, "player", u),
				F(UnitIsUnit, u .. "target", "player"), F(UnitAffectingCombat, u), (Hostile(u) and OnMe(u)) and "YES" or "no"))
		end
	end
	if #plates == 0 then print("   no nameplates: turn enemy nameplates on (V)") end
end

-- "Defias Pillager x2, Defias Evoker" (most first)
local function AggroText(names, unnamed)
	local count, order = {}, {}
	for _, n in ipairs(names) do
		if not count[n] then order[#order + 1] = n end
		count[n] = (count[n] or 0) + 1
	end
	table.sort(order, function(a, b)
		if count[a] ~= count[b] then return count[a] > count[b] end
		return a < b
	end)
	local parts = {}
	for _, n in ipairs(order) do
		parts[#parts + 1] = count[n] > 1 and (n .. " x" .. count[n]) or n
	end
	if #parts == 0 then
		return ("(%d mob%s)"):format(unnamed, unnamed == 1 and "" or "s")
	end
	if unnamed > 0 then parts[#parts + 1] = ("+%d more"):format(unnamed) end
	return table.concat(parts, ", ")
end

local aggroSince, aggroLastSent

local function CheckAggro()
	if not InCombatLockdown() then aggroLastSent = nil end -- a new fight starts fresh
	if not (db.aggro and InCombatLockdown() and Healing()) then
		aggroSince = nil
		return
	end
	local names, unnamed = MobsOnMe()
	if #names + unnamed == 0 then
		aggroSince = nil
		return
	end
	local now = GetTime()
	aggroSince = aggroSince or now
	if now - aggroSince < AGGRO_CONFIRM then return end
	if aggroLastSent and now - aggroLastSent < AGGRO_REPEAT then return end
	local ch = Channel()
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if ch and send then
		pcall(send, "Aggro on me! " .. AggroText(names, unnamed), ch)
		aggroLastSent = now
	end
end

--------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------

local function Movable(frame, posKey, defaultPoint)
	local p = db[posKey]
	if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint(unpack(defaultPoint)) end
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	local h = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	h:SetSize(60, 12)
	h:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
	h:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
	h:SetBackdropColor(0.25, 1, 0.5, 0.8)
	h:EnableMouse(true)
	h:RegisterForDrag("LeftButton")
	h:SetScript("OnDragStart", function() if not InCombatLockdown() then frame:StartMoving() end end)
	h:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local a, _, rp, x, y = frame:GetPoint()
		db[posKey] = { a, rp, x, y }
	end)
	local t = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	t:SetPoint("CENTER")
	t:SetText("|cff000000drag|r")
	h:SetShown(not db.locked)
	return h
end

local function Build()
	-- buff bar
	bar = CreateFrame("Frame", "GroupAssistBar", UIParent, "SecureHandlerStateTemplate")
	bar:SetSize(ICON, ICON)
	handle = Movable(bar, "barPos", { "CENTER", UIParent, "CENTER", -200, -160 })
	RegisterStateDriver(bar, "visibility", "[combat] hide; show")

	button = CreateFrame("Button", "GroupAssistBuffButton", bar, "SecureActionButtonTemplate")
	button:SetSize(ICON, ICON)
	button:SetPoint("LEFT")
	button:RegisterForClicks("AnyUp", "AnyDown")
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	button:HookScript("OnClick", function(_, b, down)
		if b == "RightButton" and not down then ShowMenu() end
	end)
	button:SetScript("OnEnter", function(self)
		local s = current
		if not s then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(s.spell .. " on " .. s.name, 1, 1, 1)
		GameTooltip:AddLine(s.why == "expiring" and "Running out" or "Missing", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Left-click: cast", 0.6, 0.8, 1)
		GameTooltip:AddLine(s.blessing and "Right-click: pick this player's Blessing, or skip" or "Right-click: skip", 0.6, 0.8, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:Hide()

	label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", bar, "LEFT", ICON + 6, 0)
	label:SetJustifyH("LEFT")

	-- focus button, under the buff icon
	focusBtn = CreateFrame("Button", "GroupAssistFocusButton", bar, "SecureActionButtonTemplate, BackdropTemplate")
	focusBtn:SetSize(130, 18)
	focusBtn:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
	focusBtn:RegisterForClicks("AnyUp", "AnyDown")
	focusBtn:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8", edgeFile = "Interface/Buttons/WHITE8X8", edgeSize = 1 })
	focusBtn:SetBackdropColor(0, 0, 0, 0.6)
	focusBtn:SetBackdropBorderColor(0.25, 1, 0.5, 0.8)
	focusBtn.text = focusBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	focusBtn.text:SetPoint("CENTER")
	focusBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("Click to focus the tank", 1, 1, 1)
		GameTooltip:AddLine("To use a key instead, make a macro: /click GroupAssistFocusButton", 0.6, 0.8, 1, true)
		GameTooltip:Show()
	end)
	focusBtn:SetScript("OnLeave", GameTooltip_Hide)
	focusBtn:Hide()

	-- regen countdown
	fsrFrame = CreateFrame("Frame", "GroupAssistRegen", UIParent)
	fsrFrame:SetSize(110, 12)
	fsrHandle = Movable(fsrFrame, "fsrPos", { "CENTER", UIParent, "CENTER", 0, -220 })
	local sb = CreateFrame("StatusBar", nil, fsrFrame)
	sb:SetAllPoints()
	sb:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
	sb:SetStatusBarColor(0.3, 0.55, 1, 0.8)
	sb:SetMinMaxValues(0, FSR)
	local bg = sb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.5)
	sb.text = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sb.text:SetPoint("CENTER")
	sb:Hide()
	fsrFrame.bar = sb
end

local function StartFSR()
	fsrStart = GetTime()
	if fsrFrame then fsrFrame:SetScript("OnUpdate", FSRUpdate) end
end

local function SetLocked(locked)
	db.locked = locked
	handle:SetShown(not locked)
	fsrHandle:SetShown(not locked)
	if not locked then
		-- show the regen bar so it can be placed
		fsrFrame.bar:SetValue(3)
		fsrFrame.bar.text:SetText("Regen in 3.0")
		fsrFrame.bar:Show()
	elseif fsrStart then
		fsrFrame:SetScript("OnUpdate", FSRUpdate) -- carry on with a running countdown
	else
		fsrFrame.bar:Hide() -- hide the placing preview
	end
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

local function Help()
	local _, class = UnitClass("player")
	print("   |cff40ff80Party|r: buff bar, regen timer, drinking call-out, tank focus; \"Aggro on me!\" while you heal.")
	print(("   tank: %s (now: %s), drinking call-out: %s (\"%s\"), aggro call-out: %s, Shadow Protection: %s"):format(
		db.tank or "auto", (FindTank() and Call(UnitName, FindTank())) or "none found", db.drink and "on" or "off",
		db.drinkMsg or "Drinking", db.aggro and "on" or "off", db.shadowprot and "on" or "off"))
	if class == "PALADIN" then
		local parts = {}
		for n, t in pairs(acct.blessing) do parts[#parts + 1] = n .. "=" .. t end
		print("   Blessings picked by hand: " .. (#parts > 0 and table.concat(parts, ", ") or "none (right-click the icon to pick)"))
	end
	print("   /ha tank <name> | auto, /ha drink on | off, /ha drinkmsg <text>,")
	print("   /ha aggro on | off, /ha aggrocheck (mid-fight, if the aggro call-out stays quiet),")
	print("   /ha shadowprot on | off, /ha unskip.  Focus key: macro /click GroupAssistFocusButton")
end

function M.Slash(msg)
	msg = msg or ""
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	-- "aggro check", "aggro-check", "check" all mean aggrocheck
	local squashed = msg:lower():gsub("[%s%-_/]", "")
	if squashed == "aggrocheck" or squashed == "check" or squashed == "aggrotest" then cmd = "aggrocheck" end
	if cmd == "unlock" then
		SetLocked(false); Print("drag the green handles to move the buff bar and the regen timer. /ha lock when done.")
	elseif cmd == "lock" then
		SetLocked(true); Print("locked.")
	elseif cmd == "tank" then
		db.tank = (rest == "" or rest:lower() == "auto") and "auto" or rest
		local t = FindTank()
		Print("tank: " .. db.tank .. (t and (" (found: " .. (Call(UnitName, t) or "?") .. ")") or " (nobody found yet)"))
		Update(); UpdateFocus()
	elseif cmd == "drink" then
		db.drink = rest:lower() ~= "off"
		Print("drinking call-out " .. (db.drink and "on." or "off."))
	elseif cmd == "drinkmsg" then
		if rest ~= "" then db.drinkMsg = rest end
		Print(("party chat will say: \"%s\""):format(db.drinkMsg or "Drinking"))
	elseif cmd == "aggrocheck" then
		AggroCheck()
	elseif cmd == "aggro" then
		db.aggro = rest:lower() ~= "off"
		Print("\"Aggro on me!\" call-out " .. (db.aggro and "on (in a group, while healing)." or "off."))
	elseif cmd == "shadowprot" then
		db.shadowprot = rest:lower() ~= "off"
		Print("Shadow Protection " .. (db.shadowprot and "included." or "left out."))
		Update()
	elseif cmd == "unskip" then
		wipe(skipped); Print("nothing is skipped now."); Update()
	else
		Help()
	end
end


M.Help = Help

--------------------------------------------------------------------------
-- Hooks for the core
--------------------------------------------------------------------------

function M.Init()
	db, acct = ns.char.heal, ns.acct
	if db.locked == nil then db.locked = true end
	if db.drink == nil then db.drink = true end
	if db.aggro == nil then db.aggro = true end
	db.tank = db.tank or "auto"
end

M.Build = Build
function M.Refresh() Update(); UpdateFocus() end
M.SetLocked = SetLocked

function M.Tick()
	if not InCombatLockdown() then Update() end
end

function M.FastTick() CheckAggro() end

function M.OnEvent(event, a, b, c)
	if not bar then return end
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if a == "player" and c and SpellCostsMana(c) then StartFSR() end
	elseif event == "UNIT_AURA" then
		if a == "player" then CheckDrink() end
		if a == "player" or (a and a:find("^party")) then
			if not InCombatLockdown() then Update() else pending = true end
		end
	elseif event == "SPELLS_CHANGED" then
		Update()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pending then Update(); UpdateFocus() end
	elseif event == "PLAYER_FOCUS_CHANGED" or event == "GROUP_ROSTER_UPDATE"
		or event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
		UpdateFocus()
		if event ~= "PLAYER_FOCUS_CHANGED" then Update() end
	elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "PLAYER_ROLES_ASSIGNED" then
		if not InCombatLockdown() then Update() else pending = true end
	end
end
