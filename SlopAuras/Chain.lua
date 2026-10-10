-- Chain: builds a group's lines out of AuraContainers and links them.
--
-- A line is one AuraContainer holding one aura group per display on that
-- line. The container's flow layout lines the displays up, gives each its own
-- icon size and collapses empty ones; the container sizes itself to what it
-- shows (1px when empty). Missing-icon displays can't be laid out by the game
-- (it only places buttons for auras that exist), so each is its own set of
-- frames chained after the line (NewMissing). Lines stack along the cross axis. Aura counts
-- are secret; the layout carries them, Lua never reads them.

local addonName, ns = ...

local Chain = {}
ns.Chain = Chain

local Flow = AnchorUtil.FlowDirection
local Axis = AnchorUtil.FlowLayoutAxis

Chain.GROWTHS = { RIGHT = true, LEFT = true, DOWN = true, UP = true, CENTER = true, CENTER_VERTICAL = true }

local function Vertical(growth)
  return growth == "DOWN" or growth == "UP" or growth == "CENTER_VERTICAL"
end
Chain.Vertical = Vertical

-- Which way new lines go: across the growth. A value that doesn't fit the
-- growth (the growth changed since) falls back to down, or right.
function Chain.Lines(growth, lines)
  if Vertical(growth) then
    return (lines == "LEFT" or lines == "RIGHT") and lines or "RIGHT"
  end
  return (lines == "UP" or lines == "DOWN") and lines or "DOWN"
end

-- Geometry for a line growing `growth` while new lines go `lines`:
--   start, far: the corners at the line's start and end, on its baseline (the
--               edge facing away from new lines, where smaller icons sit)
--   attach:     the corner of a line's first container where the next line starts
--   dx, dy:     one step along the line; cx, cy: one step toward new lines
--   axis, h, v: the container's flow layout
--   shadow:     centered lines only, the same geometry growing back (left, or
--               up for CENTER_VERTICAL, which otherwise grows down). Lua can't
--               halve a secret width, so half-size "shadow" containers measure
--               half the line, and the visible line starts where they end.
local layouts = {}

function Chain.Layout(growth, lines)
  local key = growth .. "/" .. lines
  if layouts[key] then
    return layouts[key]
  end
  local g
  if Vertical(growth) then
    local base = lines == "LEFT" and "RIGHT" or "LEFT"
    local away = base == "LEFT" and "RIGHT" or "LEFT"
    local first, last = "TOP", "BOTTOM"
    if growth == "UP" then
      first, last = last, first
    end
    g = {
      start = first .. base, far = last .. base, attach = first .. away,
      dx = 0, dy = growth == "UP" and 1 or -1, cx = lines == "LEFT" and -1 or 1, cy = 0,
      axis = Axis.Vertical, h = lines == "LEFT" and Flow.Left or Flow.Right,
      v = growth == "UP" and Flow.Up or Flow.Down,
    }
    if growth == "CENTER_VERTICAL" then
      g.shadow = Chain.Layout("UP", lines)
    end
  else
    local base = lines == "UP" and "BOTTOM" or "TOP"
    local away = base == "BOTTOM" and "TOP" or "BOTTOM"
    local first, last = "LEFT", "RIGHT"
    if growth == "LEFT" then
      first, last = last, first
    end
    g = {
      start = base .. first, far = base .. last, attach = away .. first,
      dx = growth == "LEFT" and -1 or 1, dy = 0, cx = 0, cy = lines == "UP" and 1 or -1,
      axis = Axis.Horizontal, h = growth == "LEFT" and Flow.Left or Flow.Right,
      v = lines == "UP" and Flow.Up or Flow.Down,
    }
    if growth == "CENTER" then
      g.shadow = Chain.Layout("LEFT", lines)
    end
  end
  layouts[key] = g
  return g
end

-- A display's spell ID sets map an ID to true (match it) or false (hide it).
-- Returns the IDs to include and the IDs to exclude, each nil when empty: the
-- exact list plus every rank of each ID in the all-ranks list (Ranks.lua; IDs
-- it doesn't know stay exact).
function Chain.SpellIDs(d)
  local include, exclude = {}, {}
  for id, on in pairs(d.spellIDs or {}) do
    (on and include or exclude)[id] = true
  end
  for id, on in pairs(d.rankSpellIDs or {}) do
    for _, rank in ipairs(ns.SpellRanks(id) or { id }) do
      (on and include or exclude)[rank] = true
    end
  end
  return next(include) and include or nil, next(exclude) and exclude or nil
end

-- Whether the display matches by spell ID (has IDs to include), not by
-- filter alone.
function Chain.MatchesByID(d)
  for _, set in ipairs({ d.spellIDs or {}, d.rankSpellIDs or {} }) do
    for _, on in pairs(set) do
      if on then
        return true
      end
    end
  end
  return false
end

-- The named dispel types (DEBUFF_DISPLAY_INFO in AuraUtil.lua). Typeless auras
-- have dispelName nil, which can't be a key in the candidate filter maps.
Chain.DISPEL_TYPES = { "Magic", "Curse", "Disease", "Poison", "Bleed" }

-- d.dispelTypes lists the ticked types, "None" for typeless. Without "None" it
-- becomes an include map; with it, an exclude map of the unticked named types,
-- which lets typeless auras through.
local function DispelFilter(d, filters)
  local ticked = {}
  for _, name in ipairs(d.dispelTypes or {}) do
    ticked[name] = true
  end
  if not next(ticked) then
    return
  end
  local map = {}
  for _, name in ipairs(Chain.DISPEL_TYPES) do
    if (ticked[name] == true) ~= (ticked.None == true) then
      map[name] = true
    end
  end
  if ticked.None then
    if next(map) then
      filters.excludeDispelTypes = map
    end
  else
    filters.includeDispelTypes = map
  end
end

-- "id:on,id:on" in ID order, so equal sets give equal strings.
local function SetText(set)
  local ids = {}
  for id in pairs(set or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for i, id in ipairs(ids) do
    ids[i] = id .. ":" .. tostring(set[id])
  end
  return table.concat(ids, ",")
end

-- Per display: the inputs Candidates last saw and its result. Every host
-- builds the same filters from the same display, and an unchanged display
-- hands back the same table, which Reconfigure uses to skip the setter.
local candidateCache = setmetatable({}, { __mode = "k" })

local function Candidates(d)
  local inputs = SetText(d.spellIDs) .. "/" .. SetText(d.rankSpellIDs) .. "/" .. table.concat(d.dispelTypes or {}, ",")
      .. "/" .. tostring(d.maxDuration)
  local cached = candidateCache[d]
  if cached and cached.inputs == inputs then
    return cached.filters
  end
  local filters = {}
  -- excludeSpellIDs is checked first, and like includeSpellIDs only where
  -- the game allows spell ID filters (CanApplyIdentityCandidateFilters in
  -- Blizzard_AuraContainerUtil.lua); elsewhere the exclusion is skipped.
  filters.includeSpellIDs, filters.excludeSpellIDs = Chain.SpellIDs(d)
  DispelFilter(d, filters)
  -- Compared with the aura's full duration, not the time left, on any unit
  -- (outside the spell ID gate). Any value also drops auras with no duration.
  filters.maxDuration = d.maxDuration
  filters = next(filters) and filters or nil
  candidateCache[d] = { inputs = inputs, filters = filters }
  return filters
end

-- Test mode (SlopAuras.lua) shows the game's placeholder auras
-- (EditModeAuraDataProvider.lua): no dispel type, spell ID or duration, so
-- candidate filters would leave most displays empty. While testing, list
-- displays get none, and a missing display's containers get one nothing
-- passes, so its icon shows: any maxDuration drops auras without a duration
-- (DoesAuraPassCandidateFilters, Blizzard_AuraContainerUtil.lua).
local testFilters = false
local NOTHING_PASSES = { maxDuration = 1 }

function Chain.SetTestFilters(on)
  testFilters = on
end

-- Whether `d`'s containers get other candidate filters while testing.
-- `missing`: a missing display's.
function Chain.TestFaked(d, missing)
  return missing or Candidates(d) ~= nil
end

local function GroupCandidates(d, missing)
  if not testFilters then
    return Candidates(d)
  end
  return missing and NOTHING_PASSES or nil
end

-- Blizzard refuses some anchors to aura containers. Report them instead of erroring.
function Chain.Anchor(frame, point, relativeTo, relativePoint, x, y)
  local ok, err = pcall(frame.SetPoint, frame, point, relativeTo, relativePoint, x or 0, y or 0)
  if not ok then
    print(addonName .. ": anchor refused: " .. tostring(err))
  end
end
local Anchor = Chain.Anchor

-- A slot's width and height: `length` along the line, `cross` across it.
local function Slot(g, length, cross)
  if g.dx ~= 0 then
    return length, cross
  end
  return cross, length
end

-- For containers that are only there for their size: their buttons draw nothing.
local function MeasureOnly(width, height)
  return function(button)
    button:SetSize(width, height)
    button:SetAlpha(0)
    button:EnableMouse(false)
  end
end

-- Masque ---------------------------------------------------------------------
-- Displays with d.skin "masque" are skinned by their group's Masque
-- group (`inst.skin`). Only their buttons are registered with Masque, so a
-- switch to or from "masque" rebuilds the line (it's in the row signature).
-- Masque sizes a skin's art from a 36px button (SkinRoot.Size); the sizes
-- here follow that rule.
local Masque = LibStub("Masque", true)
local SKIN_BASE = 36

local function UsesMasque(inst, d)
  return inst.skin ~= nil and d.skin == "masque"
end

-- How display `d` of `inst` is skinned, or nil when it isn't skinned or its
-- Masque group is disabled: { data = the skin's table, scale = the group's
-- Scale option }. The group's skin and scale have no public getter, hence db.
local function SkinData(inst, d)
  if not UsesMasque(inst, d) or inst.skin.db.Disabled then
    return nil
  end
  local db = inst.skin.db
  return {
    data = Masque:GetSkin(db.SkinID) or select(2, Masque:GetDefaultSkin()),
    scale = type(db.Scale) == "number" and db.Scale or 1,
  }
end

-- A layer's entry for aura buttons: Masque prefers a skin's per-type entry
-- (GetTypeSkin).
local function SkinLayer(skin, layer)
  local entry = skin.data[layer]
  if type(entry) == "table" and type(entry.Aura) == "table" then
    return entry.Aura
  end
  return type(entry) == "table" and entry or nil
end

-- How many pixels Masque makes `layer` for a `size` icon: its skin width on a
-- 36px button, scaled to the icon and by the group's Scale (GetScaleSize).
local function SkinSize(skin, layer, size)
  local entry = SkinLayer(skin, layer)
  return (entry and entry.Width or SKIN_BASE) * size / SKIN_BASE * skin.scale
end

-- How far a skin's art reaches past each edge of a `size` icon, never less
-- than 0. The icon itself counts: Scale enlarges it too.
local function SkinReach(skin, size)
  local width = size
  for _, layer in ipairs({ "Icon", "Normal", "Border", "Shadow", "Gloss" }) do
    width = math.max(width, SkinSize(skin, layer, size))
  end
  return math.ceil((width - size) / 2)
end

-- The icon's tex coords in the skin (left, right, top, bottom), or nil for
-- the whole texture.
local function SkinCrop(skin)
  local icon = SkinLayer(skin, "Icon")
  local coords = icon and icon.TexCoords
  return type(coords) == "table" and #coords == 4 and coords or nil
end

-- Bumped when a Masque skin changes or a font registers, so Configure restyles
-- every button.
local skinEpoch = 0

function Chain.Reskinned()
  skinEpoch = skinEpoch + 1
end

-- `crop`: a skin's tex coords for the icon (SkinCrop); zoom crops inside them.
local function StyleIcon(texture, d, crop)
  -- Zoom keeps the middle (1 - zoom / 2) of the texture on each axis, as
  -- WeakAuras does. Icon textures have a border baked into their edge.
  local left, right, top, bottom = 0, 1, 0, 1
  if crop then
    left, right, top, bottom = unpack(crop)
  end
  local keep = 1 - (d.zoom or 0) / 2
  local x, y = (left + right) / 2, (top + bottom) / 2
  local w, h = (right - left) / 2 * keep, (bottom - top) / 2 * keep
  texture:SetTexCoord(x - w, x + w, y - h, y + h)
  texture:SetDesaturated(d.desaturate == true)
  if d.tint then
    texture:SetVertexColor(unpack(d.tint))
  else
    texture:SetVertexColor(1, 1, 1)
  end
end

-- Proc glow: Blizzard's action button proc loop, a 6x5 flipbook. Blizzard
-- draws it at 1.4x the button (ActionButtonSpellAlerts.lua), where its inner
-- edge lands on the button's border art. Ours is drawn under the icon and
-- its border (GlowSize): larger moves the ring outward and shows more of it,
-- until a gap opens between border and ring; smaller hides it under the
-- border. Missing icons have no aura, so only a custom border shows on them.
--
-- GlowPad is how far a missing icon's clip window reaches past each edge of
-- the icon: the glow's reach plus 2px, so the clip never cuts the glow, or
-- the border's reach if that's further.

-- The border art has padding around the line. Blizzard's debuff buttons
-- center a 40px border on a 30px icon (BuffFrameTemplates.xml).
local BORDER_SIZE = 4 / 3

-- d.borderColor, { r, g, b }, draws one border in that color in place of the
-- dispel border. A display saves false to drop its group's.
local function CustomBorder(d)
  return type(d.borderColor) == "table" and d.borderColor or nil
end

-- d.borderStyle "plain": a solid outline (four strips just outside the icon)
-- in place of Blizzard's border art. White texture, so it takes any color
-- exactly; the art is red underneath and tints darker.
local function Plain(d)
  return d.borderStyle == "plain"
end

local function PlainWidth(d)
  return d.borderWidth
end

local function HasBorder(d)
  return CustomBorder(d) ~= nil or d.dispelBorder and d.mode ~= "missing"
end

-- How far a border reaches past each edge of the icon.
local function BorderReach(d)
  if not HasBorder(d) then
    return 0
  end
  return Plain(d) and PlainWidth(d) or math.ceil(d.size * (BORDER_SIZE - 1) / 2)
end

-- Glow size, picked by eye. Plain strips sit outside the icon, so that glow
-- is measured from their outer edge; Blizzard's art line hugs the icon's
-- edge (the rest of BORDER_SIZE is padding), so that glow is measured from
-- the icon.
local GLOW_SCALE = 1.65 -- no border, or plain strips
local GLOW_SCALE_ART = 1.75 -- Blizzard's border art

-- `skin`: how a skinned icon is skinned (SkinData). Its glow follows the
-- skin, sized as Masque sizes its own spell alerts (Skin_FlipBooks): the
-- skin's SpellAlert size, times 1.4.
local function GlowSize(d, skin)
  if skin then
    return SkinSize(skin, "SpellAlert", d.size) * 1.4
  elseif not HasBorder(d) then
    return d.size * GLOW_SCALE
  elseif Plain(d) then
    return (d.size + 2 * PlainWidth(d)) * GLOW_SCALE
  end
  return d.size * GLOW_SCALE_ART
end

-- How far the glow itself reaches past each edge of the icon.
local function GlowReach(d, skin)
  return d.glow and math.ceil((GlowSize(d, skin) - d.size) / 2) or 0
end

local function GlowPad(d, skin)
  local pad = d.glow and GlowReach(d, skin) + 2 or 0
  if skin then
    pad = math.max(pad, SkinReach(skin, d.size) + 1)
  elseif CustomBorder(d) then
    pad = math.max(pad, BorderReach(d) + 1)
  end
  return pad
end

-- Four solid strips around `anchor`, hidden. PlaceStrips sizes them.
local function NewStrips(parent, anchor)
  local strips = { anchor = anchor or parent }
  for i = 1, 4 do
    strips[i] = parent:CreateTexture(nil, "OVERLAY")
    strips[i]:SetTexture("Interface\\Buttons\\WHITE8X8")
    strips[i]:Hide()
  end
  return strips
end

-- Top and bottom span the corners; left and right fit between them.
local function PlaceStrips(strips, width)
  local a = strips.anchor
  local top, bottom, left, right = strips[1], strips[2], strips[3], strips[4]
  for _, strip in ipairs(strips) do
    strip:ClearAllPoints()
  end
  top:SetPoint("BOTTOMLEFT", a, "TOPLEFT", -width, 0)
  top:SetPoint("BOTTOMRIGHT", a, "TOPRIGHT", width, 0)
  top:SetHeight(width)
  bottom:SetPoint("TOPLEFT", a, "BOTTOMLEFT", -width, 0)
  bottom:SetPoint("TOPRIGHT", a, "BOTTOMRIGHT", width, 0)
  bottom:SetHeight(width)
  left:SetPoint("TOPRIGHT", a, "TOPLEFT")
  left:SetPoint("BOTTOMRIGHT", a, "BOTTOMLEFT")
  left:SetWidth(width)
  right:SetPoint("TOPLEFT", a, "TOPRIGHT")
  right:SetPoint("BOTTOMLEFT", a, "BOTTOMRIGHT")
  right:SetWidth(width)
end

local function ShowStrips(strips, shown, r, g, b, a)
  for _, strip in ipairs(strips) do
    if shown then
      strip:SetVertexColor(r, g, b, a)
      strip:Show()
    else
      strip:Hide()
    end
  end
end

-- The custom border, in either style: the typeless debuff border art
-- desaturated and tinted, or plain strips.
local function NewCustomBorder(parent, anchor)
  local art = parent:CreateTexture(nil, "OVERLAY")
  art:SetPoint("CENTER", anchor or parent, "CENTER")
  art:SetAtlas("ui-debuff-border-default-noicon")
  art:SetDesaturated(true)
  art:Hide()
  return { art = art, strips = NewStrips(parent, anchor) }
end

-- `ring`: a skinned button's skin border (NewRing), whose custom copy then
-- carries the color in place of our art.
local function StyleCustomBorder(kit, d, ring)
  local color = CustomBorder(d)
  kit.art:SetSize(d.size * BORDER_SIZE, d.size * BORDER_SIZE)
  PlaceStrips(kit.strips, PlainWidth(d))
  if ring then
    kit.art:Hide()
    ShowStrips(kit.strips, false)
    if color then
      ring.custom:SetVertexColor(unpack(color))
    end
    ring.custom:SetShown(color ~= nil)
    return
  end
  if color and not Plain(d) then
    kit.art:SetVertexColor(unpack(color))
    kit.art:Show()
  else
    kit.art:Hide()
  end
  ShowStrips(kit.strips, color and Plain(d), color and color[1], color and color[2], color and color[3], 1)
end

-- A glow texture on `parent`, hidden, and the AnimationGroup that plays it.
-- A stopped flipbook shows the whole atlas, so it's only shown while playing.
local function NewGlow(parent)
  -- Under the icon (ARTWORK) and so under the borders, as Blizzard draws it
  -- under the button: the icon hides the inside of the ring.
  local texture = parent:CreateTexture(nil, "BACKGROUND")
  texture:SetPoint("CENTER")
  -- ADD: the flipbook has a dark band inside its ring, and where the icon
  -- doesn't cover it, normal blending draws it as a black ring. Added, dark
  -- pixels draw nothing.
  texture:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
  texture:SetBlendMode("ADD")
  texture:Hide()
  local anim = texture:CreateAnimationGroup()
  anim:SetLooping("REPEAT")
  local flip = anim:CreateAnimation("FlipBook")
  flip:SetDuration(1)
  flip:SetFlipBookRows(6)
  flip:SetFlipBookColumns(5)
  flip:SetFlipBookFrames(30)
  return texture, anim
end

-- d.glow: true for the atlas's own gold, { r, g, b } for a color. Tinting
-- works on the desaturated art.
local function StyleGlow(texture, d, skin)
  local size = GlowSize(d, skin)
  local ok = pcall(texture.SetSize, texture, size, size)
  local color = type(d.glow) == "table" and d.glow
  ok = pcall(texture.SetDesaturated, texture, color and true or false) and ok
  if color then
    ok = pcall(texture.SetVertexColor, texture, unpack(color)) and ok
  else
    ok = pcall(texture.SetVertexColor, texture, 1, 1, 1) and ok
  end
  return ok
end

-- Whether the player is in combat; SlopAuras.lua keeps it current from the
-- REGEN events.
local inCombat = false

-- d.glowCombat: nil or "always", "in" (only in combat), "out" (only out of
-- it) or "never".
local function GlowNow(d)
  if not d.glow or d.glowCombat == "never" then
    return false
  end
  return not (d.glowCombat == "in" and not inCombat or d.glowCombat == "out" and inCombat)
end

-- Shows and plays a glow, or stops and hides it. Our texture's Shown isn't
-- one of the aspects Blizzard locks on a registered animation, so this works
-- in combat. Starting a glow on a button with no aura draws nothing.
local function ShowGlow(texture, anim, on)
  if on then
    texture:Show()
    anim:Play()
  else
    anim:Stop()
    texture:Hide()
  end
end

-- d.glowInRange hides the glow while the unit is out of range. `inRange` is
-- UnitInRange's secret answer (or true), so only SetAlphaFromBoolean may use it.
local function ApplyRange(texture, d, inRange)
  if d.glowInRange then
    pcall(texture.SetAlphaFromBoolean, texture, inRange, 1, 0)
  else
    pcall(texture.SetAlpha, texture, 1)
  end
end

-- One border texture per entry; at most one shows for a given aura. Debuffs
-- with no dispel type get Blizzard's red "None" border (DEBUFF_DISPLAY_INFO,
-- AuraUtil.lua); buffs only get a border when they have a type, as on
-- Blizzard's buff frames. The options default to harmful-only and typed-only
-- (CustomAuraButtonDispelTypeTextureOptions, AuraContainerUtilDocumentation.lua).
local BORDER_STYLE = Enum.CustomAuraButtonDispelTypeTextureStyle.Border
local BORDER_OPTIONS = {
  { style = BORDER_STYLE, showWhenHarmful = true, showWhenHelpful = false, showWithoutDispelType = true },
  { style = BORDER_STYLE, showWhenHarmful = false, showWhenHelpful = true },
}
-- The same rules for plain strips and a skin's border: PreserveAsset keeps our
-- texture and only colors it for the dispel type (AuraUtil.SetAuraBorderColor).
local PRESERVE = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset
local PLAIN_OPTIONS = {
  { style = PRESERVE, showWhenHarmful = true, showWhenHelpful = false, showWithoutDispelType = true },
  { style = PRESERVE, showWhenHarmful = false, showWhenHelpful = true },
}

-- A skin's Border layer (Caith's is a white ring) carries the dispel color
-- over the skin's frame art, which stays untinted. ring[1] is the button's
-- Border region in Masque; ring[2] copies its art (CopyRing), since one
-- texture takes one set of options and buffs and debuffs need two.
-- ring.custom copies it too, for a custom color, so we never color a
-- texture Blizzard also colors.
local function NewRing(parent)
  local ring = { parent:CreateTexture(nil, "OVERLAY"), parent:CreateTexture(nil, "OVERLAY") }
  ring.custom = parent:CreateTexture(nil, "OVERLAY")
  ring[2]:SetAllPoints(ring[1])
  ring.custom:SetAllPoints(ring[1])
  ring[1]:Hide()
  ring[2]:Hide()
  ring.custom:Hide()
  return ring
end

-- After Masque skins ring[1]: copies its art to the other two.
local function CopyRing(ring)
  local from = ring[1]
  for _, to in ipairs({ ring[2], ring.custom }) do
    pcall(function()
      to:SetTexture(from:GetTexture())
      to:SetTexCoord(from:GetTexCoord())
      to:SetBlendMode(from:GetBlendMode())
      to:SetDrawLayer(from:GetDrawLayer())
    end)
  end
end

-- The dispel border on one button: Blizzard's art (part.borders), plain
-- strips (part.plainBorders) or, `skinned`, the skin's border (part.ring),
-- handed to the button so Blizzard picks the type. Out of combat only.
-- Returns false if Blizzard refused part of it.
local function StyleDispelBorders(part, d, skinned)
  local ok = true
  local dispel = d.dispelBorder == true and not CustomBorder(d)
  local wanted = dispel and not Plain(d) and not skinned
  local wantedPlain = dispel and Plain(d) and not skinned
  local wantedRing = dispel and skinned == true
  if part.ring and wantedRing ~= part.ringOn then
    for i, ring in ipairs(part.ring) do
      if wantedRing then
        ok = pcall(part.button.AddDispelTypeTexture, part.button, ring, PLAIN_OPTIONS[i]) and ok
      else
        ok = pcall(part.button.RemoveDispelTypeTexture, part.button, ring) and ok
      end
    end
    part.ringOn = wantedRing
  end
  if part.ring and not wantedRing then
    part.ring[1]:Hide()
    part.ring[2]:Hide()
  end
  -- Made the first time they're wanted (most displays use one kind or none).
  if wantedPlain and #part.plainBorders == 0 then
    for i = 1, #PLAIN_OPTIONS do
      part.plainBorders[i] = NewStrips(part.overlay, part.button)
    end
  end
  if wanted and #part.borders == 0 then
    for i = 1, #BORDER_OPTIONS do
      part.borders[i] = part.overlay:CreateTexture(nil, "OVERLAY")
      part.borders[i]:SetPoint("CENTER", part.button, "CENTER")
    end
  end
  for i, strips in ipairs(part.plainBorders) do
    PlaceStrips(strips, PlainWidth(d))
    if wantedPlain ~= part.plainOn then
      for _, strip in ipairs(strips) do
        if wantedPlain then
          ok = pcall(part.button.AddDispelTypeTexture, part.button, strip, PLAIN_OPTIONS[i]) and ok
        else
          ok = pcall(part.button.RemoveDispelTypeTexture, part.button, strip) and ok
          strip:Hide()
        end
      end
    end
  end
  part.plainOn = wantedPlain
  for i, border in ipairs(part.borders) do
    border:SetSize(d.size * BORDER_SIZE, d.size * BORDER_SIZE)
    if wanted ~= part.borderOn then
      if wanted then
        ok = pcall(part.button.AddDispelTypeTexture, part.button, border, BORDER_OPTIONS[i]) and ok
      else
        ok = pcall(part.button.RemoveDispelTypeTexture, part.button, border) and ok
        -- Blizzard drew it last; clear what's left.
        pcall(border.SetTexture, border, nil)
      end
    end
  end
  part.borderOn = wanted
  return ok
end

-- Every display key StyleButton reads, as one string: Configure restyles a
-- button only when it changed. A new key StyleButton reads goes here too.
local STYLE_KEYS = {
  "size", "alpha", "zoom", "desaturate", "tint", "hideSwipe", "mode",
  "dispelBorder", "borderColor", "skin", "borderStyle", "borderWidth", "glow", "glowCombat",
  "glowInRange", "hideTimer", "hideStacks", "tooltip",
  "timerSize", "timerFont", "timerOutline", "timerColor", "timerPoint", "timerAlign", "timerX", "timerY",
  "stackSize", "stackFont", "stackOutline", "stackColor", "stackPoint", "stackAlign", "stackX", "stackY",
}

local function StyleText(d)
  local values = {}
  for i, key in ipairs(STYLE_KEYS) do
    local value = d[key]
    values[i] = type(value) == "table" and table.concat(value, ",") or tostring(value)
  end
  values[#values + 1] = skinEpoch
  return table.concat(values, "|")
end

-- A list button's two texts: the cooldown's countdown ("timer" keys) and the
-- stack count ("stack" keys). Per prefix: Size; Font, a LibSharedMedia name
-- (false or nil: the text's own font); Outline, "NONE", "OUTLINE" or
-- "THICKOUTLINE"; Color; Point, where on the icon; Align, which side of the
-- text sits on that point; X and Y.
local LSM = LibStub("LibSharedMedia-3.0")

-- The text's own anchor point: the icon point's top or bottom plus the
-- alignment's side. At TOPRIGHT, "RIGHT" keeps the text inside the corner and
-- "LEFT" starts it there. A one-line text sizes to fit, so justifying alone
-- would move nothing.
local function TextPoint(point, align)
  local vertical = point:match("TOP") or point:match("BOTTOM") or ""
  local textPoint = vertical .. (align ~= "CENTER" and align or "")
  return textPoint ~= "" and textPoint or "CENTER"
end

-- `face`: the font the text was created with. The count's Text and Shown are
-- Blizzard's (SetApplicationCount), its font, points and color ours.
local function StyleString(text, anchor, d, prefix, face)
  local name = d[prefix .. "Font"]
  local font = name and LSM:Fetch("font", name, true) or face
  local outline = d[prefix .. "Outline"]
  local point, align = d[prefix .. "Point"], d[prefix .. "Align"]
  local ok = pcall(text.SetFont, text, font, d[prefix .. "Size"], outline == "NONE" and "" or outline)
  ok = pcall(function()
    text:ClearAllPoints()
    text:SetPoint(TextPoint(point, align), anchor, point, d[prefix .. "X"], d[prefix .. "Y"])
    text:SetJustifyH(align)
    text:SetTextColor(unpack(d[prefix .. "Color"]))
  end) and ok
  return ok
end

-- Applies the display's look to one button's parts. Out of combat only.
-- Returns false if Blizzard refused part of it.
local function StyleButton(part, d)
  local ok = pcall(part.button.SetSize, part.button, d.size, d.size)
  -- Per button, not per container: displays sharing a line can differ.
  ok = pcall(part.button.SetAlpha, part.button, d.alpha) and ok
  local skin = SkinData(part.inst, d)
  if skin then
    -- Buttons in a container can report secret sizes, so Masque is told the
    -- size (Group:SetFrameSize); this also reskins the button.
    if pcall(part.inst.skin.SetFrameSize, part.inst.skin, d.size, d.size, part.button) then
      CopyRing(part.ring)
    else
      ok = false
    end
  elseif part.ring then
    -- A disabled Masque group leaves regions where its default skin put them.
    part.icon:ClearAllPoints()
    part.icon:SetAllPoints()
    part.cooldown:ClearAllPoints()
    part.cooldown:SetAllPoints()
  end
  StyleIcon(part.icon, d, skin and SkinCrop(skin))
  -- CooldownFrameTemplate draws the remaining time as text over the swipe.
  -- SetDurationCooldown locks only the cooldown's Cooldown and Shown
  -- (Blizzard_CustomAuraButton.lua), so the swipe and text are ours. Both
  -- texts are styled after Masque, which places the count from the skin.
  ok = pcall(part.cooldown.SetHideCountdownNumbers, part.cooldown, d.hideTimer == true) and ok
  ok = pcall(part.cooldown.SetDrawSwipe, part.cooldown, not d.hideSwipe) and ok
  local timer = part.cooldown:GetCountdownFontString()
  if timer then
    part.timerFace = part.timerFace or timer:GetFont()
    ok = StyleString(timer, part.button, d, "timer", part.timerFace) and ok
  end
  part.stackFace = part.stackFace or part.count:GetFont()
  ok = StyleString(part.count, part.button, d, "stack", part.stackFace) and ok
  -- Shown is Blizzard's, so hiding goes through alpha.
  ok = pcall(part.count.SetAlpha, part.count, d.hideStacks and 0 or 1) and ok
  -- The button's own OnEnter shows the tooltip (Blizzard_AuraButton.lua).
  -- Motion only, so clicks still reach the frame underneath.
  ok = pcall(part.button.SetMouseMotionEnabled, part.button, d.tooltip ~= "never") and ok
  ok = pcall(part.button.SetHideTooltipInCombat, part.button, d.tooltip == "out") and ok
  ok = StyleDispelBorders(part, d, skin ~= nil) and ok
  if CustomBorder(d) and not part.customBorder then
    part.customBorder = NewCustomBorder(part.overlay, part.button)
  end
  if part.customBorder then
    StyleCustomBorder(part.customBorder, d, skin and part.ring)
  elseif part.ring then
    part.ring.custom:Hide()
  end

  -- Addon code can't animate inside an aura button, so the glow is handed to
  -- the button and Blizzard plays it whenever the button shows an aura
  -- (ApplyVisibility, Blizzard_CustomAuraButton.lua). Registered, its
  -- animation can't change, but it can be removed and added again.
  if d.glow and not part.glow then
    part.glow, part.glowAnim = NewGlow(part.button)
  end
  if not part.glow then
    return ok
  end
  ok = StyleGlow(part.glow, d, skin) and ok
  local glow = d.glow and true or false
  if glow ~= part.glowOn then
    if glow then
      if pcall(part.button.AddAuraShownAnimation, part.button, part.glowAnim) then
        part.glowOn = true
      else
        ok = false
      end
    else
      pcall(part.button.RemoveAuraShownAnimation, part.button, part.glowAnim)
      part.glowOn = false
    end
  end
  -- Blizzard only starts it when a button goes from hidden to shown; this
  -- starts buttons that already show an aura.
  ShowGlow(part.glow, part.glowAnim, part.glowOn and GlowNow(d))
  ApplyRange(part.glow, d, part.inst.inRange)
  return ok
end

-- initializeFrame for a visible aura group: runs once per button the
-- container creates. The regions are registered with the button (SetIcon
-- etc.) and Blizzard fills them from the secret aura data. Size, tint and the
-- rest are ours to change out of combat, so each button's parts are kept in
-- `parts`. Buttons created later use the current values of slot `j`'s
-- display (a rebind moves displays between slots, see Chain.Resize) and the current
-- range from `inst`.
local function StyledButton(inst, j, parts)
  return function(button)
    button:EnableMouse(false)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    button:SetIcon(icon)

    local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetReverse(true)
    button:SetDurationCooldown(cooldown)

    -- The cooldown is a child frame, so its swipe draws over every texture
    -- of the button. The count, borders and glow go on a frame above it.
    local overlay = CreateFrame("Frame", nil, button, "DisableUntrustedLayoutScriptsTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameLevel(cooldown:GetFrameLevel() + 1)

    local count = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -1, 1)
    button:SetApplicationCount(count)

    -- Masque-style displays only. Registered even while the Masque group is
    -- disabled, so enabling it later skins this button too. Masque draws its
    -- frame art (Normal) on the button, under the cooldown swipe and our
    -- overlay.
    local ring
    if UsesMasque(inst, inst.displays[j]) then
      ring = NewRing(overlay)
      pcall(inst.skin.AddButton, inst.skin, button,
        { Icon = icon, Cooldown = cooldown, Count = count, Border = ring[1] }, "Aura", true)
    end

    -- Borders, the custom border and the glow are made by StyleButton when the
    -- display first uses them: creating every kind for every button made
    -- building slow (each aura group makes ten buttons).
    local part = {
      button = button, icon = icon, cooldown = cooldown, count = count, overlay = overlay, borders = {},
      borderOn = false, plainBorders = {}, plainOn = false, ring = ring, ringOn = false, glowOn = false, inst = inst,
    }
    table.insert(parts, part)
    local d = inst.displays[j]
    if StyleButton(part, d) then
      part.style = StyleText(d)
    end
  end
end

-- An aura group's options for display `d`. Each slot is the icon plus its
-- spacing plus 1px along the line, and the icon plus the line spacing plus
-- 1px across it. Slots overlap by 1px (elementSpacing -1, which also carries
-- across groups in one container), so n auras measure n * (slot - 1) + 1: the
-- 1px an empty container has, plus exactly one slot per aura. Link and the
-- line stacking cancel that 1px. `half`: a shadow's half-length slots.
-- `maxCount` is given only for a missing display's containers (one slot).
local function GroupOptions(d, g, lineSpacing, half, maxCount, init)
  local length = half and (d.size + d.spacing) / 2 + 1 or d.size + d.spacing + 1
  local width, height = Slot(g, length, d.size + lineSpacing + 1)
  return {
    maxFrameCount = maxCount or d.max,
    candidateFilters = GroupCandidates(d, maxCount ~= nil),
    sortMethod = AuraContainerSortMethod[d.sort] or AuraContainerSortMethod.Default,
    sortDirection = d.sortReverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal,
    -- lineSpacing: rows a wrapping line starts overlap by 1px too.
    layout = { elementWidth = width, elementHeight = height, elementSpacing = -1, lineSpacing = -1 },
    initializeFrame = init or MeasureOnly(width, height),
  }
end

local function NewContainer(parent, unit, g)
  -- Frames anchored to an aura container must opt out of untrusted layout
  -- scripts, and every container here is anchored to another one.
  local container = CreateFrame("AuraContainer", nil, parent,
    "CustomAuraContainerTemplate, DisableUntrustedLayoutScriptsTemplate")
  container:Hide()
  container:SetPoint(g.start, parent, g.start)
  container:SetUnit(unit)
  container:SetFlowLayoutAxis(g.axis)
  container:SetFlowLayoutAnchorPoint(g.start)
  container:SetFlowLayoutGrowthDirection(g.h, g.v)
  return container
end

local function Key(j)
  return "d" .. j
end

-- Names a frame for /fstack, which shows the parent key in place of an
-- anonymous frame's address. The prefix tells our frames from the host's.
local function Name(frame, name)
  pcall(frame.SetParentKey, frame, addonName .. " " .. name)
end

-- The missing icon's window: the icon's slot plus room for its glow (and a
-- skin's art) on every side. Fixed in size; Link places it.
local function WindowSize(d, skin)
  return d.size + 2 * GlowPad(d, skin)
end

-- The slide container's one slot along the line: a step longer than the
-- window, so the icon and glow leave it entirely when the aura shows up.
local function SlideOptions(d, g, skin)
  local options = GroupOptions(d, g, 0, false, 1)
  local width, height = Slot(g, WindowSize(d, skin) + 1, 1)
  options.layout = { elementWidth = width, elementHeight = height, elementSpacing = -1 }
  options.initializeFrame = MeasureOnly(width, height)
  return options
end

-- The missing icon's look, which is all ours: no Blizzard restrictions.
local function StyleMissing(inst)
  local d, icon = inst.display, inst.missingIcon
  local skin = SkinData(inst, d)
  inst.window:SetAlpha(d.alpha)
  local size = WindowSize(d, skin)
  inst.window:SetSize(size, size)
  inst.holder:SetSize(d.size, d.size)
  local ids = Chain.SpellIDs(d)
  local source = d.icon or (ids and next(ids)) -- an included ID
  icon:SetTexture(type(source) == "number" and C_Spell.GetSpellTexture(source) or source)
  if skin then
    if pcall(inst.skin.SetFrameSize, inst.skin, d.size, d.size, inst.holder) then
      CopyRing(inst.ring)
    end
  elseif inst.ring then
    icon:ClearAllPoints()
    icon:SetAllPoints()
  end
  StyleIcon(icon, d, skin and SkinCrop(skin))
  -- No aura, so no dispel color: the ring only ever carries a custom color.
  if inst.ring then
    inst.ring[1]:Hide()
    inst.ring[2]:Hide()
  end
  StyleCustomBorder(inst.customBorder, d, skin and inst.ring)
  StyleGlow(inst.glow, d, skin)
  -- Ours to play. It keeps looping while the icon is slid out of sight.
  ShowGlow(inst.glow, inst.glowAnim, inst.active and GlowNow(d))
  ApplyRange(inst.glow, d, inst.inRange)
end

-- A group showing only its first line (firstLine) builds its lines inside a
-- clip window at the row's origin. Empty lines collapse (PlaceLine), so the
-- window holds the first line that has auras. Lua can't measure which line
-- that is (container sizes are secret), so the window is one line of the
-- group's biggest icon deep: a smaller line on top leaves room for the edge of
-- the line after it (ns.FirstLineConflict). Along the line and behind it
-- nothing else of ours is drawn, so the window reaches far there; past the
-- line it reaches only as far as the line spacing allows without showing the
-- next line's icons or borders.
local WINDOW_REACH = 4096

function Chain.NewFirstLineWindow(parent, label)
  local window = CreateFrame("Frame", nil, parent)
  Name(window, label .. " (first line)")
  window:SetClipsChildren(true)
  return window
end

-- `clip`: false shows every line (lines shared by several units keep their
-- height, and mixed icon sizes can leak). `skin`: the group's Masque group,
-- or nil.
function Chain.StyleFirstLine(window, origin, g, displays, lineSpacing, clip, skin)
  local size = 0
  for _, d in ipairs(displays) do
    size = math.max(size, d.size)
  end
  local reach = math.ceil(size / 5)
  local owner = { skin = skin }
  for _, d in ipairs(displays) do
    local data = SkinData(owner, d)
    if data then
      reach = math.max(reach, SkinReach(data, size))
    end
  end
  local back = size -- behind the line: glows, borders and skins
  local depth = WINDOW_REACH
  if clip then
    depth = back + size + math.max(0, math.min(reach, lineSpacing - reach))
  end
  local width, height = Slot(g, 2 * WINDOW_REACH, depth)
  window:SetSize(width, height)
  window:ClearAllPoints()
  Anchor(window, g.start, origin, g.start, -g.dx * WINDOW_REACH - g.cx * back, -g.dy * WINDOW_REACH - g.cy * back)
end

-- Blizzard's nameplates add INCLUDE_NAME_PLATE_ONLY to their filters
-- (Blizzard_NamePlateAuras.lua); without it, auras flagged nameplate-only are
-- left out. Nameplate lines add it too, so they show what the default plates do.
local PLATE_TOKEN = AuraUtil.AuraFilters.IncludeNameplateOnly

local function FilterFor(inst, d)
  if inst.plate and not d.filter:find(PLATE_TOKEN, 1, true) then
    return d.filter .. "|" .. PLATE_TOKEN
  end
  return d.filter
end

-- What `container`'s aura group j was last given, for Reconfigure.
local function Sent(inst, container, j)
  inst.sent = inst.sent or {}
  local sent = inst.sent[container] or {}
  inst.sent[container] = sent
  sent[j] = sent[j] or {}
  return sent[j]
end

local function LayoutText(layout)
  return layout.elementWidth .. "x" .. layout.elementHeight .. "/" .. layout.elementSpacing
end

-- Adds aura group j and records its options, so the first Reconfigure after
-- a build only sends what changed.
local function AddGroup(inst, container, j, d, options)
  container:AddAuraGroup(Key(j), FilterFor(inst, d), options)
  local last = Sent(inst, container, j)
  last.candidatesSent, last.candidates = true, options.candidateFilters
  last.sortMethod, last.sortDirection = options.sortMethod, options.sortDirection
  last.layout = LayoutText(options.layout)
end

-- One line's list displays, for one unit: a container with an aura group per
-- display (keys d1, d2, ... in line order), hidden. `label` names its frames
-- in /fstack, e.g. "MyDebuffs line 1". `plate`: the line is on a nameplate
-- host. `skin`: the group's Masque group, or nil.
function Chain.NewList(parent, unit, displays, g, lineSpacing, label, plate, skin)
  -- slots: aura groups made, past #displays when Resize left spares.
  -- masque[j]: whether slot j's buttons are registered with Masque.
  local inst = {
    displays = displays, parts = {}, on = {}, inRange = true, plate = plate, skin = skin, slots = #displays, masque = {},
    unit = unit,
  }
  inst.main = NewContainer(parent, unit, g)
  Name(inst.main, label)
  for j, d in ipairs(displays) do
    inst.parts[j] = {}
    inst.masque[j] = UsesMasque(inst, d)
    AddGroup(inst, inst.main, j, d, GroupOptions(d, g, lineSpacing, false, nil, StyledButton(inst, j, inst.parts[j])))
  end
  if g.shadow then
    inst.shadow = NewContainer(parent, unit, g.shadow)
    Name(inst.shadow, label .. " (shadow)")
    for j, d in ipairs(displays) do
      AddGroup(inst, inst.shadow, j, d, GroupOptions(d, g.shadow, lineSpacing, true))
    end
  end
  return inst
end

-- A priority stack: for a row that shows only its first line, where every
-- line is one display showing one icon (SlopAuras.lua decides). Each display
-- is an aura slot, one button (AddAuraSlot) where an aura group makes ten
-- (Blizzard_CustomAuraContainer.lua). Slots take no part in layout, so they
-- all sit on the container's start corner, earlier displays on top: the
-- first display with an aura is the one seen, as the first-line window shows
-- it. The container itself stays 1px and only marks the spot.
local SLOT_LEVELS = 4 -- a button's own levels: itself, cooldown, overlay, and one spare

local function AddSlot(inst, j, d)
  inst.parts[j] = {}
  inst.masque[j] = UsesMasque(inst, d)
  local key = Key(j)
  local sortMethod = AuraContainerSortMethod[d.sort] or AuraContainerSortMethod.Default
  local sortDirection = d.sortReverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal
  local candidates = GroupCandidates(d, false)
  inst.main:AddAuraSlot(key, FilterFor(inst, d), {
    candidateFilters = candidates, sortMethod = sortMethod, sortDirection = sortDirection,
    initializeFrame = StyledButton(inst, j, inst.parts[j]),
  })
  local frame = inst.main:GetAuraSlotFrame(key)
  pcall(frame.SetPoint, frame, inst.g.start, inst.main, inst.g.start)
  local last = Sent(inst, inst.main, j)
  last.candidatesSent, last.candidates = true, candidates
  last.sortMethod, last.sortDirection = sortMethod, sortDirection
end

-- Display 1 on top. Children keep their offset when a frame's level changes.
local function LevelSlots(inst)
  local base, count = inst.main:GetFrameLevel() + 1, inst.slots
  for j = 1, count do
    local frame = inst.main:GetAuraSlotFrame(Key(j))
    pcall(frame.SetFrameLevel, frame, base + (count - j) * SLOT_LEVELS)
  end
end

function Chain.NewStack(parent, unit, displays, g, label, plate, skin)
  local inst = {
    stack = true, g = g, displays = displays, parts = {}, on = {}, inRange = true, plate = plate, skin = skin,
    slots = #displays, masque = {}, unit = unit,
  }
  inst.main = NewContainer(parent, unit, g)
  Name(inst.main, label)
  for j, d in ipairs(displays) do
    AddSlot(inst, j, d)
  end
  LevelSlots(inst)
  return inst
end

-- Whether list line `inst` can take `displays` through Chain.Resize. A slot's
-- Masque registration is fixed when its buttons are made, so each display
-- landing on an existing slot must match it.
function Chain.CanResize(inst, displays)
  for j = 1, math.min(#displays, inst.slots) do
    if inst.masque[j] ~= UsesMasque(inst, displays[j]) then
      return false
    end
  end
  return #displays > 0
end

-- Points a list line at a new list of displays, any length, without new
-- containers: building a line makes 10 buttons per aura group up front
-- (AddAuraGroup, Blizzard_CustomAuraContainer.lua), and a row on every
-- nameplate makes that slow. Slots past the new count are turned off and kept
-- as spares; extra displays take spares first, then new aura groups.
-- Configure then pushes each slot's settings. Out of combat.
function Chain.Resize(inst, displays, g, lineSpacing)
  inst.displays = {}
  for j, d in ipairs(displays) do
    inst.displays[j] = d
  end
  for j = inst.slots + 1, #displays do
    local d = displays[j]
    if inst.stack then
      AddSlot(inst, j, d)
    else
      inst.parts[j] = {}
      inst.masque[j] = UsesMasque(inst, d)
      AddGroup(inst, inst.main, j, d, GroupOptions(d, g, lineSpacing, false, nil, StyledButton(inst, j, inst.parts[j])))
      if inst.shadow then
        AddGroup(inst, inst.shadow, j, d, GroupOptions(d, g.shadow, lineSpacing, true))
      end
    end
  end
  inst.slots = math.max(inst.slots, #displays)
  if inst.stack then
    LevelSlots(inst)
  end
  -- inst.on[j] is slot j's state, which UpdateLine compares against. A new
  -- aura group starts on with no state, so UpdateLine sets it either way.
  for j = #displays + 1, inst.slots do
    Chain.SetDisplayActive(inst, j, false)
    inst.on[j] = false
  end
end

-- `wrap`: start a new row after that many icons, or nil for one row. The
-- container wraps by length (AnchorUtil.ApplyFlowLayout), measured in the
-- line's first display's slots: slots overlap by 1px, so n icons measure
-- n * (size + spacing) + 1. A shadow's slots are exactly half as long, so it
-- wraps at the same icon. The rows grow the way new lines go. Out of combat.
function Chain.SetWrap(inst, wrap)
  local d = inst.displays[1]
  local step = d.size + d.spacing
  inst.main:SetFlowLayoutMaximumLineSize(wrap and wrap * step + 1 or nil)
  if inst.shadow then
    inst.shadow:SetFlowLayoutMaximumLineSize(wrap and wrap * step / 2 + 1 or nil)
  end
end

-- One missing-icon display, for one unit, hidden. Lua can't know whether the
-- aura is there (aura data is secret), so containers move frames instead:
--   presence: at most one invisible slot, anchored backwards (see Link); the
--             next display starts at its start corner, so the icon takes room
--             only while the aura is missing.
--   window:   a fixed clip over the icon's slot, with room for the glow.
--   slide:    a second presence container whose slot is longer than the
--             window. The icon and glow hang off its start corner, so when the
--             aura shows up they move a full window back, out of sight.
function Chain.NewMissing(parent, unit, d, g, lineSpacing, label, plate, skin)
  local inst = { display = d, displays = { d }, inRange = true, plate = plate, skin = skin, unit = unit }
  inst.main = NewContainer(parent, unit, g)
  Name(inst.main, label .. " (presence)")
  AddGroup(inst, inst.main, 1, d, GroupOptions(d, g, lineSpacing, false, 1))

  inst.slide = NewContainer(parent, unit, g)
  Name(inst.slide, label .. " (slide)")
  AddGroup(inst, inst.slide, 1, d, SlideOptions(d, g, SkinData(inst, d)))

  inst.window = CreateFrame("Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
  Name(inst.window, label .. " (missing icon)")
  inst.window:SetClipsChildren(true)
  inst.window:Hide()
  -- Frames anchored to an aura container opt out of untrusted layout scripts.
  inst.holder = CreateFrame("Frame", nil, inst.window, "DisableUntrustedLayoutScriptsTemplate")
  -- An empty container is 1px long; +1 along puts the icon at its far end.
  inst.holder:SetPoint(g.start, inst.slide, g.start, g.dx, g.dy)
  inst.missingIcon = inst.holder:CreateTexture(nil, "ARTWORK")
  inst.missingIcon:SetAllPoints()
  inst.customBorder = NewCustomBorder(inst.holder)
  inst.glow, inst.glowAnim = NewGlow(inst.holder)
  if UsesMasque(inst, d) then
    inst.ring = NewRing(inst.holder)
    pcall(skin.AddButton, skin, inst.holder, { Icon = inst.missingIcon, Border = inst.ring[1] }, "Aura", true)
  end
  StyleMissing(inst)

  if g.shadow then
    inst.shadow = NewContainer(parent, unit, g.shadow)
    Name(inst.shadow, label .. " (shadow)")
    AddGroup(inst, inst.shadow, 1, d, GroupOptions(d, g.shadow, lineSpacing, true, 1))
  end
  return inst
end

-- `optionsFor(d)` gives each display's aura group options. The candidate
-- filter, sort and layout setters rebuild or relayout the container even when
-- the value is the same (Blizzard_CustomAuraContainer.lua), and the editor
-- applies every change to every host, so each is sent only when it differs
-- from what this container last got. The filter and max setters compare
-- themselves.
local function Reconfigure(container, inst, optionsFor)
  for j, d in ipairs(inst.displays) do
    local key, options = Key(j), optionsFor(d)
    local last = Sent(inst, container, j)
    container:SetAuraGroupFilterString(key, FilterFor(inst, d))
    if not last.candidatesSent or last.candidates ~= options.candidateFilters then
      container:SetAuraGroupCandidateFilters(key, options.candidateFilters)
      last.candidatesSent, last.candidates = true, options.candidateFilters
    end
    if last.sortMethod ~= options.sortMethod or last.sortDirection ~= options.sortDirection then
      container:SetAuraGroupSortMethod(key, options.sortMethod, options.sortDirection)
      last.sortMethod, last.sortDirection = options.sortMethod, options.sortDirection
    end
    container:SetAuraGroupMaxFrameCount(key, options.maxFrameCount)
    local layoutText = LayoutText(options.layout)
    if last.layout ~= layoutText then
      container:SetAuraGroupLayout(key, options.layout)
      last.layout = layoutText
    end
  end
end

-- Reconfigure for a stack's slots: filter, candidate filters and sort. Slots
-- have no max or layout.
local function ReconfigureSlots(inst)
  local container = inst.main
  for j, d in ipairs(inst.displays) do
    local key, last = Key(j), Sent(inst, container, j)
    container:SetAuraSlotFilterString(key, FilterFor(inst, d))
    local candidates = GroupCandidates(d, false)
    if not last.candidatesSent or last.candidates ~= candidates then
      container:SetAuraSlotCandidateFilters(key, candidates)
      last.candidatesSent, last.candidates = true, candidates
    end
    local sortMethod = AuraContainerSortMethod[d.sort] or AuraContainerSortMethod.Default
    local sortDirection = d.sortReverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal
    if last.sortMethod ~= sortMethod or last.sortDirection ~= sortDirection then
      container:SetAuraSlotSortMethod(key, sortMethod, sortDirection)
      last.sortMethod, last.sortDirection = sortMethod, sortDirection
    end
  end
end

-- Applies the current settings to existing containers and buttons, for the
-- editor. Out of combat only: containers refuse while auras are secret.
-- Changing mode, growth, line direction or line breaks needs a new line.
-- Returns false if Blizzard refused part of the restyle.
function Chain.Configure(inst, g, lineSpacing)
  local maxCount = inst.window and 1 or nil
  if inst.stack then
    ReconfigureSlots(inst)
  else
    Reconfigure(inst.main, inst, function(d) return GroupOptions(d, g, lineSpacing, false, maxCount) end)
  end
  if inst.shadow then
    Reconfigure(inst.shadow, inst, function(d) return GroupOptions(d, g.shadow, lineSpacing, true, maxCount) end)
  end
  if inst.window then
    Reconfigure(inst.slide, inst, function(d) return SlideOptions(d, g, SkinData(inst, d)) end)
    StyleMissing(inst)
    return true
  end
  local ok = true
  for j, d in ipairs(inst.displays) do
    local style = StyleText(d)
    for _, part in ipairs(inst.parts[j]) do
      if part.style ~= style then
        local styled = StyleButton(part, d)
        part.style = styled and style or nil -- a refused restyle is tried again
        ok = styled and ok
      end
    end
  end
  return ok
end

-- Places a line's container (or its shadow) at `from` ({ frame, point, x, y })
-- and returns where the next one starts.
function Chain.Link(inst, from, g, shadow)
  local container = shadow and inst.shadow or inst.main
  container:ClearAllPoints()

  if inst.window then
    local d = inst.display
    local length = shadow and (d.size + d.spacing) / 2 + 1 or d.size + d.spacing + 1
    -- Anchored backwards: the far corner sits one slot past `from`, so the
    -- start corner (where the next display begins) is
    --   aura missing (1px):      one slot past `from`, leaving room for the icon
    --   aura present (one slot): exactly at `from`, taking no room
    Anchor(container, g.far, from.frame, from.point, from.x + g.dx * length, from.y + g.dy * length)
    if not shadow then
      -- The window covers the icon's slot at `from`, plus the glow's reach
      -- back along the line and away from new lines (start is on the baseline).
      local pad = GlowPad(d, SkinData(inst, d))
      inst.window:ClearAllPoints()
      Anchor(inst.window, g.start, from.frame, from.point,
        from.x - (g.dx + g.cx) * pad, from.y - (g.dy + g.cy) * pad)
      -- The slide's far corner at `from`: missing, the icon starts at `from`;
      -- present, it moves a window's length back, which puts the glow's far
      -- edge behind the window's start.
      inst.slide:ClearAllPoints()
      Anchor(inst.slide, g.far, from.frame, from.point, from.x, from.y)
    end
    return { frame = container, point = g.start, x = 0, y = 0 }
  end

  Anchor(container, g.start, from.frame, from.point, from.x, from.y)
  return { frame = container, point = g.far, x = -g.dx, y = -g.dy }
end

local function Toggle(container, on)
  if container then
    container:SetShown(on)
    container:SetEnabled(on) -- enabling also refreshes its auras
  end
end

-- Shows or hides a whole line container or missing display.
function Chain.SetActive(inst, active)
  Toggle(inst.main, active)
  Toggle(inst.shadow, active)
  if inst.window then
    Toggle(inst.slide, active)
    inst.window:SetShown(active)
    ShowGlow(inst.glow, inst.glowAnim, active and GlowNow(inst.display))
  end
end

function Chain.SetCombat(combat)
  inCombat = combat
end

-- `inRange`: UnitInRange's secret answer for the unit, or true. Works in combat.
function Chain.SetRange(inst, inRange)
  inst.inRange = inRange
  if inst.window then
    ApplyRange(inst.glow, inst.display, inRange)
    return
  end
  for j, d in ipairs(inst.displays) do
    for _, part in ipairs(inst.parts[j]) do
      if part.glow then
        ApplyRange(part.glow, d, inRange)
      end
    end
  end
end

-- After SetCombat. Only glows that depend on combat are touched; restarting
-- the rest would make every glow skip.
function Chain.UpdateCombatGlows(inst)
  if inst.window then
    local d = inst.display
    if d.glowCombat == "in" or d.glowCombat == "out" then
      ShowGlow(inst.glow, inst.glowAnim, inst.active and GlowNow(d))
    end
    return
  end
  for j, d in ipairs(inst.displays) do
    if d.glowCombat == "in" or d.glowCombat == "out" then
      for _, part in ipairs(inst.parts[j]) do
        if part.glow then
          ShowGlow(part.glow, part.glowAnim, part.glowOn and GlowNow(d))
        end
      end
    end
  end
end

-- Turns one display's aura group on or off within its line. The flow layout
-- closes the gap. Works in combat.
function Chain.SetDisplayActive(inst, j, active)
  if inst.stack then
    pcall(inst.main.SetAuraSlotEnabled, inst.main, Key(j), active)
    return
  end
  pcall(inst.main.SetAuraGroupEnabled, inst.main, Key(j), active)
  if inst.shadow then
    pcall(inst.shadow.SetAuraGroupEnabled, inst.shadow, Key(j), active)
  end
end

local function Containers(inst)
  return inst.main, inst.shadow, inst.slide
end

function Chain.SetUnit(inst, unit)
  inst.unit = unit
  for _, container in pairs({ Containers(inst) }) do
    container:SetUnit(unit)
  end
end

-- Retires a line or missing display the editor replaced. Frames can't be
-- destroyed, so it's hidden and disabled (no events, no work) and stays in
-- memory until /reload. Returns how many containers that leaves behind.
function Chain.Release(inst)
  Chain.SetActive(inst, false)
  inst.active = nil
  if inst.skin then
    for _, parts in ipairs(inst.parts or {}) do
      for _, part in ipairs(parts) do
        if part.ring then
          pcall(inst.skin.RemoveButton, inst.skin, part.button)
        end
      end
    end
    if inst.ring then
      pcall(inst.skin.RemoveButton, inst.skin, inst.holder)
    end
  end
  local count = 0
  for _ in pairs({ Containers(inst) }) do
    count = count + 1
  end
  return count
end

-- Points a missing display at another display table of the same mode, so a
-- reorder needs no new containers. Configure then pushes its settings.
function Chain.SetDisplay(inst, d)
  inst.displays[1], inst.display = d, d
end

-- Whether missing display `inst` can take `d` through Chain.SetDisplay: its
-- holder's Masque registration is fixed when it's made.
function Chain.CanSetDisplay(inst, d)
  return (inst.ring ~= nil) == UsesMasque(inst, d)
end

-- Containers don't notice when a token like "target" or "party1" starts
-- meaning someone else. Call this when it does.
function Chain.Refresh(inst)
  for _, container in pairs({ Containers(inst) }) do
    container:UpdateAllAuras()
  end
end
