local _, ns = ...
local AceGUI = LibStub("AceGUI-3.0")
local window, selected, dragging, xInput, yInput, picker, undoButton, centerX, centerY
local handles, history, originals = {}, {}, {}
local snap, largeStep = true, false
local Refresh, Select, UpdateDrag

local function Offsets(group)
  local anchor = group.anchor or {}
  return anchor[4] or 0, anchor[5] or 0
end

local function Remember(group)
  if originals[group] == nil then
    originals[group] = rawget(group, "anchor") and CopyTable(group.anchor) or false
  end
  return { group = group, anchor = rawget(group, "anchor") and CopyTable(group.anchor) or false }
end

local function Restore(entry)
  if tContains(ns.groups, entry.group) then
    entry.group.anchor = entry.anchor and CopyTable(entry.anchor) or nil
  end
end

local function FinishDrag()
  if not dragging then
    return
  end
  if not ns.TestLocked() then
    UpdateDrag()
  end
  local drag = dragging
  dragging = nil
  local x, y = Offsets(drag.group)
  if x ~= drag.x or y ~= drag.y then
    table.insert(history, drag.before)
    ns.Changed(false)
  end
  Refresh()
end

local function Move(x, y)
  if not selected or ns.TestLocked() then
    return
  end
  FinishDrag()
  local before = Remember(selected)
  local oldX, oldY = Offsets(selected)
  ns.MoveLayoutGroup(selected, x, y)
  local newX, newY = Offsets(selected)
  if newX ~= oldX or newY ~= oldY then
    table.insert(history, before)
    ns.Changed(false)
  end
  Refresh()
end

local function Paint(handle)
  local active = handle.target.group == selected
  handle.fill:SetColorTexture(active and 0.1 or 0.04, active and 0.55 or 0.12, active and 0.7 or 0.18, 0.9)
end

function Select(group)
  FinishDrag()
  selected = group
  Refresh()
end

local function NewHandle()
  local handle = CreateFrame("Button", nil, UIParent, "DisableUntrustedLayoutScriptsTemplate")
  handle:SetSize(164, 26)
  handle:SetFrameStrata("DIALOG")
  handle:RegisterForDrag("LeftButton")
  handle.fill = handle:CreateTexture(nil, "BACKGROUND")
  handle.fill:SetAllPoints()
  local pin = handle:CreateTexture(nil, "OVERLAY")
  pin:SetColorTexture(1, 0.82, 0)
  pin:SetSize(6, 6)
  pin:SetPoint("CENTER", handle, "BOTTOMLEFT")
  handle.label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  handle.label:SetPoint("LEFT", 8, 0)
  handle.label:SetPoint("RIGHT", -5, 0)
  handle.label:SetJustifyH("LEFT")
  handle:SetScript("OnClick", function(self) Select(self.target.group) end)
  handle:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self.cursorX, self.cursorY = GetCursorPosition()
    end
  end)
  handle:SetScript("OnDragStart", function(self)
    if ns.TestLocked() then
      return
    end
    Select(self.target.group)
    local x, y = Offsets(selected)
    local cursorX, cursorY = GetCursorPosition()
    dragging = {
      group = selected, x = x, y = y, cursorX = self.cursorX or cursorX, cursorY = self.cursorY or cursorY,
      scale = self.target.origin:GetEffectiveScale(), before = Remember(selected),
    }
  end)
  handle:SetScript("OnDragStop", FinishDrag)
  return handle
end

function Refresh()
  if not window then
    return
  end
  local targets = ns.LayoutTargets()
  local values, order, available = {}, {}, {}
  for _, target in ipairs(targets) do
    local group = target.group
    if not available[group] then
      values[group.id] = group.name or ("Group " .. group.id)
      table.insert(order, group.id)
      available[group] = true
    end
  end
  if not available[selected] then
    selected = targets[1] and targets[1].group or nil
  end
  picker:SetList(values, order)
  picker:SetValue(selected and selected.id)
  picker:SetDisabled(not selected)
  local x, y = 0, 0
  if selected then
    x, y = Offsets(selected)
  end
  xInput:SetText(tostring(x))
  yInput:SetText(tostring(y))
  xInput:SetDisabled(not selected)
  yInput:SetDisabled(not selected)
  undoButton:SetDisabled(#history == 0)
  centerX:SetDisabled(not selected or selected.anchorTo ~= "screen")
  centerY:SetDisabled(not selected or selected.anchorTo ~= "screen")
  window:SetStatusText(selected and ("X: %d   Y: %d"):format(x, y) or "No preview anchors available")
  for i, target in ipairs(targets) do
    local handle = handles[i]
    if not handle then
      handle = NewHandle()
      handles[i] = handle
    end
    handle.target = target
    handle:SetParent(target.origin)
    handle:ClearAllPoints()
    handle:SetPoint("BOTTOMLEFT", target.origin, (target.group.anchor or {})[1] or "CENTER")
    handle.label:SetText((target.group.name or ("Group " .. target.group.id))
      .. (target.group.anchorTo == "unit" and (" · " .. (target.unit or "")) or ""))
    Paint(handle)
    handle:Show()
  end
  for i = #targets + 1, #handles do
    handles[i]:Hide()
    handles[i]:SetParent(UIParent)
    handles[i].target = nil
  end
end

-- Screen alignment uses the saved anchor point, not the aura row's bounds.
local function Center(axis)
  if not selected or selected.anchorTo ~= "screen" then
    return
  end
  local point = (selected.anchor or {})[3] or (selected.anchor or {})[1] or "CENTER"
  local factor = 0.5
  if axis == "x" then
    factor = point:find("LEFT") and 0 or point:find("RIGHT") and 1 or 0.5
  else
    factor = point:find("BOTTOM") and 0 or point:find("TOP") and 1 or 0.5
  end
  for _, target in ipairs(ns.LayoutTargets()) do
    if target.group == selected then
      local scale = UIParent:GetEffectiveScale() / target.origin:GetEffectiveScale()
      local x, y = Offsets(selected)
      if axis == "x" then
        x = UIParent:GetWidth() * (0.5 - factor) * scale
      else
        y = UIParent:GetHeight() * (0.5 - factor) * scale
      end
      Move(x, y)
      return
    end
  end
end

function ns.HideLayoutStudio()
  if not window then
    return
  end
  FinishDrag()
  local closing = window
  window = nil
  for _, handle in ipairs(handles) do
    handle:Hide()
    handle:SetParent(UIParent)
    handle.target = nil
  end
  wipe(history)
  wipe(originals)
  AceGUI:Release(closing)
end

local function Add(kind, label, width)
  local widget = AceGUI:Create(kind)
  if kind == "EditBox" or kind == "Dropdown" or kind == "CheckBox" then
    widget:SetLabel(label)
  else
    widget:SetText(label)
  end
  if width then
    widget:SetWidth(width)
  else
    widget:SetFullWidth(true)
  end
  window:AddChild(widget)
  return widget
end

local function Button(label, callback, width)
  local button = Add("Button", label, width)
  button:SetCallback("OnClick", callback)
  return button
end

function ns.ShowLayoutStudio()
  if ns.TestLocked() then
    return
  end
  if window then
    window:Show()
    Refresh()
    return
  end
  window = AceGUI:Create("Frame")
  window:SetTitle("Layout studio")
  window:SetStatusTable({ width = 420, height = 370, left = 30, top = UIParent:GetHeight() - 100 })
  window:EnableResize(false)
  window:SetLayout("Flow")
  window:SetCallback("OnClose", function()
    ns.HideLayoutStudio()
    ns.CloseTest()
  end)
  Add("Label", "Drag a label to move its group.\nThe gold pin marks the group's anchor.")
  picker = Add("Dropdown", "Group")
  picker:SetCallback("OnValueChanged", function(_, _, id)
    for _, group in ipairs(ns.groups) do
      if group.id == id then
        Select(group)
        return
      end
    end
  end)
  xInput = Add("EditBox", "X", 175)
  yInput = Add("EditBox", "Y", 175)
  xInput:SetCallback("OnEnterPressed", function(_, _, value)
    local x = tonumber(value)
    if selected and x and x == x and math.abs(x) < math.huge then
      local _, y = Offsets(selected)
      Move(x, y)
    end
    Refresh()
  end)
  yInput:SetCallback("OnEnterPressed", function(_, _, value)
    local y = tonumber(value)
    if selected and y and y == y and math.abs(y) < math.huge then
      local x = Offsets(selected)
      Move(x, y)
    end
    Refresh()
  end)
  local function Nudge(dx, dy)
    return function()
      if selected then
        local x, y = Offsets(selected)
        local step = largeStep and 10 or 1
        Move(x + dx * step, y + dy * step)
      end
    end
  end
  Button("Left", Nudge(-1, 0), 85)
  Button("Right", Nudge(1, 0), 85)
  Button("Down", Nudge(0, -1), 85)
  Button("Up", Nudge(0, 1), 85)
  local steps = Add("CheckBox", "Move 10 at a time")
  steps:SetValue(largeStep)
  steps:SetCallback("OnValueChanged", function(_, _, value) largeStep = value end)
  local snapping = Add("CheckBox", "Snap dragged offsets to 8")
  snapping:SetValue(snap)
  snapping:SetCallback("OnValueChanged", function(_, _, value) snap = value end)
  centerX = Button("Center anchor X", function() Center("x") end, 175)
  centerY = Button("Center anchor Y", function() Center("y") end, 175)
  undoButton = Button("Undo", function()
    FinishDrag()
    local entry = table.remove(history)
    if entry then
      Restore(entry)
      ns.Changed(false)
      Refresh()
    end
  end, 175)
  Button("Revert positions", function()
    FinishDrag()
    for group, anchor in pairs(originals) do
      Restore({ group = group, anchor = anchor })
    end
    wipe(history)
    ns.Changed(false)
    Refresh()
  end, 175)
  Add("Label", "Changes save as you move.\nClose keeps positions and ends the preview.")
  Refresh()
end

function UpdateDrag()
  if dragging then
    local x, y = GetCursorPosition()
    x = dragging.x + (x - dragging.cursorX) / dragging.scale
    y = dragging.y + (y - dragging.cursorY) / dragging.scale
    if snap then
      x, y = math.floor(x / 8 + 0.5) * 8, math.floor(y / 8 + 0.5) * 8
    end
    ns.MoveLayoutGroup(dragging.group, x, y)
    local offsetX, offsetY = Offsets(dragging.group)
    xInput:SetText(tostring(offsetX))
    yInput:SetText(tostring(offsetY))
  end
end

local watcher = CreateFrame("Frame")
watcher:SetScript("OnUpdate", function()
  if not window then
    return
  end
  if ns.TestLocked() then
    ns.HideLayoutStudio()
    ns.CloseTest()
    return
  end
  UpdateDrag()
end)

SlopAuras:RegisterCallback("GroupsChanged", function() Refresh() end)
