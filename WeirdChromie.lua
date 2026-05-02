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

local ignore_npc = {
  ["Fizzle \"The Sharpened Scissors\""] = true, -- barber
  ["Pierre \"Le Coiffeur\" Dufresne"] = true, -- barber
  ["Tansy Sparkpen"] = true, -- gadgetzan times
  ["Fara Boltbreaker"] = true, -- gadgetzan times
}

------------------------------
-- Gossip skip (ported from LazyWeirdo)
------------------------------

-- Don't skip trainer (often used for untalent); spirit healer has its own confirm.
local auto_gossip_types = {
  taxi = true, battlemaster = true, vendor = true, banker = true, healer = true,
}

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
  -- listed (e.g. "Why have I been sent back…", "So how does the Infinite
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
  },
  ["Eternos"] = {
    bronze_flight = "wings of the bronze flight",
  },
  ["Belgaristrasz"] = {
    where_next = "^So where do we go from here",
    red_flight = "wings of the red flight",
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

local function handle_gossip_show()
  if not gossip_enabled() or IsControlKeyDown() then return end

  -- Brainwasher has a single gossip option but selecting it skips the quest
  if UnitName("npc") == "Goblin Brainwashing Device" then return end

  -- If quests are involved, leave it to the player
  if GetGossipAvailableQuests() or GetGossipActiveQuests() then return end

  local raw = { GetGossipOptions() }
  local opts = {}
  for i = 1, #raw, 2 do
    table.insert(opts, { text = raw[i], gossip = raw[i + 1] })
  end

  -- Single non-gossip option (e.g. lone vendor): just click it.
  if opts[1] and not opts[2] and opts[1].gossip ~= "gossip" then
    SelectGossipOption(1)
    return
  end

  local npc_name = UnitName("npc")
  local npc_lines = npc_name and gossip_skip_by_npc[npc_name] or nil

  for i, entry in ipairs(opts) do
    if auto_gossip_types[entry.gossip] then
      SelectGossipOption(i)
      return
    end
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

local WeirdChromie = CreateFrame("Frame", "WeirdChromie")
WeirdChromie:RegisterEvent("ADDON_LOADED")
WeirdChromie:RegisterEvent("GOSSIP_SHOW")
WeirdChromie:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addon = ...
    if addon == "WeirdChromie" then
      WeirdChromieDB = WeirdChromieDB or {}
    end
  elseif event == "GOSSIP_SHOW" then
    handle_gossip_show()
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

  -- Truncate verbose [SERVER] announces at the first period (keep just the
  -- headline like "[SERVER] Restart in 11 minute(s)." and drop the rest).
  -- Color escapes never contain '.', so the first '.' in the raw message
  -- is always a content period.
  if string.find(lowered, "[server]", 1, true) == 1 then
    local pos = string.find(msg, ".", 1, true)
    if pos then
      debug_print("[SERVER] truncate", msg)
      return false, string.sub(msg, 1, pos) .. "|r", ...
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
  "Automatically click through routine NPC gossip options (taxi, vendor, banker, healer, plus per-NPC scripted skips). Hold Ctrl to bypass for one interaction.",
  cbSilence)
cbGossip:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.auto_gossip = self:GetChecked() and true or false
end)

local cbDebug = make_check(
  "WeirdChromieOptionDebug",
  "Debug capture (print silenced messages)",
  "When enabled, every system message WeirdChromie silences is also printed to the chat frame along with the pattern that caught it. Useful for adding new patterns.",
  cbGossip)
cbDebug:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.debug = self:GetChecked() and true or false
end)

optionsPanel:SetScript("OnShow", function()
  WeirdChromieDB = WeirdChromieDB or {}
  cbSilence:SetChecked(WeirdChromieDB.silence ~= false)
  cbGossip:SetChecked(WeirdChromieDB.auto_gossip ~= false)
  cbDebug:SetChecked(WeirdChromieDB.debug == true)
end)

InterfaceOptions_AddCategory(optionsPanel)

local function open_options_panel()
  -- Quirk: in 3.3.5 the first call only expands the tree, second selects.
  InterfaceOptionsFrame_OpenToCategory(optionsPanel)
  InterfaceOptionsFrame_OpenToCategory(optionsPanel)
end

------------------------------

SLASH_WEIRDCHROMIE1 = "/wc"
SLASH_WEIRDCHROMIE2 = "/weirdchromie"
SlashCmdList["WEIRDCHROMIE"] = function(arg)
  arg = string.lower(arg or "")
  WeirdChromieDB = WeirdChromieDB or {}
  if arg == "debug" or arg == "debug on" then
    WeirdChromieDB.debug = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r debug capture: ON")
  elseif arg == "debug off" then
    WeirdChromieDB.debug = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r debug capture: OFF")
  elseif arg == "gossip" or arg == "gossip on" then
    WeirdChromieDB.auto_gossip = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r auto-gossip: ON")
  elseif arg == "gossip off" then
    WeirdChromieDB.auto_gossip = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r auto-gossip: OFF")
  elseif arg == "silence" or arg == "silence on" then
    WeirdChromieDB.silence = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r silence: ON")
  elseif arg == "silence off" then
    WeirdChromieDB.silence = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC]|r silence: OFF")
  else
    open_options_panel()
  end
end
