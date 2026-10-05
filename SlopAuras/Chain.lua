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

local function Candidates(d)
  local filters = {}
  -- excludeSpellIDs is checked first, and like includeSpellIDs only where
  -- the game allows spell ID filters (CanApplyIdentityCandidateFilters in
  -- Blizzard_AuraContainerUtil.lua); elsewhere the exclusion is skipped.
  filters.includeSpellIDs, filters.excludeSpellIDs = Chain.SpellIDs(d)
  DispelFilter(d, filters)
  return next(filters) and filters or nil
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

local function StyleIcon(texture, d)
  -- Zoom keeps the middle (1 - zoom / 2) of the texture on each axis, as
  -- WeakAuras does. Icon textures have a border baked into their edge.
  local edge = (d.zoom or 0) / 4
  texture:SetTexCoord(edge, 1 - edge, edge, 1 - edge)
  texture:SetDesaturated(d.desaturate == true)
  if d.tint then
    texture:SetVertexColor(unpack(d.tint))
  else
    texture:SetVertexColor(1, 1, 1)
  end
end

-- Proc glow: Blizzard's action button proc loop, a 6x5 flipbook. Blizzard
-- draws it at 1.4x the button (ActionButtonSpellAlerts.lua), where its inner
-- edge lands on the button's border art; our icons have no border, so it's
-- drawn at 1.6x to sit just outside the icon. Blizzard's border art reaches
-- past the icon (4/3 of it, see BORDER_SIZE), so with it the glow is larger
-- still; a plain border is thin enough to leave it. Missing icons have no
-- aura, so only a custom border shows on them.
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

local function GlowScale(d)
  return HasBorder(d) and not Plain(d) and 1.8 or 1.6
end

-- How far the glow itself reaches past each edge of the icon.
local function GlowReach(d)
  return d.glow and math.ceil(d.size * (GlowScale(d) - 1) / 2) or 0
end

local function GlowPad(d)
  local pad = d.glow and GlowReach(d) + 2 or 0
  if CustomBorder(d) then
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

local function StyleCustomBorder(kit, d)
  local color = CustomBorder(d)
  kit.art:SetSize(d.size * BORDER_SIZE, d.size * BORDER_SIZE)
  PlaceStrips(kit.strips, PlainWidth(d))
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
  -- Above the dispel borders (OVERLAY sublevel 0).
  local texture = parent:CreateTexture(nil, "OVERLAY", nil, 7)
  texture:SetPoint("CENTER")
  -- Normal blending, as Blizzard draws it (ActionButtonSpellAlerts.xml). ADD
  -- would brighten the faint edge pixels into a visible square and mix in the
  -- icon's color underneath.
  texture:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
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
local function StyleGlow(texture, d)
  local scale = GlowScale(d)
  local ok = pcall(texture.SetSize, texture, d.size * scale, d.size * scale)
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
-- The same rules for plain strips: PreserveAsset keeps our white texture and
-- only colors it for the dispel type (AuraUtil.SetAuraBorderColor).
local PRESERVE = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset
local PLAIN_OPTIONS = {
  { style = PRESERVE, showWhenHarmful = true, showWhenHelpful = false, showWithoutDispelType = true },
  { style = PRESERVE, showWhenHarmful = false, showWhenHelpful = true },
}

-- Applies the display's look to one button's parts. Out of combat only.
-- Returns false if Blizzard refused part of it.
local function StyleButton(part, d)
  local ok = pcall(part.button.SetSize, part.button, d.size, d.size)
  -- Per button, not per container: displays sharing a line can differ.
  ok = pcall(part.button.SetAlpha, part.button, d.alpha) and ok
  StyleIcon(part.icon, d)
  -- CooldownFrameTemplate draws the remaining time as text over the swipe.
  ok = pcall(part.cooldown.SetHideCountdownNumbers, part.cooldown, d.hideTimer == true) and ok
  -- The engine's default countdown font is sized for action buttons and
  -- covers small icons. Keep its face and outline, use the display's size.
  local text = part.cooldown:GetCountdownFontString()
  if text then
    if not part.timerFont then
      part.timerFont = { text:GetFont() }
    end
    local face, _, flags = unpack(part.timerFont)
    if face then
      ok = pcall(text.SetFont, text, face, d.timerSize, flags) and ok
    end
  end
  local dispel = d.dispelBorder == true and not CustomBorder(d)
  local wanted = dispel and not Plain(d)
  StyleCustomBorder(part.customBorder, d)
  local wantedPlain = dispel and Plain(d)
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

  -- Addon code can't animate inside an aura button, so the glow is handed to
  -- the button and Blizzard plays it whenever the button shows an aura
  -- (ApplyVisibility, Blizzard_CustomAuraButton.lua). Registered, its
  -- animation can't change, but it can be removed and added again.
  ok = StyleGlow(part.glow, d) and ok
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
-- display (a reorder rebinds slots, see Chain.SetDisplays) and the current
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

    local borders = {}
    for i = 1, #BORDER_OPTIONS do
      borders[i] = overlay:CreateTexture(nil, "OVERLAY")
      borders[i]:SetPoint("CENTER")
    end

    local plainBorders = {}
    for i = 1, #PLAIN_OPTIONS do
      plainBorders[i] = NewStrips(overlay, button)
    end
    local customBorder = NewCustomBorder(overlay, button)
    local glow, glowAnim = NewGlow(overlay)

    local part = {
      button = button, icon = icon, cooldown = cooldown, borders = borders, borderOn = false, customBorder = customBorder,
      plainBorders = plainBorders, plainOn = false,
      glow = glow, glowAnim = glowAnim, glowOn = false, inst = inst,
    }
    table.insert(parts, part)
    StyleButton(part, inst.displays[j])
  end
end

-- An aura group's options for display `d`. Each slot is the icon plus its
-- spacing plus 1px along the line, and the icon plus the line spacing plus
-- 1px across it. Slots overlap by 1px (elementSpacing -1, which also carries
-- across groups in one container), so n auras measure n * (slot - 1) + 1: the
-- 1px an empty container has, plus exactly one slot per aura. Link and the
-- line stacking cancel that 1px. `half`: a shadow's half-length slots.
local function GroupOptions(d, g, lineSpacing, half, maxCount, init)
  local length = half and (d.size + d.spacing) / 2 + 1 or d.size + d.spacing + 1
  local width, height = Slot(g, length, d.size + lineSpacing + 1)
  return {
    maxFrameCount = maxCount or d.max,
    candidateFilters = Candidates(d),
    sortMethod = AuraContainerSortMethod[d.sort] or AuraContainerSortMethod.Default,
    sortDirection = d.sortReverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal,
    layout = { elementWidth = width, elementHeight = height, elementSpacing = -1 },
    initializeFrame = init or MeasureOnly(width, height),
  }
end

-- `placeholder`: what it's anchored to until Link places it, if not `parent`.
local function NewContainer(parent, unit, g, placeholder)
  -- Frames anchored to an aura container must opt out of untrusted layout
  -- scripts, and every container here is anchored to another one.
  local container = CreateFrame("AuraContainer", nil, parent,
    "CustomAuraContainerTemplate, DisableUntrustedLayoutScriptsTemplate")
  container:Hide()
  container:SetPoint(g.start, placeholder or parent, g.start)
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

-- The missing icon's window: the icon's slot plus room for its glow on every
-- side. Fixed in size; Link places it.
local function WindowSize(d)
  return d.size + 2 * GlowPad(d)
end

-- The slide container's one slot along the line: a step longer than the
-- window, so the icon and glow leave it entirely when the aura shows up.
local function SlideOptions(d, g)
  local options = GroupOptions(d, g, 0, false, 1)
  local width, height = Slot(g, WindowSize(d) + 1, 1)
  options.layout = { elementWidth = width, elementHeight = height, elementSpacing = -1 }
  options.initializeFrame = MeasureOnly(width, height)
  return options
end

-- The missing icon's look, which is all ours: no Blizzard restrictions.
local function StyleMissing(inst)
  local d, icon = inst.display, inst.missingIcon
  inst.window:SetAlpha(d.alpha)
  local size = WindowSize(d)
  inst.window:SetSize(size, size)
  inst.holder:SetSize(d.size, d.size)
  local ids = Chain.SpellIDs(d)
  local source = d.icon or (ids and next(ids)) -- an included ID
  icon:SetTexture(type(source) == "number" and C_Spell.GetSpellTexture(source) or source)
  StyleIcon(icon, d)
  StyleCustomBorder(inst.customBorder, d)
  StyleGlow(inst.glow, d)
  -- Ours to play. It keeps looping while the icon is slid out of sight.
  ShowGlow(inst.glow, inst.glowAnim, inst.active and GlowNow(d))
  ApplyRange(inst.glow, d, inst.inRange)
end

-- A capped line shows only its first `cap` slots: the container sits in a
-- clip window anchored to its own start. Empty displays collapse, so those
-- slots hold the first displays that have auras. The window is sized for the
-- line's biggest icon, so a capped line wants one icon size. It reaches a
-- fifth of an icon past the icons for borders and glows (dispel border: a
-- sixth, glow: a fifth), but on the far side only as far as the spacing allows
-- without showing the next icon or its border.
local function StyleCap(inst, g, cap)
  local size = 0
  for _, d in ipairs(inst.displays) do
    size = math.max(size, d.size)
  end
  local spacing = inst.displays[1].spacing
  local reach = math.ceil(size / 5)
  local farReach = math.max(0, math.min(reach, spacing - reach))
  local width, height = Slot(g, reach + cap * (size + spacing) - spacing + farReach, size + 2 * reach)
  inst.capWindow:SetSize(width, height)
  inst.capWindow:ClearAllPoints()
  Anchor(inst.capWindow, g.start, inst.main, g.start, -(g.dx + g.cx) * reach, -(g.dy + g.cy) * reach)
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

-- One line's list displays, for one unit: a container with an aura group per
-- display (keys d1, d2, ... in line order), hidden. `label` names its frames
-- in /fstack, e.g. "MyDebuffs line 1". `cap`: show only that many icons (not
-- for centered lines, whose shadow would measure the whole line). `plate`:
-- the line is on a nameplate host.
function Chain.NewList(parent, unit, displays, g, lineSpacing, label, cap, plate)
  local inst = { displays = displays, parts = {}, on = {}, inRange = true, plate = plate }
  if cap and not g.shadow then
    inst.capWindow = CreateFrame("Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
    Name(inst.capWindow, label .. " (cap)")
    inst.capWindow:SetClipsChildren(true)
    inst.capWindow:Hide()
    -- The window is anchored to the container, so the container's own
    -- placeholder can't be the window.
    inst.main = NewContainer(inst.capWindow, unit, g, parent)
  else
    inst.main = NewContainer(parent, unit, g)
  end
  Name(inst.main, label)
  for j, d in ipairs(displays) do
    inst.parts[j] = {}
    inst.main:AddAuraGroup(Key(j), FilterFor(inst, d), GroupOptions(d, g, lineSpacing, false, nil, StyledButton(inst, j, inst.parts[j])))
  end
  if g.shadow then
    inst.shadow = NewContainer(parent, unit, g.shadow)
    Name(inst.shadow, label .. " (shadow)")
    for j, d in ipairs(displays) do
      inst.shadow:AddAuraGroup(Key(j), FilterFor(inst, d), GroupOptions(d, g.shadow, lineSpacing, true))
    end
  end
  if inst.capWindow then
    StyleCap(inst, g, cap)
  end
  return inst
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
function Chain.NewMissing(parent, unit, d, g, lineSpacing, label, plate)
  local inst = { display = d, displays = { d }, inRange = true, plate = plate }
  inst.main = NewContainer(parent, unit, g)
  Name(inst.main, label .. " (presence)")
  inst.main:AddAuraGroup(Key(1), FilterFor(inst, d), GroupOptions(d, g, lineSpacing, false, 1))

  inst.slide = NewContainer(parent, unit, g)
  Name(inst.slide, label .. " (slide)")
  inst.slide:AddAuraGroup(Key(1), FilterFor(inst, d), SlideOptions(d, g))

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
  StyleMissing(inst)

  if g.shadow then
    inst.shadow = NewContainer(parent, unit, g.shadow)
    Name(inst.shadow, label .. " (shadow)")
    inst.shadow:AddAuraGroup(Key(1), FilterFor(inst, d), GroupOptions(d, g.shadow, lineSpacing, true, 1))
  end
  return inst
end

-- Loss of control --------------------------------------------------------------
-- A display fed by C_LossOfControl instead of an aura container: the player's
-- current loss of control (stun, fear, silence, school lockout...), with the
-- game's text for it ("Stunned"). GetActiveLossOfControlData has no secret
-- tags for the player (LossOfControlDocumentation.lua); for other units it's
-- secret (SecretWhenLossOfControlInfoRestricted), so this only shows on
-- "player". Lua knows when it shows, so it joins a line like any display that
-- a condition turns on and off.

-- The checkboxes: each hides these locTypes. Types not listed always show.
Chain.LOC_TYPES = {
  { key = "stun", label = "Stun", types = { STUN = true, STUN_MECHANIC = true } },
  { key = "fear", label = "Fear", types = { FEAR = true, FEAR_MECHANIC = true } },
  { key = "confuse", label = "Incapacitate", types = { CONFUSE = true } },
  { key = "charm", label = "Charm", types = { CHARM = true, POSSESS = true } },
  { key = "silence", label = "Silence", types = { SILENCE = true, PACIFYSILENCE = true } },
  { key = "pacify", label = "Pacify", types = { PACIFY = true } },
  { key = "disarm", label = "Disarm", types = { DISARM = true } },
  { key = "root", label = "Root", types = { ROOT = true } },
  { key = "interrupt", label = "Interrupted (school lockout)", types = { SCHOOL_INTERRUPT = true } },
}

local function LocHidden(d, locType)
  for _, key in ipairs(d.locHide or {}) do
    for _, entry in ipairs(Chain.LOC_TYPES) do
      if entry.key == key and entry.types[locType] then
        return true
      end
    end
  end
  return false
end

-- The first active entry (index 1 is the one the game ranks highest) that
-- the display doesn't hide and the game means to show with a timer.
local function LocEntry(d)
  for i = 1, C_LossOfControl.GetActiveLossOfControlDataCount() do
    local data = C_LossOfControl.GetActiveLossOfControlData(i)
    if data and data.displayText and data.startTime and not LocHidden(d, data.locType) then
      return data
    end
  end
end

-- Dispel-type borders for loss of control. The aura behind an entry is known
-- (auraInstanceID), but its dispel type is secret in combat, so it can't pick
-- a texture in Lua. C_UnitAuras.GetAuraDispelTypeColor maps the type through a
-- color curve instead (x: dispel type ID; 0 none, 1 Magic, 2 Curse, 3 Disease,
-- 4 Poison), and the secret color goes to SetVertexColor. Each of Blizzard's
-- border atlases gets a curve that's opaque only at its own type, so exactly
-- one shows. Other IDs (Bleed's isn't known) get the red typeless border.
local LOC_BORDERS = {
  { atlas = "ui-debuff-border-default-noicon", ids = { [0] = true, [5] = true } },
  { atlas = "ui-debuff-border-magic-noicon", ids = { [1] = true } },
  { atlas = "ui-debuff-border-curse-noicon", ids = { [2] = true } },
  { atlas = "ui-debuff-border-disease-noicon", ids = { [3] = true } },
  { atlas = "ui-debuff-border-poison-noicon", ids = { [4] = true } },
}
for _, border in ipairs(LOC_BORDERS) do
  border.curve = C_CurveUtil.CreateColorCurve()
  border.curve:SetType(Enum.LuaCurveType.Step) -- the point at 5 holds for every higher ID
  for id = 0, 5 do
    border.curve:AddPoint(id, CreateColor(1, 1, 1, border.ids[id] and 1 or 0))
  end
end

-- A plain border takes the type's color itself, through one curve.
local LOC_PLAIN_CURVE = C_CurveUtil.CreateColorCurve()
LOC_PLAIN_CURVE:SetType(Enum.LuaCurveType.Step)
for id, name in pairs({ [0] = "None", "Magic", "Curse", "Disease", "Poison", "None" }) do
  LOC_PLAIN_CURVE:AddPoint(id, AuraUtil.GetAuraBorderColor(name))
end

-- Shows the border for the aura behind `data`, or none (no aura: a school
-- lockout; or borders turned off).
local function LocBorders(inst, data)
  local d = inst.display
  local id = d.dispelBorder and not CustomBorder(d) and data and data.auraInstanceID
  local plain = Plain(d)
  local ok, color = false, nil
  if id and plain then
    ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, "player", id, LOC_PLAIN_CURVE)
  end
  if ok and color then
    ShowStrips(inst.plainStrips, true, color:GetRGBA())
  else
    ShowStrips(inst.plainStrips, false)
  end
  for i, texture in ipairs(inst.borders) do
    ok, color = false, nil
    if id and not plain then
      ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, "player", id, LOC_BORDERS[i].curve)
    end
    if ok and color then
      texture:SetVertexColor(color:GetRGBA())
      texture:Show()
    else
      texture:Hide()
    end
  end
end

local function StyleLoc(inst)
  local d = inst.display
  inst.frame:SetAlpha(d.alpha)
  inst.icon:SetSize(d.size, d.size)
  for _, texture in ipairs(inst.borders) do
    texture:SetSize(d.size * BORDER_SIZE, d.size * BORDER_SIZE)
  end
  PlaceStrips(inst.plainStrips, PlainWidth(d))
  if not d.dispelBorder or CustomBorder(d) then
    LocBorders(inst, nil)
  end
  StyleCustomBorder(inst.customBorder, d)
  inst.shownSpell = nil -- the next update redraws, borders included
  StyleIcon(inst.icon, d)
  inst.cooldown:SetHideCountdownNumbers(d.hideTimer == true)
  local text = inst.cooldown:GetCountdownFontString()
  if text then
    inst.timerFont = inst.timerFont or { text:GetFont() }
    local face, _, flags = unpack(inst.timerFont)
    if face then
      pcall(text.SetFont, text, face, d.timerSize, flags)
    end
  end
  local face, _, flags = inst.label:GetFont()
  if face then
    inst.label:SetFont(face, d.labelSize, flags)
  end
end

function Chain.NewLoc(parent, unit, d, g, label)
  local inst = { display = d, displays = { d }, loc = true, unit = unit }
  -- Anchored after aura containers, hence the template.
  inst.frame = CreateFrame("Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
  Name(inst.frame, label .. " (loss of control)")
  inst.frame:Hide()
  inst.icon = inst.frame:CreateTexture(nil, "ARTWORK")
  inst.icon:SetPoint(g.start, inst.frame, g.start)
  inst.cooldown = CreateFrame("Cooldown", nil, inst.frame, "CooldownFrameTemplate")
  inst.cooldown:SetAllPoints(inst.icon)
  inst.cooldown:SetDrawEdge(false)
  inst.cooldown:SetReverse(true)
  -- The game's text for it, under the icon. It takes no room in the line.
  inst.label = inst.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  inst.label:SetPoint("TOP", inst.icon, "BOTTOM", 0, -2)
  -- Borders on a frame above the cooldown, whose swipe would cover them.
  local overlay = CreateFrame("Frame", nil, inst.frame)
  overlay:SetAllPoints()
  overlay:SetFrameLevel(inst.cooldown:GetFrameLevel() + 1)
  inst.customBorder = NewCustomBorder(overlay, inst.icon)
  inst.plainStrips = NewStrips(overlay, inst.icon)
  inst.borders = {}
  for i, border in ipairs(LOC_BORDERS) do
    local texture = overlay:CreateTexture(nil, "OVERLAY")
    texture:SetPoint("CENTER", inst.icon, "CENTER")
    texture:SetAtlas(border.atlas)
    texture:Hide()
    inst.borders[i] = texture
  end
  StyleLoc(inst)
  return inst
end

-- Refreshes the icon, timer and text from the game. Returns whether there's
-- anything to show and, when the entry is new, its seconds remaining.
function Chain.UpdateLoc(inst)
  local data = inst.unit == "player" and LocEntry(inst.display)
  if not data then
    inst.shownSpell, inst.shownStart = nil, nil
    return false
  end
  local new = data.spellID ~= inst.shownSpell or data.startTime ~= inst.shownStart
  if new then
    inst.shownSpell, inst.shownStart = data.spellID, data.startTime
    inst.icon:SetTexture(data.iconTexture)
    CooldownFrame_Set(inst.cooldown, data.startTime, data.duration, true)
    local text = data.displayText
    if data.locType == "SCHOOL_INTERRUPT" and data.lockoutSchool and data.lockoutSchool ~= 0 then
      text = LOSS_OF_CONTROL_DISPLAY_INTERRUPT_SCHOOL:format(C_Spell.GetSchoolString(data.lockoutSchool))
    end
    inst.label:SetText(text)
    LocBorders(inst, data)
  end
  return true, new and data.timeRemaining or nil
end

-- `optionsFor(d)` gives each display's aura group options.
local function Reconfigure(container, inst, optionsFor)
  for j, d in ipairs(inst.displays) do
    local key, options = Key(j), optionsFor(d)
    container:SetAuraGroupFilterString(key, FilterFor(inst, d))
    container:SetAuraGroupCandidateFilters(key, options.candidateFilters)
    container:SetAuraGroupSortMethod(key, options.sortMethod, options.sortDirection)
    container:SetAuraGroupMaxFrameCount(key, options.maxFrameCount)
    container:SetAuraGroupLayout(key, options.layout)
  end
end

-- Applies the current settings to existing containers and buttons, for the
-- editor. Out of combat only: containers refuse while auras are secret.
-- Changing mode, growth, line direction, line breaks or whether lines are
-- capped needs a new line; `cap` (the number) can change here.
-- Returns false if Blizzard refused part of the restyle.
function Chain.Configure(inst, g, lineSpacing, cap)
  if inst.loc then
    StyleLoc(inst)
    return true
  end
  local maxCount = inst.window and 1 or nil
  if inst.capWindow and cap then
    StyleCap(inst, g, cap)
  end
  Reconfigure(inst.main, inst, function(d) return GroupOptions(d, g, lineSpacing, false, maxCount) end)
  if inst.shadow then
    Reconfigure(inst.shadow, inst, function(d) return GroupOptions(d, g.shadow, lineSpacing, true, maxCount) end)
  end
  if inst.window then
    Reconfigure(inst.slide, inst, function(d) return SlideOptions(d, g) end)
    StyleMissing(inst)
    return true
  end
  local ok = true
  for j, d in ipairs(inst.displays) do
    for _, part in ipairs(inst.parts[j]) do
      ok = StyleButton(part, d) and ok
    end
  end
  return ok
end

-- Places a line's container (or its shadow) at `from` ({ frame, point, x, y })
-- and returns where the next one starts.
function Chain.Link(inst, from, g, shadow)
  if inst.loc then
    -- Only placed while it shows, so it simply takes one slot. In the
    -- shadow pass it adds half a slot to the measured half line.
    local d = inst.display
    local length = shadow and (d.size + d.spacing) / 2 or d.size + d.spacing
    if not shadow then
      inst.frame:ClearAllPoints()
      Anchor(inst.frame, g.start, from.frame, from.point, from.x, from.y)
      local width, height = Slot(g, length, d.size)
      inst.frame:SetSize(width, height)
    end
    return { frame = from.frame, point = from.point, x = from.x + g.dx * length, y = from.y + g.dy * length }
  end

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
      local pad = GlowPad(d)
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
  if inst.loc then
    inst.frame:SetShown(active)
    return
  end
  Toggle(inst.main, active)
  Toggle(inst.shadow, active)
  if inst.capWindow then
    inst.capWindow:SetShown(active)
  end
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
  if inst.loc then
    return
  end
  if inst.window then
    ApplyRange(inst.glow, inst.display, inRange)
    return
  end
  for j, d in ipairs(inst.displays) do
    for _, part in ipairs(inst.parts[j]) do
      ApplyRange(part.glow, d, inRange)
    end
  end
end

-- After SetCombat. Only glows that depend on combat are touched; restarting
-- the rest would make every glow skip.
function Chain.UpdateCombatGlows(inst)
  if inst.loc then
    return
  end
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
        ShowGlow(part.glow, part.glowAnim, part.glowOn and GlowNow(d))
      end
    end
  end
end

-- Turns one display's aura group on or off within its line. The flow layout
-- closes the gap. Works in combat.
function Chain.SetDisplayActive(inst, j, active)
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
  local count = 0
  for _ in pairs({ Containers(inst) }) do
    count = count + 1
  end
  return count
end

-- Points an instance at reordered display tables of the same shape (same
-- modes, same lines), so a reorder needs no new containers. Configure then
-- pushes each slot's new settings.
function Chain.SetDisplays(inst, displays)
  for j, d in ipairs(displays) do
    inst.displays[j] = d
  end
  if inst.display then
    inst.display = displays[1]
  end
end

-- Containers don't notice when a token like "target" or "party1" starts
-- meaning someone else. Call this when it does.
function Chain.Refresh(inst)
  for _, container in pairs({ Containers(inst) }) do
    container:UpdateAllAuras()
  end
end
