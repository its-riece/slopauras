-- Contract model: buttons become inaccessible immediately after initializeFrame.
-- Runs actual NewStack/Resize; substitutes frame creation and decorative styling.
-- This is not a simulation of Blizzard rendering or real secret values.
local ns = ...
local function Upvalue(fn, wanted, replacement)
  for i = 1, 100 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then
      if replacement then debug.setupvalue(fn, i, replacement) end
      return value, i
    end
  end
  error("Missing test dependency: " .. wanted)
end

local secret, refused = true, 0
local function Check(frame)
  if not frame.writable then
    refused = refused + 1
    error("modeled forbidden aura button")
  end
end
local function Container()
  local container = { frames = {} }
  function container:GetFrameLevel() return 10 end
  function container:SetParentKey() end
  function container:GetAuraSlotFrame(key) return self.frames[key] end
  function container:AddAuraSlot(key, filter, options)
    local frame = { writable = true }
    function frame:SetPoint(point, relative, relativePoint)
      Check(self)
      self.anchor = {point, relative, relativePoint}
    end
    function frame:SetFrameLevel(level)
      Check(self)
      self.level = level
    end
    self.frames[key] = frame
    options.initializeFrame(frame)
    frame.writable = not secret
  end
  return container
end
local function Style(inst, j)
  return function(frame)
    Check(frame)
    frame.levelAtStyle = frame.level
    frame.anchorAtStyle = frame.anchor
  end
end

local addSlot = Upvalue(ns.Chain.NewStack, "AddSlot")
local oldContainer, containerIndex = Upvalue(ns.Chain.NewStack, "NewContainer", Container)
local oldStyle, styleIndex = Upvalue(addSlot, "StyledButton", Style)
local oldActive = ns.Chain.SetDisplayActive
ns.Chain.SetDisplayActive = function(inst, j, active) inst.main.frames["d" .. j].active = active end
local ok, err = pcall(function()
  local displays = {{filter="HELPFUL"}, {filter="HELPFUL"}}
  local inst = ns.Chain.NewStack({}, "player", displays, {start="TOPLEFT"}, "test")
  assert(refused == 0, "Secret stack accessed a slot after initialization")
  assert(inst.main.frames.d1.level == 15 and inst.main.frames.d2.level == 11,
    "First slot must draw over the fallback")
  for _, frame in pairs(inst.main.frames) do
    assert(frame.anchor and frame.anchor[1] == "TOPLEFT" and frame.anchor[2] == inst.main,
      "Slot must be anchored during initialization")
    assert(frame.levelAtStyle == frame.level and frame.anchorAtStyle == frame.anchor,
      "Place and level the button before creating styled children")
  end
  -- Resize is used outside secrecy; newly added slots and existing slots agree.
  secret = false
  for _, frame in pairs(inst.main.frames) do frame.writable = true end
  ns.Chain.Resize(inst, {{filter="HELPFUL"}, {filter="HELPFUL"}, {filter="HELPFUL"}}, inst.g, 0)
  assert(inst.slots == 3)
  assert(inst.main.frames.d1.level == 19 and inst.main.frames.d2.level == 15
    and inst.main.frames.d3.level == 11, "Growing a stack must preserve priority")
  assert(inst.main.frames.d3.levelAtStyle == 11, "New slot initialized at final level")
  ns.Chain.Resize(inst, {{filter="HELPFUL"}}, inst.g, 0)
  assert(inst.slots == 3 and inst.main.frames.d2.active == false and inst.main.frames.d3.active == false,
    "Shrinking retains and disables spare slots")
end)
debug.setupvalue(ns.Chain.NewStack, containerIndex, oldContainer)
debug.setupvalue(addSlot, styleIndex, oldStyle)
ns.Chain.SetDisplayActive = oldActive
assert(ok, err)
