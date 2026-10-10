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
  -- "blizzard" (the countdown's own), "clock", "short" or "long"
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
  nameplateUnits = "enemy",
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

local function Clean(group)
  ns.MoveGroupFilter(group)
  ns.ConvertLineMax(group)
  ns.ConvertNewLine(group)
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

local rowConfigs = {}

local OTHER_COMBAT = { ["in"] = "out", out = "in" }

-- Whether a list display is built as glowing and plain copies (GlowCopies).
local function GlowSplits(d)
  return d.glow and OTHER_COMBAT[d.glowCombat] ~= nil
end

-- Whether any of the group's displays loads: Never load (inherited from the
-- group unless a display overrides it) builds nothing.
local function Loads(group)
  for _, display in ns.Displays(group) do
    if not display.neverLoad then
      return true
    end
  end
  return false
end

-- Which displays use Masque and which groups are built as a priority stack
-- (ns.StackDisplays), as one string. Both change what's built, but the editor
-- sends them as ordinary look changes (a skin, Max icons shown, an icon size),
-- so Apply compares this to catch them.
local buildFlags = ""

local function BuildFlags()
  local flags = {}
  for _, group in ipairs(ns.groups) do
    flags[#flags + 1] = ns.StackDisplays(group) and "s" or "-"
    for _, display in ns.Displays(group) do
      flags[#flags + 1] = display.skin == "masque" and "1" or "0"
    end
  end
  return table.concat(flags)
end

-- Every setting of the group and its displays, or nil if it can't be
-- serialized.
local function GroupJSON(group)
  local ok, json = pcall(C_EncodingUtil.SerializeJSON, group)
  return ok and json or nil
end

-- A row's signature, its group's settings and the skin epoch: while auras are
-- secret a row can't be restyled, only rebuilt, so any change to it means a
-- new row (SyncHost). Without `json`, a table that matches nothing.
local function Fingerprint(signature, json)
  return json and (signature .. "|" .. json .. "|" .. Chain.SkinEpoch()) or {}
end

local function ComputeRows()
  buildFlags = BuildFlags()
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
      for _, display in ipairs(group.displays) do
        if display.mode == "break" then
          broken = started
        elseif not display.neverLoad then
          local newLine = broken and "/" or ""
          started, broken = true, false
          -- Only Masque-style displays' buttons are registered with Masque.
          local masque = display.skin == "masque" and "+masque" or ""
          -- A combat-limited glow builds two aura groups (GlowCopies).
          local split = display.mode ~= "missing" and GlowSplits(display) and "+split" or ""
          table.insert(parts, newLine .. display.mode .. masque .. split)
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

-- Blizzard's own unit frames, for "each unit's own frame" on single units.
-- Party, raid and nameplate hosts carry their frame themselves (host.frame).
local UNIT_FRAMES = { player = "PlayerFrame", target = "TargetFrame", focus = "FocusFrame" }

-- The frame a row is anchored to, and whether it was found. A frame that
-- doesn't exist yet leaves the row on the screen, retried later.
local function AnchorFrame(leader, host)
  if leader.anchorTo == "frame" then
    local frame = FindFrame((leader.anchor or {})[2] or "")
    return frame or UIParent, frame ~= nil
  elseif leader.anchorTo == "unit" then
    if host.frame then
      return host.frame, true
    elseif UNIT_FRAMES[host.kind] then
      local frame = _G[UNIT_FRAMES[host.kind]]
      return frame or UIParent, frame ~= nil
    end
    -- A nameplate host not tied to a plate yet: placed when it is.
  end
  return UIParent, true
end

-- Positions a row's origin from its group's anchor and sets its frame level.
-- Returns false while the frame it names doesn't exist yet.
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
-- displays. `j` is the display's number (ns.Displays). Displays set to Never
-- load are left out: nothing is built for them.
local function SplitLines(group)
  local lines, line, broken, j = {}, nil, false, 0
  for _, d in ipairs(group.displays) do
    if d.mode == "break" then
      broken = line ~= nil
    elseif d.neverLoad then
      j = j + 1
    else
      if not line or broken then
        line, broken = { listDisplays = {}, missingDisplays = {} }, false
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
local SINGLE_UNITS = { player = true, target = true, focus = true }

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
  if #line.missingDisplays > 0 or group.firstLine or not ns.SingleRow(group) then
    return nil
  end
  return line.listDisplays[1].d.wrap
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
      if not display.neverLoad then
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
    for _, entry in ipairs(line.listDisplays) do
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
      local function Fits(inst)
        return (inst.stack == true) == stack and inst.skin == skin and Chain.CanResize(inst, displays)
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
          ("%s line %d"):format(name, i), plate, skin)
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

  -- Everything in the row hangs off this 1px frame. On a unit frame it's a
  -- child of that frame, so it's raised with it (clicking raises a party
  -- frame) and hidden with it. Not on nameplates: see FollowPlate. PlaceOrigin
  -- sets its level, before our children are created: they start one level
  -- above their parent.
  row.origin = CreateFrame("Frame", nil, host.kind ~= "nameplate" and host.frame or UIParent)
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

local function ReadState(host)
  local unit = host.unit
  state.shown = unit ~= nil and UnitExists(unit)
      and not (host.frame and not host.frame:IsVisible())
  state.plate = host.kind == "nameplate"
  if state.shown then
    -- Polled, so a duel starting or a mind control is noticed too.
    state.hostile = UnitCanAttack("player", unit)
    state.dead = UnitIsDeadOrGhost(unit)
    state.offline = not UnitIsConnected(unit)
    state.visible = UnitIsVisible(unit)
    -- The current power, so a druid in cat or bear form reads as energy or
    -- rage. No token for some units in a PvP match (MayReturnNothing).
    state.power = select(2, UnitPowerType(unit))
    state.resting = IsResting()
    state.mounted = IsMounted()
    state.playerDead = UnitIsDeadOrGhost("player")
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

local function Shows(d)
  if not state.shown or not ClassAllowed(d) then
    return false
  end
  -- d.nameplateUnits: "enemy", "friendly" or "all". Test mode shows on any
  -- plate, since in town most plates are friendly.
  if state.plate and not testing and (d.nameplateUnits == "enemy" and not state.hostile
        or d.nameplateUnits == "friendly" and state.hostile) then
    return false
  end
  if d.neverLoad or d.combat == "in" and not inCombat or d.combat == "out" and inCombat then
    return false
  end
  if d.hideWhenDead and state.dead or d.hideWhenOffline and state.offline then
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
  -- Not secret (SpellBookDocumentation.lua has no SecretReturns on it).
  -- One ID or a list; a negative ID is one that must not be known. Of the
  -- positive IDs, at least one must be known.
  local spell = d.knownSpell
  if spell then
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
    if wanted and not known then
      return false
    end
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
    local off = testing and not testGroups[row.group]
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

-- Party and raid -------------------------------------------------------------
-- One host per Blizzard compact party or raid frame, members and pets. When
-- Blizzard gives the frame a new unit, the host's containers follow. In a raid Blizzard hides
-- the party frame (ShouldShowPartyFrames, GroupFrameVisibility.lua), so
-- party-only displays hide there.

local partyHosts = {} -- party or party pet unit frame -> its host
local raidHosts = {} -- raid or raid pet unit frame -> its host

-- Raid frames are created on demand, in two layouts (Blizzard_CompactRaidFrames):
--   grouped:   CompactRaidGroup1Member1 .. CompactRaidGroup8Member5
--   flat list: CompactRaidFrame1, 2, ... These also show pets and main tank
--              targets; frameType tells them apart. Pets are flat in both
--              layouts (AddPets). Each frameType has its own frame pool
--              (frameReservations), so a frame keeps its kind. "raidFake"
--              frames are Edit Mode's raid preview (unit "player" or a party
--              member), so raid groups can be previewed there.
local FLAT_KINDS = { raid = "raid", flagged = "raid", raidFake = "raid", pet = "raidpet" }

-- "raid", "raidpet", or nil for anything else. The CompactUnitFrame_SetUnit
-- hook also sees forbidden nameplate frames (friendly plates in instances);
-- IsForbidden is the one method they allow.
local function RaidFrameKind(frame)
  if frame:IsForbidden() then
    return nil
  end
  local name = frame:GetName()
  if not name then
    return nil
  end
  if name:match("^CompactRaidGroup%d+Member%d+$") then
    return "raid"
  end
  if name:match("^CompactRaidFrame%d+$") then
    return FLAT_KINDS[frame.frameType]
  end
end

local function AddRaidHost(frame, kind)
  if not raidHosts[frame] then
    raidHosts[frame] = NewHost(kind, frame.unit, frame)
    UpdateHost(raidHosts[frame])
  end
end

-- Raid frames seen for the first time wait here and get their hosts a few per
-- frame, within a time budget. A host builds every raid group's rows (each aura
-- group makes 10 buttons up front), and joining a raid or opening Edit Mode's
-- raid preview hands out up to 40 frames at once: built together, the game
-- froze.
local BUILD_BUDGET_MS = 4
local raidQueue, queued = {}, {}
local builder = CreateFrame("Frame")
builder:Hide()
builder:SetScript("OnUpdate", function(self)
  local start = debugprofilestop()
  repeat
    local entry = table.remove(raidQueue, 1)
    queued[entry.frame] = nil
    AddRaidHost(entry.frame, entry.kind)
  until #raidQueue == 0 or debugprofilestop() - start > BUILD_BUDGET_MS
  if #raidQueue == 0 then
    self:Hide()
  end
end)

local function QueueRaidHost(frame, kind)
  if not queued[frame] and not raidHosts[frame] then
    queued[frame] = true
    table.insert(raidQueue, { frame = frame, kind = kind })
    builder:Show()
  end
end

-- Raid frames that already exist, e.g. after a /reload in a raid.
local function ScanRaidFrames()
  for group = 1, 8 do
    for member = 1, 5 do
      local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
      if frame and frame.unit then
        AddRaidHost(frame, "raid")
      end
    end
  end
  local i = 1
  while _G["CompactRaidFrame" .. i] do
    local frame = _G["CompactRaidFrame" .. i]
    local kind = frame.unit and RaidFrameKind(frame)
    if kind then
      AddRaidHost(frame, kind)
    end
    i = i + 1
  end
end

local built = false

hooksecurefunc("CompactUnitFrame_SetUnit", function(frame, unit)
  local host = partyHosts[frame] or raidHosts[frame]
  if host then
    SetHostUnit(host, unit)
  elseif built and unit then
    local kind = RaidFrameKind(frame)
    if kind then
      QueueRaidHost(frame, kind)
    end
  end
end)

local function BuildParty()
  if next(partyHosts) or not CompactPartyFrame then
    return
  end
  for _, frame in ipairs(CompactPartyFrame.memberUnitFrames) do
    partyHosts[frame] = NewHost("party", frame.unit, frame)
  end
  -- Pet1-5 under the members (CompactPartyFrame.xml); no unit while pets are hidden.
  for _, frame in ipairs(CompactPartyFrame.petUnitFrames) do
    partyHosts[frame] = NewHost("partypet", frame.unit, frame)
  end
  UpdateAll()
end

-- Nameplates -----------------------------------------------------------------
-- The game reuses a small set of nameplate frames for whichever units are
-- nearby. A host is tied to a plate frame the first time it appears and stays
-- there, so its rows are anchored once per plate frame. Plates often
-- appear in combat, when containers can't be built, so every host is built at
-- login: one per nameplate unit token (nameplate1-40), the most plates there
-- can be at once. Idle hosts cost memory but no CPU (a disabled container
-- drops its UNIT_AURA registration).

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

-- Binds plates that were already up before we were built. Only matters when
-- building had to wait for auras to stop being secret: on a combat /reload
-- they aren't secret yet at login, so we build first and plates come after.
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

local singleHosts = {} -- "target" / "focus" -> host

-- "party1" or "raid7" may now be someone else. Containers don't notice, so
-- refresh them. In a raid GROUP_ROSTER_UPDATE comes in bursts, so wait for it
-- to settle and refresh once. (We can't refresh only the frames whose person
-- changed: UnitGUID can be secret, SecretWhenUnitIdentityRestricted.)
local rosterRefreshQueued = false

local function RefreshGroupHosts()
  rosterRefreshQueued = false
  for _, host in pairs(partyHosts) do
    RefreshHost(host)
  end
  for _, host in pairs(raidHosts) do
    RefreshHost(host)
  end
end

local function Build()
  SyncSkins()
  rowConfigs = ComputeRows()
  NewHost("player", "player")
  singleHosts.target = NewHost("target", "target")
  singleHosts.focus = NewHost("focus", "focus")

  -- Blizzard creates the party frames on demand, maybe after us.
  BuildParty()
  if CompactPartyFrame_Generate then
    hooksecurefunc("CompactPartyFrame_Generate", function()
      BuildParty()
    end)
  end
  -- Raid frames get theirs as Blizzard hands them units (the hook above).
  ScanRaidFrames()

  BuildPlateHosts()
  CatchUpPlates()

  UpdateAll()
  -- Polled: some conditions (visible range, mounting, turning hostile) have no event.
  C_Timer.NewTicker(0.25, UpdateAll)
  built = true
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
  elseif event == "PLAYER_TARGET_CHANGED" then
    if singleHosts.target then
      RefreshHost(singleHosts.target)
    end
  elseif event == "PLAYER_FOCUS_CHANGED" then
    if singleHosts.focus then
      RefreshHost(singleHosts.focus)
    end
  elseif event == "GROUP_ROSTER_UPDATE" then
    if not rosterRefreshQueued then
      rosterRefreshQueued = true
      C_Timer.After(0.2, RefreshGroupHosts)
    end
  elseif event == "UNIT_PET" then
    -- "partypet1" or "raidpet7" may now be a different pet.
    for _, list in ipairs({ partyHosts, raidHosts }) do
      for _, host in pairs(list) do
        if host.kind == "partypet" or host.kind == "raidpet" then
          RefreshHost(host)
        end
      end
    end
  end
end)
