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
  '^[Quest Helper] This server automatically notifies',
  '^If you suspect another player of breaking',
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
  '^Tip: Join a guild and make friends',
  '^There is no guild recruitment in',
  '^BGs have boosted XP',

  '^Auction deposits are only', -- we need to determine real costs and adjust them

  '^Participants of the event can become revived', -- mass-PvP .fun return blurb

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
--   `rewrite(msg)`: a function returning the replacement string, nil to
--                   leave the message unchanged, or false to silence it.
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
  -- Mass-PvP teleport announcer. Fires every minute from ~6 down to 1.
  -- Compress to a one-liner; only emit at 5-minute intervals and at 1 min,
  -- silence the others.
  {
    label = "[mass-PvP announcer]",
    needle = "for mass-pvp",
    rewrite = function(msg)
      local mins, zone = string.match(msg,
        "In (%d+) minutes? .- teleported to (.-) for mass%-PvP")
      if not mins then return nil end
      local n = tonumber(mins)
      if n == 1 or (n > 0 and n % 5 == 0) then
        return "In " .. n .. "min " .. zone .. " mass-PvP begins. Type '.fun on' to join and '.fun return' after the event."
      end
      return false
    end,
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

-- Mailbox auto-delete: senders whose mail should be auto-cleared on
-- MAIL_INBOX_UPDATE. `name` is exact sender match. `item` is the only
-- attachment we'll take and destroy; if a mail from this sender carries
-- anything else, we leave it alone. Text-only mail from the sender is
-- always deleted. COD mail is always skipped.
local auto_delete_senders = {
  { name = "Minigob Manabonk", item = "The Mischief Maker" },
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
  -- Icecrown: free Saronite Mine Slaves.
  ["Saronite Mine Slave"] = {
    free = "^Go on, you're free",
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
-- RollOnLoot rollType: 0 = pass, 1 = need, 2 = greed, 3 = disenchant.
-- Need/Greed/DE on a BoP item shows the "Looting this item will bind it to
-- you" confirmation popup (CONFIRM_LOOT_ROLL event); the roll only commits
-- after ConfirmLootRoll(rollID, rollType). pending_confirms tracks rolls we
-- initiated so we don't auto-confirm popups from the player's own need-rolls.
local roll_labels = { [0] = "passed", [1] = "needed", [2] = "greeded", [3] = "disenchanted" }
local pending_confirms = {}

-- ElvUI's Misc:LootRoll module replaces Blizzard's group-loot UI and relies
-- on CANCEL_LOOT_ROLL to release its frames. RollOnLoot called from Lua
-- doesn't fire that event (the default frame hides via its own button OnClick
-- handler, not via the event), so we call ElvUI's ReleaseFrame directly.
-- The START_LOOT_ROLL listener is re-registered on PLAYER_ENTERING_WORLD so
-- our dispatch runs after ElvUI's (which registers on PLAYER_LOGIN), meaning
-- the frame already exists in M.RollBars when we look it up.
local function release_elvui_roll_frame(rollID)
  local ElvUI = _G.ElvUI
  if not ElvUI then return end
  local E = ElvUI[1]
  if not (E and E.GetModule) then return end
  local M = E:GetModule("Misc", true)
  if not (M and M.RollBars and M.ReleaseFrame) then return end
  for _, frame in ipairs(M.RollBars) do
    if frame.rollID == rollID then
      M:ReleaseFrame(frame)
      return
    end
  end
end

local function do_auto_roll(rollID, link, rollType)
  if rollType == 1 or rollType == 2 or rollType == 3 then
    pending_confirms[rollID] = rollType
  end
  RollOnLoot(rollID, rollType)
  release_elvui_roll_frame(rollID)
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
    ConfirmLootRoll(rollID, rollType)
    StaticPopup_Hide("CONFIRM_LOOT_ROLL", rollID)
    if WeirdChromieDB and WeirdChromieDB.debug then
      DEFAULT_CHAT_FRAME:AddMessage(
        "|cff33ff99[WC]|r confirmed BoP roll " .. tostring(rollID) ..
        " (" .. (roll_labels[rollType] or tostring(rollType)) .. ")")
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

local function handle_loot_roll(rollID)
  local link = GetLootRollItemLink(rollID)
  local debug_on = WeirdChromieDB and WeirdChromieDB.debug
  if debug_on then
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cff33ff99[WC dbg]|r START_LOOT_ROLL rollID=" .. tostring(rollID) ..
      " link=" .. tostring(link) ..
      " auto_pass=" .. tostring(auto_pass_enabled()))
  end
  if not link then return end

  if auto_pass_enabled() then
    for _, needle in ipairs(auto_pass_items) do
      if string.find(link, needle, 1, true) then
        if debug_on then
          DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[WC dbg]|r matched auto-pass needle: " .. needle)
        end
        do_auto_roll(rollID, link, 0)
        return
      end
    end
  end

  local db = WeirdChromieDB
  local jc_roll = db and db.jc_design_roll
  if jc_roll == 0 or jc_roll == 1 or jc_roll == 2 then
    for _, needle in ipairs(jc_design_drops) do
      if string.find(link, needle, 1, true) then
        do_auto_roll(rollID, link, jc_roll)
        return
      end
    end
  end

  -- BoE green handling. GetLootRollItemInfo returns:
  -- texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant.
  if not db then return end
  local _, _, _, quality, bindOnPickUp, _, _, canDisenchant = GetLootRollItemInfo(rollID)
  if quality ~= 2 or bindOnPickUp then return end

  local boe = db.boe_green_roll
  if boe == 0 or boe == 1 or boe == 2 or boe == 3 then
    local rollType = boe
    if rollType == 3 then
      if not canDisenchant then
        rollType = 2
      elseif db.boe_skip_de_weapons then
        local _, _, _, _, _, itemType, itemSubType = GetItemInfo(link)
        if itemType == "Weapon" or itemSubType == "Shields" then rollType = 2 end
      end
    end
    do_auto_roll(rollID, link, rollType)
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

local function auto_delete_mail_enabled()
  return not WeirdChromieDB or WeirdChromieDB.auto_delete_mail ~= false
end

local function sender_entry(sender)
  if not sender then return nil end
  for _, e in ipairs(auto_delete_senders) do
    if sender == e.name then return e end
  end
  return nil
end

-- True if every attachment slot present matches the expected item name.
-- WotLK attachment slots span 1..ATTACHMENTS_MAX_RECEIVE (16); not contiguous.
local function attachments_ok(i, expected)
  for slot = 1, ATTACHMENTS_MAX_RECEIVE do
    local name = GetInboxItem(i, slot)
    if name and name ~= expected then return false end
  end
  return true
end

local function find_attachment_slot(i, expected)
  for slot = ATTACHMENTS_MAX_RECEIVE, 1, -1 do
    if GetInboxItem(i, slot) == expected then return slot end
  end
end

local function has_free_bag_slot()
  for bag = 0, NUM_BAG_SLOTS do
    local free, family = GetContainerNumFreeSlots(bag)
    if family == 0 and free and free > 0 then return true end
  end
  return false
end

local function bag_count_item(name)
  local total = 0
  for bag = 0, NUM_BAG_SLOTS do
    local numSlots = GetContainerNumSlots(bag) or 0
    for slot = 1, numSlots do
      local link = GetContainerItemLink(bag, slot)
      if link and string.find(link, name, 1, true) then
        local _, c = GetContainerItemInfo(bag, slot)
        total = total + (c or 1)
      end
    end
  end
  return total
end

-- Destroys up to `amount` of `name` from bags. Splits the last partial
-- stack as needed. DeleteCursorItem on common-quality items is silent;
-- uncommon+ would trigger a confirmation popup we'd need to handle.
local function destroy_from_bags(name, amount)
  for bag = 0, NUM_BAG_SLOTS do
    local numSlots = GetContainerNumSlots(bag) or 0
    for slot = 1, numSlots do
      if amount <= 0 then return end
      local link = GetContainerItemLink(bag, slot)
      if link and string.find(link, name, 1, true) then
        local _, c = GetContainerItemInfo(bag, slot)
        c = c or 1
        ClearCursor()
        if c <= amount then
          PickupContainerItem(bag, slot)
          DeleteCursorItem()
          amount = amount - c
        else
          SplitContainerItem(bag, slot, amount)
          DeleteCursorItem()
          return
        end
      end
    end
  end
end

-- pending_destroy is set after TakeInboxItem so the next tick can verify
-- the item actually landed in the bag (the take is async) and then destroy
-- exactly the delivered quantity. Bails after ~3s if the item never shows.
local pending_destroy = nil

local function process_one_spam_mail()
  if pending_destroy then
    local now = bag_count_item(pending_destroy.item)
    local delta = now - pending_destroy.before
    if delta >= pending_destroy.added then
      destroy_from_bags(pending_destroy.item, pending_destroy.added)
      pending_destroy = nil
      return true
    end
    pending_destroy.waited = pending_destroy.waited + 1
    if pending_destroy.waited > 8 then
      pending_destroy = nil
    end
    return true
  end

  local count = GetInboxNumItems and GetInboxNumItems() or 0
  if count == 0 then return false end

  for i = count, 1, -1 do
    local _, _, sender, subject, money, codAmount = GetInboxHeaderInfo(i)
    local entry = sender_entry(sender)
    if entry and not (codAmount and codAmount > 0)
       and attachments_ok(i, entry.item) then
      local slot = find_attachment_slot(i, entry.item)
      if slot and has_free_bag_slot() then
        local _, _, attachCount = GetInboxItem(i, slot)
        pending_destroy = {
          item    = entry.item,
          before  = bag_count_item(entry.item),
          added   = attachCount or 1,
          waited  = 0,
        }
        TakeInboxItem(i, slot)
        return true
      end
      if money and money > 0 then
        TakeInboxMoney(i)
        return true
      end
      if not InboxItemCanDelete or InboxItemCanDelete(i) then
        DeleteInboxItem(i)
        return true
      end
    end
  end
  return false
end

local mail_ticker = CreateFrame("Frame")
mail_ticker:Hide()
mail_ticker.elapsed = 0
mail_ticker.idle = 0
mail_ticker:SetScript("OnUpdate", function(self, elapsed)
  self.elapsed = self.elapsed + elapsed
  if self.elapsed < 0.35 then return end
  self.elapsed = 0
  if process_one_spam_mail() then
    self.idle = 0
  else
    self.idle = self.idle + 1
    if self.idle > 4 then
      self:Hide()
      self.idle = 0
    end
  end
end)

local function handle_mail_inbox_update()
  if not auto_delete_mail_enabled() then return end
  mail_ticker.elapsed = 0
  mail_ticker.idle = 0
  mail_ticker:Show()
end

local function handle_ui_error(msg)
  if not auto_dismount_enabled() then return end
  if msg ~= ERR_ATTACK_MOUNTED then return end
  if IsMounted() then Dismount() end
end

local WeirdChromie = CreateFrame("Frame", "WeirdChromie")
WeirdChromie:RegisterEvent("ADDON_LOADED")
WeirdChromie:RegisterEvent("GOSSIP_SHOW")
WeirdChromie:RegisterEvent("PLAYER_ENTERING_WORLD")
WeirdChromie:RegisterEvent("START_LOOT_ROLL")
WeirdChromie:RegisterEvent("CONFIRM_LOOT_ROLL")
WeirdChromie:RegisterEvent("UI_ERROR_MESSAGE")
WeirdChromie:RegisterEvent("MAIL_INBOX_UPDATE")
WeirdChromie:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addon = ...
    if addon == "WeirdChromie" then
      WeirdChromieDB = WeirdChromieDB or {}
      if WeirdChromieDB.drake_enabled == nil then WeirdChromieDB.drake_enabled = true end
      if WeirdChromieDB.drake_locked  == nil then WeirdChromieDB.drake_locked  = false end
      if WeirdChromieDB.auto_pass_recipes == nil then WeirdChromieDB.auto_pass_recipes = false end
      if WeirdChromieDB.jc_design_roll == nil then WeirdChromieDB.jc_design_roll = false end
      if WeirdChromieDB.boe_green_roll == nil then WeirdChromieDB.boe_green_roll = false end
      if WeirdChromieDB.boe_skip_de_weapons == nil then WeirdChromieDB.boe_skip_de_weapons = true end
      if WeirdChromieDB.auto_dismount == nil then WeirdChromieDB.auto_dismount = false end
      if WeirdChromieDB.auto_delete_mail == nil then WeirdChromieDB.auto_delete_mail = true end
      if WeirdChromieDB.skytalon_selfcast == nil then WeirdChromieDB.skytalon_selfcast = true end
      if apply_drake_position then apply_drake_position() end
      if update_drake_button  then update_drake_button()  end
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- ElvUI's LootRoll module registers its START_LOOT_ROLL handler during
    -- PLAYER_LOGIN (Misc.lua initialize callback). We register at file-load
    -- time so ours runs first by default, which means we'd call
    -- release_elvui_roll_frame before ElvUI has created the frame. By
    -- unregistering and re-registering on PLAYER_ENTERING_WORLD (which fires
    -- after PLAYER_LOGIN), we get pushed to the end of the dispatch list and
    -- run after ElvUI. Same-tick: ElvUI creates the frame, we release it,
    -- renderer paints once -> no visible flash.
    self:UnregisterEvent("START_LOOT_ROLL")
    self:RegisterEvent("START_LOOT_ROLL")
  elseif event == "GOSSIP_SHOW" then
    handle_gossip_show()
  elseif event == "START_LOOT_ROLL" then
    -- START_LOOT_ROLL fires with (rollID, rollTime). Only forward rollID.
    local rollID = ...
    handle_loot_roll(rollID)
  elseif event == "CONFIRM_LOOT_ROLL" then
    handle_confirm_loot_roll(...)
  elseif event == "UI_ERROR_MESSAGE" then
    handle_ui_error(...)
  elseif event == "MAIL_INBOX_UPDATE" then
    handle_mail_inbox_update()
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
      local out
      if r.replacement then
        out = r.replacement
      elseif r.rewrite then
        out = r.rewrite(msg)
      end
      if out == false then
        debug_print(r.label, msg)
        return true
      elseif out then
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
local apply_skytalon_override
local clear_skytalon_override

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
cbGossip:ClearAllPoints()
cbGossip:SetPoint("TOPLEFT", cbSilence, "TOPLEFT", 360, 0)
cbGossip:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.auto_gossip = self:GetChecked() and true or false
end)

local cbAutoPass = make_check(
  "WeirdChromieOptionAutoPass",
  "Auto-pass on bandage and cooking recipes",
  "Automatically pass on group loot rolls for Heavy Frostweave Bandage and dungeon cooking recipes.",
  cbSilence)
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

local cbAutoDeleteMail = make_check(
  "WeirdChromieOptionAutoDeleteMail",
  "Auto-delete Manabonks",
  "Automatically take and destroy The Mischief Maker from Minigob Manabonk mail, then delete the mail.",
  cbSilence)
cbAutoDeleteMail:ClearAllPoints()
cbAutoDeleteMail:SetPoint("TOPLEFT", cbSilence, "TOPLEFT", 180, 0)
cbAutoDeleteMail:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.auto_delete_mail = self:GetChecked() and true or false
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
jcLabel:SetText("JC Recipes")
jcLabel.tooltipText = "Auto-roll on the BoP jewelcrafting designs that drop from Northrend dungeon bosses."

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

-- BoE green dropdown: Off / Pass / Greed / Need / DE.
-- Stored value: false (off), 0 (pass), 1 (need), 2 (greed), 3 (disenchant).
local boe_roll_choices = {
  { text = "Off",   value = false },
  { text = "Pass",  value = 0 },
  { text = "Greed", value = 2 },
  { text = "Need",  value = 1 },
  { text = "Disenchant", value = 3 },
}

local function boe_roll_label(value)
  for _, c in ipairs(boe_roll_choices) do
    if c.value == value then return c.text end
  end
  return "Off"
end

local boeLabel = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
boeLabel:SetPoint("TOPLEFT", jcLabel, "TOPLEFT", 140, 0)
boeLabel:SetText("BoE Greens")
boeLabel.tooltipText = "Auto-roll on uncommon (green) BoE drops."

local boeDropdown = CreateFrame("Frame", "WeirdChromieOptionBoEDropdown", optionsPanel, "UIDropDownMenuTemplate")
boeDropdown:SetPoint("TOPLEFT", boeLabel, "BOTTOMLEFT", -16, -4)
UIDropDownMenu_SetWidth(boeDropdown, 120)

UIDropDownMenu_Initialize(boeDropdown, function()
  for _, c in ipairs(boe_roll_choices) do
    local info = UIDropDownMenu_CreateInfo()
    info.text = c.text
    info.value = c.value
    info.checked = (WeirdChromieDB and WeirdChromieDB.boe_green_roll == c.value)
    info.func = function(self)
      WeirdChromieDB = WeirdChromieDB or {}
      WeirdChromieDB.boe_green_roll = self.value
      UIDropDownMenu_SetText(boeDropdown, boe_roll_label(self.value))
    end
    UIDropDownMenu_AddButton(info)
  end
end)

local cbBoeSkipDeWeapons = make_check(
  "WeirdChromieOptionBoeSkipDeWeapons",
  "Do not DE weapons/shields",
  "When the BoE roll is Disenchant, roll Greed on weapons and shields instead.",
  boeDropdown, 16, -4)
cbBoeSkipDeWeapons:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.boe_skip_de_weapons = self:GetChecked() and true or false
end)

local cbDrakeEnabled = make_check(
  "WeirdChromieOptionDrakeEnabled",
  "Show Oculus drake essence button",
  "Show the movable drake-essence quick-use button while inside The Oculus and holding any drake essence in your bags.",
  jcDropdown, 16, -32)
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

local cbSkytalon = make_check(
  "WeirdChromieOptionSkytalon",
  "Self-cast Skytalon heals",
  "Eye of Eternity Phase 3, override Revivify and Life Burst to cast on yourself if you have no target or the target is hostile.",
  cbDrakeEnabled)
cbSkytalon:SetScript("OnClick", function(self)
  WeirdChromieDB = WeirdChromieDB or {}
  WeirdChromieDB.skytalon_selfcast = self:GetChecked() and true or false
  if WeirdChromieDB.skytalon_selfcast then
    if apply_skytalon_override then apply_skytalon_override() end
  else
    if clear_skytalon_override then clear_skytalon_override() end
  end
end)

local cbDebug = make_check(
  "WeirdChromieOptionDebug",
  "Debug capture (print silenced messages)",
  "When enabled, every system message WeirdChromie silences is also printed to the chat frame along with the pattern that caught it. Useful for adding new patterns.",
  cbSkytalon)
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
  cbAutoDeleteMail:SetChecked(WeirdChromieDB.auto_delete_mail ~= false)
  UIDropDownMenu_SetText(jcDropdown, jc_roll_label(WeirdChromieDB.jc_design_roll))
  UIDropDownMenu_SetText(boeDropdown, boe_roll_label(WeirdChromieDB.boe_green_roll))
  cbBoeSkipDeWeapons:SetChecked(WeirdChromieDB.boe_skip_de_weapons ~= false)
  cbDrakeEnabled:SetChecked(WeirdChromieDB.drake_enabled ~= false)
  cbDrakeLocked:SetChecked(WeirdChromieDB.drake_locked ~= false)
  cbSkytalon:SetChecked(WeirdChromieDB.skytalon_selfcast == true)
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
-- Eye of Eternity: Wyrmrest Skytalon friendly-target self-cast
------------------------------
-- Revivify (slot 3) and Life Burst (slot 4) on the Skytalon vehicle bar
-- want a friendly target. We override the keys bound to those action
-- slots while inside Eye of Eternity. Each override fires a macrotext
-- that casts the spell on the player when in the vehicle UI, and falls
-- through to clicking the underlying action button otherwise, so P1/P2
-- on the ground still behaves identically.
--
-- SetOverrideBindingClick is combat-locked, so we install at zone-entry
-- (PLAYER_ENTERING_WORLD into EoE happens out of combat) rather than on
-- UNIT_ENTERED_VEHICLE (which would fire mid-P3-combat and silently
-- fail). PLAYER_REGEN_ENABLED reconciles the rare /reload-in-combat case.

local SKYTALON_ZONE = "The Eye of Eternity"
local SKYTALON_SELFCAST = {
  { spell = "Revivify",   slot = 3 },
  { spell = "Life Burst", slot = 4 },
}

-- Each button uses a secure state driver to swap modes:
--   in vehicle UI: type=macro, macrotext casts the spell on @player.
--   out of vehicle: type=action, action=N, fires the player's action slot N
--     directly via the secure action handler. Independent of which action-
--     bar mod owns the visible button — /click ActionButtonN silently fails
--     under ElvUI/etc. because the Blizzard frame is hidden, but invoking
--     the action slot via the secure handler does not.
local skytalon_buttons = {}
for i, entry in ipairs(SKYTALON_SELFCAST) do
  local btn = CreateFrame("Button", "WeirdChromieSkytalon" .. i,
    UIParent, "SecureActionButtonTemplate,SecureHandlerStateTemplate")
  btn:Hide()
  btn:SetAttribute("type", "action")
  btn:SetAttribute("action", entry.slot)
  btn:SetAttribute("_onstate-veh", string.format([[
    self:SetAttribute("last-state", newstate)
    if newstate == "in" then
      self:SetAttribute("type", "macro")
      self:SetAttribute("macrotext", "/target [noexists][harm] vehicle\n/cast %s")
    else
      self:SetAttribute("type", "action")
      self:SetAttribute("action", %d)
    end
  ]], entry.spell, entry.slot))
  skytalon_buttons[i] = btn
end

local skytalon_override_active = false

local function skytalon_should_install()
  return WeirdChromieDB and WeirdChromieDB.skytalon_selfcast
     and GetRealZoneText() == SKYTALON_ZONE
end

apply_skytalon_override = function()
  if skytalon_override_active then return end
  if InCombatLockdown() then return end
  if not skytalon_should_install() then return end
  local verbose = WeirdChromieDB and WeirdChromieDB.debug
  for i, entry in ipairs(SKYTALON_SELFCAST) do
    local btn = skytalon_buttons[i]
    RegisterStateDriver(btn, "veh", "[vehicleui][bonusbar:5] in; out")
    -- State driver only fires the snippet on state changes; set the
    -- current mode manually so toggling on while already mounted works.
    if UnitInVehicle and UnitInVehicle("player") then
      btn:SetAttribute("type", "macro")
      btn:SetAttribute("macrotext",
        "/target [noexists][harm] vehicle\n/cast " .. entry.spell)
      btn:SetAttribute("last-state", "in")
    else
      btn:SetAttribute("type", "action")
      btn:SetAttribute("action", entry.slot)
      btn:SetAttribute("last-state", "out")
    end
    local k1, k2 = GetBindingKey("ACTIONBUTTON" .. entry.slot)
    if k1 then
      SetOverrideBindingClick(btn, true, k1, btn:GetName(), "LeftButton")
    end
    if k2 then
      SetOverrideBindingClick(btn, true, k2, btn:GetName(), "LeftButton")
    end
    if verbose then
      DEFAULT_CHAT_FRAME:AddMessage(
        "|cff33ff99[WC]|r Skytalon " .. entry.spell ..
        ": ACTIONBUTTON" .. entry.slot .. " bound to '" ..
        tostring(k1 or "<none>") .. "'" ..
        (k2 and ("/'" .. k2 .. "'") or "") ..
        " -> " .. btn:GetName())
    end
  end
  skytalon_override_active = true
end

clear_skytalon_override = function()
  if InCombatLockdown() then return end
  for _, btn in ipairs(skytalon_buttons) do
    ClearOverrideBindings(btn)
    UnregisterStateDriver(btn, "veh")
    btn:SetAttribute("type", "action")
    btn:SetAttribute("last-state", nil)
  end
  skytalon_override_active = false
end

local skytalonEvents = CreateFrame("Frame")
skytalonEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
skytalonEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
skytalonEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
skytalonEvents:SetScript("OnEvent", function()
  if skytalon_should_install() then
    apply_skytalon_override()
  else
    clear_skytalon_override()
  end
end)

------------------------------
-- LFG cooldown-frame refresh fix
------------------------------
-- LFDQueueFrameRandomCooldownFrame_Update reads each party member's status
-- from UnitHasLFGDeserter / UnitHasLFGRandomCooldown (hidden aura checks).
-- Blizzard only re-runs that update on UNIT_AURA / PLAYER_ENTERING_WORLD /
-- PARTY_MEMBERS_CHANGED, so if the aura table for a freshly-joined member
-- hasn't synced when the LFG frame opens, that member shows as READY and
-- nothing ever corrects it. Add the LFG_* events Blizzard left off, plus
-- an OnShow re-request and a slow ticker while the frame is visible.

local lfgFix = CreateFrame("Frame", "WeirdChromieLFGCooldownFix")
lfgFix:RegisterEvent("PLAYER_LOGIN")
lfgFix:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")

  local cd = _G.LFDQueueFrameCooldownFrame
  local update = _G.LFDQueueFrameRandomCooldownFrame_Update
  if not (cd and update) then return end

  cd:RegisterEvent("LFG_LOCK_INFO_RECEIVED")
  cd:RegisterEvent("LFG_UPDATE_RANDOM_INFO")
  cd:RegisterEvent("LFG_UPDATE")
  cd:HookScript("OnEvent", function(self, event)
    if event == "LFG_LOCK_INFO_RECEIVED"
       or event == "LFG_UPDATE_RANDOM_INFO"
       or event == "LFG_UPDATE" then
      update()
    end
  end)

  local random = _G.LFDQueueFrameRandom
  if random then
    random:HookScript("OnShow", function()
      if RequestLFDPartyLockInfo then RequestLFDPartyLockInfo() end
      update()
    end)
  end

  local parent = _G.LFDParentFrame
  if parent then
    parent:HookScript("OnShow", function()
      if RequestLFDPartyLockInfo then RequestLFDPartyLockInfo() end
      update()
    end)
  end

  -- Slow heartbeat while the LFG window is up. UNIT_AURA-driven refresh is
  -- the primary path; this is a 5s fallback for the case where the aura
  -- arrives without firing UNIT_AURA for the unit we care about. Lives on
  -- its own frame because LFDQueueFrameRandomCooldownFrame_Update clears
  -- the cooldown frame's OnUpdate when the player is off cooldown.
  local heartbeat = CreateFrame("Frame")
  heartbeat:Hide()
  local elapsedAcc = 0
  heartbeat:SetScript("OnUpdate", function(self, elapsed)
    elapsedAcc = elapsedAcc + (elapsed or 0)
    if elapsedAcc >= 5 then
      elapsedAcc = 0
      update()
    end
  end)
  if parent then
    parent:HookScript("OnShow", function() elapsedAcc = 0; heartbeat:Show() end)
    parent:HookScript("OnHide", function() heartbeat:Hide() end)
  end

end)

------------------------------

SLASH_WEIRDCHROMIE1 = "/wc"
SLASH_WEIRDCHROMIE2 = "/weirdchromie"
SlashCmdList["WEIRDCHROMIE"] = function()
  open_options_panel()
end
