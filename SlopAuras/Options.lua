-- Options: the in-game editor, AceConfigDialog's own window (/slop).
--
-- Built with AceConfig (Libs/AceConfig-3.0): this file describes the settings
-- as a table, and AceConfigDialog draws them with WoW-style widgets. The table
-- is rebuilt from ns.groups whenever the panel asks for it, so adding and
-- removing groups needs nothing special.
--
-- Every setter writes straight into the saved group or display table, then
-- calls ns.Changed. Clearing a display's own value makes it fall back to its
-- group again (metatables, see ns.Prepare in SlopAuras.lua).

local addonName, ns = ...
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

local POINTS = {
  TOPLEFT = "Top left", TOP = "Top", TOPRIGHT = "Top right",
  LEFT = "Left", CENTER = "Center", RIGHT = "Right",
  BOTTOMLEFT = "Bottom left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom right",
}
-- Reading order, as on the icon.
local POINT_ORDER = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }
local OUTLINES = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick outline" }
local ALIGNS = { LEFT = "Left", CENTER = "Center", RIGHT = "Right" }
local LSM = LibStub("LibSharedMedia-3.0")

-- Fonts registered with LibSharedMedia (SharedMedia and other addons add
-- theirs), after "[default game font]": the text's own, which differs between
-- the timer (the countdown's font) and stacks (NumberFontNormal).
local function FontValues()
  local values = { default = "[default game font]" }
  for _, name in ipairs(LSM:List("font")) do
    values[name] = name
  end
  return values
end

local function FontSorting()
  local list = { "default" }
  for _, name in ipairs(LSM:List("font")) do
    table.insert(list, name)
  end
  return list
end

-- A dropdown item that draws its font's name in that font (AceConfig's
-- `itemControl`). AceGUI pools widgets by type and never resets an item's
-- font, so this is its own type: a stock item with a changed font would turn
-- up in other addons' dropdowns. Fonts load when the list first opens.
local FONT_ITEM = "SlopAuras-FontItem"
do
  local AceGUI = LibStub("AceGUI-3.0")
  AceGUI:RegisterWidgetType(FONT_ITEM, function()
    local item = AceGUI.WidgetRegistry["Dropdown-Item-Toggle"]()
    item.type = FONT_ITEM
    local SetText = item.SetText
    -- The item's text is the font's name (FontValues), or "[default game font]".
    function item.SetText(self, text)
      SetText(self, text)
      local face, size, flags = GameFontNormalSmall:GetFont()
      self.text:SetFont(text and LSM:Fetch("font", text, true) or face, size, flags)
    end
    return item
  end, 1)
end
local GROWTHS = {
  RIGHT = "Right", LEFT = "Left", DOWN = "Down", UP = "Up",
  CENTER = "Centered (horizontal)", CENTER_VERTICAL = "Centered (vertical)",
}
local GROWTH_ORDER = { "RIGHT", "LEFT", "DOWN", "UP", "CENTER", "CENTER_VERTICAL" }
-- In the order a joined row runs through them (KIND_ORDER in SlopAuras.lua).
local TARGETS = {
  { "player", "You" }, { "target", "Your target" },
  { "focus", "Your focus" }, { "party", "Party members" },
  { "partypet", "Party pets" }, { "raid", "Raid members" },
  { "raidpet", "Raid pets" }, { "nameplate", "Nameplates" },
}
local MODES = { list = "Matching auras", missing = "Icon when none match" }

-- Loaded before us (OptionalDeps), so this is settled at file load.
local HAS_MASQUE = LibStub("Masque", true) ~= nil

-- Refresh the panel, e.g. after the tree changed.
local function Refresh()
  AceConfigRegistry:NotifyChange(addonName)
  AceConfigRegistry:NotifyChange(addonName .. " test mode") -- group names and the list
end

local function Changed(structural)
  ns.Changed(structural)
  if structural then
    Refresh()
  end
end

-- Spell IDs ------------------------------------------------------------------

-- "123, !456" -> { [123] = true, [456] = false }: ! hides that spell.
local function ParseIDs(text)
  local set
  for bang, id in text:gmatch("(!?)%s*(%d+)") do
    set = set or {}
    set[tonumber(id)] = bang == ""
  end
  return set
end

local function SortedIDs(set)
  local ids = {}
  for id in pairs(set or {}) do
    table.insert(ids, id)
  end
  table.sort(ids)
  return ids
end

local function IDsText(set)
  local parts = {}
  for _, id in ipairs(SortedIDs(set)) do
    table.insert(parts, (set[id] and "" or "!") .. id)
  end
  return table.concat(parts, ", ")
end

-- One line per ID: icon, name, ID. With ranks, also how many ranks it covers.
local function DescribeIDs(set, ranks)
  local lines = {}
  for _, id in ipairs(SortedIDs(set)) do
    local name = C_Spell.GetSpellName(id)
    local icon = C_Spell.GetSpellTexture(id)
    if name then
      local line = ("|T%s:16|t %s  |cff808080(%d)|r"):format(icon or 134400, name, id)
      if not set[id] then
        line = "|cffff4040Hidden:|r " .. line
      end
      if ranks then
        local family = ns.SpellRanks(id)
        line = line .. (family and ("  all %d ranks"):format(#family)
          or "  |cffffd100no other ranks known, matches exactly|r")
      end
      table.insert(lines, line)
    else
      table.insert(lines, ("|cffff4040%d: no such spell|r"):format(id))
    end
  end
  return table.concat(lines, "\n")
end

-- Shared pieces --------------------------------------------------------------

-- WoW edit boxes show a typed | as ||, and saving the text back doubles it
-- again each round. The game skips empty pieces (IsValidFilterString), so
-- runs of | mean one; this keeps them from growing.
local function CleanFilter(value)
  return (value:gsub("|+", "|"):gsub("^|", ""):gsub("|$", ""))
end

local function ValidateFilter(_, value)
  if value == "" then
    return true
  end
  local ok, problem = AuraUtil.IsValidFilterString(value)
  return ok or problem
end

local function SortValues()
  local values = {}
  for name in pairs(AuraContainerSortMethod) do
    values[name] = name
  end
  return values
end

-- Returns true if it moved.
local function Move(list, index, by)
  local other = index + by
  if list[other] then
    list[index], list[other] = list[other], list[index]
    Changed(true)
    return true
  end
end

local function GroupByName(name)
  for _, group in ipairs(ns.groups) do
    if group.name == name then
      return group
    end
  end
end

-- A group by its options key, "g<id>".
local function GroupByKey(key)
  for _, group in ipairs(ns.groups) do
    if "g" .. group.id == key then
      return group
    end
  end
end

-- Groups in name order, as the editor lists them. Their order in ns.groups
-- does nothing outside the editor.
local function SortedGroups()
  local list = { unpack(ns.groups) }
  table.sort(list, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
  return list
end

local function UniqueName(base)
  local name, n = base, 1
  while GroupByName(name) do
    n = n + 1
    name = base .. " " .. n
  end
  return name
end

-- Displays -------------------------------------------------------------------

-- Whether the display at list index `index` starts a line that can wrap
-- (LineWrap in SlopAuras.lua): it's the first display, or the first after a
-- line break; the line has no missing displays, the group isn't showing only
-- its first line, and its lines aren't shared by several units.
local function CanWrap(group, index)
  local list = group.displays
  local prev = list[index - 1]
  if prev and prev.mode ~= "break" or group.firstLine or not ns.SingleRow(group) then
    return false
  end
  for j = index, #list do
    if list[j].mode == "break" then
      break
    end
    if list[j].mode == "missing" then
      return false
    end
  end
  return true
end

-- A display's own name, or one made from its spell, filter or mode. rawget:
-- a display without a name would read its group's through the metatable.
local function DisplayLabel(display)
  local own = rawget(display, "name")
  if own then
    return own
  end
  local label
  local ids = ns.Chain.SpellIDs(display)
  if ids then
    local id = SortedIDs(ids)[1]
    label = id and C_Spell.GetSpellName(id) or "spell IDs"
  else
    label = display.filter
  end
  if display.mode == "missing" then
    label = "Missing: " .. label
  end
  return label
end

local function DisplayName(display, index)
  return index .. ". " .. DisplayLabel(display)
end

local ALERT = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:0|t"

-- What the editor calls a line: a row when icons grow sideways, a column when
-- they grow up or down. Players found "row" clearer than "line".
local function RowWord(group, plural)
  local word = ns.Chain.Vertical(group.growth) and "column" or "row"
  return plural and word .. "s" or word
end

local function Capital(text)
  return (text:gsub("^%l", string.upper))
end

local function FirstLineTitle(group)
  return ("\"Show only the first %s\" doesn't work with these icon sizes"):format(RowWord(group))
end

-- Why "Show only the first row" is ignored (ns.FirstLineConflict), above the
-- group's tabs, so it also shows over the displays, where sizes are usually
-- changed. With two lines, moving the smaller one last
-- fixes it; with more, a line in between would be on top, so it joins the
-- last line instead.
local function FirstLineWarning(group, order)
  return {
    type = "description", order = order, width = "full", fontSize = "medium",
    name = function()
      local conflict = ns.FirstLineConflict(group)
      if not conflict then
        return ""
      end
      local row, rows = RowWord(group), RowWord(group, true)
      local small, big = DisplayLabel(conflict.small.display), DisplayLabel(conflict.big.display)
      local move = conflict.lines == 2 and ("move it to the last %s"):format(row)
          or ("put it on the same %s as \"%s\""):format(row, DisplayLabel(conflict.last))
      local body = ("\"%s\" (%dpx) is smaller than \"%s\" (%dpx). Make \"%s\" %dpx, or %s. All %s show until then.")
          :format(small, conflict.small.size, big, conflict.big.size, small, conflict.big.size, move, rows)
      return ALERT .. " |cffff9933" .. FirstLineTitle(group) .. "|r\n" .. body
    end,
    hidden = function() return ns.FirstLineConflict(group) == nil end,
  }
end

-- Appearance, Load conditions ------------------------------------------------
-- The same two tabs on a group (defaults for its displays) and on a display.
-- Every control shows the value in effect. On a display, a value of its own
-- has an asterisk on its label, and the tooltip says where the value comes
-- from; changing a control makes the value the display's own. Right-clicking a
-- control clears it (HookWidgets).

local function ClassValues()
  local values = {}
  for _, class in ipairs(CLASS_SORT_ORDER) do
    local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class
    local color = C_ClassColor.GetClassColor(class)
    values[class] = color and color:WrapTextInColorCode(name) or name
  end
  return values
end

-- `class` may be saved as one string (older saves) or a list.
local function ClassList(value)
  if type(value) == "string" then
    return value ~= "" and { value } or {}
  end
  return value or {}
end

-- AceConfigDialog flows controls left to right and wraps where they run out of
-- room. A full-width empty description forces a new row.
local function Break(order)
  return { type = "description", order = order, name = "", width = "full" }
end

-- Icons for Link as inline escapes, from art this client's own UI uses (the
-- arrows are the action bar's page buttons, MainActionBar.xml).
local LINK_ICONS = {
  up = "|A:ui-hud-actionbar-pageuparrow-up:14:14|a",
  down = "|A:ui-hud-actionbar-pagedownarrow-up:14:14|a",
  duplicate = "|TInterface\\Buttons\\UI-PlusButton-Up:14|t",
  delete = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:14|t",
}

-- A clickable line of text in place of a button, for secondary actions (an
-- execute drawn by AceGUI's InteractiveLabel). It has no hover highlight, so
-- an icon and gold text mark it as clickable. The icon is inline: the label only puts its own image beside the
-- text with 200px to spare, and AceConfigDialog's `image` path calls SetLabel,
-- which InteractiveLabel lacks. Each link is as wide as its text, measured in
-- the label's font (GameFontHighlightSmall, AceGUIWidget-Label.lua), plus the
-- icon and a fixed gap. `extra` adds option fields (confirm).
local measure
local function LinkWidth(text)
  if not measure then
    measure = UIParent:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
    measure:Hide()
  end
  measure:SetText(text)
  return (measure:GetStringWidth() + 14 + 4 + 16) / 170
end

-- `desc` is required: the tooltip is a link's only response to the mouse, and
-- without a desc it would just repeat the text.
local function Link(order, icon, text, desc, func, extra)
  local option = {
    type = "execute", order = order, width = LinkWidth(text), dialogControl = "InteractiveLabel",
    name = ("%s |cffffd100%s|r"):format(LINK_ICONS[icon], text),
    desc = desc, func = func,
  }
  for key, value in pairs(extra or {}) do
    option[key] = value
  end
  return option
end

-- Filter picker ---------------------------------------------------------------
-- A Pick filters button beside a filter box opens checkboxes for the tokens in
-- AuraUtil.AuraFilters. Left out: MAW (Torghast only) and
-- INCLUDE_NAME_PLATE_ONLY (nameplate lines add it, see FilterFor in Chain.lua).
-- Tristate checkboxes cycle true -> nil -> false (AceGUIWidget-CheckBox
-- ToggleChecked), read here as include -> exclude -> absent. Each click saves;
-- the boxes read the saved filter, so typing in the box shows up in them.

local FILTER_TOKENS = {
  -- No exclude state: a filter needs one of these two to match anything.
  { "HELPFUL", "Buffs.", noNegate = true },
  { "HARMFUL", "Debuffs.", noNegate = true },
  { "PLAYER", "Cast by you or your pet." },
  { "RAID", "Buffs you can cast, and debuffs you can dispel." },
  { "CANCELABLE", "Auras you can right-click off." },
  { "CROWD_CONTROL", "Stuns, fears, polymorphs and other crowd control." },
  { "DISPELLABLE", "Auras anyone can dispel." },
  { "RAID_PLAYER_DISPELLABLE", "Auras someone in your group can dispel." },
  { "RAID_IN_COMBAT", "Auras the game shows on raid frames in combat." },
  { "EXTERNAL_DEFENSIVE", "Defensive buffs cast on the unit by someone else." },
  { "BIG_DEFENSIVE", "Big defensive cooldowns." },
  { "IMPORTANT", "Auras the game marks as important." },
}

local listedTokens = {}
for _, entry in ipairs(FILTER_TOKENS) do
  listedTokens[entry[1]] = true
end

local openPicker -- the group or display whose picker is open

-- Returns token -> true (include) or false (exclude), and the parts the
-- picker doesn't list, in order, so a save keeps them.
local function ParseFilter(text)
  local marks, others = {}, {}
  for _, part in ipairs({ string.split("| ", text or "") }) do
    if part ~= "" then
      local negated = part:sub(1, 1) == "!"
      local token = negated and part:sub(2) or part
      if listedTokens[token] then
        marks[token] = not negated
      else
        table.insert(others, part)
      end
    end
  end
  return marks, others
end

local function BuildFilter(marks, others)
  local parts = {}
  for _, entry in ipairs(FILTER_TOKENS) do
    local mark = marks[entry[1]]
    if mark ~= nil then
      table.insert(parts, (mark and "" or "!") .. entry[1])
    end
  end
  for _, part in ipairs(others) do
    table.insert(parts, part)
  end
  return table.concat(parts, "|")
end

-- A filter matches nothing without HELPFUL or HARMFUL: the client searches
-- one of the two lists (every filter Blizzard builds names one, e.g.
-- Blizzard_NamePlateAuras.lua), yet AuraUtil.IsValidFilterString accepts it.
local function HasAuraType(filter)
  local marks = ParseFilter(filter)
  return marks.HELPFUL == true or marks.HARMFUL == true
end

-- Adds the Pick filters button at `order`, a warning when the filter has no
-- HELPFUL or HARMFUL, and the checkboxes under it to `args`. get() returns the filter the boxes show; set(text) saves one, ""
-- when nothing is ticked.
local function AddFilterPicker(args, order, key, get, set)
  args.filterPick = {
    type = "execute", order = order, width = 0.8,
    name = function() return openPicker == key and "Hide" or "Pick filters" end,
    func = function()
      openPicker = openPicker ~= key and key or nil
      Refresh()
    end,
  }

  local pickArgs = {
    help = {
      type = "description", order = 0, width = "full",
      name = "Click once to include, again to exclude, a third time to clear.",
    },
  }
  for i, entry in ipairs(FILTER_TOKENS) do
    local token = entry[1]
    local function Mark()
      return (ParseFilter(get()))[token]
    end
    pickArgs[token] = {
      type = "toggle", order = i, width = 1.5, desc = entry[2], tristate = not entry.noNegate,
      name = function()
        return Mark() == false and ("|cffff4040!%s|r"):format(token) or token
      end,
      get = function()
        local mark = Mark()
        if mark == false then
          return nil
        end
        return mark == true
      end,
      set = function(_, value)
        local marks, others = ParseFilter(get())
        if value == nil then
          marks[token] = false
        else
          marks[token] = value or nil
        end
        set(BuildFilter(marks, others))
      end,
    }
    if i % 2 == 0 then
      pickArgs["break" .. i] = Break(i + 0.5)
    end
  end

  args.filterWarning = {
    type = "description", order = order + 0.005, width = "full", fontSize = "medium",
    name = "|cffff9933Add HELPFUL (buffs) or HARMFUL (debuffs), or this filter matches nothing.|r",
    hidden = function() return HasAuraType(get()) end,
  }

  args.filterPicker = {
    type = "group", inline = true, order = order + 0.01, name = "Filter",
    hidden = function() return openPicker ~= key end,
    args = pickArgs,
  }
end

-- Returns the Appearance, Text and Load conditions tabs for `t`, a group or a display.
-- `extra`: controls only a display has, placed in the Appearance sections.
local function SharedTabs(t, isDisplay, extra)
  -- On a display, an asterisk marks the display's own values; unmarked ones
  -- come from the group. It contrasts with the label: white after the yellow
  -- labels above sliders and dropdowns, yellow after a checkbox's white one.
  -- `keys`: one key, or a list for a control that sets several.
  local function OwnsAny(keys)
    for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
      if rawget(t, key) ~= nil then
        return true
      end
    end
    return false
  end

  local function Label(key, label, whiteLabel)
    local color = whiteLabel and "ffffd100" or "ffffffff"
    return function()
      if isDisplay and OwnsAny(key) then
        return label .. "|c" .. color .. "*|r"
      end
      return label
    end
  end

  -- Tooltip for a control on `key` (or a list of keys): what it does, plus,
  -- on a display with its own value, how to get the group's back.
  local function Desc(key, text)
    return function()
      if isDisplay and OwnsAny(key) then
        return text .. "\n\nRight click to reset to group's value."
      end
      return text
    end
  end

  -- Never load decides which containers are built (SplitLines in SlopAuras.lua).
  local STRUCTURAL = { neverLoad = true }

  local function Set(key, value)
    t[key] = value
    Changed(STRUCTURAL[key] == true)
  end

  -- `arg` is the one free-form field AceConfig allows on an option;
  -- OnRightClick looks for `reset` in it.
  local function Resettable(option, key)
    if isDisplay then
      option.arg = {
        reset = function()
          if OwnsAny(key) then
            local structural = false
            for _, k in ipairs(type(key) == "table" and key or { key }) do
              t[k] = nil
              structural = structural or STRUCTURAL[k] == true
            end
            Changed(structural)
            Refresh()
          end
        end,
      }
    end
    return option
  end

  local function Range(key, order, label, min, max, step, isPercent, desc)
    return Resettable({
      type = "range", order = order, name = Label(key, label), desc = Desc(key, desc),
      min = min, max = max, step = step, isPercent = isPercent,
      get = function() return t[key] end,
      set = function(_, value) Set(key, value) end,
    }, key)
  end

  local function Toggle(key, order, label, desc)
    return Resettable({
      type = "toggle", order = order, width = 1.5, name = Label(key, label, true), desc = Desc(key, desc),
      get = function() return t[key] == true end,
      set = function(_, value) Set(key, value) end,
    }, key)
  end

  -- A dropdown for a three-way key (Wants in SlopAuras.lua): true, false, or
  -- any. A display saves "any" so it can override a group's true/false.
  local function ThreeWay(key, order, label, yes, no, desc)
    return Resettable({
      type = "select", order = order, name = Label(key, label), desc = Desc(key, desc),
      values = { any = "Any", yes = yes, no = no }, sorting = { "any", "yes", "no" },
      get = function()
        local value = t[key]
        return value == true and "yes" or value == false and "no" or "any"
      end,
      set = function(_, value)
        if value == "any" then
          Set(key, isDisplay and "any" or nil)
        else
          Set(key, value == "yes")
        end
      end,
    }, key)
  end

  -- "Off" for a look key: false on a display, so it overrides the group's
  -- value; nil on a group.
  local function Off()
    if isDisplay then
      return false
    end
  end

  -- For settings about a list of aura icons.
  local function ListOnly()
    return isDisplay and t.mode == "missing"
  end

  local function HasAnyBorder()
    return type(t.borderColor) == "table" or t.dispelBorder == true
  end

  -- Whether a Masque skin draws the icon's frame and border. A saved "masque"
  -- without Masque loaded draws as skin "none".
  local function IsMasque()
    return HAS_MASQUE and t.skin == "masque"
  end

  -- Three checkboxes over two keys: glowCombat ("always", "in", "out" or
  -- "never") and glowInRange (true hides the glow out of range).
  local function InCombat(value)
    local mode = t.glowCombat or "always"
    if value == "in" then
      return mode == "always" or mode == "in"
    end
    return mode == "always" or mode == "out"
  end

  local function SetCombat(inCombat, outOfCombat)
    local mode = inCombat and outOfCombat and "always" or inCombat and "in" or outOfCombat and "out" or "never"
    -- A display saves "always" so it can override a group's other choice.
    Set("glowCombat", (mode ~= "always" or isDisplay) and mode or nil)
  end

  local function GlowWhenBox()
    return {
      type = "group", inline = true, order = 8.4, name = "Glow when",
      hidden = function() return not t.glow end,
      args = {
        inCombat = Resettable({
          type = "toggle", order = 1, width = 1.5, name = Label("glowCombat", "In combat", true),
          desc = Desc("glowCombat", "Glows while you're in combat."),
          get = function() return InCombat("in") end,
          set = function(_, value) SetCombat(value, InCombat("out")) end,
        }, "glowCombat"),
        outOfCombat = Resettable({
          type = "toggle", order = 2, width = 1.5, name = Label("glowCombat", "Out of combat", true),
          desc = Desc("glowCombat", "Glows while you're out of combat."),
          get = function() return InCombat("out") end,
          set = function(_, value) SetCombat(InCombat("in"), value) end,
        }, "glowCombat"),
        rowBreak = Break(2.5),
        outOfRange = Resettable({
          type = "toggle", order = 3, width = 1.5, name = Label("glowInRange", "Out of range", true),
          desc = Desc("glowInRange", "Party and raid members only. Hides glows when units are out of range/faded out. "
            .. "In combat or bgs, always glows."),
          get = function() return not t.glowInRange end,
          -- A display saves false so it can override a group's true.
          set = function(_, value) Set("glowInRange", not value or Off()) end,
        }, "glowInRange"),
      },
    }
  end

  -- One box of settings for a text on the icon (StyleString in Chain.lua):
  -- `prefix` "timer" or "stack", `hideKey` hides the text and greys the rest.
  -- `moreArgs(Select, Disabled)` returns more args for this box only.
  local function TextBox(boxOrder, title, prefix, hideKey, hideLabel, hideDesc, moreArgs)
    local function Key(name)
      return prefix .. name
    end
    local function Disabled()
      return t[hideKey] == true
    end
    local function Select(name, order, label, values, sorting, desc)
      local key = Key(name)
      return Resettable({
        type = "select", order = order, name = Label(key, label), desc = Desc(key, desc),
        values = values, sorting = sorting, disabled = Disabled,
        get = function() return t[key] end,
        set = function(_, value) Set(key, value) end,
      }, key)
    end
    local function Slider(name, order, label, min, max, desc)
      local option = Range(Key(name), order, label, min, max, 1, nil, desc)
      option.disabled = Disabled
      return option
    end

    local font = Select("Font", 2, "Font", FontValues, FontSorting,
      "Fonts from SharedMedia and other addons that register them. [default game font]: the font the game "
      .. "uses for this text, which differs between the timer and stacks.")
    font.itemControl = FONT_ITEM
    font.get = function() return t[Key("Font")] or "default" end
    -- A display saves false for the game font, so it can override a group's.
    font.set = function(_, value) Set(Key("Font"), value ~= "default" and value or Off()) end

    local box = {
      type = "group", inline = true, order = boxOrder, name = title,
      args = {
        hide = Toggle(hideKey, 1, hideLabel, hideDesc),
        break1 = Break(1.5),
        font = font,
        size = Slider("Size", 3, "Size", 6, 32, "Font size of the text."),
        outline = Select("Outline", 4, "Outline", OUTLINES, { "NONE", "OUTLINE", "THICKOUTLINE" },
          "The outline drawn around the letters."),
        break2 = Break(4.5),
        point = Select("Point", 5, "Position", POINTS, POINT_ORDER, "Where on the icon the text sits."),
        align = Select("Align", 6, "Alignment", ALIGNS, { "LEFT", "CENTER", "RIGHT" },
          "Which side of the text sits on Position. At a right-hand corner, Right keeps the text inside the icon "
          .. "and Left starts it there, running outward."),
        break3 = Break(6.5),
        x = Slider("X", 7, "X", -50, 50, "Moves the text right (positive) or left (negative) from Position, in pixels."),
        y = Slider("Y", 8, "Y", -50, 50, "Moves the text up (positive) or down (negative) from Position, in pixels."),
        break4 = Break(8.5),
        color = Resettable({
          type = "color", order = 9, name = Label(Key("Color"), "Color", true), desc = Desc(Key("Color"), "The text's color."),
          disabled = Disabled,
          get = function() return unpack(t[Key("Color")]) end,
          set = function(_, r, g, b) Set(Key("Color"), { r, g, b }) end,
        }, Key("Color")),
      },
    }
    for name, option in pairs(moreArgs and moreArgs(Select, Disabled) or {}) do
      box.args[name] = option
    end
    return box
  end

  -- The timer's number format (TimerFormatter in Chain.lua), on a row of its
  -- own under Hide timer.
  local function TimerFormatArgs(Select, Disabled)
    local decimals = Range("timerDecimals", 1.7, "Increase precision below", 0, 60, 1)
    decimals.desc = Desc("timerDecimals", "Under this many seconds left, the timer shows decimals. 0 turns them off.")
    decimals.get = function() return t.timerDecimals or 0 end
    decimals.disabled = Disabled
    local precision = Select("Precision", 1.8, "Precision", { "12.3", "12.34", "12.345" }, { 1, 2, 3 },
      "Decimal places under Increase precision below. Blizzard's format shows one.")
    precision.disabled = function()
      return Disabled() or t.timerFormat == "blizzard" or not t.timerDecimals or t.timerDecimals == 0
    end
    return {
      format = Select("Format", 1.6, "Format",
        { blizzard = "Blizzard", clock = "Clock: 3:07", short = "Short: 3m", long = "Long: 3m 7s" },
        { "blizzard", "clock", "short", "long" },
        "How the timer reads at about an hour, three minutes and ten seconds left.\n"
        .. "Clock: 63:42, 3:07, 10\nShort: 2h, 3m, 10s\nLong: 1h 3m, 3m 7s, 10s\n"
        .. "Blizzard: the game's own countdown."),
      decimals = decimals,
      precision = precision,
      formatBreak = Break(1.9),
    }
  end

  local look = {
    type = "group", name = "Appearance",
    args = {
      size = Range("size", 1, "Size", 8, 128, 1, nil, "Width and height of each icon, in pixels."),
      spacing = Range("spacing", 2, "Spacing", 0, 40, 1, nil, "Gap between icons, in pixels."),
      alpha = Range("alpha", 3, "Alpha", 0, 1, 0.05, true, "How opaque the icons are. 100% is fully visible."),
      break1 = Break(3.9),
      zoom = Range("zoom", 4, "Zoom", 0, 1, 0.01, true),
      max = Range("max", 4.3, "Max icons shown", 1, 40, 1, nil,
        "Maximum number of icons this display shows."),
      break1b = Break(4.9),
      sort = {
        type = "select", order = 6, name = Label("sort", "Sort"),
        desc = Desc("sort", "The order icons are placed in. Default is the game's own order."), values = SortValues(),
        get = function() return t.sort or "Default" end,
        set = function(_, value) Set("sort", value) end,
      },
      sortReverse = Toggle("sortReverse", 6.1, "Reverse sort", "Flips the sort order."),
      break2 = Break(6.9),
      tintMode = {
        type = "select", order = 7, name = Label("tint", "Tint"),
        desc = Desc("tint", "Colors the icon art."),
        values = { none = "None", custom = "Custom" },
        get = function() return type(t.tint) == "table" and "custom" or "none" end,
        -- A display's "none" is saved as false, so it can override a group's tint.
        set = function(_, value) Set("tint", value == "custom" and { 1, 0.85, 0.2 } or Off()) end,
      },
      tint = {
        type = "color", order = 8, name = "Tint color",
        hidden = function() return type(t.tint) ~= "table" end,
        get = function() return unpack(t.tint) end,
        set = function(_, r, g, b) Set("tint", { r, g, b }) end,
      },
      break2a = Break(8.01),
      -- Two questions: what frames the icon (skin), and which color its border
      -- has (dispelBorder / borderColor). With a Masque skin the skin draws
      -- the border as its ring; without one, borderStyle says how we draw it.
      skin = {
        type = "select", order = 8.02, name = Label("skin", "Skin"),
        values = { masque = "Masque", none = "None" },
        sorting = { "masque", "none" },
        hidden = function() return not HAS_MASQUE end,
        get = function() return t.skin end,
        set = function(_, value) Set("skin", value) end,
      },
      borderSource = {
        type = "select", order = 8.021,
        name = Label({ "dispelBorder", "borderColor" }, "Border"),
        values = { none = "None", dispel = "Dispel color", custom = "Custom" },
        sorting = { "none", "dispel", "custom" },
        get = function()
          return type(t.borderColor) == "table" and "custom" or t.dispelBorder == true and "dispel" or "none"
        end,
        -- A display saves false so it can override its group.
        set = function(_, value)
          if value == "custom" then
            t.borderColor = { 1, 1, 1 }
          elseif value == "dispel" then
            t.borderColor, t.dispelBorder = Off(), true
          else
            t.borderColor, t.dispelBorder = Off(), Off()
          end
          Changed(false)
        end,
      },
      borderStyle = {
        type = "select", order = 8.03, name = Label("borderStyle", "Border style"),
        values = { blizzard = "Blizzard", plain = "Plain" },
        sorting = { "blizzard", "plain" },
        hidden = function() return not HasAnyBorder() or IsMasque() end,
        get = function() return t.borderStyle == "plain" and "plain" or "blizzard" end,
        -- A display saves "blizzard" so it can override a group's plain.
        set = function(_, value) Set("borderStyle", (value ~= "blizzard" or isDisplay) and value or nil) end,
      },
      break2ab = Break(8.04),
      borderColor = {
        type = "color", order = 8.05, name = "Color",
        hidden = function() return type(t.borderColor) ~= "table" end,
        get = function() return unpack(t.borderColor) end,
        set = function(_, r, g, b) Set("borderColor", { r, g, b }) end,
      },
      borderWidth = Range("borderWidth", 8.06, "Border width", 1, 8, 1, nil, "How thick the plain border is, in pixels."),
      break2b = Break(8.1),
      glowMode = {
        type = "select", order = 8.2, name = Label("glow", "Glow"),
        values = { none = "None", gold = "Gold", custom = "Custom" },
        get = function()
          return type(t.glow) == "table" and "custom" or t.glow and "gold" or "none"
        end,
        -- A display's "none" is saved as false, so it can override a group's glow.
        set = function(_, value)
          Set("glow", value == "custom" and { 1, 1, 1 } or value == "gold" or Off())
        end,
      },
      glow = {
        type = "color", order = 8.3, name = "Glow color",
        hidden = function() return type(t.glow) ~= "table" end,
        get = function() return unpack(t.glow) end,
        set = function(_, r, g, b) Set("glow", { r, g, b }) end,
      },
      glowWhen = GlowWhenBox(),
      break3 = Break(8.9),
      desaturate = Toggle("desaturate", 9, "Desaturate", "Shows the icon art in grayscale."),
      hideSwipe = Toggle("hideSwipe", 10, "Hide swipe"),
      tooltip = Resettable({
        type = "select", order = 10.5, name = Label("tooltip", "Tooltips"),
        desc = Desc("tooltip", "Hover an icon to see the aura's tooltip. Your clicks still reach the frame "
          .. "underneath. Mouseover macros miss that frame's unit while the cursor is on an icon."),
        values = { never = "Never", always = "Always", out = "Out of combat" },
        sorting = { "never", "always", "out" },
        hidden = ListOnly,
        get = function() return t.tooltip end,
        -- A display saves "never" so it can override a group's choice.
        set = function(_, value) Set("tooltip", (value ~= "never" or isDisplay) and value or nil) end,
      }, "tooltip"),
      break4 = Break(10.9),
    },
  }
  -- Missing icons have neither text.
  local text = {
    type = "group", name = "Text", hidden = ListOnly,
    args = {
      timer = TextBox(1, "Timer", "timer", "hideTimer", "Hide timer", "Hides the time-left countdown on each icon.",
        TimerFormatArgs),
      stacks = TextBox(2, "Stacks", "stack", "hideStacks", "Hide stacks", "Hides the stack count on each icon."),
    },
  }
  look.args.zoom.desc = Desc("zoom", "Crops the icon's edges. At 0% you see the whole texture, including the border drawn into it.")
  look.args.hideSwipe.desc = Desc("hideSwipe", "Hides the dark sweep that shows time left. The timer text still counts down.")
  look.args.hideSwipe.hidden = ListOnly
  look.args.max.hidden = ListOnly
  look.args.sort.hidden = ListOnly
  look.args.sortReverse.hidden = ListOnly

  -- About you and where you are. A group's classes decide whether it loads at
  -- all (structural); a display's only hide that display.
  local you = {
    type = "group", inline = true, order = 1, name = "Your character",
    args = {
      class = {
        type = "multiselect", order = 0, width = "full", values = ClassValues,
        name = Label("class", "Classes (none ticked: all)"),
        desc = Desc("class", "Shows only on characters of the ticked classes. None ticked: every class."),
        get = function(_, item) return tContains(ClassList(t.class), item) end,
        set = function(_, item, on)
          local list = CopyTable(ClassList(t.class))
          if on and not tContains(list, item) then
            table.insert(list, item)
          elseif not on then
            tDeleteItem(list, item)
          end
          t.class = list
          Changed(not isDisplay)
        end,
      },
      combat = {
        type = "select", order = 1, name = Label("combat", "Combat state"),
        desc = Desc("combat", "Shows only in combat, only out of combat, or either."),
        values = { always = "Any", ["in"] = "In combat", out = "Out of combat" },
        sorting = { "always", "in", "out" },
        get = function() return t.combat or "always" end,
        -- A display saves "always" so it can override a group's in/out.
        set = function(_, value) Set("combat", (value ~= "always" or isDisplay) and value or nil) end,
      },
      resting = ThreeWay("resting", 1.01, "Resting state", "Resting", "Not resting",
        "Shows only while resting (in an inn or city), only while not, or either."),
      mounted = ThreeWay("mounted", 1.02, "Mounted state", "Mounted", "Not mounted",
        "Shows only while mounted, only while not, or either."),
      breakState = Break(1.05),
      nameplateUnits = {
        type = "select", order = 1.1, name = Label("nameplateUnits", "Which nameplates"),
        desc = Desc("nameplateUnits", "Friendly nameplates only appear outside instances, and only with friendly "
          .. "nameplates turned on in the game's options."),
        values = { enemy = "Enemies", friendly = "Friendly", all = "Both" },
        hidden = function()
          local target = t.target
          return not (target == "nameplate" or type(target) == "table" and tContains(target, "nameplate"))
        end,
        get = function() return t.nameplateUnits end,
        -- A display saves "enemy" so it can override a group's other choice.
        set = function(_, value) Set("nameplateUnits", (value ~= "enemy" or isDisplay) and value or nil) end,
      },
      knownSpell = {
        type = "input", order = 1.92, name = Label("knownSpell", "Only if you know spell"),
        desc = Desc("knownSpell", "Spell IDs separated by commas. Shows once you know any of them, e.g. 588 for "
          .. "Inner Fire. Put ! before an ID to show only while you don't know it: !588. Leave empty to show either way."),
        -- Saved as one ID or a list; negative for !.
        get = function()
          local parts = {}
          for i, id in ipairs(type(t.knownSpell) == "table" and t.knownSpell or { t.knownSpell }) do
            parts[i] = id < 0 and "!" .. -id or tostring(id)
          end
          return table.concat(parts, ", ")
        end,
        set = function(_, value)
          local ids = {}
          for bang, id in value:gmatch("(!?)%s*(%d+)") do
            table.insert(ids, (bang == "!" and -1 or 1) * tonumber(id))
          end
          Set("knownSpell", #ids > 1 and ids or ids[1])
        end,
      },
      break0 = Break(1.9),
      knownSpellName = {
        type = "description", order = 1.95, width = "full",
        name = function()
          local spell, set = t.knownSpell, {}
          for _, id in ipairs(type(spell) == "table" and spell or { spell }) do
            set[math.abs(id)] = true
          end
          return DescribeIDs(set)
        end,
        hidden = function() return t.knownSpell == nil end,
      },
      breakSpell = Break(1.97),
      hideWhenPlayerDead = Toggle("hideWhenPlayerDead", 3.55, "Hide while you're dead",
        "Hides while you're dead or a ghost."),
      neverLoad = Toggle("neverLoad", 3.6, "Never load", "Turns this off without deleting it."),
    },
  }

  -- About each unit the display is on.
  local unit = {
    type = "group", inline = true, order = 2, name = "Hide a unit's icons when",
    args = {
      hideWhenDead = Toggle("hideWhenDead", 1, "Dead", "Hides a unit's icons while that unit is dead."),
      hideWhenOffline = Toggle("hideWhenOffline", 2, "Offline", "Hides a unit's icons while that player is offline."),
      break0 = Break(2.9),
      hideWhenNotVisible = {
        type = "select", order = 3, name = Label("hideWhenNotVisible", "Out of sight"),
        desc = Desc("hideWhenNotVisible", "When a unit is too far away for the game to show, filters match the wrong auras. "
          .. "Spell ID matches stay correct. Automatic hides filter displays and keeps spell ID ones."),
        values = { auto = "Automatic", yes = "Hide", no = "Keep showing" },
        get = function()
          local value = t.hideWhenNotVisible
          return (value == nil or value == "auto") and "auto" or value and "yes" or "no"
        end,
        set = function(_, value)
          if value == "auto" then
            -- A display saves "auto" so it can override a group's yes/no.
            Set("hideWhenNotVisible", isDisplay and "auto" or nil)
          else
            Set("hideWhenNotVisible", value == "yes")
          end
        end,
      },
    },
  }

  local load = {
    type = "group", name = "Load conditions",
    args = {
      you = you,
      unit = unit,
    },
  }

  look.args.tint.desc = Desc("tint", "The color the icon art is tinted.")
  look.args.glowMode.desc = Desc("glow", "Blizzard's proc glow around each icon. It reaches about a fifth of the icon's size past each edge, so tight spacing lets it overlap the next icon.")
  look.args.glow.desc = Desc("glow", "The glow's color.")
  Resettable(look.args.sort, "sort")
  Resettable(look.args.tintMode, "tint")
  look.args.skin.desc = Desc("skin", "Masque: the frame from the skin you pick for this group in Masque's options. "
    .. "The border color goes on the skin's ring.")
  Resettable(look.args.skin, "skin")
  look.args.borderSource.desc = Desc({ "dispelBorder", "borderColor" }, "Draws a border around each icon. "
    .. "Dispel color: by the aura's dispel type, red for none. Custom: one color for every aura, missing icons included.")
  Resettable(look.args.borderSource, { "dispelBorder", "borderColor" })
  look.args.borderStyle.desc = Desc("borderStyle", "Blizzard: the game's soft border art. Plain: a solid outline "
    .. "in the exact color, as wide as Border width.")
  Resettable(look.args.borderStyle, "borderStyle")
  look.args.borderColor.desc = Desc("borderColor", "The border's color.")
  Resettable(look.args.borderColor, "borderColor")
  look.args.borderWidth.hidden = function()
    return not HasAnyBorder() or IsMasque() or t.borderStyle ~= "plain"
  end
  Resettable(look.args.tint, "tint")
  Resettable(look.args.glowMode, "glow")
  Resettable(look.args.glow, "glow")
  Resettable(you.args.combat, "combat")
  Resettable(you.args.nameplateUnits, "nameplateUnits")
  Resettable(you.args.knownSpell, "knownSpell")
  Resettable(unit.args.hideWhenNotVisible, "hideWhenNotVisible")

  -- The Appearance controls in sections, each row ended explicitly. A row,
  -- or a section, whose controls are all hidden is hidden too. `extra`: a
  -- display's own controls (Wrap after).
  local controls = look.args
  for key, option in pairs(extra or {}) do
    controls[key] = option
  end
  local function Hidden(option)
    local hidden = option.hidden
    if type(hidden) == "function" then
      return hidden()
    end
    return hidden == true
  end
  local function AllHidden(options)
    for _, option in ipairs(options) do
      if not Hidden(option) then
        return false
      end
    end
    return true
  end
  local function Section(order, name, rows)
    local args, all, n = {}, {}, 0
    for r, row in ipairs(rows) do
      local options = {}
      for _, key in ipairs(row) do
        local option = controls[key]
        if option then
          n = n + 1
          option.order = n
          args[key] = option
          table.insert(options, option)
          table.insert(all, option)
        end
      end
      if #options > 0 then
        n = n + 1
        local rowBreak = Break(n)
        rowBreak.hidden = function() return AllHidden(options) end
        args["break" .. r] = rowBreak
      end
    end
    return {
      type = "group", inline = true, order = order, name = name, args = args,
      hidden = function() return AllHidden(all) end,
    }
  end
  look.args = {
    layout = Section(1, "Arrangement", {
      { "max", "wrap", "spacing" }, { "sort", "sortReverse" },
    }),
    icon = Section(2, "Icon", {
      { "size", "zoom", "alpha" }, { "tintMode" }, { "tint" }, { "desaturate", "hideSwipe" },
      { "tooltip" },
    }),
    border = Section(3, "Border", {
      { "skin", "borderSource", "borderStyle" }, { "borderWidth" }, { "borderColor" },
    }),
    glow = Section(4, "Glow", { { "glowMode" }, { "glow" }, { "glowWhen" } }),
  }

  return look, text, load
end

-- Import / export ------------------------------------------------------------
-- Share.lua turns settings into text and back. Each place that offers it has
-- a row of buttons that open one text box at a time: Export opens a box filled
-- with the text to copy, an Import button opens an empty box to paste into,
-- and that box's Accept button (AceConfig's multi-line box brings one) does
-- the import. State is kept here per page, since the options table is rebuilt
-- on every redraw: which box is open, what was pasted, the last message, and
-- a choice waiting for an answer.

local shareStates = {}

local function ShareState(key)
  shareStates[key] = shareStates[key] or {}
  return shareStates[key]
end

-- kind: "error" (red, until the box closes) or "ask" (white and large, a
-- question waiting on the buttons below it; easy to walk away from
-- otherwise). Nothing is said on success: the result shows in the tree, and a
-- lingering "done" line has no moment to clear.
local function Say(state, message, kind)
  state.message = (kind == "error" and "|cffff4040" or "|cffffffff") .. message .. "|r"
  state.loud = kind == "ask"
end

-- Group names in gold, so they stand out in a white question.
local function Names(names)
  local parts = {}
  for i, name in ipairs(names) do
    parts[i] = "|cffffd100" .. name .. "|r|cffffffff"
  end
  return table.concat(parts, ", ")
end

-- Adds the buttons, boxes and message row to `args`, from `order` on.
-- spec.export = { button, label, text } (optional): text() makes the export.
-- spec.imports = { { key, button, label, onText }, ... }: onText(text) imports
-- and returns true when the box can close (done, or a choice to answer).
-- spec.width: the buttons' width.
local function ShareBlock(args, state, order, spec)
  local function Open(key)
    return function()
      state.open, state.pasted, state.message, state.pending = key, nil, nil, nil
      Refresh()
    end
  end

  if spec.export then
    args.shareExport = { type = "execute", order = order, width = spec.width, name = spec.export.button, func = Open("export") }
  end
  for i, import in ipairs(spec.imports) do
    args["shareImport" .. i] = {
      type = "execute", order = order + i / 10, width = spec.width, name = import.button, func = Open(import.key),
    }
  end
  args.shareButtonsBreak = Break(order + 0.9)

  -- Single line: the multi-line box always shows an Accept button, which has
  -- nothing to do here. The single-line box only shows its button after typing.
  if spec.export then
    args.shareExportBox = {
      type = "input", order = order + 1, width = "full", name = spec.export.label, arg = { selectAll = true },
      desc = "Click in the box, press Ctrl+A to select all, then Ctrl+C to copy.",
      hidden = function() return state.open ~= "export" end,
      get = spec.export.text,
      set = function() end,
    }
  end
  for i, import in ipairs(spec.imports) do
    args["shareImportBox" .. i] = {
      type = "input", order = order + 1 + i / 10, width = "full", multiline = 8, name = import.label,
      confirm = import.confirm ~= nil, confirmText = import.confirm,
      hidden = function() return state.open ~= import.key end,
      get = function() return state.pasted or "" end,
      set = function(_, text)
        state.pasted, state.message, state.pending = text, nil, nil
        if import.onText(text) then
          state.open, state.pasted = nil, nil
        end
        Refresh()
      end,
    }
  end
  args.shareClose = {
    type = "execute", order = order + 1.8, name = "Close",
    hidden = function() return state.open == nil end,
    func = function()
      state.open, state.pasted, state.message = nil, nil, nil
      Refresh()
    end,
  }
  args.shareCloseBreak = Break(order + 1.85)
  args.shareMessage = {
    type = "description", order = order + 1.9, width = "full",
    fontSize = function() return state.loud and "large" or "medium" end,
    name = function() return state.message or "" end,
    hidden = function() return state.message == nil end,
  }
  -- A full config waiting for its choice lists its groups under the
  -- question, each line a step smaller (one font size per description).
  local function PendingGroups()
    return state.pending and state.pending.kind == "config" and state.pending.groups
  end
  args.shareHeading = {
    type = "description", order = order + 1.91, width = "full", fontSize = "medium",
    name = function()
      local groups = PendingGroups()
      return groups and ("Found %d total groups:"):format(#groups) or ""
    end,
    hidden = function() return not PendingGroups() end,
  }
  args.shareList = {
    type = "description", order = order + 1.92, width = "full",
    name = function()
      local lines = {}
      for i, group in ipairs(PendingGroups() or {}) do
        lines[i] = "  • " .. group.name
      end
      -- Blank lines above and below set the list apart.
      return "\n" .. table.concat(lines, "\n") .. "\n "
    end,
    hidden = function() return not PendingGroups() end,
  }
  return args
end

-- Adds imported groups, each with a new id. A name already taken either
-- replaces that group in place or gets a number added.
local function AddGroups(groups, replaceSameName)
  for _, group in ipairs(groups) do
    group.id = ns.NewGroupID()
    ns.Prepare(group)
    local index
    for i, other in ipairs(ns.groups) do
      if other.name == group.name then
        index = i
      end
    end
    if index and replaceSameName then
      ns.groups[index] = group
    else
      group.name = UniqueName(group.name)
      table.insert(ns.groups, group)
    end
  end
  Changed(true)
end

local function ReplaceAllGroups(groups)
  wipe(ns.groups)
  AddGroups(groups, false)
end

local function Clashes(groups)
  local names = {}
  for _, group in ipairs(groups) do
    if GroupByName(group.name) then
      table.insert(names, group.name)
    end
  end
  return names
end

-- A button for a waiting choice; `kind` picks which choice it belongs to.
local function ChoiceButton(state, kind, order, label, func, confirmText)
  return {
    type = "execute", order = order, name = label,
    hidden = function() return not state.pending or state.pending.kind ~= kind end,
    confirm = confirmText ~= nil, confirmText = confirmText,
    func = function()
      local pending = state.pending
      state.pending, state.message = nil, nil
      func(pending)
      Refresh()
    end,
  }
end

local function OfferAdd(state, groups)
  local clashes = Clashes(groups)
  if #clashes > 0 then
    state.pending = { kind = "clash", groups = groups, count = #clashes }
    if #clashes == 1 then
      Say(state, ("You already have a group called %s. Replace it with the imported one, or add the import as a copy?")
        :format(Names(clashes)), "ask")
    else
      Say(state, ("You already have groups called %s. Replace them with the imported ones, or add the imports as copies?")
        :format(Names(clashes)), "ask")
    end
  else
    AddGroups(groups, false)
  end
end

-- For the main page: the full config, or one group.
local function AddTopShare(args, order)
  local state = ShareState("top")
  ShareBlock(args, state, order, {
    export = {
      button = "Export full config", label = "Full config as text",
      text = function() return ns.Share.ExportConfig() end,
    },
    imports = {
      {
        key = "all", button = "Import full config",
        label = "Paste a full config here, then click Accept. Then choose to replace your groups or add these.",
        onText = function(text)
          local groups, problem = ns.Share.Import(text, "config")
          if not groups then
            Say(state, problem, "error")
            return false
          end
          state.pending = { kind = "config", groups = groups }
          -- The group list shows under this (shareHeading, shareList).
          Say(state, "|cffff4040Confirm config import|r", "ask")
          return true
        end,
      },
      {
        key = "group", button = "Import a group",
        label = "Paste one group here, then click Accept to add it.",
        onText = function(text)
          local group, problem = ns.Share.Import(text, "group")
          if not group then
            Say(state, problem, "error")
            return false
          end
          OfferAdd(state, { group })
          return true
        end,
      },
    },
  })
  args.shareReplaceAll = ChoiceButton(state, "config", order + 2, "Replace all my groups", function(pending)
    ReplaceAllGroups(pending.groups)
  end, "Delete all your groups and use the imported ones?")
  args.shareAddAll = ChoiceButton(state, "config", order + 2.1, "Add as new groups", function(pending)
    OfferAdd(state, pending.groups)
  end)
  args.shareReplaceSame = ChoiceButton(state, "clash", order + 2.2, "Replace it", function(pending)
    AddGroups(pending.groups, true)
  end)
  args.shareKeepBoth = ChoiceButton(state, "clash", order + 2.3, "Add as a copy", function(pending)
    AddGroups(pending.groups, false)
  end)
  local function Plural(single, plural)
    return function() return state.pending and (state.pending.count or 1) > 1 and plural or single end
  end
  args.shareReplaceSame.name = Plural("Replace it", "Replace them")
  args.shareKeepBoth.name = Plural("Add as a copy", "Add as copies")
  args.shareCancelChoice = {
    type = "execute", order = order + 2.4, name = "Cancel",
    hidden = function() return not state.pending end,
    func = function()
      state.pending, state.message = nil, nil
      Refresh()
    end,
  }
  args.shareChoiceBreak = Break(order + 2.9)
end

-- The group's Export button, in its button row from `order` on; the box
-- opens under the row.
local function GroupExport(args, group, order, width)
  ShareBlock(args, ShareState(group), order, {
    width = width,
    export = {
      button = "Export", label = "This group as text",
      text = function() return ns.Share.ExportGroup(group) end,
    },
    imports = {},
  })
end

-- The Import display button and its box, from `order` on.
local function DisplayImport(args, group, order, width)
  local state = ShareState(tostring(group) .. ":add")
  ShareBlock(args, state, order, {
    width = width,
    imports = {
      {
        key = "display", button = "Import display",
        label = "Paste one display here, then click Accept to add it to the end of this group.",
        onText = function(text)
          local display, problem = ns.Share.Import(text, "display")
          if not display then
            Say(state, problem, "error")
            return false
          end
          table.insert(group.displays, display)
          ns.Prepare(group)
          Changed(true)
          AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "displays", "d" .. #group.displays)
          return true
        end,
      },
    },
  })
end

-- Only the display's own values move; Prepare points its metatable at the
-- new group, so everything else follows that group.
local function MoveToGroup(group, display, index, order)
  return {
    type = "select", order = order, width = 1.5, name = "Move to group",
    desc = "Moves this display to the end of the chosen group. Settings it doesn't set itself then come from that group.",
    hidden = function() return #ns.groups < 2 end,
    confirm = function(_, key)
      local target = GroupByKey(key)
      return target and ("Move %s to %s?"):format(DisplayLabel(display), target.name)
    end,
    values = function()
      local values = {}
      for _, other in ipairs(ns.groups) do
        if other ~= group then
          values["g" .. other.id] = other.name
        end
      end
      return values
    end,
    sorting = function()
      local keys = {}
      for _, other in ipairs(SortedGroups()) do
        if other ~= group then
          table.insert(keys, "g" .. other.id)
        end
      end
      return keys
    end,
    get = function() return nil end,
    set = function(_, key)
      local target = GroupByKey(key)
      table.remove(group.displays, index)
      table.insert(target.displays, display)
      ns.Prepare(target)
      Changed(true)
      AceConfigDialog:SelectGroup(addonName, key, "displays", "d" .. #target.displays)
    end,
  }
end

-- Keyed by group and position, so the state outlives the display it replaces.
local function DisplayShareTab(group, display, index)
  local state = ShareState(tostring(group) .. ":" .. index)
  local args = ShareBlock({
    moveTo = MoveToGroup(group, display, index, 0.1),
    moveToBreak = Break(0.2),
  }, state, 1, {
    export = {
      button = "Export this display", label = "This display as text",
      text = function() return ns.Share.ExportDisplay(display, state.withGroup) end,
    },
    imports = {
      {
        key = "display", button = "Import new settings",
        label = "Paste one display here, then click Accept. It replaces this display's settings.",
        onText = function(text)
          local imported, problem = ns.Share.Import(text, "display")
          if not imported then
            Say(state, problem, "error")
            return false
          end
          group.displays[index] = imported
          ns.Prepare(group)
          Changed(true)
          return true
        end,
      },
    },
  })
  args.withGroup = {
    type = "toggle", order = 1.95, width = 1.5, name = "Include the group's values",
    desc = "Adds the values this display takes from its group, so it looks the same in any group. "
        .. "It then keeps those values instead of following its new group's.",
    hidden = function() return state.open ~= "export" end,
    get = function() return state.withGroup == true end,
    set = function(_, value)
      state.withGroup = value
      Refresh()
    end,
  }
  args.withGroupBreak = Break(1.97)
  return { type = "group", order = 5, name = "Import / export", args = args }
end

-- Displays -------------------------------------------------------------------
-- A display is a tree entry under its group, with its settings in tabs.

-- Checkboxes for display.dispelTypes, two per row. Chain.lua turns the list
-- into the container's include or exclude map.
local function DispelTypesBox(display)
  local entries = {}
  for _, name in ipairs(ns.Chain.DISPEL_TYPES) do
    table.insert(entries, { name, name })
  end
  table.insert(entries, { "None", "No type" })

  local args = {
    intro = {
      type = "description", order = 0, width = "full",
      name = "Tick none to show every type.",
    },
  }
  for i, entry in ipairs(entries) do
    local key = entry[1]
    args[key] = {
      type = "toggle", order = i, width = 1.5, name = entry[2],
      get = function() return tContains(display.dispelTypes or {}, key) end,
      set = function(_, on)
        local list = display.dispelTypes or {}
        if on then
          table.insert(list, key)
        else
          tDeleteItem(list, key)
        end
        display.dispelTypes = #list > 0 and list or nil
        Changed(false)
      end,
    }
    if i % 2 == 0 then
      args["break" .. i] = Break(i + 0.5)
    end
  end
  return { type = "group", inline = true, order = 6.5, name = "Dispel types", args = args }
end

-- `index`: the display's place in the group's list, line breaks included,
-- which also keys its tree entry; `number`: its place among the displays.
local function DisplayOptions(group, display, index, number)
  local list = group.displays

  -- Displays are keyed by position (d1, d2, ...), so the selection has to
  -- follow the display to its new key.
  local function MoveDisplay(by)
    if Move(list, index, by) then
      AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "displays", "d" .. (index + by))
    end
  end

  local what = {
    type = "group", order = 1, name = "Filters",
    args = {
      filter = {
        type = "input", order = 2, width = 1.5, name = "Filter",
        desc = "Join tokens with | and put ! before one to exclude it: HARMFUL|!CROWD_CONTROL. Empty means HELPFUL.",
        validate = ValidateFilter,
        get = function() return display.filter end,
        set = function(_, value)
          value = CleanFilter(value)
          display.filter = value ~= "" and value or nil
          Changed(false)
        end,
      },
      spellIDs = {
        type = "input", order = 3, width = "full", name = "Spell IDs (exact)",
        desc = "Separate IDs with commas. Matches these IDs only. Put ! before an ID to hide that spell instead: !12345. "
            .. "The game allows this for buffs on friendly units and debuffs on enemies.",
        get = function() return IDsText(rawget(display, "spellIDs")) end,
        set = function(_, value)
          display.spellIDs = ParseIDs(value)
          Changed(false)
        end,
      },
      spellNames = {
        type = "description", order = 4, name = function() return DescribeIDs(rawget(display, "spellIDs")) end,
        hidden = function() return rawget(display, "spellIDs") == nil end,
      },
      rankSpellIDs = {
        type = "input", order = 5, width = "full", name = "Spell IDs (all ranks)",
        desc = "Separate IDs with commas. Enter one rank of a spell to match all its ranks. Rank data covers class spells "
            .. "(from talentsforever.com); other IDs match only themselves. Put ! before an ID to hide all its ranks "
            .. "instead. Works alongside the exact list.",
        get = function() return IDsText(rawget(display, "rankSpellIDs")) end,
        set = function(_, value)
          display.rankSpellIDs = ParseIDs(value)
          Changed(false)
        end,
      },
      rankSpellNames = {
        type = "description", order = 6, name = function() return DescribeIDs(rawget(display, "rankSpellIDs"), true) end,
        hidden = function() return rawget(display, "rankSpellIDs") == nil end,
      },
      maxDuration = {
        type = "input", order = 6.2, name = "Maximum aura duration",
        desc = "In seconds. Matches auras whose full duration is this long or shorter, however much time they have left. "
            .. "Auras without a duration don't match. Leave empty for no limit.",
        validate = function(_, value)
          local seconds = tonumber(value)
          if strtrim(value) ~= "" and not (seconds and seconds >= 1 and seconds <= 86400) then
            return "Enter a number of seconds, or leave it empty."
          end
          return true
        end,
        get = function()
          local seconds = rawget(display, "maxDuration")
          return seconds and tostring(seconds) or ""
        end,
        set = function(_, value)
          display.maxDuration = tonumber(value)
          Changed(false)
        end,
      },
      breakMaxDuration = Break(6.3),
      dispelTypes = DispelTypesBox(display),
      icon = {
        type = "input", order = 7, name = "Icon",
        desc = "A spell ID or texture path. Leave empty to use the icon of one of this display's spell IDs.",
        hidden = function() return display.mode ~= "missing" end,
        get = function()
          local icon = rawget(display, "icon")
          return icon and tostring(icon) or ""
        end,
        set = function(_, value)
          display.icon = tonumber(value) or (value ~= "" and value or nil)
          Changed(false)
        end,
      },
    },
  }

  AddFilterPicker(what.args, 2.05, display, function() return display.filter end, function(text)
    display.filter = text ~= "" and text or nil
    Changed(false)
  end)

  local look, text, load = SharedTabs(display, true, {
    wrap = {
      type = "range", name = "Wrap after", min = 0, max = 40, step = 1,
      desc = function()
        local text = "Wraps this %s after this many icons. 0: no wrapping. Counts icons at this display's size, "
            .. "so bigger icons later in the %s fit fewer before it wraps."
        return text:format(RowWord(group), RowWord(group))
      end,
      hidden = function() return not CanWrap(group, index) end,
      get = function() return rawget(display, "wrap") or 0 end,
      set = function(_, value)
        display.wrap = value > 0 and value or nil
        Changed(false)
      end,
    },
  })
  look.order, text.order, load.order = 2, 3, 4

  return {
    type = "group", order = 100 + index, childGroups = "tab",
    name = function() return DisplayName(display, number) end,
    args = {
      -- Drawn above the tabs: no box or title (unnamed inline group).
      actions = {
        type = "group", inline = true, order = 0, name = "",
        args = {
          name = {
            type = "input", order = 5.1, width = 1.5, name = "Name",
            desc = "Shown in this list. Leave empty to name it after its spell or filter.",
            get = function() return rawget(display, "name") or "" end,
            set = function(_, value)
              value = strtrim(value)
              display.name = value ~= "" and value or nil
              Refresh()
            end,
          },
          mode = {
            type = "select", order = 5.2, name = "Shows", values = MODES,
            desc = function()
              return ("\"Icon when none match\" draws at the end of its %s, after the %s's other icons.")
                  :format(RowWord(group), RowWord(group))
            end,
            get = function() return display.mode end,
            set = function(_, value)
              display.mode = value
              Changed(true)
            end,
          },
          nameRow = Break(5.5),
          up = Link(1, "up", "Move up", "Moves this display up one", function() MoveDisplay(-1) end),
          down = Link(2, "down", "Move down", "Moves this display down one", function() MoveDisplay(1) end),
          duplicate = Link(3, "duplicate", "Duplicate", "Adds a copy below this one", function()
            table.insert(list, index + 1, CopyTable(display))
            ns.Prepare(group)
            Changed(true)
            AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "displays", "d" .. (index + 1))
          end),
          delete = Link(4, "delete", "Delete", "Removes this display", function()
            table.remove(list, index)
            Changed(true)
          end, { confirm = function() return ("Delete %s?"):format(DisplayLabel(display)) end }),
          breakActions = Break(4.5),
        },
      },
      what = what,
      look = look,
      text = text,
      load = load,
      share = DisplayShareTab(group, display, index),
    },
  }
end

-- A line break's tree entry, a gray rule so it doesn't read as a display.
-- Keyed by list index like displays ("b" instead of "d").
local function BreakOptions(group, index)
  local list = group.displays
  local function MoveBreak(by)
    if Move(list, index, by) then
      AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "displays", "b" .. (index + by))
    end
  end
  return {
    type = "group", order = 100 + index, name = "|cff808080==============|r",
    desc = "Line break",
    args = {
      intro = {
        type = "description", order = 0, width = "full",
        name = function()
          return ("Displays after this start a new %s."):format(RowWord(group))
        end,
      },
      introBreak = Break(0.5),
      up = Link(1, "up", "Move up", "Moves this line break up one", function() MoveBreak(-1) end),
      down = Link(2, "down", "Move down", "Moves this line break down one", function() MoveBreak(1) end),
      delete = Link(3, "delete", "Delete", function()
        return ("Removes this line break. The displays after it join the %s before."):format(RowWord(group))
      end, function()
        table.remove(list, index)
        Changed(true)
      end),
      buttonsBreak = Break(3.5),
    },
  }
end

-- Groups ---------------------------------------------------------------------
-- A group is a leaf of the main tree with tabs; its displays are a second
-- tree inside its Displays tab. AceConfigDialog puts a node's child groups
-- either in the tree or in tabs (childGroups), never both, and draws a new
-- tree for a tree group whose parent is a tab (FeedGroup).

local function Field(group, key, structural)
  return function() return group[key] end, function(_, value)
    group[key] = value
    Changed(structural)
  end
end

local function Anchor(group)
  if not rawget(group, "anchor") then
    group.anchor = { "CENTER", nil, "CENTER", 0, 0 }
  end
  return group.anchor
end

local function AnchorField(group, slot, default)
  return function()
    local value = Anchor(group)[slot]
    if value == nil then
      return default
    end
    return value
  end, function(_, value)
    if value == "" then
      value = nil
    end
    Anchor(group)[slot] = value
    Changed(false)
  end
end


-- A new display starts with the last display's filter: displays in one group
-- usually match the same aura type.
local function AddDisplay(group)
  local last
  for _, display in ns.Displays(group) do
    last = display
  end
  table.insert(group.displays, { mode = "list", filter = last and rawget(last, "filter") })
  ns.Prepare(group)
  Changed(true)
  AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "displays", "d" .. #group.displays)
end

local function AddLineBreak(group)
  table.insert(group.displays, { mode = "break" })
  Changed(true)
  AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "displays", "b" .. #group.displays)
end

-- The Lines section of a group's Layout tab.
local function LineControls(group)
  local growthGet, growthSet = Field(group, "growth", true)
  local args = {
    growth = {
      type = "select", order = 1, name = "Grow", values = GROWTHS, sorting = GROWTH_ORDER,
      desc = "The direction new icons are added in. Centered keeps each line centered on the anchor.",
      get = growthGet, set = growthSet,
    },
    lines = {
      type = "select", order = 2,
      name = function() return ("New %s go"):format(RowWord(group, true)) end,
      desc = function()
        return "Displays after a line break go this way: across from the way icons grow."
      end,
      values = function()
        if ns.Chain.Vertical(group.growth) then
          return { LEFT = "Left", RIGHT = "Right" }
        end
        return { UP = "Up", DOWN = "Down" }
      end,
      get = function() return ns.Chain.Lines(group.growth, group.lines) end,
      set = function(_, value)
        group.lines = value
        Changed(true)
      end,
    },
    lineSpacing = {
      type = "range", order = 3, min = 0, max = 40, step = 1,
      name = function() return Capital(RowWord(group)) .. " spacing" end,
      desc = function() return ("Gap between %s."):format(RowWord(group, true)) end,
      get = function() return group.lineSpacing end,
      set = function(_, value)
        group.lineSpacing = value
        Changed(false)
      end,
    },
    break1 = Break(3.5),
    firstLine = {
      type = "toggle", order = 4, width = 1.5,
      name = function() return ("Show only the first %s"):format(RowWord(group)) end,
      desc = function() return ("Shows only the first %s with icons, hides the rest."):format(RowWord(group)) end,
      -- Lines shared by several units keep their height, so nothing moves up.
      hidden = function() return not ns.SingleRow(group) end,
      get = function() return group.firstLine == true end,
      set = function(_, value)
        group.firstLine = value or nil
        Changed(true)
      end,
    },
  }
  return {
    type = "group", inline = true, order = 1, args = args,
    name = function() return Capital(RowWord(group, true)) end,
  }
end

local function LayoutTab(group)
  local function AnchorRange(slot, order, label, desc)
    local get, set = AnchorField(group, slot, 0)
    return {
      type = "range", order = order, name = label, min = -2000, max = 2000, softMin = -600, softMax = 600, step = 1,
      desc = desc, get = get, set = set,
    }
  end

  local function AnchorPoint(slot, order, label, desc)
    local get, set = AnchorField(group, slot, "CENTER")
    return { type = "select", order = order, name = label, desc = desc, values = POINTS, get = get, set = set }
  end

  local frameGet, frameSet = AnchorField(group, 2, "")

  local anchor = {
    type = "group", inline = true, order = 2, name = "Anchor",
    args = {
      anchorTo = {
        type = "select", order = 4, name = "Anchor to",
        values = { unit = "Each unit's own frame", screen = "Screen", frame = "A named frame" },
        desc = "Each unit's own frame: PlayerFrame, TargetFrame or FocusFrame for you, your target and your focus; "
            .. "raid-style frames for party and raid members and their pets; nameplates for units with one.",
        get = function() return group.anchorTo end,
        set = function(_, value)
          group.anchorTo = value
          Changed(false)
        end,
      },
      relativeTo = {
        type = "input", order = 5, name = "Frame name",
        desc = "The frame's global name, such as TargetFrame. Dotted paths like PartyFrame.MemberFrame1 work too.",
        hidden = function() return group.anchorTo ~= "frame" end,
        get = frameGet, set = frameSet,
      },
      break2 = Break(5.9),
      point = AnchorPoint(1, 6, "Group's point", "The point on the group that's attached."),
      relativePoint = AnchorPoint(3, 7, "To the frame's", "The point on the frame the group attaches to."),
      break3 = Break(7.9),
      x = AnchorRange(4, 8, "X", "Moves the group right (positive) or left (negative), in pixels."),
      y = AnchorRange(5, 9, "Y", "Moves the group up (positive) or down (negative), in pixels."),
      break4 = Break(9.9),
      layer = {
        type = "range", order = 10, name = "Layer", min = 0, max = 10, step = 1,
        desc = "When groups overlap on one frame, the higher layer draws on top.",
        get = function() return group.layer end,
        set = function(_, value)
          group.layer = value > 0 and value or nil
          Changed(false)
        end,
      },
    },
  }

  return { type = "group", order = 2, name = "Layout", args = { lines = LineControls(group), anchor = anchor } }
end

-- The group's `target` list as a dropdown of checkboxes. Keys are TARGETS
-- indexes: the dropdown sorts its items by key, and this keeps TARGETS order.
-- AceConfigDialog redraws a multiselect dropdown only when it closes, so a
-- tick applies without Refresh, which would close it mid-pick.
local function UnitsSelect(group, order)
  local function AsList()
    local value = group.target
    if type(value) == "string" then
      value = value ~= "" and { value } or {}
    end
    return value or {}
  end
  local values = {}
  for i, entry in ipairs(TARGETS) do
    values[i] = entry[2]
  end
  return {
    type = "multiselect", order = order, width = 1.5, name = "Units", dialogControl = "Dropdown",
    desc = "Which units this group shows icons for. Anchored to each unit's own frame, every unit gets a row there. "
        .. "Anchored to the screen or a named frame, the units share one row in this order.",
    values = values,
    get = function(_, i) return tContains(AsList(), TARGETS[i][1]) end,
    set = function(_, i, on)
      local list, kind = AsList(), TARGETS[i][1]
      if on and not tContains(list, kind) then
        table.insert(list, kind)
      elseif not on then
        tDeleteItem(list, kind)
      end
      group.target = list
      ns.Changed(true)
    end,
  }
end

-- `index`: the group's place in name order (SortedGroups).
local function GroupOptions(group, index)
  local look, text, load = SharedTabs(group, false)
  look.order, text.order, load.order = 1, 2, 3

  -- Above the group's tabs, so they show on every tab. An inline group with
  -- no name is drawn without a box or title.
  local actions = {
    type = "group", inline = true, order = 0, name = "",
    args = {
      name = {
        type = "input", order = 0.1, width = 1.5, name = "Name",
        desc = "The group's name in this list and in Masque's options.",
        validate = function(_, value)
          if value == "" then
            return "Give it a name."
          end
          local other = GroupByName(value)
          return (other == nil or other == group) or "Another group has that name."
        end,
        get = function() return group.name or "" end,
        set = function(_, value)
          group.name = value
          Changed(true)
        end,
      },
      target = UnitsSelect(group, 0.2),
      nameRow = Break(0.5),
      testGroup = {
        type = "execute", order = 1, width = 0.7, name = "Test group",
        desc = "Preview this group with sample icons. Unavailable in combat and PvP matches.",
        func = function() ns.OpenTest(group) end,
        disabled = function() return ns.TestLocked() end,
      },
      duplicate = {
        type = "execute", order = 1.1, width = 0.7, name = "Duplicate",
        desc = "Adds a copy of this group and its displays. The copy sits on top of the original on screen until you move it.",
        func = function()
          -- CopyTable copies raw fields only, no metatables; Prepare adds them.
          local copy = CopyTable(group)
          copy.id = ns.NewGroupID()
          copy.name = UniqueName((group.name or "Group") .. " copy")
          ns.Prepare(copy)
          table.insert(ns.groups, copy)
          Changed(true)
          AceConfigDialog:SelectGroup(addonName, "g" .. copy.id)
        end,
      },
      delete = {
        type = "execute", order = 1.3, width = 0.7, name = "Delete",
        -- A confirm function returning a string sets the prompt (AceConfigDialog).
        confirm = function() return ("Delete %s and its displays?"):format(group.name or ("Group " .. group.id)) end,
        func = function()
          tDeleteItem(ns.groups, group)
          Changed(true)
        end,
      },
      firstLineWarning = FirstLineWarning(group, 6),
    },
  }
  -- Export sits between Duplicate and Delete and ends the row; its box
  -- opens under it.
  GroupExport(actions.args, group, 1.2, 0.7)

  -- The Displays tab's own options draw above its tree (FeedGroup feeds a
  -- group's options before its tree), so these show on the Displays tab only.
  local entries = {
    add = {
      type = "execute", order = 0.1, width = 0.85, name = "Add display",
      desc = "The new display lists matching auras. Set its Shows option to \"Icon when none match\" for a missing-aura icon.",
      func = function() AddDisplay(group) end,
    },
    addBreak = {
      type = "execute", order = 0.2, width = 0.85, name = "Add line break",
      desc = function()
        return ("Displays you add after it start a new %s. Move it up or down to split %s elsewhere.")
            :format(RowWord(group), RowWord(group, true))
      end,
      func = function() AddLineBreak(group) end,
    },
    empty = {
      type = "description", order = 3, width = "full", fontSize = "medium",
      name = "No displays yet",
      hidden = function() return #group.displays > 0 end,
    },
  }
  DisplayImport(entries, group, 0.2, 0.85)
  for number, display, i in ns.Displays(group) do
    entries["d" .. i] = DisplayOptions(group, display, i, number)
  end
  for i, entry in ipairs(group.displays) do
    if entry.mode == "break" then
      entries["b" .. i] = BreakOptions(group, i)
    end
  end

  local args = {
    actions = actions,
    displays = { type = "group", order = 1, name = "Displays", childGroups = "tree", args = entries },
    placement = LayoutTab(group),
    -- What every display uses unless it sets its own.
    shared = {
      type = "group", order = 3, name = "Shared settings", childGroups = "tab",
      args = { look = look, text = text, load = load },
    },
  }

  -- An alert icon in the tree while FirstLineWarning shows, so it's seen from
  -- other pages too; hovering the entry shows its desc.
  local function TreeName()
    local name = group.name or ("Group " .. group.id)
    return ns.FirstLineConflict(group) and ALERT .. " " .. name or name
  end
  local function TreeDesc()
    return ns.FirstLineConflict(group) and FirstLineTitle(group) .. "." or nil
  end
  return { type = "group", order = 10 + index, name = TreeName, desc = TreeDesc, childGroups = "tab", args = args }
end

-- Root -----------------------------------------------------------------------

-- Retired containers (see ns.Leaked) past which the editor suggests a reload.
local RELOAD_HINT = 500

local function NeedsReload()
  return ns.Leaked() >= RELOAD_HINT
end

local function Status()
  if NeedsReload() then
    return "|cffff9933After large amounts of edits it is recommended you /reload to clean up unused frames.|r"
  end
  return ""
end

local function NewGroup()
  local group = {
    id = ns.NewGroupID(),
    name = UniqueName("New group"),
    anchor = { "CENTER", nil, "CENTER", 0, 0 },
    displays = {},
  }
  ns.Prepare(group)
  table.insert(ns.groups, group)
  Changed(true)
  AceConfigDialog:SelectGroup(addonName, "g" .. group.id)
end

-- The status line as last drawn, so RefreshStatus redraws only when it changed.
local lastStatus

local function Options()
  local args = {
    status = {
      type = "description", order = 1, fontSize = "medium", name = Status,
      hidden = function()
        lastStatus = Status()
        return lastStatus == ""
      end,
    },
    statusGap = { type = "description", order = 1.5, name = " ", width = "full", hidden = function() return Status() == "" end },
    newGroup = { type = "execute", order = 2, name = "New group", func = NewGroup },
    testMode = {
      type = "execute", order = 2.5, name = "Test mode",
      desc = "Preview your groups with sample icons. Unavailable in combat and PvP matches.",
      func = function() ns.OpenTest() end,
      disabled = function() return ns.TestLocked() end,
    },
    topBreak = Break(3.9),
  }
  AddTopShare(args, 4)
  for index, group in ipairs(SortedGroups()) do
    args["g" .. group.id] = GroupOptions(group, index)
  end
  return {
    type = "group", name = "SlopAuras", childGroups = "tree", args = args,
  }
end

-- The status line changes when an apply retires enough containers, and the
-- test buttons when combat or a restriction starts or ends. Only then redraw:
-- redrawing mid-drag would interrupt it.
local function RefreshStatus()
  local status = Status()
  if status ~= lastStatus then
    lastStatus = status
    Refresh()
  end
end
ns.OnApplied = RefreshStatus

local lastTestLocked
ns.OnLockChanged = function()
  local locked = ns.TestLocked()
  if locked ~= lastTestLocked then
    lastTestLocked = locked
    Refresh()
  end
end

-- AceConfigDialog has no right-click hook, so after it draws our panel, each
-- widget's mouse-enabled frames get an OnMouseUp hook. Widgets are pooled and
-- shared with other addons' panels, so the hook is added once per frame and
-- checks at click time whose option the widget is showing. The widget's own
-- handler runs first (a checkbox toggles, a slider sets its value); the reset
-- then overrides that.
local hookedFrames = {}

local function OnRightClick(frame, button)
  local widget = frame.obj
  if button ~= "RightButton" or not widget or widget:GetUserData("appName") ~= addonName then
    return
  end
  local option = widget:GetUserData("option")
  local arg = option and option.arg
  if type(arg) == "table" and arg.reset then
    arg.reset()
  end
end

-- Export boxes (arg.selectAll) select their text when clicked into, ready to
-- copy. The click places the cursor after focus arrives, so the selection
-- waits a frame.
local hookedFocus = {}

local function OnEditFocus(editbox)
  local widget = editbox.obj
  if not widget or widget:GetUserData("appName") ~= addonName then
    return
  end
  local option = widget:GetUserData("option")
  local arg = option and option.arg
  if type(arg) == "table" and arg.selectAll then
    C_Timer.After(0, function()
      if editbox:HasFocus() then
        editbox:HighlightText()
      end
    end)
  end
end

local passThrough = {}

local function HookWidgets(container)
  for _, widget in ipairs(container.children or {}) do
    -- A slider jumps to the cursor on any mouse button. Right-clicks pass
    -- through it to the widget frame behind, which is hooked below.
    -- SetPassThroughButtons is protected, so only out of combat.
    local slider = widget.slider
    if slider and not passThrough[slider] and slider.SetPassThroughButtons and not InCombatLockdown() then
      passThrough[slider] = pcall(slider.SetPassThroughButtons, slider, "RightButton")
    end
    for _, frame in pairs({ widget.frame, widget.slider, widget.editbox, widget.button, widget.button_cover }) do
      if not hookedFrames[frame] and frame.HookScript then
        hookedFrames[frame] = true
        frame:HookScript("OnMouseUp", OnRightClick)
      end
    end
    local editbox = widget.editbox
    if editbox and not hookedFocus[editbox] and editbox.HookScript then
      hookedFocus[editbox] = true
      editbox:HookScript("OnEditFocusGained", OnEditFocus)
    end
    HookWidgets(widget)
  end
end

-- AceConfigDialog remembers the selected tab per entry and reads it when it
-- draws the entry's tabs (status.groups.selected). Setting the same tab on
-- every entry at the same level opens the next display or group on the tab in
-- use. Each level carries on its own: a display's tab set on its group would
-- switch the group away from the Displays tab being shown.
-- `level`: "group" (the group's tabs), "shared" (Shared settings' tabs) or
-- "display".
-- A missing display has no Text tab, so AceConfigDialog opens it on its first
-- tab instead. That fallback isn't carried, so the next display with text
-- still opens on Text.
local displayTab
local function CarryTab(tab, level, display)
  if level == "display" then
    if display and display.mode == "missing" and displayTab == "text" and tab ~= "text" then
      return
    end
    displayTab = tab
  end
  local function Select(path)
    local status = AceConfigDialog:GetStatusTable(addonName, path)
    status.groups = status.groups or {}
    status.groups.selected = tab
  end
  for _, group in ipairs(ns.groups) do
    local key = "g" .. group.id
    if level == "display" then
      for _, _, i in ns.Displays(group) do
        Select({ key, "displays", "d" .. i })
      end
    elseif level == "shared" then
      Select({ key, "shared" })
    else
      Select({ key })
    end
  end
end

-- Test mode window -------------------------------------------------------------
-- Its own AceConfigDialog window, apart from the editor, so it stays open when
-- the editor closes. Test mode runs while it's open (ns.SetTestOpen); closing
-- it, or combat (ns.OnTestEnded), ends it. Collapsed, it's just an Expand button (the window has its own Close).

local TEST_APP = addonName .. " test mode"
local testCollapsed = false
local testOpened = false -- the first opening ticks every group
-- The window's frame while open. AceGUI pools frames across addons, so the
-- OnHide hook checks it's still ours.
local testFrame
local hookedTest = {}

local function TestWindow()
  return AceConfigDialog.OpenFrames[TEST_APP]
end

-- Sized to what it shows. AceConfigDialog applies the size from its status
-- table on every redraw, so it's set there (SetDefaultSize), not on the frame.
-- The window's own chrome (title, status bar) takes about 90px; the rest are
-- rough heights of the intro, a button row, the Groups box and a checkbox.
local TEST_WIDTH, MAX_HEIGHT = 450, 640

local function SizeTestWindow()
  local height = 90 + 30
  if not testCollapsed then
    height = math.min(height + 50 + 40 + 26 * #ns.groups, MAX_HEIGHT)
  end
  AceConfigDialog:SetDefaultSize(TEST_APP, TEST_WIDTH, height)
end

local function SetCollapsed(collapsed)
  testCollapsed = collapsed
  SizeTestWindow()
  AceConfigRegistry:NotifyChange(TEST_APP)
end

local function TestOptions()
  local function Collapsed() return testCollapsed end
  local function Expanded() return not testCollapsed end
  local args = {
    intro = {
      type = "description", order = 0, width = "full", fontSize = "medium", hidden = Collapsed,
      name = "Preview how your groups look with sample icons. Closing this window or entering combat ends the preview.",
    },
    selectAll = {
      type = "execute", order = 1, width = 0.8, name = "Select all", hidden = Collapsed,
      func = function()
        for _, group in ipairs(ns.groups) do
          ns.SetTested(group, true)
        end
      end,
    },
    deselectAll = {
      type = "execute", order = 2, width = 0.8, name = "Deselect all", hidden = Collapsed,
      func = function()
        for _, group in ipairs(ns.groups) do
          ns.SetTested(group, false)
        end
      end,
    },
    collapse = {
      type = "execute", order = 3, width = 0.8, name = "Collapse", hidden = Collapsed,
      func = function() SetCollapsed(true) end,
    },
    expand = {
      type = "execute", order = 4, width = 0.8, name = "Expand", hidden = Expanded,
      func = function() SetCollapsed(false) end,
    },
    buttonsBreak = Break(5.5),
  }
  local groups = {}
  for i, group in ipairs(SortedGroups()) do
    groups["g" .. group.id] = {
      type = "toggle", order = i, width = "full", name = group.name or ("Group " .. group.id),
      desc = "Shows this group with sample icons while test mode is open.",
      get = function() return ns.IsTested(group) end,
      set = function(_, value) ns.SetTested(group, value) end,
    }
  end
  args.groups = { type = "group", inline = true, order = 6, name = "Groups", hidden = Collapsed, args = groups }
  return { type = "group", name = "Test mode", args = args, disabled = function() return ns.TestLocked() end }
end

local function OnTestHide(frame)
  if frame == testFrame then
    testFrame = nil
    ns.SetTestOpen(false)
  end
end

-- `only`: a group to test on its own (its "Test group" button); otherwise the
-- ticks from last time, or every group the first time.
function ns.OpenTest(only)
  if ns.TestLocked() then
    return
  end
  if only or not testOpened then
    for _, group in ipairs(ns.groups) do
      ns.SetTested(group, not only or group == only)
    end
  end
  testOpened = true
  testCollapsed = false
  SizeTestWindow()
  AceConfigDialog:Open(TEST_APP)
  testFrame = TestWindow().frame
  if not hookedTest[testFrame] then
    hookedTest[testFrame] = true
    testFrame:HookScript("OnHide", OnTestHide)
  end
  ns.SetTestOpen(true)
end

function ns.OnTestEnded()
  if TestWindow() then
    AceConfigDialog:Close(TEST_APP)
  end
end

function ns.InitOptions()
  LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, Options)
  LibStub("AceConfig-3.0"):RegisterOptionsTable(TEST_APP, TestOptions)
  -- Only in its own window (/slop), not the game's Options -> AddOns: that
  -- panel is too narrow for two trees beside the settings.
  -- Wide enough for two trees (groups, and a group's displays) beside rows of
  -- three 170px controls.
  AceConfigDialog:SetDefaultSize(addonName, 1080, 640)
  hooksecurefunc(AceConfigDialog, "FeedGroup", function(_, appName, _, container, _, path)
    if appName ~= addonName then
      return
    end
    HookWidgets(container)
    -- A tab's page: { group, tab }, { group, "shared", tab } or
    -- { group, "displays", display, tab }.
    if path and type(path[1]) == "string" and path[1]:match("^g%d+$") then
      if #path == 2 then
        CarryTab(path[2], "group")
      elseif #path == 3 and path[2] == "shared" then
        CarryTab(path[3], "shared")
      elseif #path == 4 then
        local index = tonumber(path[3]:match("^d(%d+)$"))
        local display
        for _, group in ipairs(ns.groups) do
          if "g" .. group.id == path[1] then
            display = index and group.displays[index]
          end
        end
        CarryTab(path[4], "display", display)
      end
    end
  end)
  SLASH_SLOPAURAS1 = "/slop"
  -- Toggles AceConfigDialog's own window. Unlike the game's settings panel
  -- (C_SettingsUtil.OpenSettingsPanel refuses addon calls in combat), it opens
  -- in combat too.
  SlashCmdList.SLOPAURAS = function()
    if AceConfigDialog.OpenFrames[addonName] then
      AceConfigDialog:Close(addonName)
    else
      AceConfigDialog:Open(addonName)
    end
  end
end

