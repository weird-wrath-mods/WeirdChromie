-- Name: WeirdChromie (3.3.5 Wrath, ChromieCraft)
-- Originally based on SilentServer for Turtle WoW.

-- String entries are plain literals (matched with string.find plain=true).
-- A leading '^' anchors the literal to the start of the message.
-- Table entries {pattern, guard} are Lua patterns; `guard` is a cheap plain
-- substring pre-filter so the real matcher only runs on candidate messages.
local system_patterns = {
  '^[BG Queue Announcer]',
  '^[Arena Queue Announcer]',
  '^[Arena Queue]',
  '^[BG Queue]',
  '^Top PvP players of the month', -- pvp header
  {"^%d+%. .- %- %d+$", " - "},  -- Leaderboard rows e.g. "1. Mustang - 212" through "10. Bryle - 78"
  'Check all PvP statistics', -- pvp footer
  '^Visit Chromie',
  '^The best PvP players of every month',
  '^Visit www.Chromie',
  '^You can queue for arenas',

  '^ChromieCraft is a welcoming place',
  '^Welcome to ChromieCraft',
  '^This server runs on AzerothCore',
  '^This server features a Recruit',
  '^This Server Max Account of Same IP is:',
  'joyous journeys',

  '^We are always looking for new contributors',
  '^Have a look at: chromiecraft.com',
  
  '^ChromieCraft.com is a free',
  '^This is a NON-profit',
  '^You can always find the latest news',
  '^Consider supporting',
  '^You can buy cosmetic',
  '^The /world channel is english only',

  '^Tip: Cross-faction',
  '^Tip: You can use the',
  '^Tip: Stuck on a quest',
  '^Tip: Battlegrounds give experience',
  '^There is no guild recruitment in',
  '^BGs have boosted XP',

  '^Auction deposits are only', -- we need to determine real costs and adjust them

  -- Weekly arena-point flush sequence; consolidated to a single
  -- "Arena points updated." headline (rewritten on the final line below).
  '^Flushing Arena points based on team ratings',
  '^Distributing arena points to players',
  '^Finished setting arena points for online players',
  '^Modifying played count, arena points',
  '^Modification done',
}

local compiled_patterns = {}
for _, def in ipairs(system_patterns) do
  local pattern, guard
  if type(def) == "table" then
    pattern, guard = def[1], def[2]
  else
    pattern = def
  end
  local lowered = string.lower(pattern)
  local entry = {}
  entry.source = pattern
  if guard then
    entry.needle = lowered
    entry.guard = string.lower(guard)
    entry.plain = false
  elseif string.sub(lowered, 1, 1) == "^" then
    entry.needle = string.sub(lowered, 2)
    entry.anchored = true
    entry.plain = true
  else
    entry.needle = lowered
    entry.plain = true
  end
  table.insert(compiled_patterns, entry)
end

-- Rewrite rules for system messages. Each entry needs a `needle`
-- (lowercase plain substring used to match), and either:
--   `replacement`: a fixed string to emit, OR
--   `rewrite(msg)`: a function returning the replacement string (or nil
--                   to leave the message unchanged).
-- `anchored = true` requires the needle to match at position 1.
local system_rewrites = {
  {
    label = "[SERVER] truncate",
    needle = "[server]",
    anchored = true,
    rewrite = function(msg)
      local pos = string.find(msg, ".", 1, true)
      return pos and (string.sub(msg, 1, pos) .. "|r") or nil
    end,
  },
  {
    label = "[arena points consolidate]",
    needle = "done flushing arena points",
    replacement = "Arena points updated.",
  },
}

-- Auto-pass on group loot rolls when the rolled item link contains any of
-- these plain-substring patterns. The four cooking recipes are the random
-- Northrend mob drops (BoP, but still rolled in group loot mode); every
-- other Wrath cooking recipe is vendor-purchased and never hits a roll.
local auto_pass_items = {
  "Heavy Frostweave Bandage",
  "Recipe: Bad Clams",
  "Recipe: Haunted Herring",
  "Recipe: Last Week's Mammoth",
  "Recipe: Tasty Cupcake",
}

-- BoP jewelcrafting designs that drop from Northrend dungeon bosses.
-- Roll action is configurable (pass/greed/need) via WeirdChromieDB.jc_design_roll.
local jc_design_drops = {
  "Design: Austere Earthsiege Diamond",   -- Utgarde Pinnacle, King Ymiron
  "Design: Bracing Earthsiege Diamond",   -- The Oculus, Cache of Eregos
  "Design: Eternal Earthsiege Diamond",   -- Halls of Lightning, Loken
  "Design: Deadly Monarch Topaz",         -- The Nexus (heroic), Keristrasza
  "Design: Deft Monarch Topaz",           -- Halls of Stone (heroic), Sjonnir
  "Design: Fierce Monarch Topaz",         -- Utgarde Keep (heroic), Ingvar
  "Design: Precise Scarlet Ruby",         -- Ahn'kahet (heroic), Herald Volazj
  "Design: Thick Autumn's Glow",          -- Violet Hold (heroic), Cyanigosa
  "Design: Timeless Forest Emerald",      -- Drak'Tharon Keep (heroic), Tharon'ja
  "Design: Infused Twilight Opal",        -- Azjol-Nerub (heroic), Anub'arak
}

local ignore_npc = {
  ["Fizzle \"The Sharpened Scissors\""] = true, -- barber
  ["Pierre \"Le Coiffeur\" Dufresne"] = true, -- barber
  ["Tansy Sparkpen"] = true, -- gadgetzan times
  ["Fara Boltbreaker"] = true, -- gadgetzan times
}

------------------------------
-- Gossip skip (ported from LazyWeirdo)
------------------------------

-- For options whose gossip type is "gossip" (plain dialogue), skip when the
-- displayed text matches one of these Lua patterns.
--
-- `general` patterns are checked for any NPC. Other keys are exact-matched
-- against UnitName("npc") and only their patterns get tried while talking
-- to that NPC.
local gossip_skip_by_npc = {
  general = {
    bwl       = "my hand on the orb",
    mc        = "me to the Molten Core",
    wv        = "Happy Winter Veil",
    nef1      = "made no mistakes",
    nef2      = "have lost your mind",
    rag1      = "challenged us and we have come",
    rag2      = "else do you have to say",
    ironbark  = "Thank you, Ironbark",
    pusilin1  = "Game %? Are you crazy %?",
    pusilin2  = "Why you little",
    pusilin3  = "DIE!",
    meph      = "Touch the Portal",
    kara      = "Teleport me back to Kara",
    mizzle1   = "^I'm the new king%?",
    mizzle2   = "^It's good to be King!",
  },
  -- Stratholme: Culling of Stratholme.
  -- Option texts taken from AzerothCore gossip_menu_option (menus 9586,
  -- 9595, 9612, 11277). Lore-investigation options are intentionally not
  -- listed (e.g. "Why have I been sent back...", "So how does the Infinite
  -- Dragonflight plan to interfere?").
  ["Chromie"] = {
    skip_ahead = "skip us ahead to all the real action",        -- 9586/2
    teleport   = "^Yes, please",                              -- 11277/0
    very_well  = "^Very well, Chromie",                       -- 9612/0 (mid-instance)
  },
  -- Stratholme: Culling of Stratholme - Arthas progression options
  -- (menus 13076, 13125, 13126, 13177, 13179, 13287; option texts from AC
  -- gossip_menu_option ids 9653/9680/9681/9695/9696/9676).
  ["Arthas"] = {
    -- Intro (9653) intentionally not auto-clicked: players should opt in
    -- to start the run themselves.
    -- we_are_ready  = "^Yes, my Prince%. We are ready",
    best_lordaeron = "^We're only doing what is best for Lordaeron", -- 9680 town hall
    lead_way      = "^Lead the way, Prince Arthas",           -- 9681 town hall follow-up
    ready         = "^I'm ready",                             -- 9695 + 9676 (Mal'Ganis)
    for_lordaeron = "^For Lordaeron!",                        -- 9696 last city
  },
  -- The Oculus: dragon mount handlers
  ["Verdisa"] = {
    green_flight = "wings of the green flight",
    exchange = "want to exchange my",
  },
  ["Eternos"] = {
    bronze_flight = "wings of the bronze flight",
    exchange = "want to exchange my",
  },
  ["Belgaristrasz"] = {
    where_next = "^So where do we go from here",
    red_flight = "wings of the red flight",
    exchange = "want to exchange my",
  },
  -- Violet Hold entrance / event start
  ["Lieutenant Sinclari"] = {
    briefing = "^Activate the crystals when we get in trouble",
    -- start    = "^Get your people to safety",
  },
  -- Halls of Stone progression dialogues
  ["Brann Bronzebeard"] = {
    honor      = "^Brann, it would be our honor",
    move       = "^Let's move Brann, enough of the history lessons",
    moving     = "^There will be plenty of time for this later Brann",
    open_it    = "^We're with you Brann",
  },
}

local function gossip_enabled()
  return WeirdChromieDB and WeirdChromieDB.auto_gossip ~= false
end

local function silence_enabled()
  return not WeirdChromieDB or WeirdChromieDB.silence ~= false
end

local function auto_pass_enabled()
  return WeirdChromieDB and WeirdChromieDB.auto_pass_recipes == true
end

-- RollOnLoot rollType: 0 = pass, 1 = need, 2 = greed, 3 = disenchant.
-- Need/Greed/DE on a BoP item shows the "Looting this item will bind it to
-- you" confirmation popup (CONFIRM_LOOT_ROLL event); the roll only commits
-- after ConfirmLootRoll(rollID, rollType). pending_confirms tracks rolls we
-- initiated so we don't auto-confirm popups from the player's own need-rolls.
local roll_labels = { [0] = "passed", [1] = "needed", [2] = "greeded", [3] = "disenchanted" }
local pending_confirms = {}
-- When true, RollOnLoot/ConfirmLootRoll are diverted to chat prints so the
-- decision/confirm flow can be exercised without a live group loot drop.
-- Toggled by the `/wc testroll` debug command.
local test_mode = false

local function do_auto_roll(rollID, link, rollType)
  if rollType == 1 or rollType == 2 or rollType == 3 then
    pending_confirms[rollID] = rollType
  end
  if test_mode then
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cff33ff99[WC test]|r would RollOnLoot(" .. tostring(rollID) ..
      ", " .. tostring(rollType) .. ") [" .. (roll_labels[rollType] or "?") .. "] " .. link)
    return
  end
  RollOnLoot(rollID, rollType)
  if WeirdChromieDB and WeirdChromieDB.debug then
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cff33ff99[WC]|r auto-" .. (roll_labels[rollType] or "rolled") .. " on " .. link)
  end
end

-- Deferred-confirm queue: ConfirmLootRoll fired synchronously inside the
-- event handler can race the popup's own setup, leaving the dialog
-- on-screen. Stash the (rollID,rollType) and resolve it next OnUpdate tick.
local confirm_queue = {}
local confirm_dispatcher = CreateFrame("Frame")
confirm_dispatcher:Hide()
confirm_dispatcher:SetScript("OnUpdate", function(self)
  for rollID, rollType in pairs(confirm_queue) do
    if test_mode then
      DEFAULT_CHAT_FRAME:AddMessage(
        "|cff33ff99[WC test]|r would ConfirmLootRoll(" .. tostring(rollID) ..
        ", " .. tostring(rollType) .. ") [" .. (roll_labels[rollType] or "?") .. "]")
    else
      ConfirmLootRoll(rollID, rollType)
      StaticPopup_Hide("CONFIRM_LOOT_ROLL", rollID)
      if WeirdChromieDB and WeirdChromieDB.debug then
        DEFAULT_CHAT_FRAME:AddMessage(
          "|cff33ff99[WC]|r confirmed BoP roll " .. tostring(rollID) ..
          " (" .. (roll_labels[rollType] or tostring(rollType)) .. ")")
      end
    end
    confirm_queue[rollID] = nil
  end
  self:Hide()
end)

local function handle_confirm_loot_roll(rollID, rollType)
  local pending = pending_confirms[rollID]
  if not pending then return end
  pending_confirms[rollID] = nil
  confirm_queue[rollID] = pending
  confirm_dispatcher:Show()
end

local function handle_loot_roll(rollID, link_override)
  local link = link_override or GetLootRollItemLink(rollID)
  if not link then return end

  if auto_pass_enabled() then
    for _, needle in ipairs(auto_pass_items) do
      if string.find(link, needle, 1, true) then
        do_auto_roll(rollID, link, 0)
        return
      end
    end
  end

  local jc_roll = WeirdChromieDB and WeirdChromieDB.jc_design_roll
  if jc_roll == 0 or jc_roll == 1 or jc_roll == 2 then
    for _, needle in ipairs(jc_design_drops) do
      if string.find(link, needle, 1, true) then
        do_auto_roll(rollID, link, jc_roll)
        return
      end
    end
  end
end

local function handle_gossip_show()
  if not gossip_enabled() or IsControlKeyDown() then return end

  -- If quests are involved, leave it to the player
  if GetGossipAvailableQuests() or GetGossipActiveQuests() then return end

  local raw = { GetGossipOptions() }
  local opts = {}
  for i = 1, #raw, 2 do
    table.insert(opts, { text = raw[i], gossip = raw[i + 1] })
  end

  -- Single non-gossip option (e.g. lone vendor): just click it.
  -- With multiple options we never auto-click typed entries, a profession
  -- trainer who also sells, etc., needs the player to choose. Configured
  -- general/per-NPC skip lines below still fire regardless of option count.
  if opts[1] and not opts[2] and opts[1].gossip ~= "gossip" then
    SelectGossipOption(1)
    return
  end

  local npc_name = UnitName("npc")
  local npc_lines = npc_name and gossip_skip_by_npc[npc_name] or nil

  for i, entry in ipairs(opts) do
    if entry.gossip == "gossip" then
      for _, pattern in pairs(gossip_skip_by_npc.general) do
        if string.find(entry.text, pattern) then
          SelectGossipOption(i)
          return
        end
      end
      if npc_lines then
        for _, pattern in pairs(npc_lines) do
          if string.find(entry.text, pattern) then
            SelectGossipOption(i)
            return
          end
        end
      end
    end
  end
end

------------------------------

local function auto_dismount_enabled()
  return WeirdChromieDB and WeirdChromieDB.auto_dismount == true
end

local function handle_ui_error(msg)
  if not auto_dismount_enabled() then return end
  if msg ~= ERR_ATTACK_MOUNTED then return end
  if IsMounted() then Dismount() end
end

local WeirdChromie = CreateFrame("Frame", "WeirdChromie")
WeirdChromie:RegisterEvent("ADDON_LOADED")
WeirdChromie:RegisterEvent("GOSSIP_SHOW")
WeirdChromie:RegisterEvent("START_LOOT_ROLL")
WeirdChromie:RegisterEvent("CONFIRM_LOOT_ROLL")
WeirdChromie:RegisterEvent("UI_ERROR_MESSAGE")
WeirdChromie:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addon = ...
    if addon == "WeirdChromie" then
      WeirdChromieDB = WeirdChromieDB or {}
      if WeirdChromieDB.drake_enabled == nil then WeirdChromieDB.drake_enabled = true end
      if WeirdChromieDB.drake_locked  == nil then WeirdChromieDB.drake_locked  = false end
      if WeirdChromieDB.auto_pass_recipes == nil then WeirdChromieDB.auto_pass_recipes = false end
      if WeirdChromieDB.jc_design_roll == nil then WeirdChromieDB.jc_design_roll = 2 end
      if WeirdChromieDB.auto_dismount == nil then WeirdChromieDB.auto_dismount = false end
      if apply_drake_position then apply_drake_position() end
      if update_drake_button  then update_drake_button()  end
    end
  elseif event == "GOSSIP_SHOW" then
    handle_gossip_show()
  elseif event == "START_LOOT_ROLL" then
    -- START_LOOT_ROLL fires with (rollID, rollTime). Only forward rollID;
    -- handle_loot_roll's second arg is a test-mode link override.
    local rollID = ...
    handle_loot_roll(rollID)
  elseif event == "CONFIRM_LOOT_ROLL" then
    handle_confirm_loot_roll(...)
  elseif event == "UI_ERROR_MESSAGE" then
    handle_ui_error(...)
  end
end)

local function strip_colors(s)
  s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
  s = string.gsub(s, "|r", "")
  return s
end

local function debug_print(pattern_source, msg)
  if not (WeirdChromieDB and WeirdChromieDB.debug) then return end
  -- Escape '|' so color codes show as literal text in the capture line.
  local escaped = string.gsub(tostring(msg or ""), "|", "||")
  DEFAULT_CHAT_FRAME:AddMessage(
    "|cff33ff99[WC]|r caught by [" .. tostring(pattern_source) .. "] | " .. escaped)
end

local function system_filter(self, event, msg, ...)
  if not silence_enabled() then return false end
  local lowered = string.lower(strip_colors(msg or ""))

  for _, r in ipairs(system_rewrites) do
    local pos = string.find(lowered, r.needle, 1, true)
    if pos and (not r.anchored or pos == 1) then
      local out = r.replacement or (r.rewrite and r.rewrite(msg))
      if out then
        debug_print(r.label, msg)
        return false, out, ...
      end
    end
  end

  for _, entry in ipairs(compiled_patterns) do
    if entry.plain then
      local pos = string.find(lowered, entry.needle, 1, true)
      if pos and (not entry.anchored or pos == 1) then
        debug_print(entry.source, msg)
        return true
      end
    else
      if string.find(lowered, entry.guard, 1, true) and string.find(lowered, entry.needle) then
        debug_print(entry.source, msg)
        return true
      end
    end
  end
  return false
end

local function monster_yell_filter(self, event, msg, sender, ...)
  if not silence_enabled() then return false end
  if sender and ignore_npc[sender] then
    return true
  end
  return false
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", system_filter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_YELL", monster_yell_filter)

-- Forward declarations so the options panel's checkbox callbacks can
-- reach into the drake-button section defined further down.
local update_drake_button
local apply_drake_position

------------------------------
-- Interface Options panel (Esc -> Interface -> AddOns -> WeirdChromie)
------------------------------

local optionsPanel = CreateFrame("Frame", "WeirdChromieOptionsPanel")
optionsPanel.name = "WeirdChromie"

local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("WeirdChromie")

local subtitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetPoint("RIGHT", optionsPanel, -32, 0)
subtitle:SetJustifyH("LEFT")
subtitle:SetJustifyV("TOP")
subtitle:SetText("Silence ChromieCraft server spam and auto-skip routine NPC gossip dialogues.")

local function make_check(name, label, tooltip, anchor, x, y)
  local cb = CreateFrame("CheckButton", name, optionsPanel, "InterfaceOptionsCheckButtonTemplate")
  cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x or 0, y or -8)
  _G[cb:GetName() .. "Text"]:SetText(label)
  cb.tooltipText = tooltip
  return cb
end

local cbSilence = make_check(
  "WeirdChromieOptionSilence",
  "Silence server spam",
  "Filter out ChromieCraft server-spam system messages (BG/Arena queue announces, Top PvP leaderboard, server notices, etc.) and configured NPC yells.",
  subtitle, 0, -16)
cbSilence:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.silence = self:GetChecked() and true or false
end)

local cbGossip = make_check(
  "WeirdChromieOptionAutoGossip",
  "Auto-skip gossip dialogues",
  "Automatically click through routine NPC gossip options (taxi, vendor, banker, healer, dungeon-progression gossips like Chromie/Arthas in Culling of Stratholme, Oculus drake handlers, Halls of Stone Brann, etc.). Hold Ctrl to bypass for one interaction.",
  cbSilence)
cbGossip:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.auto_gossip = self:GetChecked() and true or false
end)

local cbAutoPass = make_check(
  "WeirdChromieOptionAutoPass",
  "Auto-pass on bandage and cooking recipes",
  "Automatically pass on group loot rolls for Heavy Frostweave Bandage and dungeon cooking recipes.",
  cbGossip)
cbAutoPass:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.auto_pass_recipes = self:GetChecked() and true or false
end)

local cbAutoDismount = make_check(
  "WeirdChromieOptionAutoDismount",
  "Auto-dismount flying mounts when attacking",
  "Automatically dismount from a flying mount when attempting an attack.",
  cbAutoPass)
cbAutoDismount:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.auto_dismount = self:GetChecked() and true or false
end)

-- JC design roll dropdown: Off / Pass / Greed / Need.
-- Stored value: false (off), 0 (pass), 1 (need), or 2 (greed).
local jc_roll_choices = {
  { text = "Off",   value = false },
  { text = "Pass",  value = 0 },
  { text = "Greed", value = 2 },
  { text = "Need",  value = 1 },
}

local function jc_roll_label(value)
  for _, c in ipairs(jc_roll_choices) do
    if c.value == value then return c.text end
  end
  return "Off"
end

local jcLabel = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
jcLabel:SetPoint("TOPLEFT", cbAutoDismount, "BOTTOMLEFT", 0, -16)
jcLabel:SetText("Auto-roll on BoP jewelcrafting designs from dungeon bosses:")

local jcDropdown = CreateFrame("Frame", "WeirdChromieOptionJCDropdown", optionsPanel, "UIDropDownMenuTemplate")
jcDropdown:SetPoint("TOPLEFT", jcLabel, "BOTTOMLEFT", -16, -4)
UIDropDownMenu_SetWidth(jcDropdown, 100)

UIDropDownMenu_Initialize(jcDropdown, function()
  for _, c in ipairs(jc_roll_choices) do
    local info = UIDropDownMenu_CreateInfo()
    info.text = c.text
    info.value = c.value
    info.checked = (WeirdChromieDB and WeirdChromieDB.jc_design_roll == c.value)
    info.func = function(self)
      WeirdChromieDB = WeirdChromieDB or {}
      WeirdChromieDB.jc_design_roll = self.value
      UIDropDownMenu_SetText(jcDropdown, jc_roll_label(self.value))
    end
    UIDropDownMenu_AddButton(info)
  end
end)

local cbDrakeEnabled = make_check(
  "WeirdChromieOptionDrakeEnabled",
  "Show Oculus drake essence button",
  "Show the movable drake-essence quick-use button while inside The Oculus and holding any drake essence in your bags.",
  jcDropdown, 16, -8)
cbDrakeEnabled:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.drake_enabled = self:GetChecked() and true or false
  if update_drake_button then update_drake_button() end
end)

local cbDrakeLocked = make_check(
  "WeirdChromieOptionDrakeLocked",
  "Lock position",
  "When unlocked, left-click and drag the drake-essence button to move it. Lock to prevent accidental drags.",
  cbDrakeEnabled)
-- Place on the same row as cbDrakeEnabled, just past its label.
cbDrakeLocked:ClearAllPoints()
cbDrakeLocked:SetPoint("LEFT", _G["WeirdChromieOptionDrakeEnabledText"], "RIGHT", 16, 0)
cbDrakeLocked:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.drake_locked = self:GetChecked() and true or false
end)

local btnDrakeReset = CreateFrame("Button", "WeirdChromieOptionDrakeReset", optionsPanel, "UIPanelButtonTemplate")
btnDrakeReset:SetWidth(110)
btnDrakeReset:SetHeight(22)
btnDrakeReset:SetPoint("LEFT", _G["WeirdChromieOptionDrakeLockedText"], "RIGHT", 12, 0)
btnDrakeReset:SetText("Reset Position")
btnDrakeReset.tooltipText = "Move the drake-essence button back to screen center."
btnDrakeReset:SetScript("OnClick", function()
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.drake_pos = nil
  if apply_drake_position then apply_drake_position() end
end)

local cbDebug = make_check(
  "WeirdChromieOptionDebug",
  "Debug capture (print silenced messages)",
  "When enabled, every system message WeirdChromie silences is also printed to the chat frame along with the pattern that caught it. Useful for adding new patterns.",
  cbDrakeEnabled)
cbDebug:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.debug = self:GetChecked() and true or false
end)

optionsPanel:SetScript("OnShow", function()
  WeirdChromieDB = WeirdChromieDB or {}
  cbSilence:SetChecked(WeirdChromieDB.silence ~= false)
  cbGossip:SetChecked(WeirdChromieDB.auto_gossip ~= false)
  cbAutoPass:SetChecked(WeirdChromieDB.auto_pass_recipes == true)
  cbAutoDismount:SetChecked(WeirdChromieDB.auto_dismount == true)
  UIDropDownMenu_SetText(jcDropdown, jc_roll_label(WeirdChromieDB.jc_design_roll))
  cbDrakeEnabled:SetChecked(WeirdChromieDB.drake_enabled ~= false)
  cbDrakeLocked:SetChecked(WeirdChromieDB.drake_locked ~= false)
  cbDebug:SetChecked(WeirdChromieDB.debug == true)
  if update_drake_button then update_drake_button() end
end)
optionsPanel:SetScript("OnHide", function()
  if update_drake_button then update_drake_button() end
end)
if InterfaceOptionsFrame then
  InterfaceOptionsFrame:HookScript("OnHide", function()
    if update_drake_button then update_drake_button() end
  end)
end

InterfaceOptions_AddCategory(optionsPanel)

local function open_options_panel()
  -- Quirk: in 3.3.5 the first call only expands the tree, second selects.
  InterfaceOptionsFrame_OpenToCategory(optionsPanel)
  InterfaceOptionsFrame_OpenToCategory(optionsPanel)
end

------------------------------
-- Drake essence button (Oculus drake mounts)
------------------------------
-- Standalone movable button. Click uses whichever item from DRAKE_ESSENCES
-- is currently in the player's bags. Outside DRAKE_ZONE the work is
-- short-circuited.
--
-- The two configs below are intentionally hoisted so they can be swapped
-- for testing (e.g. point them at food/drink in a leveling zone to verify
-- bag-scan, cache, and click-to-use without entering the dungeon).

-- local DRAKE_ZONE = "Borean Tundra"
local DRAKE_ZONE = "The Oculus"

local DRAKE_ESSENCES = {
  { name = "Ruby Essence",    icon = "Interface\\Icons\\inv_misc_head_dragon_01" },
  -- { name = "Frostberries",    icon = "Interface\\Icons\\inv_misc_head_dragon_01" },
  { name = "Amber Essence",   icon = "Interface\\Icons\\inv_misc_head_dragon_bronze" },
  -- { name = "Amber Essence",   icon = "Interface\\Icons\\inv_misc_head_dragon_bronze" },
  { name = "Emerald Essence", icon = "Interface\\Icons\\inv_misc_head_dragon_green" },
  -- { name = "Frostberry Juice", icon = "Interface\\Icons\\inv_misc_head_dragon_green" },
}

local drakeBtn = CreateFrame("Button", "WeirdChromieDrakeButton", UIParent, "SecureActionButtonTemplate")
drakeBtn:Hide()
-- Single secure macrotext dispatches both actions: leave the drake when in
-- the vehicle UI, otherwise /use the held essence. apply_essence rewrites
-- this when the held essence changes.
drakeBtn:SetAttribute("type", "macro")
drakeBtn:SetAttribute("macrotext",
  "/click [vehicleui] VehicleMenuBarLeaveButton\n/use [novehicleui] " .. DRAKE_ESSENCES[1].name)

-- Match the vehicle-leave button's natural size and effective scale
-- (parent chain may scale differently than UIParent). Queried dynamically
-- because both vary by client/skin and may not be set at file-load time.
local function sync_drake_size()
  local leave = VehicleMenuBarLeaveButton
  local w = leave and leave:GetWidth()  or 0
  local h = leave and leave:GetHeight() or 0
  if w > 0 and h > 0 then
    drakeBtn:SetWidth(w)
    drakeBtn:SetHeight(h)
  else
    drakeBtn:SetWidth(40)
    drakeBtn:SetHeight(40)
  end
  -- Match effective scale by compensating for our own parent's scale.
  -- We parent to UIParent, so SetScale must equal leave:GetEffectiveScale()
  -- divided by UIParent:GetEffectiveScale() to render at the same on-screen
  -- size as the leave button.
  if leave and leave.GetEffectiveScale then
    local le = leave:GetEffectiveScale()
    local ue = UIParent:GetEffectiveScale()
    if le and ue and ue > 0 then
      drakeBtn:SetScale(le / ue)
    end
  end
end
sync_drake_size()

-- Position. Defaults to screen center; saved coords live in
-- WeirdChromieDB.drake_pos and are applied after ADDON_LOADED.
drakeBtn:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

apply_drake_position = function()
  drakeBtn:ClearAllPoints()
  local p = WeirdChromieDB and WeirdChromieDB.drake_pos
  if p and p.point then
    drakeBtn:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
  else
    drakeBtn:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local function save_drake_position()
  local point, _, relPoint, x, y = drakeBtn:GetPoint()
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.drake_pos = { point = point, relPoint = relPoint, x = x, y = y }
end

drakeBtn:SetMovable(true)
drakeBtn:RegisterForDrag("LeftButton")
drakeBtn:SetScript("OnDragStart", function(self)
  if WeirdChromieDB and WeirdChromieDB.drake_locked == false
     and not InCombatLockdown() then
    self:StartMoving()
  end
end)
drakeBtn:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  save_drake_position()
end)

local drakeIcon = drakeBtn:CreateTexture(nil, "ARTWORK")
drakeIcon:SetAllPoints()
drakeIcon:SetTexture(DRAKE_ESSENCES[1].icon)

drakeBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(self._essenceName or DRAKE_ESSENCES[1].name)
  GameTooltip:AddLine("Use the Oculus drake essence currently in your bags.", 1, 1, 1, true)
  if WeirdChromieDB and WeirdChromieDB.drake_locked == false then
    GameTooltip:AddLine("Drag to move (button is unlocked).", 0.6, 0.8, 1, true)
  end
  GameTooltip:Show()
end)
drakeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function find_held_essence()
  for bag = 0, NUM_BAG_SLOTS do
    for slot = 1, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)
      if link then
        for _, e in ipairs(DRAKE_ESSENCES) do
          if string.find(link, e.name, 1, true) then
            return e
          end
        end
      end
    end
  end
  return nil
end

local cachedEssence = nil
local inOculus      = false

local function apply_essence(e)
  cachedEssence = e
  drakeIcon:SetTexture(e.icon)
  drakeBtn._essenceName = e.name
  drakeBtn:SetAttribute("macrotext",
    "/click [vehicleui] VehicleMenuBarLeaveButton\n/use [novehicleui] " .. e.name)
end

update_drake_button = function()
  if not (WeirdChromieDB and WeirdChromieDB.drake_enabled ~= false) then
    drakeBtn:Hide()
    return
  end
  if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown()
     and optionsPanel and optionsPanel:IsShown() then
    drakeBtn:Show()
    return
  end
  if GetRealZoneText() ~= DRAKE_ZONE then
    drakeBtn:Hide()
    return
  end

  local held = find_held_essence()
  if WeirdChromieDB and WeirdChromieDB.debug then
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cff33ff99[WC]|r drake: held=" ..
      tostring(held and held.name or "nil") ..
      " cached=" ..
      tostring(cachedEssence and cachedEssence.name or "nil"))
  end

  if held then
    if held ~= cachedEssence then apply_essence(held) end
    drakeBtn:Show()
  else
    cachedEssence = nil
    drakeBtn:Hide()
  end
end

local drakeEvents = CreateFrame("Frame")
drakeEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
drakeEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")

local function check_zone()
  local nowOculus = GetRealZoneText() == DRAKE_ZONE
  if nowOculus and not inOculus then
    inOculus = true
    drakeEvents:RegisterEvent("BAG_UPDATE")
    update_drake_button()
  elseif inOculus and not nowOculus then
    inOculus = false
    drakeEvents:UnregisterEvent("BAG_UPDATE")
    drakeBtn:Hide()
    cachedEssence = nil
  end
end

drakeEvents:SetScript("OnEvent", function(self, event)
  if event == "BAG_UPDATE" then
    update_drake_button()
  else
    if event == "PLAYER_ENTERING_WORLD" then
      sync_drake_size()
    end
    check_zone()
  end
end)

------------------------------

-- Synthetic item link wrapper for test rolls. Real links carry the full
-- |Hitem:id::::::::::|h header; for matching we only need the bracketed
-- name to appear inside the link string.
local function fake_item_link(name)
  return "|cffffffff|Hitem:0::::::::::|h[" .. name .. "]|h|r"
end

local test_roll_counter = 0
local function run_test_roll(link)
  test_mode = true
  test_roll_counter = test_roll_counter + 1
  local fake_id = test_roll_counter
  if WeirdChromieDB and WeirdChromieDB.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC test]|r START_LOOT_ROLL rollID=" .. tostring(fake_id) .. " link=" .. link)
  end
  handle_loot_roll(fake_id, link)
  -- If our decision queued a BoP confirm, exercise that path too.
  if pending_confirms[fake_id] then
    handle_confirm_loot_roll(fake_id, pending_confirms[fake_id])
    -- Force the deferred OnUpdate to run immediately so the print lands
    -- in the same command output instead of one tick later.
    local script = confirm_dispatcher:GetScript("OnUpdate")
    if script then script(confirm_dispatcher) end
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC test]|r no BoP confirm needed (pass or no match)")
  end
  test_mode = false
end

local function run_test_roll_all()
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC test]|r --- auto-pass patterns ---")
  for _, name in ipairs(auto_pass_items) do
    run_test_roll(fake_item_link(name))
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC test]|r --- jc-design patterns (rolls per current jc_design_roll setting) ---")
  for _, name in ipairs(jc_design_drops) do
    run_test_roll(fake_item_link(name))
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC test]|r --- no-match control ---")
  run_test_roll(fake_item_link("Linen Cloth"))
end

SLASH_WEIRDCHROMIE1 = "/wc"
SLASH_WEIRDCHROMIE2 = "/weirdchromie"
SlashCmdList["WEIRDCHROMIE"] = function(msg)
  msg = msg or ""
  local cmd, rest = string.match(msg, "^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd and string.lower(cmd) or ""
  if cmd == "testroll" then
    if not (WeirdChromieDB and WeirdChromieDB.debug) then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r enable Debug capture in /wc first to use testroll")
      return
    end
    if rest == "" then
      run_test_roll_all()
    else
      run_test_roll(rest)
    end
    return
  end
  open_options_panel()
end
