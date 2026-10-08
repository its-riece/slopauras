-- Options: the in-game editor, in Options -> AddOns -> SlopAuras (or /slop).
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
  { "raid", "Raid members" }, { "nameplate", "Nameplates" },
}
local MODES = { list = "Matching auras", missing = "Icon when none match" }

-- Loaded before us (OptionalDeps), so this is settled at file load.
local HAS_MASQUE = LibStub("Masque", true) ~= nil

-- Refresh the panel, e.g. after the tree changed.
local function Refresh()
  AceConfigRegistry:NotifyChange(addonName)
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

local function UniqueName(base)
  local name, n = base, 1
  while GroupByName(name) do
    n = n + 1
    name = base .. " " .. n
  end
  return name
end

-- Displays -------------------------------------------------------------------

-- Whether display `index` starts a line that can wrap (LineWrap in
-- SlopAuras.lua): the line has no missing displays, the group isn't capped,
-- and its lines aren't shared by several units.
local function CanWrap(group, index)
  local list = group.displays
  if (index > 1 and not list[index].newLine) or group.lineMax or not ns.SingleRow(group) then
    return false
  end
  for j = index, #list do
    if j > index and list[j].newLine then
      break
    end
    if list[j].mode == "missing" then
      return false
    end
  end
  return true
end

-- Whether any line of the group wraps. A saved wrap that doesn't apply (the
-- display no longer starts a line, say) doesn't count.
local function AnyWraps(group)
  for j, display in ipairs(group.displays) do
    if rawget(display, "wrap") and CanWrap(group, j) then
      return true
    end
  end
  return false
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

-- Returns the Appearance and Load conditions tabs for `t`, a group or a display.
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

  -- Tooltip for a control on `key`; on a display, says where the value comes
  -- from and how to get the group's back.
  local function Desc(key, text)
    return function()
      if not isDisplay then
        return text
      end
      local source = rawget(t, key) == nil and "Uses the group's value. Change it to give this display its own."
          or "This display's own value. Right-click to use the group's."
      return text and (source .. "\n\n" .. text) or source
    end
  end

  local function Set(key, value)
    t[key] = value
    Changed(false)
  end

  -- `arg` is the one free-form field AceConfig allows on an option;
  -- OnRightClick looks for `reset` in it.
  local function Resettable(option, key)
    if isDisplay then
      option.arg = {
        reset = function()
          if OwnsAny(key) then
            for _, k in ipairs(type(key) == "table" and key or { key }) do
              t[k] = nil
            end
            Changed(false)
            Refresh()
          end
        end,
      }
    end
    return option
  end

  local function Range(key, order, label, min, max, step, isPercent)
    return Resettable({
      type = "range", order = order, name = Label(key, label), desc = Desc(key),
      min = min, max = max, step = step, isPercent = isPercent,
      get = function() return t[key] end,
      set = function(_, value) Set(key, value) end,
    }, key)
  end

  local function Toggle(key, order, label)
    return Resettable({
      type = "toggle", order = order, width = 1.5, name = Label(key, label, true), desc = Desc(key),
      get = function() return t[key] == true end,
      set = function(_, value) Set(key, value) end,
    }, key)
  end

  -- A dropdown for a three-way key (Wants in SlopAuras.lua): true, false, or
  -- any. A display saves "any" so it can override a group's true/false.
  local function ThreeWay(key, order, label, yes, no)
    return Resettable({
      type = "select", order = order, name = Label(key, label), desc = Desc(key),
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
          desc = Desc("glowCombat"),
          get = function() return InCombat("in") end,
          set = function(_, value) SetCombat(value, InCombat("out")) end,
        }, "glowCombat"),
        outOfCombat = Resettable({
          type = "toggle", order = 2, width = 1.5, name = Label("glowCombat", "Out of combat", true),
          desc = Desc("glowCombat"),
          get = function() return InCombat("out") end,
          set = function(_, value) SetCombat(InCombat("in"), value) end,
        }, "glowCombat"),
        rowBreak = Break(2.5),
        outOfRange = Resettable({
          type = "toggle", order = 3, width = 1.5, name = Label("glowInRange", "Out of range", true),
          desc = Desc("glowInRange", "Party and raid members only. Unticked, the glow hides while they're out of range, "
            .. "the same check that fades Blizzard's party frames."),
          get = function() return not t.glowInRange end,
          -- A display saves false so it can override a group's true.
          set = function(_, value) Set("glowInRange", not value or Off()) end,
        }, "glowInRange"),
      },
    }
  end

  -- One box of settings for a text on the icon (StyleString in Chain.lua):
  -- `prefix` "timer" or "stack", `hideKey` hides the text and greys the rest.
  -- Missing icons have neither text.
  local function TextBox(title, prefix, hideKey, hideLabel)
    local function Key(name)
      return prefix .. name
    end
    -- A control's own `disabled` replaces the panel's combat lock.
    local function Disabled()
      return ns.Locked() or t[hideKey] == true
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
    local function Slider(name, order, label, min, max)
      local option = Range(Key(name), order, label, min, max, 1)
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

    return {
      type = "group", inline = true, name = title,
      hidden = function() return isDisplay and t.mode == "missing" end,
      args = {
        hide = Toggle(hideKey, 1, hideLabel),
        break1 = Break(1.5),
        font = font,
        size = Slider("Size", 3, "Size", 6, 32),
        outline = Select("Outline", 4, "Outline", OUTLINES, { "NONE", "OUTLINE", "THICKOUTLINE" }),
        break2 = Break(4.5),
        point = Select("Point", 5, "Position", POINTS, POINT_ORDER, "Where on the icon the text sits."),
        align = Select("Align", 6, "Alignment", ALIGNS, { "LEFT", "CENTER", "RIGHT" },
          "Which side of the text sits on Position. At a right-hand corner, Right keeps the text inside the icon "
          .. "and Left starts it there, running outward."),
        break3 = Break(6.5),
        x = Slider("X", 7, "X", -50, 50),
        y = Slider("Y", 8, "Y", -50, 50),
        break4 = Break(8.5),
        color = Resettable({
          type = "color", order = 9, name = Label(Key("Color"), "Color", true), desc = Desc(Key("Color")),
          disabled = Disabled,
          get = function() return unpack(t[Key("Color")]) end,
          set = function(_, r, g, b) Set(Key("Color"), { r, g, b }) end,
        }, Key("Color")),
      },
    }
  end

  local look = {
    type = "group", name = "Appearance",
    args = {
      size = Range("size", 1, "Size", 8, 128, 1),
      spacing = Range("spacing", 2, "Spacing", 0, 40, 1),
      alpha = Range("alpha", 3, "Alpha", 0, 1, 0.05, true),
      break1 = Break(3.9),
      zoom = Range("zoom", 4, "Zoom", 0, 1, 0.01, true),
      max = Range("max", 4.3, "Show at most", 1, 40, 1),
      break1b = Break(4.9),
      sort = {
        type = "select", order = 6, name = Label("sort", "Sort"), desc = Desc("sort"), values = SortValues(),
        get = function() return t.sort or "Default" end,
        set = function(_, value) Set("sort", value) end,
      },
      sortReverse = Toggle("sortReverse", 6.1, "Reverse sort"),
      break2 = Break(6.9),
      tintMode = {
        type = "select", order = 7, name = Label("tint", "Tint"), desc = Desc("tint"),
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
      borderWidth = Range("borderWidth", 8.06, "Border width", 1, 8, 1),
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
      desaturate = Toggle("desaturate", 9, "Desaturate"),
      hideSwipe = Toggle("hideSwipe", 10, "Hide swipe"),
      break4 = Break(10.9),
      timerText = TextBox("Timer", "timer", "hideTimer", "Hide timer"),
      stackText = TextBox("Stacks", "stack", "hideStacks", "Hide stacks"),
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
        name = Label("class", "Classes (none ticked: all)"), desc = Desc("class"),
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
        type = "select", order = 1, name = Label("combat", "Combat state"), desc = Desc("combat"),
        values = { always = "Any", ["in"] = "In combat", out = "Out of combat" },
        sorting = { "always", "in", "out" },
        get = function() return t.combat or "always" end,
        -- A display saves "always" so it can override a group's in/out.
        set = function(_, value) Set("combat", (value ~= "always" or isDisplay) and value or nil) end,
      },
      resting = ThreeWay("resting", 1.01, "Resting state", "Resting", "Not resting"),
      mounted = ThreeWay("mounted", 1.02, "Mounted state", "Mounted", "Not mounted"),
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
      hideWhenPlayerDead = Toggle("hideWhenPlayerDead", 3.55, "Hide while you're dead"),
      neverLoad = Toggle("neverLoad", 3.6, "Never load"),
    },
  }

  -- About each unit the display is on.
  local unit = {
    type = "group", inline = true, order = 2, name = "Hide a unit's icons when",
    args = {
      hideWhenDead = Toggle("hideWhenDead", 1, "Dead"),
      hideWhenOffline = Toggle("hideWhenOffline", 2, "Offline"),
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

  look.args.tint.desc = Desc("tint")
  look.args.glowMode.desc = Desc("glow", "Blizzard's proc glow around each icon. It reaches about a fifth of the icon's size past each edge, so tight spacing lets it overlap the next icon.")
  look.args.glow.desc = Desc("glow")
  Resettable(look.args.sort, "sort")
  Resettable(look.args.tintMode, "tint")
  look.args.skin.desc = Desc("skin", "Masque: the frame from the skin you pick for this group in Masque's options. "
    .. "The border color goes on the skin's ring.")
  Resettable(look.args.skin, "skin")
  look.args.borderSource.desc = "Dispel color: by the aura's dispel type, red for none. "
      .. "Custom: one color for every aura, missing icons included."
  Resettable(look.args.borderSource, { "dispelBorder", "borderColor" })
  look.args.borderStyle.desc = Desc("borderStyle", "Blizzard: the game's soft border art. Plain: a solid outline "
    .. "in the exact color, as wide as Border width.")
  Resettable(look.args.borderStyle, "borderStyle")
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
  -- display's own controls (Start a new line, Icons per row).
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
    layout = Section(1, "Layout", {
      { "newLine" }, { "max", "wrap", "spacing" }, { "sort", "sortReverse" },
    }),
    icon = Section(2, "Icon", {
      { "size", "zoom", "alpha" }, { "tintMode" }, { "tint" }, { "desaturate", "hideSwipe" },
    }),
    text = Section(3, "Text", { { "timerText" }, { "stackText" } }),
    border = Section(4, "Border", {
      { "skin", "borderSource", "borderStyle" }, { "borderWidth" }, { "borderColor" },
    }),
    glow = Section(5, "Glow", { { "glowMode" }, { "glow" }, { "glowWhen" } }),
  }

  return look, load
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
-- spec.export = { button, label, text }: text() makes the export.
-- spec.imports = { { key, button, label, onText }, ... }: onText(text) imports
-- and returns true when the box can close (done, or a choice to answer).
local function ShareBlock(args, state, order, spec)
  local function Open(key)
    return function()
      state.open, state.pasted, state.message, state.pending = key, nil, nil, nil
      Refresh()
    end
  end

  args.shareExport = { type = "execute", order = order, name = spec.export.button, func = Open("export") }
  for i, import in ipairs(spec.imports) do
    args["shareImport" .. i] = { type = "execute", order = order + i / 10, name = import.button, func = Open(import.key) }
  end
  args.shareButtonsBreak = Break(order + 0.9)

  -- Single line: the multi-line box always shows an Accept button, which has
  -- nothing to do here. The single-line box only shows its button after typing.
  args.shareExportBox = {
    type = "input", order = order + 1, width = "full", name = spec.export.label, arg = { selectAll = true },
    desc = "Click in the box, press Ctrl+A to select all, then Ctrl+C to copy.",
    hidden = function() return state.open ~= "export" end,
    get = spec.export.text,
    set = function() end,
  }
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

local function GroupShareTab(group)
  local state = ShareState(group)
  return {
    type = "group", order = 6, name = "Import / export",
    args = ShareBlock({}, state, 1, {
      export = {
        button = "Export this group", label = "This group as text",
        text = function() return ns.Share.ExportGroup(group) end,
      },
      imports = {
        {
          key = "display", button = "Import a display",
          label = "Paste one display here, then click Accept to add it to the end of this group.",
          onText = function(text)
            local display, problem = ns.Share.Import(text, "display")
            if not display then
              Say(state, problem, "error")
              return false
            end
            display.newLine = nil -- a new last display joins the last line
            table.insert(group.displays, display)
            ns.Prepare(group)
            Changed(true)
            return true
          end,
        },
      },
    }),
  }
end

-- Keyed by group and position, so the state outlives the display it replaces.
local function DisplayShareTab(group, display, index)
  local state = ShareState(tostring(group) .. ":" .. index)
  local args = ShareBlock({}, state, 1, {
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
          -- Same place in the group: same line as before.
          imported.newLine = rawget(display, "newLine")
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

local function DisplayOptions(group, display, index)
  local list = group.displays

  -- Displays are keyed by position (d1, d2, ...), so the selection has to
  -- follow the display to its new key.
  local function MoveDisplay(by)
    if Move(list, index, by) then
      AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "d" .. (index + by))
    end
  end

  local what = {
    type = "group", order = 1, name = "Filters",
    args = {
      name = {
        type = "input", order = 0.5, width = 1.5, name = "Name",
        desc = "Shown in this list. Leave empty to name it after its spell or filter.",
        get = function() return rawget(display, "name") or "" end,
        set = function(_, value)
          value = strtrim(value)
          display.name = value ~= "" and value or nil
          Refresh()
        end,
      },
      breakName = Break(0.6),
      mode = {
        type = "select", order = 1, name = "Shows", values = MODES,
        desc = "An \"Icon when none match\" display draws at the end of its line, after the line's other icons.",
        get = function() return display.mode end,
        set = function(_, value)
          display.mode = value
          Changed(true)
        end,
      },
      breakMode = Break(1.5),
      filter = {
        type = "input", order = 2, width = 1.5, name = "Filter",
        desc = "Leave empty to use the group's filter. Join tokens with | and put ! before one to exclude it: HARMFUL|!CROWD_CONTROL",
        validate = ValidateFilter,
        get = function() return rawget(display, "filter") or "" end,
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

  -- Shows the group's filter when the display has none; a result equal
  -- to the group's keeps the display following the group.
  AddFilterPicker(what.args, 2.05, display, function() return display.filter end, function(text)
    display.filter = nil
    if text ~= "" and text ~= display.filter then
      display.filter = text
    end
    Changed(false)
  end)
  what.args.mode.desc = "\"Icon when none match\" draws at the end of its line, after the line's other icons."

  local look, load = SharedTabs(display, true, {
    newLine = {
      type = "toggle", width = 1.5, name = "Start a new line", hidden = index == 1,
      desc = "Puts this display and the ones after it on a new line. The group's Placement tab sets where new lines go.",
      get = function() return rawget(display, "newLine") == true end,
      set = function(_, value)
        display.newLine = value or nil
        Changed(true)
      end,
    },
    wrap = {
      type = "range", name = "Icons per row", min = 0, max = 40, step = 1,
      desc = "Starts another row of this line after this many icons. 0: one row. "
          .. "Counts icons at this display's size, so bigger icons later in the line fit fewer to a row.",
      hidden = function() return not CanWrap(group, index) end,
      get = function() return rawget(display, "wrap") or 0 end,
      set = function(_, value)
        display.wrap = value > 0 and value or nil
        Changed(false)
      end,
    },
  })
  look.order, load.order = 2, 3

  return {
    type = "group", order = 100 + index, childGroups = "tab",
    name = function() return DisplayName(display, index) end,
    args = {
      -- Drawn above the tabs: no box or title (unnamed inline group), a
      -- horizontal rule (empty header) between the button pairs.
      actions = {
        type = "group", inline = true, order = 0, name = "",
        args = {
          -- One row of four: the editor panel is often only ~2.7 units wide.
          up = { type = "execute", order = 1, width = 0.62, name = "Move up", func = function() MoveDisplay(-1) end },
          down = { type = "execute", order = 2, width = 0.62, name = "Move down", func = function() MoveDisplay(1) end },
          duplicate = {
            type = "execute", order = 4, width = 0.62, name = "Duplicate",
            desc = "Adds a copy below this one.",
            func = function()
              table.insert(list, index + 1, CopyTable(display))
              ns.Prepare(group)
              Changed(true)
              AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "d" .. (index + 1))
            end,
          },
          delete = {
            type = "execute", order = 5, width = 0.62, name = "Delete",
            confirm = function() return ("Delete %s?"):format(DisplayLabel(display)) end,
            func = function()
              table.remove(list, index)
              Changed(true)
            end,
          },
        },
      },
      what = what,
      look = look,
      load = load,
      share = DisplayShareTab(group, display, index),
    },
  }
end

-- Groups ---------------------------------------------------------------------
-- In the tree a group has a "Settings" entry (tabs) followed by its displays.
-- AceConfigDialog puts a node's child groups either in the tree or in tabs,
-- never both, so the tabs live one level down under "Settings".

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

-- `target` and `class` are saved as lists; the editor shows them as checkboxes.
local function ListField(group, key, structural)
  local function AsList()
    local value = group[key]
    if type(value) == "string" then
      value = value ~= "" and { value } or {}
    end
    return value or {}
  end
  return function(_, item)
    return tContains(AsList(), item)
  end, function(_, item, on)
    local list = AsList()
    if on and not tContains(list, item) then
      table.insert(list, item)
    elseif not on then
      tDeleteItem(list, item)
    end
    group[key] = list
    Changed(structural)
  end
end


local function AddDisplay(group)
  table.insert(group.displays, { mode = "list" })
  ns.Prepare(group)
  Changed(true)
end

local function PlacementTab(group)
  local growthGet, growthSet = Field(group, "growth", true)

  local function AnchorRange(slot, order, label)
    local get, set = AnchorField(group, slot, 0)
    return {
      type = "range", order = order, name = label, min = -2000, max = 2000, softMin = -600, softMax = 600, step = 1,
      get = get, set = set,
    }
  end

  local function AnchorPoint(slot, order, label)
    local get, set = AnchorField(group, slot, "CENTER")
    return { type = "select", order = order, name = label, values = POINTS, get = get, set = set }
  end

  local frameGet, frameSet = AnchorField(group, 2, "")

  local lines = {
    type = "group", inline = true, order = 1, name = "Lines",
    args = {
      growth = {
        type = "select", order = 1, name = "Grow", values = GROWTHS, sorting = GROWTH_ORDER,
        get = growthGet, set = growthSet,
      },
      lines = {
        type = "select", order = 2, name = "New lines go",
        desc = "Where a display set to start a new line goes: across from the way icons grow.",
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
        type = "range", order = 3, name = "Line spacing", min = 0, max = 40, step = 1,
        desc = "Gap between lines.",
        get = function() return group.lineSpacing end,
        set = function(_, value)
          group.lineSpacing = value
          Changed(false)
        end,
      },
      break1 = Break(3.4),
      lineMax = {
        type = "range", order = 3.5, name = "Show at most per line", min = 0, max = 40, step = 1,
        desc = "Shows only the first icons of each line, in display order. 0: no limit. "
            .. "Works best when every icon on the line is the same size. Not for centered growth.",
        -- A line can't both wrap and cap.
        hidden = function() return group.growth == "CENTER" or group.growth == "CENTER_VERTICAL" or AnyWraps(group) end,
        get = function() return group.lineMax or 0 end,
        set = function(_, value)
          group.lineMax = value > 0 and value or nil
          Changed(true)
        end,
      },
    },
  }

  local anchor = {
    type = "group", inline = true, order = 2, name = "Anchor",
    args = {
      anchorTo = {
        type = "select", order = 4, name = "Anchor to",
        values = { unit = "Each unit's own frame", screen = "Screen", frame = "A named frame" },
        desc = "Each unit's own frame: PlayerFrame, TargetFrame or FocusFrame for you, your target and your focus; "
            .. "raid-style frames for party and raid members; nameplates for units with one.",
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
      point = AnchorPoint(1, 6, "Group's point"),
      relativePoint = AnchorPoint(3, 7, "To the frame's"),
      break3 = Break(7.9),
      x = AnchorRange(4, 8, "X"),
      y = AnchorRange(5, 9, "Y"),
    },
  }

  return { type = "group", order = 2, name = "Placement", args = { lines = lines, anchor = anchor } }
end

-- One checkbox per unit kind, two per row, in TARGETS order. A multiselect
-- would sort them by key.
local function UnitsBox(get, set)
  local args = {}
  for i, entry in ipairs(TARGETS) do
    local kind = entry[1]
    args[kind] = {
      type = "toggle", order = i, width = 1.5, name = entry[2],
      desc = "Anchored to each unit's own frame, every unit gets a row there. "
          .. "Anchored to the screen or a named frame, the units share one row in this order.",
      get = function() return get(nil, kind) end,
      set = function(_, on) set(nil, kind, on) end,
    }
    if i % 2 == 0 then
      args["break" .. i] = Break(i + 0.5)
    end
  end
  return { type = "group", inline = true, order = 2, name = "Units", args = args }
end

local function GroupOptions(group, index)
  local targetGet, targetSet = ListField(group, "target", true)

  local general = {
    type = "group", order = 1, name = "Group",
    args = {
      name = {
        type = "input", order = 1, width = "double", name = "Name",
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
      target = UnitsBox(targetGet, targetSet),
    },
  }

  local look, load = SharedTabs(group, false)
  look.order, load.order = 3, 4
  general.args.filter = {
    type = "input", order = 3, width = 1.5, name = "Filter", validate = ValidateFilter,
    desc = "Which auras the displays show. A display with its own filter uses that instead.",
    get = function() return group.filter end,
    set = function(_, value)
      value = CleanFilter(value)
      group.filter = value ~= "" and value or nil -- empty: back to the default
      Changed(false)
    end,
  }
  AddFilterPicker(general.args, 3.1, group, function() return group.filter end, function(text)
    group.filter = text ~= "" and text or nil
    Changed(false)
  end)

  -- Above the Settings tabs, so they show on every tab. An inline group with
  -- no name is drawn without a box or title.
  local actions = {
    type = "group", inline = true, order = 0, name = "",
    args = {
      add = {
        type = "execute", order = 1, width = 0.8, name = "Add display",
        desc = "The new display lists matching auras. Set its Shows option to \"Icon when none match\" for a missing-aura icon.",
        func = function() AddDisplay(group) end,
      },
      duplicate = {
        type = "execute", order = 2, width = 0.8, name = "Duplicate group",
        desc = "Adds a copy of this group and its displays below it. The copy sits on top of the original until you move it.",
        func = function()
          -- CopyTable copies raw fields only, no metatables; Prepare adds them.
          local copy = CopyTable(group)
          copy.id = ns.NewGroupID()
          copy.name = UniqueName((group.name or "Group") .. " copy")
          ns.Prepare(copy)
          table.insert(ns.groups, index + 1, copy)
          Changed(true)
          AceConfigDialog:SelectGroup(addonName, "g" .. copy.id, "settings")
        end,
      },
      delete = {
        type = "execute", order = 3, width = 0.8, name = "Delete group",
        -- A confirm function returning a string sets the prompt (AceConfigDialog).
        confirm = function() return ("Delete %s and its displays?"):format(group.name or ("Group " .. group.id)) end,
        func = function()
          table.remove(ns.groups, index)
          Changed(true)
        end,
      },
      rowBreak = Break(3.5),
      up = { type = "execute", order = 4, width = 0.8, name = "Move up", func = function() Move(ns.groups, index, -1) end },
      down = { type = "execute", order = 5, width = 0.8, name = "Move down", func = function() Move(ns.groups, index, 1) end },
    },
  }

  local tabs = {
    general = general, placement = PlacementTab(group), look = look, load = load,
    share = GroupShareTab(group),
  }
  tabs.actions = actions

  -- Selecting the group itself opens Settings (see ns.InitOptions).
  local args = {
    settings = {
      -- Gold, so it doesn't read as one of the displays listed under it.
      type = "group", order = 2, name = "|cffffd100Settings|r", childGroups = "tab",
      args = tabs,
    },
  }
  for i, display in ipairs(group.displays) do
    args["d" .. i] = DisplayOptions(group, display, i)
  end

  return { type = "group", order = 10 + index, name = function() return group.name or ("Group " .. group.id) end, args = args }
end

-- Root -----------------------------------------------------------------------

-- Retired containers (see ns.Leaked) past which the editor suggests a reload.
local RELOAD_HINT = 500

local function NeedsReload()
  return ns.Leaked() >= RELOAD_HINT
end

local function Status()
  if ns.Locked() then
    return "|cffff4040Locked during combat.|r"
  end
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
    displays = { { mode = "list" } },
  }
  ns.Prepare(group)
  table.insert(ns.groups, group)
  Changed(true)
  AceConfigDialog:SelectGroup(addonName, "g" .. group.id, "settings")
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
    topBreak = Break(3.9),
  }
  AddTopShare(args, 4)
  for index, group in ipairs(ns.groups) do
    args["g" .. group.id] = GroupOptions(group, index)
  end
  return {
    type = "group", name = "SlopAuras", childGroups = "tree", args = args,
    disabled = function() return ns.Locked() end,
  }
end

-- The status line changes when combat starts or ends, or an apply retires
-- enough containers. Only then redraw: redrawing mid-drag would interrupt it.
local function RefreshStatus()
  local status = Status()
  if status ~= lastStatus then
    lastStatus = status
    Refresh()
  end
end
ns.OnLockChanged = RefreshStatus
ns.OnApplied = RefreshStatus

-- AceConfigDialog has no right-click hook, so after it draws our panel, each
-- widget's mouse-enabled frames get an OnMouseUp hook. Widgets are pooled and
-- shared with other addons' panels, so the hook is added once per frame and
-- checks at click time whose option the widget is showing. The widget's own
-- handler runs first (a checkbox toggles, a slider sets its value); the reset
-- then overrides that.
local hookedFrames = {}

local function OnRightClick(frame, button)
  local widget = frame.obj
  if button ~= "RightButton" or not widget or widget:GetUserData("appName") ~= addonName or ns.Locked() then
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

-- The tab keys of a display entry and of a group's Settings entry.
local DISPLAY_TABS = { what = true, look = true, load = true, share = true }
local SETTINGS_TABS = { general = true, placement = true, look = true, load = true, share = true }

-- AceConfigDialog remembers the selected tab per tree entry and reads it when
-- it draws the entry's tabs (status.groups.selected). Setting the same tab on
-- every entry that has it opens the next display or group on the tab in use.
local function CarryTab(tab)
  local function Select(path)
    local status = AceConfigDialog:GetStatusTable(addonName, path)
    status.groups = status.groups or {}
    status.groups.selected = tab
  end
  for _, group in ipairs(ns.groups) do
    local key = "g" .. group.id
    if SETTINGS_TABS[tab] then
      Select({ key, "settings" })
    end
    if DISPLAY_TABS[tab] then
      for i in ipairs(group.displays) do
        Select({ key, "d" .. i })
      end
    end
  end
end

function ns.InitOptions()
  LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, Options)
  local _, categoryID = AceConfigDialog:AddToBlizOptions(addonName, "SlopAuras")
  hooksecurefunc(AceConfigDialog, "FeedGroup", function(_, appName, _, container, _, path)
    if appName ~= addonName then
      return
    end
    HookWidgets(container)
    -- A tab's page: { group, display or "settings", tab }.
    if path and #path == 3 and type(path[1]) == "string" and path[1]:match("^g%d+$") then
      CarryTab(path[3])
    end
    -- A group's own page has nothing on it: its tabs live under its Settings
    -- entry (AceConfigDialog can't give one node both tree children and
    -- tabs). Selecting the group goes there instead, a frame later, once this
    -- feed is done.
    local key = path and #path == 1 and path[1]
    if type(key) == "string" and key:match("^g%d+$") then
      C_Timer.After(0, function() AceConfigDialog:SelectGroup(addonName, key, "settings") end)
    end
  end)
  SLASH_SLOPAURAS1 = "/slop"
  SlashCmdList.SLOPAURAS = function()
    -- The game refuses to open its settings panel for an addon in combat
    -- (C_SettingsUtil.OpenSettingsPanel, HasRestrictions). Esc > Options still
    -- works then, since that click isn't addon code.
    if InCombatLockdown() then
      print(addonName .. ": settings can't open in combat. Try again after the fight.")
      return
    end
    Settings.OpenToCategory(categoryID)
  end
end

