-- SlopAuras: rows of aura displays, built on Blizzard AuraContainers.
-- Chain.lua does the container work, Options.lua is the editor. This file
-- decides which displays exist (groups, inheritance, units) and which are
-- showing (conditions), and applies the editor's changes.
--
-- A "host" is one unit's place on screen: the player, the target, the focus,
-- one party or raid frame, or one nameplate. Every host gets its own copy of
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

-- Display modes this version draws. A display saved with any other mode is
-- dropped: SplitLines would otherwise draw it as an aura list.
local MODES = { list = true, missing = true }
-- Keys nothing reads any more. Export writes every raw key and import rejects
-- unknown ones, so they're dropped too.
local RETIRED_KEYS = { "locHide", "labelSize" }

local function Clean(group)
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

local TARGETS = { player = true, target = true, focus = true, party = true, raid = true, nameplate = true }
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

-- Which displays use Masque, as one string. Switching a display to or from
-- "masque" changes its row's signature, but the editor sends that as an
-- ordinary look change, so Apply compares this to catch it.
local masqueFlags = ""

local function MasqueFlags()
  local flags = {}
  for _, group in ipairs(ns.groups) do
    for _, display in ipairs(group.displays) do
      flags[#flags + 1] = display.skin == "masque" and "1" or "0"
    end
  end
  return table.concat(flags)
end

local function ComputeRows()
  masqueFlags = MasqueFlags()
  local rows = {}
  for _, group in ipairs(ns.groups) do
    local targets = TargetSet(group.target)
    if not ClassAllowed(group) or #group.displays == 0 then
      -- not loaded on this character
    elseif not targets then
      Warn(("group %s: unknown target in %s"):format(tostring(group.name), tostring(group.target)))
    elseif not Chain.GROWTHS[group.growth] then
      Warn(("group %s: unknown growth %q"):format(tostring(group.name), tostring(group.growth)))
    else
      -- Which group, growing which way, and each display's mode and line.
      -- Display identity is left out: reordering displays of the same mode
      -- keeps the row and rebinds it (RebindRow). The group's identity is its
      -- table (tostring gives its address).
      local lines = Chain.Lines(group.growth, group.lines)
      local parts = { tostring(group), group.growth, lines, group.lineMax and "capped" or "" }
      for j, display in ipairs(group.displays) do
        local newLine = j > 1 and display.newLine and "/" or ""
        -- Only Masque-style displays' buttons are registered with Masque.
        local masque = display.skin == "masque" and "+masque" or ""
        table.insert(parts, newLine .. display.mode .. masque)
      end
      table.insert(rows, {
        group = group, targets = targets, lines = lines, signature = table.concat(parts, "|"),
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

-- Positions a row's origin from its group's anchor. Returns false while the
-- frame it names doesn't exist yet.
local function PlaceOrigin(row, host)
  local anchor = row.group.anchor or {}
  local point = anchor[1] or "CENTER"
  local relativeTo, found = AnchorFrame(row.group, host)

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

-- Splits a group's displays into lines: a display with newLine starts the
-- next one. Missing-icon displays have their own frames and sit after the
-- line's list displays.
local function SplitLines(group)
  local lines, line = {}, nil
  for j, d in ipairs(group.displays) do
    if not line or (j > 1 and d.newLine) then
      line = { listDisplays = {}, missingDisplays = {} }
      table.insert(lines, line)
    end
    table.insert(d.mode == "missing" and line.missingDisplays or line.listDisplays, { d = d, j = j })
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
-- does a capped group.
local function LineWrap(group, line)
  if #line.missingDisplays > 0 or group.lineMax or not ns.SingleRow(group) then
    return nil
  end
  return line.listDisplays[1].d.wrap
end

-- Masque ---------------------------------------------------------------------
-- One Masque group per SlopAuras group that has Masque-style displays, keyed
-- by group id, so each group can have its own skin in Masque's options.
local Masque = LibStub("Masque", true)
local skins, skinNames = {}, {} -- group id -> Masque group, name it was given

local function UsesMasque(group)
  for _, display in ipairs(group.displays) do
    if display.skin == "masque" then
      return true
    end
  end
  return false
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
        -- A skin or option change in Masque restyles every button.
        skins[id]:RegisterCallback(function()
          Chain.Reskinned()
          ns.Changed(false)
        end)
      elseif skinNames[id] ~= name then
        skins[id]:SetName(name)
      end
      skinNames[id] = name
    end
  end
  for id, skin in pairs(skins) do
    if not live[id] then
      skin:Delete()
      skins[id], skinNames[id] = nil, nil
    end
  end
end

local function BuildRow(config, host)
  local group = config.group
  local row = { group = group, g = Chain.Layout(group.growth, config.lines), signature = config.signature }

  -- Everything in the row hangs off this 1px frame. On a unit frame it's a
  -- child of that frame, so it's raised with it (clicking raises a party
  -- frame) and hidden with it. The extra levels put it above the frame's own
  -- health bar and borders. Set before creating our children, which start one
  -- level above their parent.
  row.origin = CreateFrame("Frame", nil, host.frame or UIParent)
  row.origin:SetSize(1, 1)
  if host.frame then
    row.origin:SetFrameLevel(host.frame:GetFrameLevel() + 10)
  end
  if not PlaceOrigin(row, host) then
    table.insert(unresolved, { row = row, host = host })
  end

  local unit, name = host.unit or "player", group.name or "Group"
  local skin = skins[tostring(group.id)]
  row.lines = SplitLines(group)
  for i, line in ipairs(row.lines) do
    -- Later lines start at their own 1px origin, anchored by Relink. It may be
    -- anchored to a container, hence the template.
    if i == 1 then
      line.origin = row.origin
    else
      line.origin = CreateFrame("Frame", nil, row.origin, "DisableUntrustedLayoutScriptsTemplate")
      line.origin:SetSize(1, 1)
    end
    if #line.listDisplays > 0 then
      local displays = {}
      for k, entry in ipairs(line.listDisplays) do
        displays[k] = entry.d
      end
      line.list = Chain.NewList(row.origin, unit, displays, row.g, group.lineSpacing, ("%s line %d"):format(name, i),
        group.lineMax, host.kind == "nameplate", skin)
      Chain.SetWrap(line.list, LineWrap(group, line))
    end
    line.missing = {}
    for _, entry in ipairs(line.missingDisplays) do
      local label = ("%s %d"):format(name, entry.j)
      table.insert(line.missing,
        Chain.NewMissing(row.origin, unit, entry.d, row.g, group.lineSpacing, label, host.kind == "nameplate", skin))
    end
  end

  return row
end

local function ReleaseRow(row)
  for inst in EachInst(row) do
    leaked = leaked + Chain.Release(inst)
  end
  row.origin:Hide()
  row.released = true
end

-- Hosts in the order a joined row runs through them: you, target, focus,
-- party, raid, nameplates; within a kind, in the order they were made.
local KIND_ORDER = { player = 1, target = 2, focus = 3, party = 4, raid = 5, nameplate = 6 }
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

-- A kept row's displays may have been reordered: same modes and lines, other
-- tables. Points its lines and containers at the current ones.
local function RebindRow(row)
  for i, fresh in ipairs(SplitLines(row.group)) do
    local line = row.lines[i]
    line.listDisplays, line.missingDisplays = fresh.listDisplays, fresh.missingDisplays
    if line.list then
      local displays = {}
      for k, entry in ipairs(fresh.listDisplays) do
        displays[k] = entry.d
      end
      Chain.SetDisplays(line.list, displays)
    end
    for k, entry in ipairs(fresh.missingDisplays) do
      Chain.SetDisplays(line.missing[k], { entry.d })
    end
  end
end

-- Brings a host's rows in line with rowConfigs: keeps rows whose signature
-- is unchanged, builds new ones, retires the rest.
local function SyncHost(host)
  local old, rows, bySignature = host.rowsBySignature or {}, {}, {}
  for _, config in ipairs(rowConfigs) do
    if config.targets[host.kind] then
      local row = old[config.signature]
      if row then
        old[config.signature] = nil
        row.group = config.group
        RebindRow(row)
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
  if kind == "party" or kind == "raid" then
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
    state.resting = IsResting()
    state.mounted = IsMounted()
    state.playerDead = UnitIsDeadOrGhost("player")
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
  -- d.nameplateUnits: "enemy", "friendly" or "all".
  if state.plate and (d.nameplateUnits == "enemy" and not state.hostile
        or d.nameplateUnits == "friendly" and state.hostile) then
    return false
  end
  if d.neverLoad or d.combat == "in" and not inCombat or d.combat == "out" and inCombat then
    return false
  end
  if d.hideWhenDead and state.dead or d.hideWhenOffline and state.offline then
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
-- display appearing or disappearing needs a relink.
local function UpdateLine(line)
  local changed = false
  local list = line.list
  if list then
    local any = false
    for j, d in ipairs(list.displays) do
      local on = Shows(d)
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
    local on = Shows(inst.display)
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
    local changed = relink
    for _, line in ipairs(row.lines) do
      changed = UpdateLine(line) or changed
    end
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

local function UpdateAll()
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

-- Building waits for auras to stop being secret ------------------------------

local pending = {} -- functions waiting for auras to stop being secret

-- Containers refuse to be configured while auras are secret.
local function WhenSafe(fn)
  if C_Secrets.ShouldAurasBeSecret() then
    table.insert(pending, fn)
  else
    fn()
  end
end

-- Party and raid -------------------------------------------------------------
-- One host per Blizzard compact party or raid frame. When Blizzard gives the
-- frame a new unit, the host's containers follow. In a raid Blizzard hides
-- the party frame (ShouldShowPartyFrames, GroupFrameVisibility.lua), so
-- party-only displays hide there.

local partyHosts = {} -- party unit frame -> its host
local raidHosts = {} -- raid unit frame -> its host

-- Raid frames are created on demand, in two layouts (Blizzard_CompactRaidFrames):
--   grouped:   CompactRaidGroup1Member1 .. CompactRaidGroup8Member5
--   flat list: CompactRaidFrame1, 2, ... These also show pets and main tank
--              targets; frameType tells them apart.
local function IsRaidFrame(frame)
  local name = frame:GetName()
  if not name then
    return false
  end
  if name:match("^CompactRaidGroup%d+Member%d+$") then
    return true
  end
  return name:match("^CompactRaidFrame%d+$") ~= nil
      and (frame.frameType == "raid" or frame.frameType == "flagged")
end

local function AddRaidHost(frame)
  if not raidHosts[frame] then
    raidHosts[frame] = NewHost("raid", frame.unit, frame)
    UpdateHost(raidHosts[frame])
  end
end

-- Raid frames that already exist, e.g. after a /reload in a raid.
local function ScanRaidFrames()
  for group = 1, 8 do
    for member = 1, 5 do
      local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
      if frame and frame.unit then
        AddRaidHost(frame)
      end
    end
  end
  local i = 1
  while _G["CompactRaidFrame" .. i] do
    local frame = _G["CompactRaidFrame" .. i]
    if frame.unit and IsRaidFrame(frame) then
      AddRaidHost(frame)
    end
    i = i + 1
  end
end

local built = false

hooksecurefunc("CompactUnitFrame_SetUnit", function(frame, unit)
  local host = partyHosts[frame] or raidHosts[frame]
  if host then
    SetHostUnit(host, unit)
  elseif built and unit and IsRaidFrame(frame) then
    -- A raid frame we haven't seen. Blizzard only creates them out of
    -- combat, but give it its host once that's safe either way.
    WhenSafe(function()
      AddRaidHost(frame)
    end)
  end
end)

local function BuildParty()
  if next(partyHosts) or not CompactPartyFrame then
    return
  end
  for _, frame in ipairs(CompactPartyFrame.memberUnitFrames) do
    partyHosts[frame] = NewHost("party", frame.unit, frame)
  end
  UpdateAll()
end

-- Nameplates -----------------------------------------------------------------
-- The game reuses a small set of nameplate frames for whichever units are
-- nearby. A host is tied to a plate frame the first time it appears and stays
-- there: re-parenting makes every button under it lay out again. Plates often
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
    -- Rows live on the plate itself, not Blizzard's UnitFrame inside it:
    -- nameplate addons hide or disable that UnitFrame and draw their own,
    -- but every one keeps the plate, which the engine places over the unit.
    local frame = plate
    host.frame = frame
    for _, row in ipairs(host.rows) do
      row.origin:SetParent(frame)
      row.origin:SetFrameLevel(frame:GetFrameLevel() + 10)
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
-- applied together a moment later (a slider drag sends many), out of combat.

-- The editor is locked while auras are secret: containers refuse changes then.
function ns.Locked()
  return inCombat or C_Secrets.ShouldAurasBeSecret()
end

-- How many retired containers are waiting for a /reload to be freed.
function ns.Leaked()
  return leaked
end

-- Rebuilds rows whose structure changed, then pushes every setting to the
-- containers that stay.
local function Apply(structural)
  SyncSkins()
  if structural or MasqueFlags() ~= masqueFlags then
    rowConfigs = ComputeRows()
    for _, host in ipairs(hosts) do
      SyncHost(host)
    end
  end

  Batch(function()
    for _, host in ipairs(hosts) do
      for _, row in ipairs(host.rows) do
        PlaceOrigin(row, host)
        for inst in EachInst(row) do
          Chain.Configure(inst, row.g, row.group.lineSpacing, row.group.lineMax)
        end
        for _, line in ipairs(row.lines) do
          if line.list then
            Chain.SetWrap(line.list, LineWrap(row.group, line))
          end
        end
      end
      UpdateRange(host) -- new rows start out in range
      UpdateHost(host, true)
    end
  end)
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
    WhenSafe(function()
      applyQueued = false
      local wasStructural = structuralPending
      structuralPending = false
      Apply(wasStructural)
      if ns.OnApplied then
        ns.OnApplied()
      end
    end)
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
      WhenSafe(BuildParty)
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

-- Media addons can register fonts after we've styled; a saved font name that
-- wasn't there yet then takes effect.
LibStub("LibSharedMedia-3.0").RegisterCallback(ns, "LibSharedMedia_Registered", function(_, mediaType)
  if mediaType == "font" and built then
    Chain.Reskinned()
    ns.Changed(false)
  end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
if C_EventUtils.IsEventValid("PLAYER_FOCUS_CHANGED") then
  events:RegisterEvent("PLAYER_FOCUS_CHANGED")
end

events:SetScript("OnEvent", function(_, event, arg)
  if event == "NAME_PLATE_UNIT_ADDED" then
    if built then
      OnPlateAdded(arg)
    end
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    OnPlateRemoved(arg)
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
    WhenSafe(Build)
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
    local queue = pending
    pending = {}
    for _, fn in ipairs(queue) do
      fn()
    end
    UpdateAll()
    if ns.OnLockChanged then
      ns.OnLockChanged()
    end
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
  end
end)
