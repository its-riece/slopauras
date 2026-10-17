-- SlopAuras: rows of aura displays, built on Blizzard AuraContainers.
-- Chain.lua does the container work, Options.lua is the editor. This file
-- decides which displays exist (groups, inheritance, units) and which are
-- showing (conditions), and applies the editor's changes.
--
-- A "host" is one unit's place on screen: the player, the target, the focus,
-- one party or raid frame (members or pets), or one nameplate. Every host gets its own copy of
-- the rows meant for it.

local addonName, ns = ...
local Chain = ns.Chain

-- What a group falls back to. A display falls back to its group.
local DEFAULTS = {
  target = "player",
  anchorTo = "screen", -- "screen", "unit" (each unit's own frame) or "frame" (anchor[2] names it)
  growth = "RIGHT",
  filter = "HELPFUL",
  mode = "list",
  max = 8,
  size = 24,
  spacing = 2,
  alpha = 1,
  zoom = 0,
  -- Texts on the icon (StyleString in Chain.lua). No font: the text's own,
  -- the countdown's for the timer, NumberFontNormal for stacks.
  timerSize = 12,
  timerOutline = "OUTLINE",
  timerColor = { 1, 1, 1 },
  timerPoint = "CENTER",
  timerAlign = "CENTER",
  timerX = 0,
  timerY = 0,
  -- "blizzard" (the cooldown countdown's look), "clock", "short" or "long"
  -- (TIMER_FORMATS in Chain.lua). No timerDecimals: the game's threshold.
  timerFormat = "blizzard",
  timerPrecision = 1,
  stackSize = 14,
  stackOutline = "OUTLINE",
  stackColor = { 1, 1, 1 },
  stackPoint = "BOTTOMRIGHT",
  stackAlign = "RIGHT",
  stackX = -1,
  stackY = 1,
  -- "masque": the group's Masque skin draws the frame and the border ring.
  -- Masque loads first (OptionalDeps), so with it installed, it drives icons
  -- unless a group or display says otherwise.
  skin = LibStub("Masque", true) and "masque" or "none",
  borderStyle = "blizzard", -- or "plain"; without a skin only
  borderWidth = 2, -- plain borders only
  lineSpacing = 2,
  layer = 0,
  tooltip = "never", -- "always" or "out" (out of combat only)
  hideWhenDead = true,
  hideWhenOffline = true,
}
ns.DEFAULTS = DEFAULTS

local function Warn(message)
  print(addonName .. ": " .. message)
end

-- Saved settings -------------------------------------------------------------
-- SlopAurasDB = { groups = { ... }, nextID = n }, shared by every character.
-- No profiles: when a group applies is decided by its load conditions.

-- Inheritance: display -> group -> DEFAULTS. Metatables aren't saved, so this
-- runs on load and on every table the editor creates.
function ns.Prepare(group)
  setmetatable(group, { __index = DEFAULTS })
  for _, display in ipairs(group.displays) do
    setmetatable(display, { __index = group })
  end
end

function ns.NewGroupID()
  ns.db.nextID = (ns.db.nextID or 0) + 1
  return ns.db.nextID
end

-- Settings found in AceDB's layout (profiles.Default) are moved to the top level.
local function Migrate(db)
  local old = db.profiles and db.profiles.Default
  if not db.groups and old then
    db.groups, db.nextID = old.groups, old.nextID
  end
  db.profiles, db.profileKeys = nil, nil
end

-- A group's display list also holds line breaks, { mode = "break" }: the
-- displays after one start a new line. Iterates the displays alone, giving
-- each one's number among them (as the editor shows it) and its list index.
function ns.Displays(group)
  local list, index, number = group.displays, 0, 0
  return function()
    repeat
      index = index + 1
    until not list[index] or list[index].mode ~= "break"
    if list[index] then
      number = number + 1
      return number, list[index], index
    end
  end
end

-- Display modes this version draws, and line breaks. A display saved with any
-- other mode is dropped: SplitLines would otherwise draw it as an aura list.
local MODES = { list = true, missing = true, ["break"] = true }
-- Keys nothing reads any more. Export writes every raw key and import rejects
-- unknown ones, so they're dropped too.
local RETIRED_KEYS = { "locHide", "labelSize" }

-- Filters belong to displays only. A group's filter, from older saves and
-- import strings, moves to each display without its own. Also takes
-- unvalidated import tables, hence the type checks.
function ns.MoveGroupFilter(group)
  local filter = group.filter
  group.filter = nil
  if type(filter) ~= "string" or type(group.displays) ~= "table" then
    return
  end
  for _, display in ipairs(group.displays) do
    if type(display) == "table" and rawget(display, "filter") == nil then
      display.filter = filter
    end
  end
end

-- `lineMax` (older saves and import strings) showed only the first N icons of
-- each line. With one line and N = 1 it picked one icon by display order: the
-- same as each display on its own line, showing one icon, and only the first
-- line showing. Other uses have no equivalent and show every icon. Also takes
-- import tables, after validation.
function ns.ConvertLineMax(group)
  local cap = group.lineMax
  group.lineMax = nil
  if cap ~= 1 or group.growth == "CENTER" or group.growth == "CENTER_VERTICAL" then
    return -- centered lines ignored it
  end
  for n, display in ns.Displays(group) do
    if n > 1 and display.newLine then
      return
    end
  end
  group.firstLine = true
  for n, display in ns.Displays(group) do
    display.newLine = n > 1 or nil
    display.max = 1
  end
end

-- `newLine` (older saves and import strings) marked a display that starts a
-- line. It becomes a line break before that display. Also takes import
-- tables, after validation.
function ns.ConvertNewLine(group)
  local list = {}
  for _, entry in ipairs(group.displays) do
    local last = list[#list]
    if entry.newLine and last and last.mode ~= "break" then
      table.insert(list, { mode = "break" })
    end
    entry.newLine = nil
    table.insert(list, entry)
  end
  group.displays = list
end

-- `nameplateUnits` (older saves and import strings: "enemy", "friendly" or
-- "all", nameplates only) becomes `reaction`, which applies to every unit.
-- Unset still means enemies on nameplates. Takes a group or a display, and
-- import tables after validation.
local REACTIONS = { enemy = "enemy", friendly = "friendly", all = "any" }

local function ConvertReaction(t)
  local old = t.nameplateUnits
  t.nameplateUnits = nil
  if old ~= nil and t.reaction == nil then
    t.reaction = REACTIONS[old]
  end
end

function ns.ConvertNameplateUnits(group)
  ConvertReaction(group)
  for _, display in ns.Displays(group) do
    ConvertReaction(display)
  end
end
ns.ConvertReaction = ConvertReaction

local function Clean(group)
  ns.MoveGroupFilter(group)
  ns.ConvertLineMax(group)
  ns.ConvertNewLine(group)
  ns.ConvertNameplateUnits(group)
  for _, key in ipairs(RETIRED_KEYS) do
    group[key] = nil
  end
  for j = #group.displays, 1, -1 do
    local display = group.displays[j]
    for _, key in ipairs(RETIRED_KEYS) do
      display[key] = nil
    end
    if display.mode ~= nil and not MODES[display.mode] then
      table.remove(group.displays, j)
    end
  end
end

local function LoadSettings()
  SlopAurasDB = SlopAurasDB or {}
  ns.db = SlopAurasDB
  Migrate(ns.db)
  ns.db.groups = ns.db.groups or {}
  for _, group in ipairs(ns.db.groups) do
    group.id = group.id or ns.NewGroupID()
    group.displays = group.displays or {}
    Clean(group)
    -- A group without anchorTo gets the one its anchor implies: a frame name
    -- -> that frame; party/raid/nameplate units -> each unit's frame; else the screen.
    if not group.anchorTo then
      local name = group.anchor and group.anchor[2]
      local targets = type(group.target) == "table" and group.target or { group.target }
      if name and name ~= "" then
        group.anchorTo = "frame"
      elseif tContains(targets, "party") or tContains(targets, "raid") or tContains(targets, "nameplate") then
        group.anchorTo = "unit"
      else
        group.anchorTo = "screen"
      end
    end
    ns.Prepare(group)
  end
  ns.groups = ns.db.groups
end

-- Rows -----------------------------------------------------------------------
-- A row is one group on one host: its lines of displays. Everything its
-- containers are built from goes into its signature: when an edit changes the
-- signature the row is rebuilt, otherwise it's updated in place.

local TARGETS = {
  player = true, target = true, focus = true, party = true, partypet = true, raid = true, raidpet = true,
  nameplate = true,
}
ns.TARGETS = TARGETS

-- `target` is one name or a list of them. Returns a set, or false if a name is
-- unknown.
local function TargetSet(target)
  local set = {}
  for _, kind in ipairs(type(target) == "table" and target or { target }) do
    if not TARGETS[kind] then
      return false
    end
    set[kind] = true
  end
  return set
end

-- `class` is one class token, a list of them, or empty for every class. Works
-- for a group (load) and for a display (a condition; it inherits the group's).
local playerClass

local function ClassAllowed(t)
  playerClass = playerClass or UnitClassBase("player")
  if type(t.class) == "string" then
    return t.class == "" or t.class == playerClass
  end
  return not t.class or #t.class == 0 or tContains(t.class, playerClass)
end

-- "Only if you know spell": one ID or a list; a negative ID is one that must
-- not be known. Of the positive IDs, at least one must be known. Not secret
-- (SpellBookDocumentation.lua has no SecretReturns on it).
local function KnowsSpells(d)
  local spell = d.knownSpell
  if not spell then
    return true
  end
  local wanted, known = false, false
  for _, id in ipairs(type(spell) == "table" and spell or { spell }) do
    if id < 0 then
      if C_SpellBook.IsSpellKnown(-id) then
        return false
      end
    else
      wanted = true
      known = known or C_SpellBook.IsSpellKnown(id)
    end
  end
  return known or not wanted
end

-- Whether a display is built at all. Every container costs 10 buttons per
-- aura group per host (Blizzard's FrameCreationBatchSize), so displays that
-- can't show on this character aren't built: Never load, a class that isn't
-- yours, a spell you don't know. Classes can't change in a session; known
-- spells can, and WatchKnownSpells rebuilds when they do.
-- NotBuiltReason says why not, for the editor: "never", "class" or "spell".
function ns.NotBuiltReason(d)
  if d.neverLoad then
    return "never"
  elseif not ClassAllowed(d) then
    return "class"
  elseif not KnowsSpells(d) then
    return "spell"
  end
end

local function Builds(d)
  return ns.NotBuiltReason(d) == nil
end

ns.ClassAllowed = ClassAllowed

-- Every spell ID a display's "Only if you know spell" names, and whether it
-- was known when the rows were last computed. `knownKey` lists the known ones;
-- it's part of each row's fingerprint, so a spell learned while auras are
-- secret rebuilds rows even when the displays that swap have the same mode.
local knownAtBuild, knownIDs, knownKey = {}, {}, ""

local function RecordKnownSpells()
  wipe(knownAtBuild)
  wipe(knownIDs)
  local known = {}
  for _, group in ipairs(ns.groups) do
    for _, d in ns.Displays(group) do
      local spell = d.knownSpell
      for _, id in ipairs(type(spell) == "table" and spell or { spell }) do
        id = math.abs(id)
        if knownAtBuild[id] == nil then
          knownAtBuild[id] = C_SpellBook.IsSpellKnown(id)
          table.insert(knownIDs, id)
          if knownAtBuild[id] then
            table.insert(known, id)
          end
        end
      end
    end
  end
  knownKey = table.concat(known, ",")
end

-- Whether any of those spells has been learned or unlearned since (a level,
-- a talent, a respec, or spells loading after login). Polled rather than
-- event-driven so no event can be missed; a few calls per tick.
local function KnownSpellsChanged()
  for _, id in ipairs(knownIDs) do
    if C_SpellBook.IsSpellKnown(id) ~= knownAtBuild[id] then
      return true
    end
  end
  return false
end

local rowConfigs = {}

local OTHER_COMBAT = { ["in"] = "out", out = "in" }

-- Whether a list display is built as glowing and plain copies (GlowCopies).
local function GlowSplits(d)
  return d.glow and OTHER_COMBAT[d.glowCombat] ~= nil
end

-- Whether any of the group's displays is built (Builds).
local function Loads(group)
  for _, display in ns.Displays(group) do
    if Builds(display) then
      return true
    end
  end
  return false
end

-- Which displays use Masque, which groups are built as a priority stack
-- (ns.StackDisplays) and which lines are capped (CapFlags), as one string.
-- All change what's built, but the editor sends them as ordinary look changes
-- (a skin, Max icons shown, an icon size, a cap), so Apply compares this to
-- catch them.
local buildFlags = ""

local function SameValue(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not SameValue(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

-- Keys two displays may differ in and still share an aura group: the name;
-- known spells, which already decided that both are built (Builds); and the
-- line's settings, which only the display starting the line holds (SplitLines).
local MERGE_IGNORES = { name = true, knownSpell = true, dispelTypes = true, wrap = true, lineCap = true }

-- Whether two displays' own settings match apart from MERGE_IGNORES. Both
-- belong to one group, so what they inherit matches too.
local function SameButDispel(a, b)
  if not a.dispelTypes or not b.dispelTypes then
    return false
  end
  for k, v in pairs(a) do
    if not MERGE_IGNORES[k] and not SameValue(v, rawget(b, k)) then
      return false
    end
  end
  for k in pairs(b) do
    if not MERGE_IGNORES[k] and rawget(a, k) == nil then
      return false
    end
  end
  return true
end

-- The built list displays that join the one before them on their line
-- (MergeDispelSplits), as a set. Not for priority stacks.
local function MergedDisplays(group)
  local merged, base = {}, nil
  if ns.StackDisplays(group) then
    return merged
  end
  for _, d in ipairs(group.displays) do
    if d.mode == "break" then
      base = nil
    elseif d.mode ~= "missing" and Builds(d) then
      if base and SameButDispel(base, d) then
        merged[d] = true
      else
        base = d
      end
    end
  end
  return merged
end

-- Defined with the line helpers below (LineWrap).
local LineCap, CapFlags

local function BuildFlags()
  local flags = {}
  for _, group in ipairs(ns.groups) do
    flags[#flags + 1] = ns.StackDisplays(group) and "s" or "-"
    flags[#flags + 1] = CapFlags(group)
    local merged = MergedDisplays(group)
    for _, display in ns.Displays(group) do
      flags[#flags + 1] = (display.skin == "masque" and "1" or "0") .. (merged[display] and "m" or "")
    end
  end
  return table.concat(flags)
end

-- Every setting of the group and its displays, or nil if it can't be
-- serialized.
-- `suite` only sorts groups in the editor, so it's left out: moving a group
-- between suites while auras are secret mustn't rebuild its rows.
local function GroupJSON(group)
  local suite = rawget(group, "suite")
  group.suite = nil
  local ok, json = pcall(C_EncodingUtil.SerializeJSON, group)
  group.suite = suite
  return ok and json or nil
end

-- A row's signature, its group's settings, the skin epoch and the known
-- spells (knownKey): while auras are
-- secret a row can't be restyled, only rebuilt, so any change to it means a
-- new row (SyncHost). Without `json`, a table that matches nothing.
local function Fingerprint(signature, json)
  return json and (signature .. "|" .. json .. "|" .. Chain.SkinEpoch() .. "|" .. knownKey) or {}
end

local function ComputeRows()
  buildFlags = BuildFlags()
  RecordKnownSpells()
  local rows = {}
  for _, group in ipairs(ns.groups) do
    local targets = TargetSet(group.target)
    if not ClassAllowed(group) or not Loads(group) then
      -- not loaded on this character
    elseif not targets then
      Warn(("group %s: unknown target in %s"):format(tostring(group.name), tostring(group.target)))
    elseif not Chain.GROWTHS[group.growth] then
      Warn(("group %s: unknown growth %q"):format(tostring(group.name), tostring(group.growth)))
    else
      -- Which group, growing which way, and each display's mode and line.
      -- Display identity is left out: reordering displays of the same mode
      -- keeps the row as it is. The group's identity is its
      -- table (tostring gives its address).
      local lines = Chain.Lines(group.growth, group.lines)
      local parts = {
        tostring(group), group.growth, lines, group.firstLine and "first line" or "",
      }
      -- The shape leaves out the displays and lines: a row of the same shape
      -- is kept and its containers handed to the lines (AssignLines).
      local shape = table.concat(parts, "|")
      -- A break only counts between displays, as in SplitLines.
      local started, broken = false, false
      local merged = MergedDisplays(group)
      for _, display in ipairs(group.displays) do
        if display.mode == "break" then
          broken = started
        elseif Builds(display) then
          local newLine = broken and "/" or ""
          started, broken = true, false
          -- Only Masque-style displays' buttons are registered with Masque.
          local masque = display.skin == "masque" and "+masque" or ""
          -- A combat-limited glow builds two aura groups (GlowCopies).
          local split = display.mode ~= "missing" and GlowSplits(display) and "+split" or ""
          -- Joins the aura group before it (MergeDispelSplits).
          local join = merged[display] and "+merged" or ""
          table.insert(parts, newLine .. display.mode .. masque .. split .. join)
        end
      end
      if ns.StackDisplays(group) then
        table.insert(parts, "stack")
      end
      local signature = table.concat(parts, "|")
      table.insert(rows, {
        group = group, targets = targets, lines = lines, signature = signature, shape = shape,
        fingerprint = Fingerprint(signature, GroupJSON(group)),
      })
    end
  end
  return rows
end

-- Hosts ----------------------------------------------------------------------

local hosts = {} -- every host
local unresolved = {} -- rows anchored to frames that don't exist yet
local leaked = 0 -- containers retired by edits, in memory until /reload

-- "TargetFrame" or "PartyFrame.MemberFrame1" -> the frame, or nil.
local function FindFrame(path)
  local frame = _G
  for part in path:gmatch("[^.]+") do
    frame = type(frame) == "table" and frame[part] or nil
  end
  return frame
end

-- Units that are one person each, with a frame of their own.
local SINGLE_UNITS = { player = true, target = true, focus = true }

-- The frame a row is anchored to, and whether it was found. A frame that
-- doesn't exist yet leaves the row on the screen, retried later. A unit with
-- no frame (host.frame nil) hides its unit-anchored rows (UpdateHost).
local function AnchorFrame(leader, host)
  if leader.anchorTo == "frame" then
    local frame = FindFrame((leader.anchor or {})[2] or "")
    return frame or UIParent, frame ~= nil
  elseif leader.anchorTo == "unit" and host.frame then
    return host.frame, true
  end
  return UIParent, true
end

-- What a row's origin is a child of, or nil to leave it where it is. On a
-- party or raid frame it's a child of the frame, so it's raised with it
-- (clicking raises a party frame) and hidden with it, whatever it's anchored
-- to. You, target and focus put only rows anchored to their frame there:
-- their other rows show whether or not the frame does. Nameplates: see
-- FollowPlate.
local function RowParent(row, host)
  if host.kind == "nameplate" or SINGLE_UNITS[host.kind] and row.group.anchorTo ~= "unit" then
    return UIParent
  end
  return host.frame
end

-- Positions a row's origin from its group's anchor and sets its frame level.
-- Returns false while the frame it names doesn't exist yet. Also moves the
-- row to a new frame (SetHostFrame), which the game allows in combat and
-- while auras are secret.
--
-- The level: 10 above the parent clears a unit frame's health bar and
-- borders. Rows on one frame share its strata, and equal levels draw in no
-- set order, so each layer adds 10, enough for a row's own levels (container,
-- button, cooldown, overlay). Children keep their offset when the origin's
-- level changes later.
local function PlaceOrigin(row, host)
  local anchor = row.group.anchor or {}
  local point = anchor[1] or "CENTER"
  local relativeTo, found = AnchorFrame(row.group, host)

  local parent = RowParent(row, host)
  if parent and row.origin:GetParent() ~= parent then
    row.origin:SetParent(parent)
  end
  row.origin:SetFrameLevel(row.origin:GetParent():GetFrameLevel() + 10 + row.group.layer * 10)
  row.origin:ClearAllPoints()
  row.origin:SetPoint(point, relativeTo, anchor[3] or point, anchor[4] or 0, anchor[5] or 0)
  return found
end

-- Every container pair of a row: each line's list, then its missing displays.
local function EachInst(row)
  local insts = {}
  for _, line in ipairs(row.lines) do
    if line.list then
      table.insert(insts, line.list)
    end
    for _, inst in ipairs(line.missing) do
      table.insert(insts, inst)
    end
  end
  local i = 0
  return function()
    i = i + 1
    return insts[i]
  end
end

-- Splits a group's displays into lines at its line breaks. A break before the
-- first display, after the last or right after another makes no line.
-- Missing-icon displays have their own frames and sit after the line's list
-- displays. `j` is the display's number (ns.Displays). Displays that aren't
-- built (Builds) are left out.
local function SplitLines(group)
  -- lead: the display that starts the line in the list, built or not; it
  -- holds the line's settings (wrap, lineCap), which the editor shows there.
  local lines, line, broken, j, lead = {}, nil, false, 0, nil
  for _, d in ipairs(group.displays) do
    if d.mode == "break" then
      broken, lead = line ~= nil, nil
    elseif not Builds(d) then
      j, lead = j + 1, lead or d
    else
      lead = lead or d
      if not line or broken then
        line, broken = { listDisplays = {}, missingDisplays = {}, lead = lead }, false
        table.insert(lines, line)
      end
      j = j + 1
      table.insert(d.mode == "missing" and line.missingDisplays or line.listDisplays, { d = d, j = j })
    end
  end
  return lines
end

-- Whether every strand of the group's rows is a single row (Strand): on each
-- unit's own frame, or one single unit. Lines in longer strands keep a fixed
-- height (PlaceLine), so they can't wrap.
function ns.SingleRow(group)
  if group.anchorTo == "unit" then
    return true
  end
  local targets = type(group.target) == "table" and group.target or { group.target }
  return #targets == 1 and SINGLE_UNITS[targets[1]] == true
end

-- How many icons a line's rows hold, or nil for one row: the wrap of the
-- display that starts it. A line with missing displays keeps one row (missing
-- icons chain after the first row, and the line's height is fixed), and so
-- does a group showing only its first line.
local function LineWrap(group, line)
  if #line.missingDisplays > 0 or group.firstLine or not ns.SingleRow(group) or not line.lead then
    return nil
  end
  return line.lead.wrap
end

-- Why a line can't be capped (lineCap), or nil. `missing`: the line has
-- missing displays; `wraps`: it wraps (LineWrap), which wins over a cap,
-- since a cap's window is one row deep.
--   center:  a centered line's shadow measures the whole line
--   strand:  later rows of a strand follow the whole container (Strand)
--   missing: missing icons chain after the whole container, not the window
--   stack:   a priority stack already shows one icon
local function CapBlock(group, missing, wraps)
  if wraps then
    return "wrap"
  elseif group.growth == "CENTER" or group.growth == "CENTER_VERTICAL" then
    return "center"
  elseif not ns.SingleRow(group) then
    return "strand"
  elseif missing then
    return "missing"
  elseif ns.StackDisplays(group) then
    return "stack"
  end
end

-- How many icons a line shows across all its displays, or nil for no cap:
-- the lineCap of the display that starts it, unless CapBlock rules it out.
function LineCap(group, line)
  local cap = line.lead and line.lead.lineCap
  if cap and not CapBlock(group, #line.missingDisplays > 0, LineWrap(group, line)) then
    return cap
  end
end

-- For the editor: why the line that display `index` starts can't be capped,
-- or nil. Read from the saved list, built or not, as the editor shows it.
function ns.LineCapBlock(group, index)
  local lead, missing = group.displays[index], false
  for j = index, #group.displays do
    local d = group.displays[j]
    if d.mode == "break" then
      break
    end
    missing = missing or d.mode == "missing"
  end
  local wraps = lead.wrap ~= nil and not missing and not group.firstLine and ns.SingleRow(group)
  return CapBlock(group, missing, wraps)
end

-- Which of the group's lines are capped, for BuildFlags: a line that gains or
-- loses its cap needs another container (Chain.Capped). Edits that change it
-- (lineCap, wrap, growth) are sent as look changes.
function CapFlags(group)
  local flags = {}
  for k, line in ipairs(SplitLines(group)) do
    flags[k] = LineCap(group, line) and "c" or "-"
  end
  return table.concat(flags)
end

-- How far a line reaches across: its biggest icon plus the line spacing.
local function LineHeight(line, group)
  local size = 0
  for _, entry in ipairs(line.listDisplays) do
    size = math.max(size, entry.d.size)
  end
  for _, entry in ipairs(line.missingDisplays) do
    size = math.max(size, entry.d.size)
  end
  return size + group.lineSpacing
end

-- Why "Show only the first row" can't work with the group's icon sizes, or
-- nil. Its window (Chain.StyleFirstLine) is one line of the biggest icon deep,
-- and Lua can't tell which line is on top. A line of smaller icons on top leaves
-- room for the edge of any line after it, so only the last line may be
-- smaller. Returns { small, big, last, lines }: the smaller line and the
-- biggest as { display = its first display, size = its biggest icon }, the
-- last line's first display, and how many lines there are. While it returns
-- one the setting is ignored (StyleFirstLine) and the editor says why.
function ns.FirstLineConflict(group)
  if not group.firstLine or not ns.SingleRow(group) then
    return nil
  end
  local lines, biggest = SplitLines(group), nil
  for _, line in ipairs(lines) do
    local first = line.listDisplays[1]
    if line.missingDisplays[1] and (not first or line.missingDisplays[1].j < first.j) then
      first = line.missingDisplays[1]
    end
    line.first, line.size = first.d, LineHeight(line, group) - group.lineSpacing
    if not biggest or line.size > biggest.size then
      biggest = line
    end
  end
  for i = 1, #lines - 1 do
    local line = lines[i]
    if line.size < biggest.size then
      return {
        small = { display = line.first, size = line.size },
        big = { display = biggest.first, size = biggest.size },
        last = lines[#lines].first, lines = #lines,
      }
    end
  end
  return nil
end

-- The displays of a group that's built as a priority stack (Chain.NewStack),
-- or nil. That's a group showing only its first line where every line is one
-- list display showing one icon: the same result with one button per display
-- instead of ten. Not for centered growth (the stack has no length to
-- center), or while the first-line window can't work (ns.FirstLineConflict).
function ns.StackDisplays(group)
  if not group.firstLine or not ns.SingleRow(group) or group.growth == "CENTER"
      or group.growth == "CENTER_VERTICAL" or ns.FirstLineConflict(group) then
    return nil
  end
  local displays = {}
  for _, line in ipairs(SplitLines(group)) do
    local entry = line.listDisplays[1]
    if #line.missingDisplays > 0 or #line.listDisplays ~= 1 or entry.d.max ~= 1 then
      return nil
    end
    displays[#displays + 1] = entry.d
  end
  return #displays > 0 and displays or nil
end

-- Masque ---------------------------------------------------------------------
-- One Masque group per SlopAuras group that has Masque-style displays, keyed
-- by group id, so each group can have its own skin in Masque's options.
local Masque = LibStub("Masque", true)
local skins, skinNames = {}, {} -- group id -> Masque group, name it was given

local function UsesMasque(group)
  for _, display in ns.Displays(group) do
    if display.skin == "masque" then
      return true
    end
  end
  return false
end

-- A skin or font change restyles every button (Chain.Reskinned bumps the
-- epoch StyleText and row fingerprints include). While auras are secret,
-- buttons can't be restyled and a new epoch would make Apply rebuild every
-- row, so the change waits until they aren't (ADDON_RESTRICTION_STATE_CHANGED).
local reskinPending = false

local function Reskin()
  if C_Secrets.ShouldAurasBeSecret() then
    reskinPending = true
    return
  end
  reskinPending = false
  Chain.Reskinned()
  ns.Changed(false)
end

local function SyncSkins()
  if not Masque then
    return
  end
  local live = {}
  for _, group in ipairs(ns.groups) do
    local id, name = tostring(group.id), group.name or "Group"
    if UsesMasque(group) then
      live[id] = true
      if not skins[id] then
        skins[id] = Masque:Group(addonName, name, id)
        -- A skin or option change in Masque.
        skins[id]:RegisterCallback(Reskin)
      elseif skinNames[id] ~= name then
        skins[id]:SetName(name)
      end
      skinNames[id] = name
    end
  end
  -- Delete removes each button from Masque, which reads the button: refused
  -- while auras are secret. The group then waits for a later apply.
  if C_Secrets.ShouldAurasBeSecret() then
    return
  end
  for id, skin in pairs(skins) do
    if not live[id] then
      skin:Delete()
      skins[id], skinNames[id] = nil, nil
    end
  end
end

-- Sizes a row's first line window (Chain.StyleFirstLine). Only a row on its
-- own collapses empty lines (PlaceLine), so elsewhere the window shows every
-- line, as it does while the icon sizes don't allow it (ns.FirstLineConflict).
local function StyleFirstLine(row)
  if row.firstLineWindow then
    local group = row.group
    local clip = ns.SingleRow(group) and not ns.FirstLineConflict(group)
    local displays = {}
    for _, display in ns.Displays(group) do
      if Builds(display) then
        displays[#displays + 1] = display
      end
    end
    Chain.StyleFirstLine(row.firstLineWindow, row.origin, row.g, displays, group.lineSpacing, clip,
      skins[tostring(group.id)])
  end
end

-- A list display whose glow shows only in or only out of combat is built as
-- two copies, one glowing and one plain, each loading in one combat state. A
-- list button's glow can't be switched while auras are secret, which they are
-- in combat, but an aura group can be turned on and off. A copy reads every
-- other setting from the display; one the display's own combat load rules
-- out is left out.
local function GlowCopies(entry)
  local d = entry.d
  if not GlowSplits(d) then
    return { entry }
  end
  local copies = {}
  for _, copy in ipairs({
    { combat = d.glowCombat, glowCombat = "always" },
    { combat = OTHER_COMBAT[d.glowCombat], glow = false },
  }) do
    if d.combat ~= OTHER_COMBAT[copy.combat] then
      copies[#copies + 1] = { d = setmetatable(copy, { __index = d }), j = entry.j }
    end
  end
  return copies
end

-- Neighbouring list displays that differ only in dispel types become one
-- aura group with the types combined: every aura group costs 10 buttons per
-- host, and a class-agnostic config splits one row into per-type displays that
-- only differ in which dispel spells you know. Max icons shown then counts the
-- combined display, and its auras sort together.
local function MergeDispelSplits(entries)
  local merged = {}
  for _, entry in ipairs(entries) do
    local last = merged[#merged]
    local base = last and (last.base or last.d)
    if base and SameButDispel(base, entry.d) then
      local types = CopyTable(last.d.dispelTypes)
      for _, t in ipairs(entry.d.dispelTypes) do
        if not tContains(types, t) then
          table.insert(types, t)
        end
      end
      merged[#merged] = { d = setmetatable({ dispelTypes = types }, { __index = base }), j = last.j, base = base }
    else
      merged[#merged + 1] = entry
    end
  end
  return merged
end

local function ListDisplays(line)
  local displays = {}
  for k, entry in ipairs(line.listDisplays) do
    displays[k] = entry.d
  end
  return displays
end

-- Removes and returns the first container in `pool` that `fits`, or nil.
local function Take(pool, fits)
  for k, inst in ipairs(pool) do
    if fits(inst) then
      return table.remove(pool, k)
    end
  end
end

-- Gives the row's lines, as its group's displays split now, their
-- containers. Building is slow (each aura group makes 10 buttons up front,
-- and nameplate groups exist on 40 hosts), so a line first takes one the
-- row already has: list lines one whose slots match Masque-wise
-- (Chain.CanResize), missing displays one with the same Masque registration.
-- Only what's left is built. Containers no line takes are turned off and kept
-- as spares for later edits, so moving a line break and back builds nothing.
-- Not while auras are secret: reuse restyles buttons (SyncHost).
-- Whether the game shows placeholder auras (Edit Mode or test mode), from
-- AURA_DATA_PROVIDER_SWITCH. Containers learn that only from the event, and a
-- new one starts on real auras (Blizzard_ManagedAuraContainer.lua:95), so
-- building any while placeholders are on sets `refake`, and UpdateAll calls the
-- switch again for them.
local placeholders, refake = false, false

local function AssignLines(row, host)
  local group, lists, missing = row.group, row.spareLists, row.spareMissing
  for _, line in ipairs(row.lines) do
    if line.list then
      table.insert(lists, line.list)
    end
    for _, inst in ipairs(line.missing) do
      table.insert(missing, inst)
    end
  end
  local unit, name, plate = host.unit or "player", group.name or "Group", host.kind == "nameplate"
  local skin = skins[tostring(group.id)]
  local function Reuse(inst)
    if inst.unit ~= unit then
      Chain.SetUnit(inst, unit)
    end
    return inst
  end

  local built = false
  row.lines = SplitLines(group)
  -- A priority stack is one container: its one-display lines become one line.
  local stack = ns.StackDisplays(group) ~= nil
  if stack then
    local merged = { listDisplays = {}, missingDisplays = {} }
    for k, line in ipairs(row.lines) do
      merged.listDisplays[k] = line.listDisplays[1]
    end
    row.lines = { merged }
  end
  for _, line in ipairs(row.lines) do
    local entries = {}
    -- A stack shows one display per slot, so its displays stay separate.
    for _, entry in ipairs(stack and line.listDisplays or MergeDispelSplits(line.listDisplays)) do
      for _, copy in ipairs(GlowCopies(entry)) do
        entries[#entries + 1] = copy
      end
    end
    line.listDisplays = entries
  end
  for i, line in ipairs(row.lines) do
    -- Later lines start at their own 1px origin, anchored by Relink. It may be
    -- anchored to a container, hence the template.
    if not row.origins[i] then
      row.origins[i] = CreateFrame("Frame", nil, row.origin, "DisableUntrustedLayoutScriptsTemplate")
      row.origins[i]:SetSize(1, 1)
    end
    line.origin = row.origins[i]
    if #line.listDisplays > 0 then
      local displays = ListDisplays(line)
      local cap = LineCap(group, line)
      local function Fits(inst)
        return (inst.stack == true) == stack and inst.skin == skin and Chain.Capped(inst) == (cap ~= nil)
            and Chain.CanResize(inst, displays)
      end
      -- Preferably one with enough aura groups already (Resize adds the rest).
      line.list = Take(lists, function(inst) return inst.slots >= #displays and Fits(inst) end)
          or Take(lists, Fits)
      if line.list then
        Chain.Resize(Reuse(line.list), displays, row.g, group.lineSpacing)
      elseif stack then
        built = true
        line.list = Chain.NewStack(row.parent, unit, displays, row.g, name .. " stack", plate, skin)
      else
        built = true
        line.list = Chain.NewList(row.parent, unit, displays, row.g, group.lineSpacing,
          ("%s line %d"):format(name, i), plate, skin, cap)
        Chain.SetWrap(line.list, LineWrap(group, line))
      end
    end
    line.missing = {}
    for _, entry in ipairs(line.missingDisplays) do
      local inst = Take(missing, function(inst) return inst.skin == skin and Chain.CanSetDisplay(inst, entry.d) end)
      if inst then
        Chain.SetDisplay(Reuse(inst), entry.d)
      else
        built = true
        inst = Chain.NewMissing(row.parent, unit, entry.d, row.g, group.lineSpacing,
          ("%s %d"):format(name, entry.j), plate, skin)
      end
      table.insert(line.missing, inst)
    end
  end

  refake = refake or placeholders and built
  for _, spares in ipairs({ lists, missing }) do
    for _, inst in ipairs(spares) do
      if inst.active ~= false then
        Chain.SetActive(inst, false)
        inst.active = false
      end
    end
  end
end

local function BuildRow(config, host)
  local group = config.group
  local row = {
    group = group, g = Chain.Layout(group.growth, config.lines), signature = config.signature, shape = config.shape,
    fingerprint = config.fingerprint,
  }

  -- Everything in the row hangs off this 1px frame. PlaceOrigin gives it its
  -- parent (RowParent) and level, before our children are created: they
  -- start one level above their parent.
  row.origin = CreateFrame("Frame", nil, RowParent(row, host) or UIParent)
  row.origin:SetSize(1, 1)
  if not PlaceOrigin(row, host) then
    table.insert(unresolved, { row = row, host = host })
  end

  -- Containers go inside the first line window when there is one, so it clips
  -- them.
  row.parent = row.origin
  if group.firstLine then
    row.firstLineWindow = Chain.NewFirstLineWindow(row.origin, group.name or "Group")
    row.parent = row.firstLineWindow
  end
  -- Line i starts at origins[i]; spares are containers no line uses now.
  row.origins, row.lines, row.spareLists, row.spareMissing = { row.origin }, {}, {}, {}
  AssignLines(row, host)
  StyleFirstLine(row)

  return row
end

local function ReleaseRow(row)
  for inst in EachInst(row) do
    leaked = leaked + Chain.Release(inst)
  end
  for _, spares in ipairs({ row.spareLists, row.spareMissing }) do
    for _, inst in ipairs(spares) do
      leaked = leaked + Chain.Release(inst)
    end
  end
  row.origin:Hide()
  row.released = true
end

-- Hosts in the order a joined row runs through them: you, target, focus,
-- party, party pets, raid, raid pets, nameplates; within a kind, in the order they were made.
local KIND_ORDER = { player = 1, target = 2, focus = 3, party = 4, partypet = 5, raid = 6, raidpet = 7, nameplate = 8 }
local orderedHosts = {}
local hostCount = 0

-- The rows linked as one: on a unit's own frame, just this row; on the screen
-- or a named frame, this config's row on every host, so the units don't stack
-- on the same spot. The first row's origin anchors them all.
local function Strand(row)
  if row.group.anchorTo == "unit" then
    return { row }
  end
  local strand = {}
  for _, host in ipairs(orderedHosts) do
    local other = host.rowsBySignature[row.signature]
    if other then
      table.insert(strand, other)
    end
  end
  return strand
end

-- The showing parts of line `i` of a row, in order: its list, then its
-- missing displays.
local function LineInsts(row, i)
  local line, insts = row.lines[i], {}
  if line.list and line.list.active then
    table.insert(insts, line.list)
  end
  for _, inst in ipairs(line.missing) do
    if inst.active then
      table.insert(insts, inst)
    end
  end
  return insts
end

-- Places line `i`'s origin after line i - 1. A line with only aura icons
-- collapses with its container: the next line attaches to the container's far
-- edge (the 1px of an empty container cancelled), or straight to the line's
-- origin when the list is hidden. Containers can't measure a missing icon or
-- the tallest of several units' lines, so lines with missing displays, and
-- lines shared by several units, keep their full height.
local function PlaceLine(strand, i)
  local first = strand[1]
  local g, line, prev = first.g, first.lines[i], first.lines[i - 1]
  line.origin:ClearAllPoints()
  if #strand == 1 and #prev.missing == 0 then
    local list = prev.list
    if list and list.active then
      -- A centered line's shadow starts at the origin, so its edge is where
      -- the next line starts.
      local frame, corner = list.main, g.attach
      if g.shadow then
        frame, corner = list.shadow, g.shadow.attach
      end
      Chain.Anchor(line.origin, g.start, frame, corner, -g.cx, -g.cy)
    else
      Chain.Anchor(line.origin, g.start, prev.origin, g.start)
    end
  else
    local height = LineHeight(prev, first.group)
    Chain.Anchor(line.origin, g.start, prev.origin, g.start, g.cx * height, g.cy * height)
  end
end

-- Links the showing displays of a strand, line by line: each line runs
-- through every row of the strand. Hidden displays are skipped, so they take
-- no room.
local function Relink(strand)
  local first = strand[1]
  local g = first.g
  for i, line in ipairs(first.lines) do
    if i > 1 then
      PlaceLine(strand, i)
    end
    local from = { frame = line.origin, point = g.start, x = 0, y = 0 }

    if g.shadow then
      for _, row in ipairs(strand) do
        for _, inst in ipairs(LineInsts(row, i)) do
          from = Chain.Link(inst, from, g.shadow, true)
        end
      end
      -- The line ends in a trailing gap. Shift by half of it so the icons
      -- themselves are centered.
      from.x = from.x - g.shadow.dx * first.group.spacing / 2
      from.y = from.y - g.shadow.dy * first.group.spacing / 2
    end

    for _, row in ipairs(strand) do
      for _, inst in ipairs(LineInsts(row, i)) do
        from = Chain.Link(inst, from, g, false)
      end
    end
  end
end

-- Rows waiting for Relink, keyed by row; a joined row's strand is relinked
-- once per batch however many of its hosts changed.
local dirty, batching = {}, false

local function FlushRelinks()
  local done = {}
  for row in pairs(dirty) do
    dirty[row] = nil
    if not row.released then
      local strand = Strand(row)
      if not done[strand[1]] then
        done[strand[1]] = true
        Relink(strand)
      end
    end
  end
end

-- An old row with `config`'s shape, or nil. The shape includes the group's
-- identity, so the row is already that group's.
local function SameShape(old, config)
  for _, row in pairs(old) do
    if row.shape == config.shape then
      return row
    end
  end
end

-- Brings a host's rows in line with rowConfigs: keeps rows of the same shape
-- and gives their lines containers (AssignLines), builds new ones, retires
-- the rest. While auras are secret, reusing a container restyles its buttons,
-- which the game refuses, so only unchanged rows are kept.
local function SyncHost(host)
  local old, rows, bySignature = host.rowsBySignature or {}, {}, {}
  local secret = C_Secrets.ShouldAurasBeSecret()
  for _, config in ipairs(rowConfigs) do
    if config.targets[host.kind] then
      local row
      if secret then
        row = old[config.signature]
        row = row and row.fingerprint == config.fingerprint and row or nil
      else
        row = old[config.signature] or SameShape(old, config)
      end
      if row then
        old[row.signature] = nil
        if not secret then
          row.group, row.signature, row.fingerprint = config.group, config.signature, config.fingerprint
          AssignLines(row, host)
        end
      else
        row = BuildRow(config, host)
      end
      table.insert(rows, row)
      bySignature[config.signature] = row
    end
  end
  for _, row in pairs(old) do
    ReleaseRow(row)
  end
  host.rows, host.rowsBySignature = rows, bySignature
end

-- Range, for glows that hide out of range. UnitInRange only checks other
-- group members (oUF's range element limits it the same way), so only party
-- and raid hosts track it; you, offline members and other hosts count as in
-- range. Its answer is secret and goes straight to Chain.SetRange.
local function IsMe(unit)
  local me = UnitIsUnit(unit, "player")
  return not issecretvalue(me) and me
end

local function UpdateRange(host)
  if not host.rangeEvents then
    return
  end
  local unit, inRange = host.unit, true
  if unit and UnitExists(unit) and UnitIsConnected(unit) and not IsMe(unit) then
    inRange = UnitInRange(unit)
  end
  for _, row in ipairs(host.rows) do
    for inst in EachInst(row) do
      Chain.SetRange(inst, inRange)
    end
  end
end

-- The game announces range changes per unit (CompactUnitFrame.lua registers
-- the same way).
local function WatchRange(host)
  local events = host.rangeEvents
  if not events then
    return
  end
  events:UnregisterAllEvents()
  if host.unit then
    events:RegisterUnitEvent("UNIT_IN_RANGE_UPDATE", host.unit)
    events:RegisterUnitEvent("UNIT_CONNECTION", host.unit)
  end
  UpdateRange(host)
end

local function NewHost(kind, unit, frame)
  hostCount = hostCount + 1
  local host = {
    kind = kind, unit = unit, frame = frame,
    rank = KIND_ORDER[kind] * 1000 + hostCount,
  }
  if kind == "party" or kind == "partypet" or kind == "raid" or kind == "raidpet" then
    host.rangeEvents = CreateFrame("Frame")
    host.rangeEvents:SetScript("OnEvent", function()
      UpdateRange(host)
    end)
  end
  SyncHost(host)
  WatchRange(host)
  table.insert(hosts, host)
  table.insert(orderedHosts, host)
  table.sort(orderedHosts, function(a, b) return a.rank < b.rank end)
  return host
end

-- Conditions -----------------------------------------------------------------

-- Tracked from the REGEN events: InCombatLockdown() isn't true yet while
-- PLAYER_REGEN_DISABLED is being handled. Seeded at login.
local inCombat = false

-- The host's unit state, read once per update and shared by all its displays.
-- None of these are secret (UnitDocumentation.lua has no SecretReturns on
-- them), so Lua can decide and simply leave the display out of the chain.
local state = {}

-- Hosts that only show on a frame: their rows are its children.
local FRAMED = { party = true, partypet = true, raid = true, raidpet = true, nameplate = true }

local function ReadState(host)
  local unit = host.unit
  state.shown = unit ~= nil and UnitExists(unit)
      and not (FRAMED[host.kind] and not (host.frame and host.frame:IsVisible()))
  state.plate = host.kind == "nameplate"
  if state.shown then
    -- Polled, so a duel starting or a mind control is noticed too. Blizzard's
    -- target frame splits friend from enemy the same way (TargetFrame.lua:511).
    state.friendly = UnitIsFriend("player", unit)
    state.dead = UnitIsDeadOrGhost(unit)
    state.offline = not UnitIsConnected(unit)
    state.visible = UnitIsVisible(unit)
    state.unitCombat = UnitAffectingCombat(unit)
    -- The current power, so a druid in cat or bear form reads as energy or
    -- rage. No token for some units in a PvP match (MayReturnNothing).
    state.power = select(2, UnitPowerType(unit))
    state.resting = IsResting()
    state.mounted = IsMounted()
    state.playerDead = UnitIsDeadOrGhost("player")
    -- 0 when solo, which counts as 1. Not in Blizzard_APIDocumentationGenerated,
    -- so no secret tags; Blizzard's raid container loops on it
    -- (Blizzard_CompactRaidFrameContainer.lua:469).
    state.groupSize = math.max(GetNumGroupMembers(), 1)
  end
end

-- Test mode: the game's placeholder auras (the ones Edit Mode shows) fill the
-- containers. That's one global switch with no restrictions
-- (UnitAuraDocumentation.lua), so Blizzard's aura frames fill too and it
-- can't be limited to some containers; untested groups are hidden instead.
-- Test mode runs while the editor's test window is open (ns.SetTestOpen) and at
-- least one group is ticked. Never in combat: UpdateAll ends it when combat
-- starts, or whenever the poll finds combat.
local testOpen, testing = false, false
local testGroups = {} -- group table -> true; kept until /reload
-- Test filters (Chain.SetTestFilters) are container changes, so after testing
-- they stay until Apply can put the real ones back, which waits out combat.
-- Until then the displays they changed are hidden: with no candidate filters
-- they'd show auras they shouldn't.
local restoring = false

function ns.IsTested(group)
  return testGroups[group] == true
end

local UpdateAll

local function SyncTesting()
  for group in pairs(testGroups) do
    if not tContains(ns.groups, group) then
      testGroups[group] = nil -- deleted
    end
  end
  local want = testOpen and next(testGroups) ~= nil and not ns.TestLocked()
  if want ~= testing then
    testing = want
    Chain.SetTestFilters(want)
    restoring = not want
    if want then
      C_UnitAuras.SwitchAuraDataProvider()
    else
      C_UnitAuras.ResetAuraDataProvider()
    end
    ns.Changed(false) -- sends the containers their filters
  end
  UpdateAll()
end

function ns.SetTested(group, on)
  testGroups[group] = on or nil
  SyncTesting()
end

function ns.SetTestOpen(open)
  if open ~= testOpen then
    testOpen = open
    SyncTesting()
  end
end

-- A three-way key: true = only while, false = only while not, nil or "any"
-- (a display overriding its group) = either.
local function Wants(want, actual)
  return want == nil or want == "any" or want == actual
end

-- groupSizeOp compares the group's size with groupSize; nil or "any" (a
-- display overriding its group) = any size.
local function SizeFits(op, size, actual)
  if op == nil or op == "any" or size == nil then
    return true
  end
  if op == "atLeast" then
    return actual >= size
  elseif op == "atMost" then
    return actual <= size
  end
  return actual == size
end

-- d.reaction: "enemy" (anyone not friendly, neutral creatures included),
-- "friendly" or "any". Unset: enemies on nameplates, any unit elsewhere.
local function ReactionFits(d)
  local reaction = d.reaction or (state.plate and "enemy" or "any")
  return reaction == "any" or (reaction == "friendly") == (state.friendly == true)
end
-- What an unset reaction means on a group showing on `target`, for the editor.
function ns.ReactionDefault(target)
  return (target == "nameplate" or type(target) == "table" and tContains(target, "nameplate")) and "enemy" or "any"
end

-- Never load, class and known spells aren't checked here: displays that fail
-- them aren't built (Builds).
local function Shows(d)
  if not state.shown then
    return false
  end
  -- Test mode ignores it: in town most plates are friendly, and a target's
  -- friend and enemy sets both preview.
  if not testing and not ReactionFits(d) then
    return false
  end
  if d.combat == "in" and not inCombat or d.combat == "out" and inCombat then
    return false
  end
  if d.hideWhenDead and state.dead or d.hideWhenOffline and state.offline then
    return false
  end
  if not Wants(d.unitCombat, state.unitCombat) then
    return false
  end
  -- An empty list (a display overriding its group) means any power. A unit
  -- with no power token matches nothing.
  local power = d.unitPower
  if power and #power > 0 and not (state.power and tContains(power, state.power)) then
    return false
  end
  if not Wants(d.resting, state.resting) or not Wants(d.mounted, state.mounted)
      or d.hideWhenPlayerDead and state.playerDead then
    return false
  end
  -- Test mode ignores it, so a set made for big raids can be previewed solo.
  if not testing and not SizeFits(d.groupSizeOp, d.groupSize, state.groupSize) then
    return false
  end
  -- Beyond the visible range, flag tokens and PLAYER match the wrong auras;
  -- spell-ID filters stay correct.
  local notVisible = d.hideWhenNotVisible
  if notVisible == nil or notVisible == "auto" then -- a display saves "auto" to override its group
    notVisible = not Chain.MatchesByID(d)
  end
  if notVisible and not state.visible then
    return false
  end

  return true
end

-- A list display hiding or showing turns its aura group off or on; the line's
-- container closes the gap itself. Only a whole line container or a missing
-- display appearing or disappearing needs a relink. `off`: hide every display
-- (a group left out of test mode).
local function UpdateLine(line, off)
  local changed = false
  local list = line.list
  if list then
    local any = false
    for j, d in ipairs(list.displays) do
      local on = not off and not (restoring and Chain.TestFaked(d, false)) and Shows(d)
      any = any or on
      if on ~= list.on[j] then
        list.on[j] = on
        Chain.SetDisplayActive(list, j, on)
      end
    end
    if any ~= list.active then
      list.active = any
      Chain.SetActive(list, any)
      changed = true
    end
  end
  for _, inst in ipairs(line.missing) do
    local on = not off and not restoring and Shows(inst.display)
    if on ~= inst.active then
      inst.active = on
      Chain.SetActive(inst, on)
      changed = true
    end
  end
  return changed
end

-- relink: true to relink every row even if no display changed (lengths did).
local function UpdateHost(host, relink)
  ReadState(host)
  for _, row in ipairs(host.rows) do
    local changed, showing = relink, false
    local off = testing and not testGroups[row.group] or row.group.anchorTo == "unit" and not host.frame
    for _, line in ipairs(row.lines) do
      changed = UpdateLine(line, off) or changed
      showing = showing or (line.list and line.list.active) or false
      for _, inst in ipairs(line.missing) do
        showing = showing or inst.active
      end
    end
    row.showing = showing
    if changed then
      dirty[row] = true
    end
  end
  if not batching then
    FlushRelinks()
  end
end

-- Runs fn with relinks held back, then relinks each changed strand once.
local function Batch(fn)
  batching = true
  fn()
  batching = false
  FlushRelinks()
end

local function RefreshHost(host)
  for _, row in ipairs(host.rows) do
    for inst in EachInst(row) do
      if inst.active then
        Chain.Refresh(inst)
      end
    end
  end
  UpdateHost(host)
end

function UpdateAll()
  if testOpen and (inCombat or UnitAffectingCombat("player") or C_Secrets.ShouldAurasBeSecret()) then
    testOpen = false
    SyncTesting()
    if ns.OnTestEnded then
      ns.OnTestEnded() -- closes the test window
    end
    return -- SyncTesting ran UpdateAll
  end
  if KnownSpellsChanged() then
    ns.Changed(true) -- builds or drops the displays that depend on them
  end
  if refake then
    refake = false
    if placeholders and not inCombat and not C_Secrets.ShouldAurasBeSecret() then
      C_UnitAuras.SwitchAuraDataProvider() -- containers already switched ignore it
    end
  end
  Batch(function()
    for _, host in ipairs(hosts) do
      UpdateHost(host)
    end
  end)
end

local function UpdateCombatGlows()
  for _, host in ipairs(hosts) do
    for _, row in ipairs(host.rows) do
      for inst in EachInst(row) do
        Chain.UpdateCombatGlows(inst)
      end
    end
  end
end

local function SetHostUnit(host, unit)
  host.unit = unit
  if unit then
    for _, row in ipairs(host.rows) do
      for inst in EachInst(row) do
        Chain.SetUnit(inst, unit)
      end
    end
  end
  WatchRange(host)
  UpdateHost(host)
end

-- Unit frames ----------------------------------------------------------------
-- A host belongs to a unit token (player, party1, raid7, partypet2...). Its
-- rows sit on whatever frame shows that unit, Blizzard's or another addon's
-- (Grid2, ElvUI, VuhDo...), and move when the unit's frame changes. Party and
-- raid hosts show only while their unit has a visible frame.
--
-- Frames come from LibGetFrame. It keeps a list of every visible unit button,
-- made by walking the UI after group, pet and combat events (about a second
-- later), but reads each listed frame's unit when asked. So when Blizzard or
-- Grid2 give a frame a new unit, the hooks below look again at once and ask
-- for a new list, which picks up frames that just appeared.

local LGF = LibStub("LibGetFrame-1.0")

-- The units with a host, by kind. Your own pet is "pet".
local GROUP_UNITS = { party = { "player" }, partypet = { "pet" }, raid = {}, raidpet = {} }
for i = 1, 4 do
  table.insert(GROUP_UNITS.party, "party" .. i)
  table.insert(GROUP_UNITS.partypet, "partypet" .. i)
end
for i = 1, 40 do
  table.insert(GROUP_UNITS.raid, "raid" .. i)
  table.insert(GROUP_UNITS.raidpet, "raidpet" .. i)
end

local singleHosts = {} -- "player" / "target" / "focus" -> host
local unitHosts = {} -- party or raid unit token -> host
local previewHosts = {} -- preview frame -> host (see Previews below)

-- Lookups return every frame found (returnAll). LibGetFrame's defaults leave
-- player, target and focus frames out of group lookups; single lookups leave
-- party and raid frames out.
local GROUP_LOOKUP = { returnAll = true }
local SINGLE_LOOKUP = {
  returnAll = true, ignorePlayerFrame = false, ignoreTargetFrame = false, ignoreFocusFrame = false,
  ignorePartyFrame = true, ignoreRaidFrame = true, ignoreBossFrame = true,
}

-- Frame names, from LibGetFrame's lists (frame addons add theirs there).
-- `accepted[kind]`: a frame must match one to count for that kind; group units
-- take party and raid frames only, so a pet group stays off pet frames like
-- PetFrame that also show "pet". `ranking[kind]`: best first, so a unit shown
-- by two frame addons gets the one ranked first.
local accepted, ranking = {}, {}
local partyPatterns -- party frames, for previews

local function Rank(frame, patterns)
  local name = frame:GetName()
  if name then
    for i, pattern in ipairs(patterns) do
      if name:find(pattern) then
        return i
      end
    end
  end
  return #patterns + 1
end

-- The unit a frame shows, as LibGetFrame reads it (SecureTemplates.lua).
local GetFrameUnit = _G.SecureButton_GetUnit

local function ShowsUnit(frame, unit)
  local shown = frame and GetFrameUnit(frame)
  return shown ~= nil and not issecretvalue(shown) and shown == unit
end

local function Accepts(kind, frame)
  return Rank(frame, accepted[kind]) <= #accepted[kind]
end

-- The frames LibGetFrame lists for `unit` that show exactly that token and
-- are accepted for `kind`. Its lookup also counts a frame showing the same
-- person under another token (a raid frame for "party1"), which would put
-- party rows on raid frames.
local function UnitFrames(kind, unit)
  local found = {}
  local lookup = SINGLE_UNITS[kind] and SINGLE_LOOKUP or GROUP_LOOKUP
  for frame in pairs(LGF.GetUnitFrame(unit, lookup) or {}) do
    if ShowsUnit(frame, unit) and Accepts(kind, frame) then
      table.insert(found, frame)
    end
  end
  return found
end

-- The best frame showing `unit`, or nil.
local function FindUnitFrame(kind, unit)
  if not UnitExists(unit) then
    return nil
  end
  local best, bestRank
  for _, frame in ipairs(UnitFrames(kind, unit)) do
    local rank = Rank(frame, ranking[kind])
    if not best or rank < bestRank then
      best, bestRank = frame, rank
    end
  end
  return best
end

-- Moves a host's rows to `frame`.
local function SetHostFrame(host, frame)
  if host.frame == frame then
    return
  end
  host.frame = frame
  for _, row in ipairs(host.rows) do
    PlaceOrigin(row, host)
  end
  UpdateHost(host, true)
end

-- A frame that's out of LibGetFrame's list (it only lists visible frames:
-- a target frame while you have no target) is kept while it still shows the
-- unit; its rows hide with it.
local function BestFrame(kind, unit, host)
  local frame = FindUnitFrame(kind, unit)
  if not frame and host and ShowsUnit(host.frame, unit) then
    frame = host.frame
  end
  return frame
end

-- Unit hosts are made the first time their unit has a frame, a few per frame
-- within a time budget (QueueHost below): a host builds every group's rows
-- for its kind (each aura group makes 10 buttons up front), and joining a raid
-- finds up to 40 units at once: built together, the game froze.
local function AddUnitHost(unit, kind)
  if not unitHosts[unit] then
    unitHosts[unit] = NewHost(kind, unit, FindUnitFrame(kind, unit))
    UpdateHost(unitHosts[unit])
  end
end

local BUILD_BUDGET_MS = 4
local hostQueue, queued = {}, {} -- queued: key -> kind
local builder = CreateFrame("Frame")
builder:Hide()
builder:SetScript("OnUpdate", function(self)
  local start = debugprofilestop()
  repeat
    local entry = table.remove(hostQueue, 1)
    if queued[entry.key] == entry.kind then
      queued[entry.key] = nil
    end
    entry.add(entry.key, entry.kind)
  until #hostQueue == 0 or debugprofilestop() - start > BUILD_BUDGET_MS
  if #hostQueue == 0 then
    self:Hide()
  end
end)

-- `add(key, kind)` makes the host.
local function QueueHost(key, kind, add)
  if queued[key] ~= kind then
    queued[key] = kind
    table.insert(hostQueue, { key = key, kind = kind, add = add })
    builder:Show()
  end
end

-- Previews: Edit Mode's party and raid frames and Grid2's test mode fill
-- their empty slots with unit "player" (CompactPartyFrame.lua:176, Grid2's
-- SetupTestMode in GridGroupHeaders.lua). While the game shows placeholder
-- auras (Edit Mode or test mode), each such frame gets a host of its own
-- showing the rows of a real member: party rows on party frames, raid rows
-- on the rest. Your own frame keeps its party host.

local function PreviewKind(frame)
  return Rank(frame, partyPatterns) <= #partyPatterns and "party" or "raid"
end

local function AddPreviewHost(frame, kind)
  if placeholders and not previewHosts[frame] then
    previewHosts[frame] = NewHost(kind, "player", frame)
    UpdateHost(previewHosts[frame])
  end
end

local function SyncPreviews()
  local own = unitHosts.player and unitHosts.player.frame
  local wanted = {}
  if placeholders then
    for _, frame in ipairs(UnitFrames("raid", "player")) do
      if frame ~= own then
        wanted[frame] = true
        if not previewHosts[frame] then
          QueueHost(frame, PreviewKind(frame), AddPreviewHost)
        end
      end
    end
  end
  for frame, host in pairs(previewHosts) do
    local unit = wanted[frame] and "player" or nil
    if host.unit ~= unit then
      SetHostUnit(host, unit)
    end
  end
end

-- Gives every host the frame showing its unit now.
local function Rebind()
  Batch(function()
    for kind, host in pairs(singleHosts) do
      SetHostFrame(host, BestFrame(kind, kind, host))
    end
    for kind, units in pairs(GROUP_UNITS) do
      for _, unit in ipairs(units) do
        local host = unitHosts[unit]
        local frame = BestFrame(kind, unit, host)
        if host then
          SetHostFrame(host, frame)
        elseif frame then
          QueueHost(unit, kind, AddUnitHost)
        end
      end
    end
    SyncPreviews()
  end)
end

local built = false
local rebindQueued = false

-- Rebinds on the next frame, once however many requests come in. `scan`:
-- frames may have appeared, so LibGetFrame lists them again (it coalesces
-- requests itself) and its GETFRAME_REFRESH rebinds once more.
local function RequestRebind(scan)
  if not built then
    return
  end
  if scan then
    LGF.ScanForUnitFrames()
  end
  if not rebindQueued then
    rebindQueued = true
    C_Timer.After(0, function()
      rebindQueued = false
      Rebind()
    end)
  end
end

-- Blizzard's party and raid frames, including Edit Mode's previews. The hook
-- also sees nameplate unit frames (forbidden ones in instances allow only
-- IsForbidden), which don't need a scan.
hooksecurefunc("CompactUnitFrame_SetUnit", function(frame)
  if frame:IsForbidden() then
    return
  end
  local name = frame:GetName()
  if name and (name:find("^CompactParty") or name:find("^CompactRaid")) then
    RequestRebind(true)
  end
end)

local function WatchFrames()
  accepted.player = LGF.getDefaultPlayerFrames()
  accepted.target = LGF.getDefaultTargetFrames()
  accepted.focus = LGF.getDefaultFocusFrames()
  -- Its player and target lists match any oUF layout; its focus list doesn't.
  table.insert(accepted.focus, "^oUF_.-Focus$")
  for kind in pairs(SINGLE_UNITS) do
    ranking[kind] = accepted[kind]
  end
  partyPatterns = LGF.getDefaultPartyFrames()
  local groupFrames, order = LGF.getDefaultRaidFrames(), LGF.getDefaultFramePriorities()
  for _, pattern in ipairs(partyPatterns) do
    table.insert(groupFrames, pattern)
  end
  for kind in pairs(GROUP_UNITS) do
    accepted[kind], ranking[kind] = groupFrames, order
  end
  LGF.RegisterCallback(ns, "GETFRAME_REFRESH", function()
    RequestRebind(false)
  end)
  -- Grid2 routes every unit change on its frames through SetFrameUnit
  -- (GridFrame.lua), test mode included.
  local grid2 = _G.Grid2
  if grid2 and grid2.SetFrameUnit then
    hooksecurefunc(grid2, "SetFrameUnit", function()
      RequestRebind(true)
    end)
  end
  -- LibGetFrame starts listing frames on its first lookup.
  LGF.GetUnitFrame("player")
  Rebind()
end

-- Every host on a party or raid frame.
local function EachGroupHost(fn)
  for _, list in ipairs({ unitHosts, previewHosts }) do
    for _, host in pairs(list) do
      fn(host)
    end
  end
end

-- Nameplates -----------------------------------------------------------------
-- The game reuses a small set of nameplate frames for whichever units are
-- nearby. A host is tied to a plate frame the first time it appears and stays
-- there, so its rows are anchored once per plate frame. Every host is built at
-- login, behind the loading screen, so plates appearing later (often several
-- at once on a pull) build nothing: one per nameplate unit token
-- (nameplate1-40), the most plates there can be at once. Idle hosts cost
-- memory but no CPU (a disabled container drops its UNIT_AURA registration).

local MAX_PLATES = 40
local plateHosts = {} -- nameplate frame -> its host
local freeHosts = {}

local function BuildPlateHosts()
  for _ = 1, MAX_PLATES do
    table.insert(freeHosts, NewHost("nameplate"))
  end
end

local function OnPlateAdded(unit)
  -- nil for "forbidden" plates (friendly ones in instances).
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then
    return
  end

  local host = plateHosts[plate]
  if not host then
    host = table.remove(freeHosts)
    if not host then
      return
    end
    plateHosts[plate] = host
    -- Rows follow the plate itself, not Blizzard's UnitFrame inside it:
    -- nameplate addons hide or disable that UnitFrame and draw their own,
    -- but every one keeps the plate, which the engine places over the unit.
    local frame = plate
    host.frame = frame
    for _, row in ipairs(host.rows) do
      PlaceOrigin(row, host)
    end
  end

  SetHostUnit(host, unit)
end

local function OnPlateRemoved(unit)
  for _, host in pairs(plateHosts) do
    if host.unit == unit then
      SetHostUnit(host, nil)
    end
  end
end

-- Rows sit on UIParent and are only anchored to their plate. As children of
-- the plate, they cost every frame even while hidden: in a city full of
-- players, 140 fps dropped to 50 with every nameplate group hidden. The game
-- updates plates every frame (fading and scaling them by distance), and that
-- reaches every descendant. Rows copy the plate's alpha and scale instead,
-- rounded to steps so a fade changes them a few times rather than every
-- frame, and only while they show something.
local FOLLOW_STEP = 0.05

local function Step(value)
  return math.floor(value / FOLLOW_STEP + 0.5) * FOLLOW_STEP
end

local function FollowPlate(plate, host)
  local alpha, scale = plate:GetEffectiveAlpha(), plate:GetEffectiveScale()
  if issecretvalue(alpha) or issecretvalue(scale) then
    return
  end
  alpha, scale = Step(alpha), math.max(Step(scale / UIParent:GetEffectiveScale()), FOLLOW_STEP)
  for _, row in ipairs(host.rows) do
    if row.showing and (row.alpha ~= alpha or row.scale ~= scale) then
      row.alpha, row.scale = alpha, scale
      row.origin:SetAlpha(alpha)
      row.origin:SetScale(scale)
    end
  end
end

CreateFrame("Frame"):SetScript("OnUpdate", function()
  for plate, host in pairs(plateHosts) do
    if host.unit then
      FollowPlate(plate, host)
    end
  end
end)

-- Binds plates that were already up when Build ran: NAME_PLATE_UNIT_ADDED is
-- ignored until then.
local function CatchUpPlates()
  for i = 1, MAX_PLATES do
    local unit = "nameplate" .. i
    if UnitExists(unit) then
      OnPlateAdded(unit)
    end
  end
end

-- Editor changes -------------------------------------------------------------
-- The editor writes straight into ns.groups and calls ns.Changed. Changes are
-- applied together a moment later (a slider drag sends many).

-- Test mode is unavailable in combat and while auras are secret: the switch
-- to placeholder auras is refused then.
function ns.TestLocked()
  return inCombat or C_Secrets.ShouldAurasBeSecret()
end

-- How many retired containers are waiting for a /reload to be freed.
function ns.Leaked()
  return leaked
end

-- Pushes every setting to a host's rows. While auras are secret, buttons
-- can't be restyled (SyncHost rebuilt every changed row instead), so only
-- what's outside them is touched.
local function ConfigureHost(host)
  local secret = C_Secrets.ShouldAurasBeSecret()
  for _, row in ipairs(host.rows) do
    PlaceOrigin(row, host)
    StyleFirstLine(row)
    for _, line in ipairs(row.lines) do
      if line.list then
        Chain.SetCap(line.list, row.g, LineCap(row.group, line))
      end
    end
    if not secret then
      for inst in EachInst(row) do
        Chain.Configure(inst, row.g, row.group.lineSpacing)
      end
      for _, line in ipairs(row.lines) do
        if line.list then
          Chain.SetWrap(line.list, LineWrap(row.group, line))
        end
      end
    end
  end
  UpdateRange(host) -- new rows start out in range
  UpdateHost(host, true)
end

-- While auras are secret every edit rebuilds the changed rows on each host
-- they're on (up to 40 for raid or nameplate groups), so hosts are synced a
-- few per frame within BUILD_BUDGET_MS; at once, the game froze.
local syncQueue, syncQueued = {}, {}
local syncer = CreateFrame("Frame")
syncer:Hide()
syncer:SetScript("OnUpdate", function(self)
  local start = debugprofilestop()
  repeat
    local host = table.remove(syncQueue, 1)
    syncQueued[host] = nil
    Batch(function()
      SyncHost(host)
      ConfigureHost(host)
    end)
  until #syncQueue == 0 or debugprofilestop() - start > BUILD_BUDGET_MS
  if #syncQueue == 0 then
    self:Hide()
    if ns.OnApplied then
      ns.OnApplied()
    end
  end
end)

-- Rebuilds rows whose structure changed, then pushes every setting to the
-- containers that stay.
local function Apply(structural)
  -- Configure below sends every container its real filters again.
  restoring = restoring and testing
  SyncSkins()
  local secret = C_Secrets.ShouldAurasBeSecret()
  if structural or secret or BuildFlags() ~= buildFlags then
    rowConfigs = ComputeRows()
    if secret then
      for _, host in ipairs(hosts) do
        if not syncQueued[host] then
          syncQueued[host] = true
          table.insert(syncQueue, host)
        end
      end
      syncer:Show()
      return
    end
    for _, host in ipairs(hosts) do
      SyncHost(host)
    end
  end

  Batch(function()
    for _, host in ipairs(hosts) do
      ConfigureHost(host)
    end
  end)
  -- Every row now has the current settings, so it takes the current
  -- fingerprint: with a stale one, the next apply while secret would rebuild
  -- rows that didn't change.
  local jsons = {}
  for _, host in ipairs(hosts) do
    for _, row in ipairs(host.rows) do
      local group = row.group
      if jsons[group] == nil then
        jsons[group] = GroupJSON(group) or false
      end
      row.fingerprint = Fingerprint(row.signature, jsons[group] or nil)
    end
  end
end

local applyQueued, structuralPending = false, false

-- structural: the change affects which containers exist (see ComputeRows).
function ns.Changed(structural)
  structuralPending = structuralPending or structural
  if applyQueued then
    return
  end
  applyQueued = true
  C_Timer.After(0.1, function()
    applyQueued = false
    local wasStructural = structuralPending
    structuralPending = false
    Apply(wasStructural)
    if ns.OnApplied then
      ns.OnApplied()
    end
  end)
end

-- Setup ----------------------------------------------------------------------

-- "party1" or "raid7" may now be someone else. Containers don't notice, so
-- refresh them. In a raid GROUP_ROSTER_UPDATE comes in bursts, so wait for it
-- to settle and refresh once. (We can't refresh only the units whose person
-- changed: UnitGUID can be secret, SecretWhenUnitIdentityRestricted.) Frames
-- may show other units now too.
local rosterRefreshQueued = false

local function RefreshGroupHosts()
  rosterRefreshQueued = false
  EachGroupHost(RefreshHost)
  RequestRebind(false)
end

local function Build()
  SyncSkins()
  rowConfigs = ComputeRows()
  for _, kind in ipairs({ "player", "target", "focus" }) do
    singleHosts[kind] = NewHost(kind, kind)
  end

  BuildPlateHosts()
  CatchUpPlates()

  built = true
  WatchFrames()
  UpdateAll()
  -- Polled: some conditions (visible range, mounting, turning hostile) have no event.
  C_Timer.NewTicker(0.25, UpdateAll)
  ns.InitOptions()
end

-- Whether any display's timer or stack text uses font `name`.
local function UsesFont(name)
  for _, group in ipairs(ns.groups) do
    for _, display in ns.Displays(group) do
      if display.timerFont == name or display.stackFont == name then
        return true
      end
    end
  end
  return false
end

-- Media addons can register fonts after we've styled; a saved font name that
-- wasn't there yet then takes effect. Other fonts change nothing.
LibStub("LibSharedMedia-3.0").RegisterCallback(ns, "LibSharedMedia_Registered", function(_, mediaType, name)
  if mediaType == "font" and built and UsesFont(name) then
    Reskin()
  end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("UNIT_PET")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("AURA_DATA_PROVIDER_SWITCH")
events:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
if C_EventUtils.IsEventValid("PLAYER_FOCUS_CHANGED") then
  events:RegisterEvent("PLAYER_FOCUS_CHANGED")
end

events:SetScript("OnEvent", function(_, event, arg, arg2)
  if event == "NAME_PLATE_UNIT_ADDED" then
    if built then
      OnPlateAdded(arg)
    end
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    OnPlateRemoved(arg)
  elseif event == "AURA_DATA_PROVIDER_SWITCH" then
    placeholders = not arg -- arg: useRealDataProvider
    RequestRebind(true) -- previews come or go
  elseif event == "ADDON_LOADED" then
    if arg == addonName then
      LoadSettings()
    end
    -- A frame named in an anchor may have just been created.
    for i = #unresolved, 1, -1 do
      local entry = unresolved[i]
      if entry.row.released or PlaceOrigin(entry.row, entry.host) then
        table.remove(unresolved, i)
      end
    end
  elseif event == "PLAYER_LOGIN" then
    -- On a /reload mid-fight, InCombatLockdown() is still false here, and no
    -- REGEN event follows for a fight already going.
    inCombat = UnitAffectingCombat("player")
    Chain.SetCombat(inCombat)
    Chain.HoldRange(C_Secrets.ShouldAurasBeSecret())
    Build()
  elseif event == "PLAYER_REGEN_DISABLED" then
    inCombat = true
    Chain.SetCombat(true)
    UpdateCombatGlows()
    UpdateAll()
    if ns.OnLockChanged then
      ns.OnLockChanged()
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    inCombat = false
    Chain.SetCombat(false)
    UpdateCombatGlows()
    UpdateAll()
    if ns.OnLockChanged then
      ns.OnLockChanged()
    end
  elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
    -- arg2 Activating: the restriction isn't enforced until this event is
    -- done, the last moment buttons can be changed before auras turn secret.
    -- Range-limited glows go fully visible for the duration (Chain.HoldRange).
    if arg2 == Enum.AddOnRestrictionState.Activating and not C_Secrets.ShouldAurasBeSecret() then
      Chain.HoldRange(true)
      for _, host in ipairs(hosts) do
        UpdateRange(host)
      end
    end
    -- Checked a frame later, once ShouldAurasBeSecret reflects the change.
    -- Test mode's lock follows it too.
    C_Timer.After(0, function()
      if not C_Secrets.ShouldAurasBeSecret() then
        Chain.HoldRange(false)
        for _, host in ipairs(hosts) do
          UpdateRange(host)
        end
        if reskinPending then
          Reskin()
        end
      end
      if ns.OnLockChanged then
        ns.OnLockChanged()
      end
    end)
  elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
    local host = singleHosts[event == "PLAYER_TARGET_CHANGED" and "target" or "focus"]
    if host then
      RefreshHost(host)
      -- Its frame was hidden with no unit, so out of LibGetFrame's list
      -- until it's listed again. Once found it's kept (BestFrame).
      if not host.frame then
        RequestRebind(true)
      end
    end
  elseif event == "GROUP_ROSTER_UPDATE" then
    if not rosterRefreshQueued then
      rosterRefreshQueued = true
      C_Timer.After(0.2, RefreshGroupHosts)
    end
  elseif event == "UNIT_PET" then
    -- "partypet1" or "raidpet7" may now be a different pet.
    EachGroupHost(function(host)
      if host.kind == "partypet" or host.kind == "raidpet" then
        RefreshHost(host)
      end
    end)
  end
end)
