-- Share: settings as text, for import and export.
--
-- A string is "SlopAuras:<version>:<kind>:<json>", kind being "config" (all
-- groups), "group" or "display". The JSON is the saved table with two changes,
-- because JSON object keys are strings: spell ID sets become lists of IDs, and
-- a group's anchor becomes named fields. Parsing uses C_EncodingUtil, so
-- nothing pasted runs as code.
--
-- Import is strict: any unknown key or bad value rejects the whole string and
-- names the problem. Nothing is changed until a string has passed.

local _, ns = ...

local Share = {}
ns.Share = Share

local VERSION = 1

-- Validation ------------------------------------------------------------------
-- Each check takes the JSON value and its path ("displays[2].size") and
-- returns the value to save, or raises a problem with Fail.

local function Fail(path, message)
  error({ problem = path .. ": " .. message }, 0)
end

local function IsList(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count == #value
end

local function Number(min, max)
  return function(value, path)
    if type(value) ~= "number" or value ~= value then
      Fail(path, "should be a number")
    end
    if value < min or value > max then
      Fail(path, ("should be between %s and %s"):format(min, max))
    end
    return value
  end
end

local function Boolean(value, path)
  if type(value) ~= "boolean" then
    Fail(path, "should be true or false")
  end
  return value
end

-- true (only while), false (only while not) or "any".
local function ThreeWay(value, path)
  if value ~= "any" and type(value) ~= "boolean" then
    Fail(path, "should be \"any\", true or false")
  end
  return value
end

-- `values`: a set of the allowed strings.
local function OneOf(values)
  return function(value, path)
    if type(value) ~= "string" or not values[value] then
      Fail(path, ("%q isn't one of the allowed values"):format(tostring(value)))
    end
    return value
  end
end

local function Set(...)
  local set = {}
  for _, value in ipairs({ ... }) do
    set[value] = true
  end
  return set
end

-- A list of strings from `values`, no repeats.
local function ListOf(values)
  local check = OneOf(values)
  return function(value, path)
    if not IsList(value) then
      Fail(path, "should be a list")
    end
    local seen = {}
    for i, item in ipairs(value) do
      check(item, ("%s[%d]"):format(path, i))
      if seen[item] then
        Fail(path, ("lists %q twice"):format(item))
      end
      seen[item] = true
    end
    return CopyTable(value)
  end
end

local function Color(value, path)
  if not IsList(value) or #value ~= 3 then
    Fail(path, "should be a color: [red, green, blue], each 0 to 1")
  end
  local check = Number(0, 1)
  for i = 1, 3 do
    check(value[i], ("%s[%d]"):format(path, i))
  end
  return { value[1], value[2], value[3] }
end

local function Filter(value, path)
  if type(value) ~= "string" then
    Fail(path, "should be a filter string")
  end
  local ok, problem = AuraUtil.IsValidFilterString(value)
  if not ok then
    Fail(path, problem or "isn't a filter the game accepts")
  end
  return value
end

-- Spell ID sets are saved as { [id] = true, [hiddenID] = false } and shared
-- as a list: IDs as numbers, hidden ones as "!12345" strings.
local function SpellIDs(value, path)
  if not IsList(value) or #value == 0 then
    Fail(path, "should be a list of spell IDs")
  end
  local set = {}
  for i, item in ipairs(value) do
    local id, on = item, true
    if type(item) == "string" and item:match("^!%d+$") then
      id, on = tonumber(item:sub(2)), false
    end
    if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then
      Fail(("%s[%d]"):format(path, i), "should be a spell ID, or \"!\" and a spell ID to hide it")
    end
    set[id] = on
  end
  return set
end

local COMBAT = Set("always", "in", "out")
local POINTS = Set("TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT")
local OUTLINES = Set("NONE", "OUTLINE", "THICKOUTLINE")
local ALIGNS = Set("LEFT", "CENTER", "RIGHT")

local function FontName(value, path)
  if value ~= false and (type(value) ~= "string" or value == "") then
    Fail(path, "should be a font name or false")
  end
  return value
end

local function Classes()
  return Set(unpack(CLASS_SORT_ORDER))
end

local function Sorts()
  local set = {}
  for name in pairs(AuraContainerSortMethod) do
    set[name] = true
  end
  return set
end

-- Keys a display and its group can both hold (on a group: defaults for its
-- displays). Checks are built when used, since some read game tables.
local SHARED = {
  size = function() return Number(8, 128) end,
  spacing = function() return Number(0, 40) end,
  alpha = function() return Number(0, 1) end,
  zoom = function() return Number(0, 1) end,
  timerSize = function() return Number(6, 32) end,
  max = function() return Number(1, 40) end,
  sort = function() return OneOf(Sorts()) end,
  sortReverse = function() return Boolean end,
  desaturate = function() return Boolean end,
  dispelBorder = function() return Boolean end,
  borderStyle = function() return OneOf(Set("blizzard", "plain")) end,
  skin = function() return OneOf(Set("masque", "none")) end,
  borderWidth = function() return Number(1, 8) end,
  borderColor = function()
    return function(value, path)
      if value == false then
        return false
      end
      return Color(value, path)
    end
  end,
  hideTimer = function() return Boolean end,
  hideStacks = function() return Boolean end,
  hideSwipe = function() return Boolean end,
  stackSize = function() return Number(6, 32) end,
  -- A LibSharedMedia name, which the importer may not have (StyleString falls
  -- back to the text's own font); false for the text's own font.
  timerFont = function() return FontName end,
  stackFont = function() return FontName end,
  timerOutline = function() return OneOf(OUTLINES) end,
  stackOutline = function() return OneOf(OUTLINES) end,
  timerColor = function() return Color end,
  stackColor = function() return Color end,
  timerPoint = function() return OneOf(POINTS) end,
  stackPoint = function() return OneOf(POINTS) end,
  timerAlign = function() return OneOf(ALIGNS) end,
  stackAlign = function() return OneOf(ALIGNS) end,
  timerX = function() return Number(-50, 50) end,
  timerY = function() return Number(-50, 50) end,
  stackX = function() return Number(-50, 50) end,
  stackY = function() return Number(-50, 50) end,
  tint = function()
    return function(value, path)
      if value == false then
        return false
      end
      return Color(value, path)
    end
  end,
  glow = function()
    return function(value, path)
      if type(value) == "boolean" then
        return value
      end
      return Color(value, path)
    end
  end,
  glowCombat = function() return OneOf(Set("always", "in", "out", "never")) end,
  glowInRange = function() return Boolean end,
  combat = function() return OneOf(COMBAT) end,
  nameplateUnits = function() return OneOf(Set("enemy", "friendly", "all")) end,
  class = function() return ListOf(Classes()) end,
  resting = function() return ThreeWay end,
  mounted = function() return ThreeWay end,
  neverLoad = function() return Boolean end,
  hideWhenPlayerDead = function() return Boolean end,
  -- Saved as one ID or a list, negative for "must not know"; shared as 588,
  -- "!588" or a list of those.
  knownSpell = function()
    local function One(value, path)
      local id, sign = value, 1
      if type(value) == "string" and value:match("^!%d+$") then
        id, sign = tonumber(value:sub(2)), -1
      end
      if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then
        Fail(path, 'should be a spell ID, or "!" and a spell ID')
      end
      return sign * id
    end
    return function(value, path)
      if IsList(value) and #value > 0 then
        local ids = {}
        for i, item in ipairs(value) do
          ids[i] = One(item, ("%s[%d]"):format(path, i))
        end
        return ids
      end
      return One(value, path)
    end
  end,
  hideWhenDead = function() return Boolean end,
  hideWhenOffline = function() return Boolean end,
  hideWhenNotVisible = function()
    return function(value, path)
      if value == "auto" or type(value) == "boolean" then
        return value
      end
      Fail(path, "should be \"auto\", true or false")
    end
  end,
}

local DISPLAY_ONLY = {
  name = function()
    return function(value, path)
      if type(value) ~= "string" or value == "" then
        Fail(path, "should be a name")
      end
      return value
    end
  end,
  mode = function() return OneOf(Set("list", "missing")) end,
  filter = function() return Filter end,
  newLine = function() return Boolean end,
  wrap = function() return Number(1, 40) end,
  spellIDs = function() return SpellIDs end,
  rankSpellIDs = function() return SpellIDs end,
  maxDuration = function() return Number(1, 86400) end,
  icon = function()
    return function(value, path)
      if type(value) == "number" or (type(value) == "string" and value ~= "") then
        return value
      end
      Fail(path, "should be a spell ID or a texture path")
    end
  end,
  dispelTypes = function()
    return ListOf(Set("None", unpack(ns.Chain.DISPEL_TYPES)))
  end,
}

-- Saved: { point, frameName or nil, relativePoint, x, y }.
-- Shared: { point = ..., frame = ..., relativePoint = ..., x = ..., y = ... }.
local function Anchor(value, path)
  if type(value) ~= "table" or IsList(value) and next(value) then
    Fail(path, "should be { point, relativePoint, x, y } with an optional frame")
  end
  for key in pairs(value) do
    if key ~= "point" and key ~= "frame" and key ~= "relativePoint" and key ~= "x" and key ~= "y" then
      Fail(path, ("has an unknown key %q"):format(tostring(key)))
    end
  end
  local frame = value.frame
  if frame ~= nil and (type(frame) ~= "string" or frame == "") then
    Fail(path .. ".frame", "should be a frame's name")
  end
  local offset = Number(-2000, 2000)
  return {
    OneOf(POINTS)(value.point, path .. ".point"),
    frame,
    OneOf(POINTS)(value.relativePoint, path .. ".relativePoint"),
    offset(value.x, path .. ".x"),
    offset(value.y, path .. ".y"),
  }
end

local ValidateDisplay

local GROUP_ONLY = {
  name = function()
    return function(value, path)
      if type(value) ~= "string" or value == "" then
        Fail(path, "should be a name")
      end
      return value
    end
  end,
  target = function() return ListOf(ns.TARGETS) end,
  anchorTo = function() return OneOf(Set("unit", "screen", "frame")) end,
  anchor = function() return Anchor end,
  growth = function() return OneOf(ns.Chain.GROWTHS) end,
  lines = function() return OneOf(Set("UP", "DOWN", "LEFT", "RIGHT")) end,
  lineSpacing = function() return Number(0, 40) end,
  lineMax = function() return Number(1, 40) end,
  displays = function()
    return function(value, path)
      if not IsList(value) then
        Fail(path, "should be a list of displays")
      end
      local displays = {}
      for i, display in ipairs(value) do
        displays[i] = ValidateDisplay(display, ("%s[%d]"):format(path, i))
      end
      return displays
    end
  end,
}

-- Checks every key of `value` against the spec tables; returns the saved form.
local function ValidateTable(value, path, ...)
  if type(value) ~= "table" or (IsList(value) and next(value)) then
    Fail(path, "should be a table of settings")
  end
  local specs = { ... }
  local result = {}
  for key, item in pairs(value) do
    local spec
    for _, specTable in ipairs(specs) do
      spec = spec or specTable[key]
    end
    if not spec then
      Fail(path, ("has a key SlopAuras doesn't know: %q"):format(tostring(key)))
    end
    result[key] = spec()(item, path .. "." .. key)
  end
  return result
end

function ValidateDisplay(value, path)
  return ValidateTable(value, path, SHARED, DISPLAY_ONLY)
end

local function ValidateGroup(value, path)
  if type(value) == "table" then
    ns.MoveGroupFilter(value)
  end
  local group = ValidateTable(value, path, SHARED, GROUP_ONLY)
  if not group.name then
    Fail(path, "needs a name")
  end
  group.displays = group.displays or {}
  return group
end

local function ValidateConfig(value)
  local config = value
  if type(config) ~= "table" or IsList(config) and next(config) then
    Fail("config", "should be a table with a list of groups")
  end
  for key in pairs(config) do
    if key ~= "groups" then
      Fail("config", ("has a key SlopAuras doesn't know: %q"):format(tostring(key)))
    end
  end
  if not IsList(config.groups) then
    Fail("config.groups", "should be a list of groups")
  end
  local groups, names = {}, {}
  for i, group in ipairs(config.groups) do
    groups[i] = ValidateGroup(group, ("groups[%d]"):format(i))
    if names[groups[i].name] then
      Fail(("groups[%d]"):format(i), ("has the same name as another group: %q"):format(groups[i].name))
    end
    names[groups[i].name] = true
  end
  return groups
end

-- Export ------------------------------------------------------------------------
-- The saved form turned into the shared form: copies, so nothing saved changes.

local function SharedValue(key, value)
  if key == "knownSpell" then
    local function One(id)
      return id < 0 and "!" .. -id or id
    end
    if type(value) ~= "table" then
      return One(value)
    end
    local ids = {}
    for i, id in ipairs(value) do
      ids[i] = One(id)
    end
    return ids
  end
  if key == "spellIDs" or key == "rankSpellIDs" then
    local ids = {}
    for id in pairs(value) do
      table.insert(ids, id)
    end
    table.sort(ids)
    for i, id in ipairs(ids) do
      if not value[id] then
        ids[i] = "!" .. id
      end
    end
    return #ids > 0 and ids or nil
  end
  if key == "anchor" then
    return { point = value[1], frame = value[2], relativePoint = value[3], x = value[4], y = value[5] }
  end
  if (key == "class" or key == "target") and type(value) == "string" then
    return value ~= "" and { value } or nil
  end
  if type(value) == "table" then
    -- An empty list would come back as an empty JSON object or array, and
    -- means the same as no value.
    return next(value) and CopyTable(value) or nil
  end
  return value
end

local function ExportDisplay(display, withGroup)
  local result = {}
  for key, value in pairs(display) do -- raw keys only: pairs skips the metatable
    result[key] = SharedValue(key, value)
  end
  if withGroup then
    for key in pairs(SHARED) do
      if result[key] == nil and display[key] ~= nil then
        result[key] = SharedValue(key, display[key])
      end
    end
  end
  return result
end

local function ExportGroup(group)
  local result = {}
  for key, value in pairs(group) do
    if key == "displays" then
      result.displays = {}
      for i, display in ipairs(value) do
        result.displays[i] = ExportDisplay(display, false)
      end
    elseif key ~= "id" then
      result[key] = SharedValue(key, value)
    end
  end
  return result
end

local function Encode(kind, value)
  return ("SlopAuras:%d:%s:%s"):format(VERSION, kind, C_EncodingUtil.SerializeJSON(value))
end

function Share.ExportConfig()
  local groups = {}
  for i, group in ipairs(ns.groups) do
    groups[i] = ExportGroup(group)
  end
  return Encode("config", { groups = groups })
end

function Share.ExportGroup(group)
  return Encode("group", ExportGroup(group))
end

-- withGroup: also the values it takes from its group (and the defaults).
function Share.ExportDisplay(display, withGroup)
  return Encode("display", ExportDisplay(display, withGroup))
end

-- Import ------------------------------------------------------------------------

local KIND_NAMES = { config = "a full config", group = "a group", display = "a display" }
local VALIDATORS = {
  config = ValidateConfig,
  group = function(value) return ValidateGroup(value, "group") end,
  display = function(value) return ValidateDisplay(value, "display") end,
}

-- Returns the saved form of `text` if it holds `kind`, or nil and a message.
-- config: a list of groups; group: a group; display: a display.
function Share.Import(text, kind)
  text = strtrim(text or "")
  if text == "" then
    return nil, "Nothing pasted."
  end
  local version, found, json = text:match("^SlopAuras:(%d+):(%a+):(.*)$")
  if not version then
    return nil, "That isn't SlopAuras text. It should start with \"SlopAuras:\"."
  end
  if tonumber(version) ~= VERSION then
    return nil, ("That text is from a different version of SlopAuras (format %s)."):format(version)
  end
  if not VALIDATORS[found] then
    return nil, ("Unknown kind of text: %q."):format(found)
  end
  if found ~= kind then
    return nil, ("That text holds %s, not %s."):format(KIND_NAMES[found], KIND_NAMES[kind])
  end
  local parsed, value = pcall(C_EncodingUtil.DeserializeJSON, json)
  if not parsed or value == nil then
    return nil, "The text after the prefix isn't valid JSON."
  end
  local ok, result = pcall(VALIDATORS[kind], value)
  if not ok then
    if type(result) == "table" and result.problem then
      return nil, "Not imported. " .. result.problem
    end
    error(result, 0)
  end
  return result
end
