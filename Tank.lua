-- GroupAssist: Tank.lua (was TankAssist)
--
-- Your own buffs: a row of icons for buffs you're missing (class self-buffs
-- the party bar doesn't already cover, Righteous Fury, food, weapon oils
-- and stones, elixirs, scrolls, flasks). Hidden while you heal.
-- Left-click casts/uses it, right-click ignores it for this session.
--
-- While you tank:
--   * your healer drinking: big green line with their mana %, always on top;
--     healer under 40% mana out of combat: red line; others drinking: grey
--   * loose mobs: red "!!" + outline on a mob attacking someone else, orange
--     "!" + outline when someone is about to pull a mob off you
--
-- /ta blessing Kings, Sanctuary, Might    Blessing order for your own icon
-- /ta aura Retribution, Devotion          Aura order
-- /ta healer <name> | auto, /ta unignore, /ta loose auto|on|off,
-- /ta buffs auto|on|off  (auto = hidden while you heal)

local addonName, ns = ...

local ICON = 26
local MIN_DURATION = 300   -- seconds; shorter buffs (potions) are ignored
local EXPIRING = 30        -- a buff with less than this left counts as missing
local HEALER_MANA = 0.40

local Print, Plain = ns.Print, ns.Plain
local M = { name = "Tank" }
ns.modules[#ns.modules + 1] = M

local db           -- GroupAssistChar.tank (per character)
local ignored = {} -- this session only

--------------------------------------------------------------------------
-- Class buffs
--------------------------------------------------------------------------

-- kind "own": you should have one buff of this group cast by YOU. Others'
--   buffs of the same type block that choice, so the next preference is used.
-- kind "self": a single buff that should be up.
local CLASS_BUFFS = {
	PALADIN = {
		{ key = "aura", kind = "own", prefKey = "auras", match = " Aura$",
		  default = { "Retribution Aura", "Devotion Aura", "Concentration Aura", "Sanctity Aura",
			"Fire Resistance Aura", "Frost Resistance Aura", "Shadow Resistance Aura" } },
		{ key = "blessing", kind = "own", prefKey = "blessings", match = "Blessing of",
		  default = { "Blessing of Kings", "Blessing of Sanctuary", "Blessing of Might", "Blessing of Wisdom", "Blessing of Light" } },
		{ key = "rf", kind = "self", spells = { "Righteous Fury" }, tankOnly = true },
	},
	PRIEST = {
		{ key = "fort", kind = "self", spells = { "Power Word: Fortitude" } },
		{ key = "innerfire", kind = "self", spells = { "Inner Fire" } },
		{ key = "spirit", kind = "self", spells = { "Divine Spirit" } },
		{ key = "shadowprot", kind = "self", spells = { "Shadow Protection" } },
	},
	MAGE = {
		{ key = "ai", kind = "self", spells = { "Arcane Intellect" } },
		{ key = "armor", kind = "self", spells = { "Mage Armor", "Ice Armor", "Frost Armor", "Molten Armor" } },
	},
	DRUID = {
		{ key = "motw", kind = "self", spells = { "Mark of the Wild" } },
		{ key = "thorns", kind = "self", spells = { "Thorns" } },
	},
	WARLOCK = {
		{ key = "armor", kind = "self", spells = { "Fel Armor", "Demon Armor", "Demon Skin" } },
	},
	SHAMAN = {
		{ key = "shield", kind = "self", spells = { "Lightning Shield", "Water Shield" } },
	},
}

-- Buffs that can't be up together (casting one replaces/is blocked by the other)
local CONFLICTS = {
	["Blessing of Kings"] = { "Boosted Stats", "Fish Bowl" },
	["Greater Blessing of Kings"] = { "Boosted Stats", "Fish Bowl" },
	["Stamina"] = { "Power Word: Fortitude", "Prayer of Fortitude" },
	["Intellect"] = { "Arcane Intellect", "Arcane Brilliance" },
	["Spirit"] = { "Divine Spirit", "Prayer of Spirit" },
	["Armor"] = { "Mark of the Wild", "Gift of the Wild" },
}

-- Bag items whose buff isn't useful for tanking
local SKIP_WORDS = { "teaches you", "returns you", "teleport", "hearth", "summon", "breath", "swim", "underwater", "water walk", "fishing", "detect", "invisib",
	"disguise", "costume", "transform", "lure", "mount", "fall", "levitat", "speed" }

--------------------------------------------------------------------------
-- What's on you
--------------------------------------------------------------------------

-- Aura data can be "secret" (in combat, or for other units in some
-- situations); touching it then throws an error. Read it protected and treat
-- a refusal as "can't see it right now".
local function SafeAura(unit, i)
	local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
	if ok then return a, true end
	return nil, false
end

local auras = {} -- [name] = { mine = bool, left = seconds or nil, id = spellId }

local function ReadAuras()
	wipe(auras)
	local now = GetTime()
	for i = 1, 40 do
		local a = SafeAura("player", i)
		if not a then break end
		local name = Plain(a.name)
		if name then
			local exp = Plain(a.expirationTime)
			local left = (exp and exp > 0) and (exp - now) or nil
			local src = Plain(a.sourceUnit)
			local mine = src == "player" or src == "pet" or src == "vehicle"
			local cur = auras[name]
			if not cur or (mine and not cur.mine) then
				auras[name] = { mine = mine, left = left, id = Plain(a.spellId) }
			end
		end
	end
end

local function Active(name)
	local a = auras[name]
	if not a then return false end
	if a.left and a.left < EXPIRING then return false end
	return true, a.mine
end

-- the "type" of a Blessing, so Greater Blessing of Kings counts as Kings
local function BlessingType(name)
	return name:match("Blessing of (.+)$")
end

local function Blocked(name)
	if Active(name) then return true end
	local t = BlessingType(name)
	if t then
		for n in pairs(auras) do
			if BlessingType(n) == t and Active(n) then return true end
		end
	end
	for _, other in ipairs(CONFLICTS[name] or {}) do
		if Active(other) then return true end
	end
	return false
end

local known = ns.known
local SpellIcon = ns.SpellIcon

--------------------------------------------------------------------------
-- Buff items in your bags
--------------------------------------------------------------------------

-- How long the buff from a "Use:" line lasts, in seconds. Only counts
-- "for 30 min" / "lasts 1 hour" phrasing, never the item's cooldown.
local function Seconds(text)
	text = text:gsub("%b()", "") -- "(1 Hour Cooldown)"
	local best
	for n, unit in text:gmatch("[Ff]or (%d+)%s*(%a+)") do
		n = tonumber(n)
		unit = unit:lower()
		local s
		if unit:find("^hour") or unit:find("^hr") then s = n * 3600
		elseif unit:find("^min") then s = n * 60
		elseif unit:find("^sec") then s = n end
		if s then best = math.max(best or 0, s) end
	end
	for n, unit in text:gmatch("[Ll]asts (%d+)%s*(%a+)") do
		n = tonumber(n)
		unit = unit:lower()
		local s
		if unit:find("^hour") or unit:find("^hr") then s = n * 3600
		elseif unit:find("^min") then s = n * 60
		elseif unit:find("^sec") then s = n end
		if s then best = math.max(best or 0, s) end
	end
	return best
end

local function ItemSpellName(itemID)
	if C_Item.GetItemSpell then return C_Item.GetItemSpell(itemID) end
	return GetItemSpell and GetItemSpell(itemID)
end

local SHARP = { [0] = true, [1] = true, [6] = true, [7] = true, [8] = true, [13] = true, [15] = true }
local BLUNT = { [4] = true, [5] = true, [10] = true }

local function MainHandType()
	local id = GetInventoryItemID("player", 16)
	if not id then return nil end
	local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
	if classID ~= 2 then return nil end
	return SHARP[subClassID] and "sharp" or (BLUNT[subClassID] and "blunt") or "other"
end

-- What a bag item is good for, worked out once per item ID:
-- { kind = "food"|"weapon"|"item", itemID, name, spell, ilvl } or false
local classified = {}
local spellTries = {}

local function Clean(t)
	t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	t = t:gsub("\194\160", " ") -- non-breaking spaces (e.g. "1 hour")
	return (t:gsub("%s+", " "))
end

-- The item's "Use:" text, or nil. Second value is false while the item's
-- data hasn't arrived from the server yet (so we try again later).
local function UseText(id)
	if not C_Item.GetItemInfo(id) then
		C_Item.RequestLoadItemDataByID(id)
		return nil, false
	end
	local data = C_TooltipInfo and C_TooltipInfo.GetItemByID(id)
	if not (data and data.lines and #data.lines > 1) then return nil, false end
	for _, line in ipairs(data.lines) do
		local t = Plain(line.leftText)
		if t then
			t = Clean(t)
			local use = t:match("Use:%s*(.*)")
			if use then return "Use: " .. use, true end
		end
	end
	return nil, true
end
ns.UseText = UseText

local function Classify(id)
	if classified[id] ~= nil then return classified[id] end
	-- recipes, patterns and plans (item class 9) show the crafted item's
	-- tooltip too, e.g. a cooking recipe mentions "Well Fed": never a buff item
	local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(id)
	if classID == 9 then
		classified[id] = false
		return false
	end
	local result = false
	local found = {}
	do
		do
				local useText, loaded = UseText(id)
				if not loaded then return false end -- not cached yet; try again on the next scan
				if useText then
					local lower = useText:lower()
					local skip = false
					for _, w in ipairs(SKIP_WORDS) do
						if lower:find(w, 1, true) then skip = true break end
					end
					local name, _, _, ilvl, minLevel = C_Item.GetItemInfo(id)
					ilvl = (minLevel or 0) * 1000 + (ilvl or 0) -- better = higher required level, then item level
					if not skip then
						if lower:find("well fed", 1, true) then
							found[#found + 1] = { kind = "food", itemID = id, name = name, ilvl = ilvl or 0 }
						elseif lower:find("weapon", 1, true) and (Seconds(useText) or 0) >= MIN_DURATION then
							local wtype = lower:find("sharp", 1, true) and "sharp" or (lower:find("blunt", 1, true) and "blunt") or "any"
							found[#found + 1] = { kind = "weapon", itemID = id, name = name, wtype = wtype, ilvl = ilvl or 0 }
						elseif name:find("Elixir") or name:find("Flask")
							or ((Seconds(useText) or 0) >= MIN_DURATION and not lower:find("restores", 1, true)) then
							local spell = ItemSpellName(id)
							spellTries[id] = (spellTries[id] or 0) + 1
							if not spell and spellTries[id] > 5 then spell = name end -- no spell info: go by the item's name
							if not spell then
								-- the buff's spell data isn't loaded yet; ask for it and look again next scan
								local _, spellID = ItemSpellName(id)
								if spellID and C_Spell and C_Spell.RequestLoadSpellData then C_Spell.RequestLoadSpellData(spellID) end
								return false
							end
							found[#found + 1] = { kind = "item", itemID = id, name = name, spell = spell, ilvl = ilvl or 0 }
						end
					end
				end
		end
	end
	result = found[1] or false
	classified[id] = result
	return result
end

local bagItems -- cached list, cleared when your bags change

local function ScanBags()
	if bagItems then return bagItems end
	local found, seen, incomplete = {}, {}, false
	local getNum = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
	local getID = C_Container and C_Container.GetContainerItemID or GetContainerItemID
	for bag = 0, 4 do
		for slot = 1, (getNum(bag) or 0) do
			local id = getID(bag, slot)
			if id and not seen[id] then
				seen[id] = true
				local it = Classify(id)
				if it then found[#found + 1] = it end
				if classified[id] == nil then incomplete = true end
			end
		end
	end
	if not incomplete then bagItems = found end
	return found
end

--------------------------------------------------------------------------
-- Working out what's missing
--------------------------------------------------------------------------

-- each suggestion: { key, label, icon, cast = spellName | nil, item = itemID | nil, weapon = bool }
local function Suggestions()
	local out = {}
	local _, class = UnitClass("player")

	for _, group in ipairs(CLASS_BUFFS[class] or {}) do
		-- the party buff bar (Heal.lua) buffs you too: leave those to it
		local covered = ns.PartyCovers and ns.PartyCovers(group.key == "blessing" and "blessing" or group.spells)
		-- Righteous Fury only when you're the tank (group role Tank or /ga role tank),
		-- never while you level as Retribution
		if group.tankOnly and not ns.Tanking() then covered = true end
		if covered then
			-- nothing: shown on the party buff bar instead
		elseif group.kind == "own" then
			local haveMine = false
			for name, a in pairs(auras) do
				if a.mine and name:find(group.match) and Active(name) then haveMine = true end
			end
			if not haveMine then
				for _, spell in ipairs(db[group.prefKey] or group.default) do
					if known[spell] and not Blocked(spell) then
						out[#out + 1] = { key = group.key, label = spell, icon = SpellIcon(spell), cast = spell }
						break
					end
				end
			end
		else
			local up = false
			for _, spell in ipairs(group.spells) do
				if Active(spell) then up = true end
			end
			if not up then
				for _, spell in ipairs(group.spells) do
					if known[spell] and not Blocked(spell) then
						out[#out + 1] = { key = group.key, label = spell, icon = SpellIcon(spell), cast = spell }
						break
					end
				end
			end
		end
	end

	local items = ScanBags()
	table.sort(items, function(a, b) return a.ilvl > b.ilvl end)

	-- food
	if not Active("Well Fed") then
		for _, it in ipairs(items) do
			if it.kind == "food" then
				out[#out + 1] = { key = "food", label = it.name .. " (Well Fed)", icon = C_Item.GetItemIconByID(it.itemID), item = it.itemID }
				break
			end
		end
	end

	-- weapon oil / stone
	local hasMH = GetWeaponEnchantInfo and GetWeaponEnchantInfo()
	local mhType = MainHandType()
	if mhType and not hasMH then
		for _, it in ipairs(items) do
			if it.kind == "weapon" and (it.wtype == "any" or it.wtype == mhType) then
				out[#out + 1] = { key = "weapon", label = it.name .. " (main hand)", icon = C_Item.GetItemIconByID(it.itemID), item = it.itemID, weapon = true }
				break
			end
		end
	end

	-- elixirs, scrolls, flasks...
	-- items giving the same buff overwrite each other: only the best one is shown
	local spellsDone = {}
	for _, it in ipairs(items) do
		if it.kind == "item" and not spellsDone[it.spell] then
			spellsDone[it.spell] = it.name
			if not Blocked(it.spell) then
				out[#out + 1] = { key = "item:" .. it.spell, label = it.name, icon = C_Item.GetItemIconByID(it.itemID), item = it.itemID }
			end
		end
	end

	local shown = {}
	for _, s in ipairs(out) do
		if not ignored[s.key] then shown[#shown + 1] = s end
	end
	return shown
end

--------------------------------------------------------------------------
-- The icon bar
--------------------------------------------------------------------------

local bar, handle, buttons = nil, nil, {}
local Update -- defined below; forward-declared so the menu callbacks reach it

local function ShowMenu(btn)
	local s = btn.suggestion
	if not s then return end
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(btn, function(_, root)
			root:CreateTitle(s.label)
			root:CreateButton("Ignore this session", function()
				ignored[s.key] = true
				Update()
			end)
		end)
	else
		ignored[s.key] = true
		Print(s.label .. " ignored for this session. /ta unignore brings it back.")
		Update()
	end
end

local function GetButton(i)
	if buttons[i] then return buttons[i] end
	local b = CreateFrame("Button", "GroupAssistTankButton" .. i, bar, "SecureActionButtonTemplate")
	b:SetSize(ICON, ICON)
	-- both, so it works whatever "cast on key down" is set to (the game only acts on one)
	b:RegisterForClicks("AnyUp", "AnyDown")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	-- right-click has no secure action; it opens the Ignore menu
	b:HookScript("OnClick", function(self, button, down)
		if button == "RightButton" and not down then ShowMenu(self) end
	end)
	b:SetScript("OnEnter", function(self)
		local s = self.suggestion
		if not s then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(s.label, 1, 1, 1)
		GameTooltip:AddLine("Left-click: " .. (s.cast and "cast" or "use"), 0.6, 0.8, 1)
		GameTooltip:AddLine("Right-click: ignore this session", 0.6, 0.8, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	buttons[i] = b
	return b
end

local pending = false

-- While you heal, the party buff bar is what matters, so your own buff
-- icons step aside (/ta buffs on|off|auto).
local function BuffIconsHidden()
	local mode = db.buffs or "auto"
	if mode == "on" then return false end
	if mode == "off" then return true end
	return ns.Healing()
end

function Update() -- fills in the forward declaration above ShowMenu
	if not bar then return end
	if InCombatLockdown() then pending = true return end
	pending = false
	ReadAuras()
	local list = BuffIconsHidden() and {} or Suggestions()
	for i, s in ipairs(list) do
		local b = GetButton(i)
		b.suggestion = s
		b.icon:SetTexture(s.icon or 134400)
		if s.cast then
			b:SetAttribute("type1", "spell")
			b:SetAttribute("spell1", s.cast)
			b:SetAttribute("unit1", "player")
			b:SetAttribute("macrotext1", nil)
		else
			-- items go through a small macro: "/use <item>", and for oils and
			-- stones a second "/use 16" to put it on your main-hand weapon
			local name = C_Item.GetItemInfo(s.item) or ("item:" .. s.item)
			local text = "/use " .. name
			if s.weapon then text = text .. "\n/use 16" end
			b:SetAttribute("type1", "macro")
			b:SetAttribute("macrotext1", text)
			b:SetAttribute("spell1", nil)
			b:SetAttribute("unit1", nil)
		end
		b:ClearAllPoints()
		b:SetPoint("LEFT", bar, "LEFT", (i - 1) * (ICON + 3), 0)
		b:Show()
	end
	for i = #list + 1, #buttons do buttons[i]:Hide() end
	bar:SetWidth(math.max(ICON, #list * (ICON + 3)))
end

--------------------------------------------------------------------------
-- Group alerts: drinking, healer mana
--------------------------------------------------------------------------

local healerAlert -- big line under the bar: your healer (drinking / low mana)
local alert       -- small lines under that: everyone else drinking

local function UnitDrinking(unit)
	-- nobody drinks in combat, and party auras are secret then
	if InCombatLockdown() or UnitAffectingCombat(unit) then return false end
	for i = 1, 40 do
		local a = SafeAura(unit, i)
		if not a then break end
		local name = Plain(a.name)
		if name and (name == "Drink" or name == "Food & Drink" or name == "Refreshment" or name:find("^Drink")) then
			return true
		end
	end
	return false
end

local HEAL_CLASSES = { PRIEST = 1, DRUID = 2, SHAMAN = 3, PALADIN = 4 }

local function FindHealer()
	local units = {}
	for i = 1, 4 do
		local u = "party" .. i
		if UnitExists(u) then units[#units + 1] = u end
	end
	if db.healer and db.healer ~= "auto" then
		for _, u in ipairs(units) do
			if Plain(UnitName(u)) == db.healer then return u end
		end
	end
	for _, u in ipairs(units) do
		if UnitGroupRolesAssigned and UnitGroupRolesAssigned(u) == "HEALER" then return u end
	end
	local best, rank
	for _, u in ipairs(units) do
		local _, class = UnitClass(u)
		local r = HEAL_CLASSES[class]
		if r and (not rank or r < rank) then best, rank = u, r end
	end
	return best
end

-- healer's mana as a whole percent, or nil if unknown (secret / no mana bar)
local function ManaPct(unit)
	local cur, max = Plain(UnitPower(unit, 0)), Plain(UnitPowerMax(unit, 0))
	if cur and max and max > 0 then return math.floor(cur / max * 100) end
end

local function UpdateAlerts()
	if not alert then return end
	if not ns.Tanking() then
		healerAlert:SetText(""); healerAlert:Hide(); alert:SetText("")
		return
	end
	local healer = FindHealer()
	if healer and UnitIsDeadOrGhost(healer) then healer = nil end

	-- top line: the healer, if they're drinking or low on mana
	local top
	if healer then
		local name = Plain(UnitName(healer)) or healer
		local pct = ManaPct(healer)
		if UnitDrinking(healer) then
			top = pct and ("|cff40ff40HEALER %s is drinking (%d%%)|r"):format(name, pct)
				or ("|cff40ff40HEALER %s is drinking|r"):format(name)
		elseif pct and not UnitAffectingCombat("player") and pct < HEALER_MANA * 100 then
			top = ("|cffff6060HEALER %s: %d%% mana|r"):format(name, pct)
		end
	end

	-- everyone else who's drinking
	local lines = {}
	for i = 1, 4 do
		local u = "party" .. i
		if UnitExists(u) and not UnitIsDeadOrGhost(u) and not (healer and UnitIsUnit(u, healer)) and UnitDrinking(u) then
			lines[#lines + 1] = "|cffaaaaaa" .. (Plain(UnitName(u)) or u) .. " is drinking|r"
		end
	end

	healerAlert:SetText(top or "")
	healerAlert:SetShown(top ~= nil)
	alert:ClearAllPoints()
	if top then
		alert:SetPoint("TOPLEFT", healerAlert, "BOTTOMLEFT", 0, -2)
	else
		alert:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
	end
	alert:SetText(table.concat(lines, "\n"))
end

--------------------------------------------------------------------------
-- Loose mobs: marks enemy nameplates while you're tanking
--   red "!!" + red outline     a mob in the fight that's attacking someone
--                              else (you're not tanking it)
--   orange "!" + orange outline you're tanking it, but someone is close to
--                              pulling it off you
-- It only shows things; picking the target is still your Tab/click.
-- Reads UnitThreatSituation (readable in combat on this client; the
-- detailed threat % is secret) and who the mob is attacking.
-- /ta loose auto | on | off   (auto = when you're the tank: tank role,
-- Righteous Fury, Defensive Stance or Bear Form)
--------------------------------------------------------------------------

local LOOSE_COLOR = { loose = { 1, 0.15, 0.15 }, slip = { 1, 0.55, 0 } }
local marks = {} -- nameplate frame -> our mark frame

-- nil for secret values, so they're never tested
local function Safe(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end
local function Call(fn, ...)
	if not fn then return nil end
	local ok, a = pcall(fn, ...)
	if ok then return Safe(a) end
end

local function AmTank()
	local mode = db.loose or "auto"
	if mode == "on" then return true end
	if mode == "off" then return false end
	return ns.Tanking()
end

-- Is this mob attacking someone in your group (not you)?
local function OnGroupMember(unit)
	local tgt = unit .. "target"
	if not Call(UnitExists, tgt) then return false end
	if Call(UnitIsUnit, tgt, "player") then return false end
	if Call(UnitIsUnit, tgt, "pet") then return true end
	for i = 1, 4 do
		if Call(UnitIsUnit, tgt, "party" .. i) or Call(UnitIsUnit, tgt, "partypet" .. i) then return true end
	end
	if IsInRaid and Call(IsInRaid) then
		return Call(UnitInRaid, tgt) and true or false
	end
	return false
end

-- "loose", "slip" or nil for one enemy nameplate unit
local function LooseState(unit)
	if not Call(UnitCanAttack, "player", unit) or Call(UnitIsDead, unit) then return nil end
	if not Call(UnitAffectingCombat, unit) then return nil end
	local sit = Call(UnitThreatSituation, "player", unit)
	if sit == 3 then return nil end
	if sit == 2 then return "slip" end
	if sit == 0 or sit == 1 then
		-- on your threat list but not attacking you
		return OnGroupMember(unit) and "loose" or nil
	end
	-- not on your threat list at all: loose if it's on someone in your group
	return OnGroupMember(unit) and "loose" or nil
end

local function Mark(plate)
	local m = marks[plate]
	if m ~= nil then return m or nil end
	local ok, frame = pcall(function()
		local anchor = (plate.UnitFrame and plate.UnitFrame.healthBar) or plate.UnitFrame or plate
		local f = CreateFrame("Frame", nil, plate)
		f:SetAllPoints(anchor)
		f:SetFrameLevel(math.max(0, (anchor.GetFrameLevel and anchor:GetFrameLevel() or 1) - 1))
		f.edge = f:CreateTexture(nil, "BACKGROUND")
		f.edge:SetPoint("TOPLEFT", -3, 3)
		f.edge:SetPoint("BOTTOMRIGHT", 3, -3)
		local top = CreateFrame("Frame", nil, plate)
		top:SetSize(40, 30)
		top:SetPoint("BOTTOM", anchor, "TOP", 0, 14)
		top:SetFrameLevel((anchor.GetFrameLevel and anchor:GetFrameLevel() or 1) + 5)
		f.text = top:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
		f.text:SetPoint("CENTER")
		f.top = top
		f:Hide(); top:Hide()
		return f
	end)
	marks[plate] = ok and frame or false -- false: couldn't attach (protected plate)
	return ok and frame or nil
end

local function SetMark(plate, state)
	local m = (state or marks[plate]) and Mark(plate)
	if not m then return end
	if not state then
		m:Hide(); m.top:Hide()
		return
	end
	local c = LOOSE_COLOR[state]
	m.edge:SetColorTexture(c[1], c[2], c[3], 0.85)
	m.text:SetText(state == "loose" and "!!" or "!")
	m.text:SetTextColor(c[1], c[2], c[3])
	m:Show(); m.top:Show()
end

local looseOn = false
local function UpdateLoose()
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
	local tank = AmTank()
	if not tank and not looseOn then return end
	looseOn = tank
	for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
		local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
		local state = tank and unit and LooseState(unit) or nil
		SetMark(plate, state)
	end
end

--------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------

local function Build()
	bar = CreateFrame("Frame", "GroupAssistTankBar", UIParent, "SecureHandlerStateTemplate")
	bar:SetSize(ICON, ICON)
	local p = db.pos
	if p then bar:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else bar:SetPoint("CENTER", 0, -160) end
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	RegisterStateDriver(bar, "visibility", "[combat] hide; show")

	handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	handle:SetSize(60, 12)
	handle:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 2)
	handle:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
	handle:SetBackdropColor(1, 0.82, 0, 0.8)
	handle:EnableMouse(true)
	handle:RegisterForDrag("LeftButton")
	handle:SetScript("OnDragStart", function() if not InCombatLockdown() then bar:StartMoving() end end)
	handle:SetScript("OnDragStop", function()
		bar:StopMovingOrSizing()
		local a, _, rp, x, y = bar:GetPoint()
		db.pos = { a, rp, x, y }
	end)
	local t = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	t:SetPoint("CENTER")
	t:SetText("|cff000000drag|r")
	handle:SetShown(not db.locked)

	healerAlert = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	healerAlert:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
	healerAlert:SetJustifyH("LEFT")
	healerAlert:Hide()

	alert = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	alert:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
	alert:SetJustifyH("LEFT")
end

local function Help()
	print("   |cff6fb6ffTank|r: own buff icons (left-click casts/uses, right-click ignores), loose-mob marks and healer lines while you tank.")
	print(("   blessings: %s"):format(table.concat(db.blessings or CLASS_BUFFS.PALADIN[2].default, ", ")))
	print(("   auras: %s"):format(table.concat(db.auras or CLASS_BUFFS.PALADIN[1].default, ", ")))
	print(("   healer: %s, loose-mob marks: %s, buff icons: %s%s"):format(db.healer or "auto", db.loose or "auto", db.buffs or "auto",
		BuffIconsHidden() and " (hidden)" or ""))
	print("   /ta blessing Kings, Sanctuary, Might, /ta aura Retribution, Devotion,")
	print("   /ta healer <name> | auto, /ta unignore, /ta loose auto|on|off, /ta buffs auto|on|off")
end

-- "Kings, Might" -> { "Blessing of Kings", "Blessing of Might" }
local function ParseList(text, prefix, suffix)
	local out = {}
	for word in text:gmatch("[^,]+") do
		word = word:match("^%s*(.-)%s*$")
		if word ~= "" then
			word = word:gsub("^%l", string.upper)
			if prefix and not word:find(prefix, 1, true) then word = prefix .. word end
			if suffix and not word:find(suffix .. "$") then word = word .. suffix end
			out[#out + 1] = word
		end
	end
	return out
end

function M.Slash(msg)
	msg = msg or ""
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "unlock" then
		M.SetLocked(false); Print("drag the yellow handle to move the bar. /ta lock when done.")
	elseif cmd == "lock" then
		M.SetLocked(true); Print("locked.")
	elseif cmd == "blessing" or cmd == "blessings" then
		if rest == "" then db.blessings = nil else db.blessings = ParseList(rest, "Blessing of ") end
		Print("blessing order: " .. table.concat(db.blessings or CLASS_BUFFS.PALADIN[2].default, ", "))
		Update()
	elseif cmd == "aura" or cmd == "auras" then
		if rest == "" then db.auras = nil else db.auras = ParseList(rest, nil, " Aura") end
		Print("aura order: " .. table.concat(db.auras or CLASS_BUFFS.PALADIN[1].default, ", "))
		Update()
	elseif cmd == "healer" then
		db.healer = (rest == "" or rest:lower() == "auto") and "auto" or rest
		Print("healer: " .. db.healer)
	elseif cmd == "unignore" then
		wipe(ignored); Print("nothing is ignored now."); Update()
	elseif cmd == "buffs" then
		local m = rest:lower()
		if m == "on" or m == "off" or m == "auto" then db.buffs = m end
		Print(("buff icons: %s%s. Usage: /ta buffs auto|on|off (auto = hidden while you heal)"):format(
			db.buffs or "auto", BuffIconsHidden() and " (hidden now)" or ""))
		Update()
	elseif cmd == "loose" then
		local m = rest:lower()
		if m == "on" or m == "off" or m == "auto" then db.loose = m end
		Print(("loose-mob marks: %s. Usage: /ta loose auto|on|off (auto = when you tank: tank role, Righteous Fury, Defensive Stance or Bear Form)"):format(db.loose or "auto"))
		UpdateLoose()
	elseif cmd == "debug" then
		wipe(classified); bagItems = nil
		local getNum = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
		local getID = C_Container and C_Container.GetContainerItemID or GetContainerItemID
		Print("bag items with a Use: effect:")
		for bag = 0, 4 do
			for slot = 1, (getNum(bag) or 0) do
				local id = getID(bag, slot)
				if id then
					local use, loaded = UseText(id)
					if use or not loaded then
						local it = Classify(id)
						local status = it and (it.kind .. (it.spell and (", buff: " .. it.spell .. (Blocked(it.spell) and " (already up)" or "")) or "")
							.. (", rank " .. it.ilvl))
							or (classified[id] == nil and "still loading" or "not a tanking buff")
						print(("   %s: %s -> %s"):format(C_Item.GetItemInfo(id) or id, loaded and use or "(not loaded yet)", status))
					end
				end
			end
		end
		local has, exp = GetWeaponEnchantInfo()
		print(("   main hand: %s, temporary enchant: %s"):format(MainHandType() or "no weapon", has and "yes" or "no"))
		ReadAuras()
		print("   Well Fed active: " .. (Active("Well Fed") and "yes" or "no"))
		Update()
	else
		Help()
	end
end


M.Help = Help

--------------------------------------------------------------------------
-- Hooks for the core
--------------------------------------------------------------------------

function M.Init()
	db = ns.char.tank
	db.sound = nil
	if db.locked == nil then db.locked = true end
	db.loose = db.loose or "auto"
	db.buffs = db.buffs or "auto"
end

M.Build = Build
M.Refresh = Update

function M.SetLocked(locked)
	db.locked = locked
	if handle then handle:SetShown(not locked) end
end

function M.Tick()
	if pending or not InCombatLockdown() then Update() end
	UpdateAlerts()
end

function M.FastTick() UpdateLoose() end

function M.OnEvent(event, a)
	if not bar then return end
	if event == "BAG_UPDATE_DELAYED" then
		bagItems = nil; Update()
	elseif event == "SPELLS_CHANGED" then
		Update()
	elseif event == "UNIT_AURA" then
		if a == "player" then Update() elseif a and a:find("^party") then UpdateAlerts() end
	elseif event == "UNIT_POWER_UPDATE" then
		if a and a:find("^party") then UpdateAlerts() end
	elseif event == "GROUP_ROSTER_UPDATE" then
		UpdateAlerts(); Update()
	elseif event == "PLAYER_REGEN_ENABLED" or event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED"
		or event == "UPDATE_SHAPESHIFT_FORM" or event == "PLAYER_ROLES_ASSIGNED" then
		Update()
	end
end
