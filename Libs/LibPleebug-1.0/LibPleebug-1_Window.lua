
-- File: LibPleebug-1_Window.lua
-- Purpose: Standalone dev window for debugger reports (expandable tree).



-- === BLOCK: MemDebugWindow - Setup Starts ===
local LibStub = _G.LibStub
local Pleebug = LibStub and LibStub("LibPleebug-1", true)
if not Pleebug then return end

-- Backwards-compatible alias (rest of file can keep using MemDebug)
local MemDebug = Pleebug

local W = MemDebug.Window or {}
MemDebug.Window = W


local _wipe = _G.wipe or (table and table.wipe) or function(t)
  if not t then return end
  for k in pairs(t) do
    t[k] = nil
  end
end



W.frame = W.frame or nil
W.rows = W.rows or {}
W.expanded = W.expanded or {}
-- UI tuning (dev window only)
W.uiScale = W.uiScale or 1.25     -- increase for readability/clicking
W.fontSize = W.fontSize or (MemDebug.GetFontSize and MemDebug:GetFontSize()) or 14
W.titleFontSize = W.titleFontSize or 18
local function _nowPrecise()
  if GetTimePreciseSec then
    return GetTimePreciseSec()
  end
  return (GetTime and GetTime()) or 0
end

-- Graph/timeline trace wrappers were removed.
-- Keep a simple sequence bump wrapper so the stats list still refreshes on new data.
if not W._statsWrapped then
  W._statsWrapped = true

  local origTrackEvent = MemDebug.TrackEvent
  if type(origTrackEvent) == "function" then
    MemDebug.TrackEvent = function(self, moduleName, eventName, ...)
      origTrackEvent(self, moduleName, eventName, ...)
      W._traceSeq = (W._traceSeq or 0) + 1
    end
  end

  local origTrackFunc = MemDebug.TrackFunc
  if type(origTrackFunc) == "function" then
    MemDebug.TrackFunc = function(self, moduleName, bucketName, funcName, ...)
      origTrackFunc(self, moduleName, bucketName, funcName, ...)
      W._traceSeq = (W._traceSeq or 0) + 1
    end
  end
end



-- Hard rule for this dev window:
-- No host-theme dependencies. Library provides a small internal palette.
local function _getPalette()
  -- Defaults: square, dark, readable, accent highlight
  local accent = { 0.20, 0.60, 1.00, 1.00 }
  local border = { 0.20, 0.20, 0.20, 1.00 }
  local text   = { 1.00, 1.00, 1.00, 1.00 }
  local bgWin  = { 0.00, 0.00, 0.00, 0.88 }
  local bgPane = { 0.00, 0.00, 0.00, 0.35 }

  if MemDebug and type(MemDebug.GetThemeColors) == "function" then
    local a, b, t, w, p = MemDebug:GetThemeColors()
    if type(a) == "table" then accent = a end
    if type(b) == "table" then border = b end
    if type(t) == "table" then text = t end
    if type(w) == "table" then bgWin = w end
    if type(p) == "table" then bgPane = p end
  end

  return accent, border, text, bgWin, bgPane
end

local function _applyFontSafe(fs, size, flags)
  if not fs or not fs.SetFont then return end
  size = tonumber(size) or 12
  size = math.floor(size * (W.uiScale or 1) + 0.5)
  flags = flags or ""

  local path = fs.GetFont and select(1, fs:GetFont()) or nil
  if not path or path == "" then
    path = (STANDARD_TEXT_FONT and STANDARD_TEXT_FONT ~= "" and STANDARD_TEXT_FONT) or "Fonts\\FRIZQT__.TTF"
  end
  fs:SetFont(path, size, flags)
end

local function _colorText(fs)
  if not fs or not fs.SetTextColor then return end
  local _, _, t = _getPalette()
  fs:SetTextColor(t[1], t[2], t[3], t[4] or 1)
end


local function _buildTreeFromSnapshot(snapshot)
  local root = { name = "root", path = "", count = 0, children = {} }

  local function ensureChild(node, name, path)
    node.children[name] = node.children[name] or { name = name, path = path, count = 0, children = {} }
    return node.children[name]
  end

  local function addPath(key, value)
    if type(key) ~= "string" or key == "" or key:match("^__") then
      return
    end

    value = tonumber(value) or 0
    if value > 0 then
      root.count = root.count + value
    end

    local node = root
    local path = ""
    for part in key:gmatch("[^%.]+") do
      path = (path == "" and part) or (path .. "." .. part)
      node = ensureChild(node, part, path)
      node.count = (node.count or 0) + value
    end
  end

  for key, v in pairs(snapshot or {}) do
    if type(v) == "number" and v > 0 then
      addPath(key, v)
    end
  end

  -- Native mode has no wrappers, so registered functions may have zero calls in the
  -- current interval. Still show them, otherwise the stats window looks unregistered.
  local cpu = MemDebug and MemDebug.CPU
  local funcs = cpu and cpu._nativeFuncs
  if type(funcs) == "table" then
    for path in pairs(funcs) do
      addPath("Funcs." .. tostring(path), snapshot and snapshot["Funcs." .. tostring(path)] or 0)
    end
  end

  local events = cpu and cpu._nativeEvents
  if type(events) == "table" then
    for eventName in pairs(events) do
      local key = "Events.Global." .. tostring(eventName)
      addPath(key, snapshot and snapshot[key] or 0)
    end
  end

  return root
end

local function _sortedChildList(node)
  local list = {}
  for _, child in pairs(node.children or {}) do
    list[#list + 1] = child
  end
  table.sort(list, function(a, b)
    if a.count == b.count then
      return a.name < b.name
    end
    return a.count > b.count
  end)
  return list
end

local function _flatten(node, out, depth, expanded)
  depth = depth or 0
  out = out or {}

  if node.path ~= "" then
    out[#out + 1] = { node = node, depth = depth }
  end

  local hasChildren = node.children and next(node.children) ~= nil
  if not hasChildren then
    return out
  end

  if node.path == "" or expanded[node.path] then
    local kids = _sortedChildList(node)
    for i = 1, #kids do
      _flatten(kids[i], out, depth + 1, expanded)
    end
  end

  return out
end

---------------------------
-- Deferred tree building (prevents /pleebug freeze on large snapshots)
---------------------------
W._buildInProgress = W._buildInProgress or false
W._buildIterKey = W._buildIterKey or nil
W._buildRoot = W._buildRoot or nil
W._pendingSnapshot = W._pendingSnapshot or nil
W._pendingInterval = W._pendingInterval or nil
W._pendingEnabled = W._pendingEnabled or nil
W._pendingLiveMode = W._pendingLiveMode or nil

W._flat = W._flat or {}
W._flatBuiltFor = W._flatBuiltFor or nil
W._lastRenderAt = W._lastRenderAt or 0
W._lastTimelineAt = W._lastTimelineAt or 0

local function _treeEnsureChild(node, name, path)
  node.children[name] = node.children[name] or { name = name, path = path, count = 0, children = {} }
  return node.children[name]
end

local function _treeAddPath(root, key, value)
  if type(root) ~= "table" or type(key) ~= "string" or key == "" or key:match("^__") then
    return
  end

  value = tonumber(value) or 0
  if value <= 0 then
    return
  end

  root.count = (root.count or 0) + value

  local node = root
  local path = ""
  for part in key:gmatch("[^%.]+") do
    path = (path == "" and part) or (path .. "." .. part)
    node = _treeEnsureChild(node, part, path)
    node.count = (node.count or 0) + value
  end
end

local function _treeAddNativeRegisteredRows(root, snapshot)
  local cpu = MemDebug and MemDebug.CPU

  local funcs = cpu and cpu._nativeFuncs
  if type(funcs) == "table" then
    for path in pairs(funcs) do
      local key = "Funcs." .. tostring(path)
      _treeAddPath(root, key, snapshot and snapshot[key] or 0)
    end
  end

  local events = cpu and cpu._nativeEvents
  if type(events) == "table" then
    for eventName in pairs(events) do
      local key = "Events.Global." .. tostring(eventName)
      _treeAddPath(root, key, snapshot and snapshot[key] or 0)
    end
  end
end

-- Safe deferral: never use C_Timer.After(0) (can spinlock WoW)
local function _Defer(fn)
  if not fn then return end
  C_Timer.After(0.01, fn)
end


function W:_StartDeferredBuild(snapshot)
  self._pendingSnapshot = snapshot or {}
  self._buildRoot = { name = "root", path = "", count = 0, children = {} }
  self._buildIterKey = nil
  self._buildInProgress = true

  if self.frame and self.frame._statusText then
    self.frame._statusText:SetText("Status: Building tree...")
  end

  if C_Timer and C_Timer.After then
    _Defer(function()
      if W and W._BuildDeferredStep then
        W:_BuildDeferredStep()
      end
    end)
  else
    self:_BuildDeferredStep()
  end
end

function W:_BuildDeferredStep()
  if not self._buildInProgress then return end
  local snap = self._pendingSnapshot
  if type(snap) ~= "table" then
    self._buildInProgress = false
    return
  end

  local root = self._buildRoot
  if not root then
    self._buildInProgress = false
    return
  end

  local startMs = (debugprofilestop and debugprofilestop()) or nil
  local budgetMs = 6

  while true do
    local k, v = next(snap, self._buildIterKey)
    if not k then
      -- Done. Do not merge registered native rows here.
      -- The stats tree should only show paths with real calls in the active snapshot.
      self._buildInProgress = false
      self._flat = _flatten(root, {}, 0, self.expanded or {})
      self._flatBuiltFor = snap

      -- Render immediately once build finishes
      self:_RenderFlat()
      return
    end

    self._buildIterKey = k

    if type(v) == "number" and v > 0 and type(k) == "string" and not k:match("^__")
      and k ~= "Funcs.Total" and k ~= "Events.Total"
    then
      _treeAddPath(root, k, v)
    end

    if startMs and (debugprofilestop() - startMs) >= budgetMs then
      break
    end
  end

  if C_Timer and C_Timer.After then
    _Defer(function()
      if W and W._BuildDeferredStep then
        W:_BuildDeferredStep()
      end
    end)
  end
end

local _ensureRow

function W:_RenderFlat()

  local f = self.frame
  if not f or not f:IsShown() then return end

  local flat = self._flat or {}
  local interval = self._pendingInterval or (MemDebug.GetInterval and MemDebug:GetInterval()) or 10

  -- Row cap safety (UI only)
  local MAX_ROWS = 600
  local nRows = #flat
  if nRows > MAX_ROWS then
    nRows = MAX_ROWS
  end

  local parent = f._content
  if parent and parent.SetHeight then
    local rowH = W.rowHeight or 24
    parent:SetHeight((nRows + 1) * rowH)
  end

  local y = -2
  local rowH = W.rowHeight or 24

  for i = 1, nRows do
local entry = flat[i]
    local row = _ensureRow(i)
    row:Show()

    if row.BG then
      if (i % 2) == 0 then
        row.BG:SetColorTexture(0.10, 0.10, 0.10, 0.35)
      else
        row.BG:SetColorTexture(0.07, 0.07, 0.07, 0.25)
      end
    end


    if row.SetHeight then
      row:SetHeight(rowH)
    end
    if row.label then
      _applyFontSafe(row.label, W.fontSize or 14, nil)
      _colorText(row.label)
    end
    if row.value then
      _applyFontSafe(row.value, W.fontSize or 14, nil)
      _colorText(row.value)
    end
    if row.cpuValue then
      _applyFontSafe(row.cpuValue, W.fontSize or 14, nil)
      _colorText(row.cpuValue)
    end


    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)

    local node = entry.node
    local depth = entry.depth or 0

    local hasChildren = node.children and next(node.children) ~= nil
    local prefix = ""
    if hasChildren then
      prefix = (self.expanded[node.path] and "- " or "+ ")
    else
      prefix = "  "
    end

    local indent = string.rep("   ", math.max(0, depth - 1))
    local labelName = node.name


    local count = node.count or 0
    local rate = (interval and interval > 0) and (count / interval) or 0

    -- show cpu toggle only on function leaf rows:
    -- "Funcs.<Module>.<Func>" or "Funcs.<Module>.<Bucket>.<Func>"
    local partCount = 0
    if node.path then
      for _ in tostring(node.path):gmatch("[^%.]+") do
        partCount = partCount + 1
      end
    end

    local isFuncLeaf =
      node.path
      and tostring(node.path):match("^Funcs%.")
      and (partCount >= 3)
      and not (node.children and next(node.children))

    local isEventLeaf =
      node.path
      and tostring(node.path):match("^Events%.")
      and (partCount >= 3)
      and not (node.children and next(node.children))

    local cpu = MemDebug and MemDebug.CPU
    local statKey = nil
    local cpuPath = nil
    if isFuncLeaf and node.path then
      -- Window tree uses "Funcs.<Module>....", CPU uses "<Module>...." for per-function measuring
      cpuPath = tostring(node.path):gsub("^Funcs%.", "")
      statKey = cpuPath
    elseif isEventLeaf and node.path then
      -- Event stats are keyed exactly as the window tree path
      statKey = tostring(node.path)
    end

    -- Presets own measurement now:
    --   light = native CPU counters
    --   full  = wrapper CPU/mem debug stats for every P:Def call
    -- Keep the per-row measured-path checkbox hidden to avoid mixed states.
    if row.cpuToggle then
      row.cpuToggle:Hide()
    end

    -- Hot path flag: table churn
    if (isFuncLeaf or isEventLeaf) and cpu and cpu.GetStat and statKey then
      local st0 = cpu:GetStat(statKey)
      if st0 and st0.hotTables then
        labelName = "! " .. labelName
      end
    end

    row.label:SetText(prefix .. indent .. labelName)

    local baseText = string.format("%d (%.1f/s)", count, rate)
    row.value:SetText(baseText)

    local cpuText = ""
    local memText = ""

    if (isFuncLeaf or isEventLeaf) and cpu and cpu.GetStat and statKey then
      local st = cpu:GetStat(statKey)
      if st and st.n and st.n > 0 then
        local n = (st.n or 1)

        local avgMs = (st.timeSum or 0) / n
        local maxMs = st.timeMax or st.timeLast or 0

        cpuText = string.format("%.3f(%.3f)ms", avgMs, maxMs)

        if st.native ~= true then
          local avgMemKB = (st.memSum or 0) / n
          local maxMemKB = st.memMax or st.memLast or 0
          memText = string.format("%.1f(%.1f)kb", avgMemKB, maxMemKB)
        end

        -- Best-effort split: string vs table churn (debug mode only)
        if st.strOpsSum and st.tblOpsSum then
          local avgS = (st.strOpsSum or 0) / n
          local avgT = (st.tblOpsSum or 0) / n
          if (avgS > 0) or (avgT > 0) then
            memText = memText .. string.format("  s%.0f t%.0f", avgS, avgT)
          end
        end
      end
    end


    if row.cpuValue then
      row.cpuValue:SetText(cpuText)
      row.cpuValue:SetShown(cpuText ~= "")
    end

    if row.memValue then
      row.memValue:SetText(memText)
      row.memValue:SetShown(memText ~= "")
    end
    -- ensure cpu sampler is alive if CPU exists
    if cpu and cpu.EnsureSampler then
      cpu:EnsureSampler()
    end


    row._data = entry
    y = y - rowH
  end

  for i = nRows + 1, #self.rows do
    if self.rows[i] then
      self.rows[i]:Hide()
      self.rows[i]._data = nil
    end
  end

  if nRows < #flat and f._statusText then

    f._statusText:SetText((f._statusText:GetText() or "") .. string.format("   (Showing first %d rows)", nRows))
  end
end

-- === BLOCK: MemDebugWindow - Setup Ends ===


-- === BLOCK: MemDebugWindow - UI Factory Starts ===

-- === BLOCK: MemDebugWindow - Skin + Native Widgets Starts ===
local function _applyBackdrop(frame, bg, border, inset)
  if not frame or not frame.SetBackdrop then return end
  inset = tonumber(inset) or 1
  frame:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets   = { left = inset, right = inset, top = inset, bottom = inset },
  })
  frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
  frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function _skinFrame(frame, kind)
  if not frame then return end
  local _, border, _, bgWin, bgPane = _getPalette()
  local bg = (kind == "pane") and bgPane or bgWin
  _applyBackdrop(frame, bg, border, 1)
end

local function _hookAccentBorder(frame)
  if not frame or frame.__pleebugAccentHooked then return end
  frame.__pleebugAccentHooked = true

  local accent, border = _getPalette()
  frame:HookScript("OnEnter", function(self)
    if self.SetBackdropBorderColor then
      self:SetBackdropBorderColor(accent[1], accent[2], accent[3], accent[4] or 1)
    end
  end)
  frame:HookScript("OnLeave", function(self)
    if self.SetBackdropBorderColor then
      self:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
    end
  end)
end

local function _skinButton(btn)
  if not btn then return end
  if not btn.SetBackdrop then
    -- ensure BackdropTemplate behavior without changing the template used
    local bg = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    bg:SetAllPoints(btn)
    bg:SetFrameLevel((btn:GetFrameLevel() or 0) - 1)
    btn._pleebugBg = bg
    _skinFrame(bg, "pane")
    _hookAccentBorder(bg)
    if bg.EnableMouse then bg:EnableMouse(false) end
  else
    _skinFrame(btn, "pane")
    _hookAccentBorder(btn)
  end
end

local function _makeLabeledSlider(parent, label, minV, maxV, stepV, valueV, onChanged)
  local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  wrap:SetHeight(46)
  wrap:SetWidth(360)
  _skinFrame(wrap, "pane")
  _hookAccentBorder(wrap)

  local lbl = wrap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lbl:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -6)
  lbl:SetText(label or "")
  _applyFontSafe(lbl, math.max(12, (W.fontSize or 14)), "OUTLINE")
  _colorText(lbl)
  wrap._label = lbl

  local valText = wrap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  valText:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -8, -6)
  _applyFontSafe(valText, math.max(12, (W.fontSize or 14)), "OUTLINE")
  _colorText(valText)
  wrap._valText = valText

  local slider = CreateFrame("Slider", nil, wrap)
  slider:SetPoint("BOTTOMLEFT", wrap, "BOTTOMLEFT", 10, 8)
  slider:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -10, 8)
  slider:SetHeight(14)
  slider:SetOrientation("HORIZONTAL")

  minV = tonumber(minV) or 0
  maxV = tonumber(maxV) or 1
  stepV = tonumber(stepV) or 1
  slider:SetMinMaxValues(minV, maxV)
  slider:SetValueStep(stepV)
  slider:SetObeyStepOnDrag(true)

  local accent = _getPalette()
  local thumb = slider:CreateTexture(nil, "OVERLAY")
  thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  thumb:SetSize(10, 16)
  thumb:SetVertexColor(accent[1] or 1, accent[2] or 1, accent[3] or 1, 1)
  slider:SetThumbTexture(thumb)


  local track = slider:CreateTexture(nil, "ARTWORK")
  track:SetTexture("Interface\\Buttons\\WHITE8x8")
  track:SetPoint("CENTER", slider, "CENTER", 0, 0)
  track:SetSize(1, 4)
  track:SetVertexColor(1, 1, 1, 0.10)
  track:SetPoint("LEFT", slider, "LEFT", 0, 0)
  track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
  wrap._track = track

  local function setValueText(v)
    if wrap._valText then
      wrap._valText:SetText(tostring(v))
    end
  end

  slider:SetScript("OnValueChanged", function(_, v)
    v = tonumber(v) or 0
    v = math.floor(v + 0.5)
    setValueText(v)
    if type(onChanged) == "function" then
      onChanged(v)
    end
  end)

  valueV = tonumber(valueV) or minV
  if valueV < minV then valueV = minV end
  if valueV > maxV then valueV = maxV end
  slider:SetValue(valueV)
  setValueText(math.floor(valueV + 0.5))

  wrap._slider = slider
  return wrap
end

local function _makeLabeledInput(parent, label, textValue, onChanged)
  local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  wrap:SetHeight(52)
  wrap:SetWidth(360)
  _skinFrame(wrap, "pane")
  _hookAccentBorder(wrap)

  local lab = wrap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lab:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -6)
  lab:SetText(label or "")
  _applyFontSafe(lab, math.max(12, (W.fontSize or 14)), "OUTLINE")
  _colorText(lab)
  wrap._label = lab

  local edit = CreateFrame("EditBox", nil, wrap, "InputBoxTemplate")
  edit:SetAutoFocus(false)
  edit:SetSize(120, 18)
  edit:SetPoint("TOPLEFT", lab, "BOTTOMLEFT", -4, -6)
  edit:SetText(tostring(textValue or ""))
  edit:SetCursorPosition(0)

  edit:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  edit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  edit:SetScript("OnEditFocusLost", function(self)
    if type(onChanged) == "function" then
      onChanged(self:GetText())
    end
  end)

  -- Optional: live update helper (caller can set wrap._onTextChanged)
  edit:SetScript("OnTextChanged", function(self)
    local p = self:GetParent()
    if p and type(p._onTextChanged) == "function" then
      p._onTextChanged(p, self:GetText())
    end
  end)


  wrap._edit = edit
  return wrap
end

local function _makeCheckbox(parent, label, checked, onChanged)

  local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  wrap:SetHeight(26)
  wrap:SetWidth(360)
  _skinFrame(wrap, "pane")
  _hookAccentBorder(wrap)

  local cb = CreateFrame("CheckButton", nil, wrap, "UICheckButtonTemplate")
  cb:SetPoint("LEFT", wrap, "LEFT", 6, 0)
  cb:SetSize(18, 18)
  cb:SetChecked(checked and true or false)

  local txt = wrap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  txt:SetPoint("LEFT", cb, "RIGHT", 6, 0)
  txt:SetText(label or "")
  _applyFontSafe(txt, math.max(12, (W.fontSize or 14)), "OUTLINE")
  _colorText(txt)

  cb:SetScript("OnClick", function()
    local v = cb:GetChecked() and true or false
    if type(onChanged) == "function" then
      onChanged(v)
    end
  end)

  wrap._cb = cb
  wrap._text = txt
  return wrap
end
-- === BLOCK: MemDebugWindow - Skin + Native Widgets Ends ===

local function _ensureFrame()
  if W.frame then return W.frame end


  local f = CreateFrame("Frame", "PleeBUG_MemDebugWindow", UIParent, "BackdropTemplate")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:SetSize(720, 520)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetResizable(true)

  if f.SetResizeBounds then
    f:SetResizeBounds(520, 360, 1400, 1000)
  else
    if f.SetMinResize then f:SetMinResize(520, 360) end
    if f.SetMaxResize then f:SetMaxResize(1400, 1000) end
  end


  local resize = CreateFrame("Button", nil, f)
  resize:SetSize(18, 18)
  resize:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  resize:EnableMouse(true)
  resize:SetScript("OnMouseDown", function()
    f:StartSizing("BOTTOMRIGHT")
  end)
  resize:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
  end)

  resize.tex = resize:CreateTexture(nil, "OVERLAY")
  resize.tex:SetAllPoints()
  resize.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  if f:GetName() then
    table.insert(UISpecialFrames, f:GetName())
  end

  _skinFrame(f, "window")


  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
  title:SetText("PleeBUG Debug")
  _applyFontSafe(title, W.titleFontSize or 18, "OUTLINE")
  _colorText(title)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

  -- Settings window (separate frame, toggled by "Settings" button)
  local sf = CreateFrame("Frame", "PleeBUG_MemDebugSettingsWindow", UIParent, "BackdropTemplate")
  sf:SetFrameStrata("FULLSCREEN_DIALOG")
  sf:SetToplevel(true)
  sf:SetSize(380, f:GetHeight() or 520)
  sf:SetPoint("TOPRIGHT", f, "TOPLEFT", -8, 0)
  sf:SetClampedToScreen(true)
  sf:SetMovable(true)
  sf:EnableMouse(true)
  sf:RegisterForDrag("LeftButton")
  sf:SetScript("OnDragStart", function(self) self:StartMoving() end)
  sf:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  -- Keep settings height in sync with the main window height.
  f:HookScript("OnSizeChanged", function(self)
    local sff = self and self._settingsFrame
    if not sff then
      return
    end
    local h = self.GetHeight and self:GetHeight() or nil
    if h and h > 0 then
      sff:SetHeight(h)
    end
  end)

  _skinFrame(sf, "window")

  local sTitle = sf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sTitle:SetPoint("TOPLEFT", sf, "TOPLEFT", 12, -10)
  sTitle:SetText("PleeBUG Settings")
  _applyFontSafe(sTitle, W.titleFontSize or 18, "OUTLINE")
  _colorText(sTitle)

  local sClose = CreateFrame("Button", nil, sf, "UIPanelCloseButton")
  sClose:SetPoint("TOPRIGHT", sf, "TOPRIGHT", -4, -4)
  sClose:SetScript("OnClick", function() sf:Hide() end)

  sf:Hide()
  f._settingsFrame = sf

  -- If the main window closes (close button, ESC, Hide(), etc),
  -- force-close the settings window too.
  f:HookScript("OnHide", function(self)
    local sff = self and self._settingsFrame
    if sff and sff.IsShown and sff:IsShown() then
      sff:Hide()
    end
  end)


  function W:ToggleSettings()
    local ff = _ensureFrame()
    local sff = ff and ff._settingsFrame
    if not sff then return end
    if sff:IsShown() then
      sff:Hide()
    else
      sff:Show()
      self:Refresh()
    end
  end

 ------------------
  -- Export (copy table rows to a multiline editbox)
 ------------------
  local ExportFrame
  local ExportEditBox

  local function _EnsureExportFrame()
    if ExportFrame and ExportEditBox then
      return
    end

    local ef = CreateFrame("Frame", "PleeBUG_ExportWindow", UIParent, "BackdropTemplate")
    ef:SetFrameStrata("FULLSCREEN_DIALOG")
    ef:SetToplevel(true)
    ef:SetSize(820, 520)
    ef:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    ef:SetClampedToScreen(true)
    ef:SetMovable(true)
    ef:EnableMouse(true)
    ef:RegisterForDrag("LeftButton")
    ef:SetScript("OnDragStart", function(self) self:StartMoving() end)
    ef:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    if ef.SetResizeBounds then
      ef:SetResizable(true)
      ef:SetResizeBounds(520, 300, 1400, 1000)
    elseif ef.SetMinResize then
      ef:SetResizable(true)
      ef:SetMinResize(520, 300)
    end

    _skinFrame(ef, "window")

    local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", ef, "TOPLEFT", 12, -10)
    title:SetText("PleeBUG Export (Ctrl+C)")
    _applyFontSafe(title, W.titleFontSize or 18, "OUTLINE")
    _colorText(title)

    local close = CreateFrame("Button", nil, ef, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", ef, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() ef:Hide() end)

    local scroll = CreateFrame("ScrollFrame", nil, ef, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", ef, "TOPLEFT", 12, -36)
    scroll:SetPoint("BOTTOMRIGHT", ef, "BOTTOMRIGHT", -30, 12)

    local edit = CreateFrame("EditBox", nil, scroll, "BackdropTemplate")
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:EnableMouse(true)
    edit:SetAutoFocus(true)
    edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    edit:SetWidth(760)
    edit:SetScript("OnEscapePressed", function()
      ef:Hide()
    end)

    scroll:SetScrollChild(edit)

    ExportFrame = ef
    ExportEditBox = edit

    if ef:GetName() and UISpecialFrames then
      table.insert(UISpecialFrames, ef:GetName())
    end

    ef:Hide()
  end

  function W:BuildExportText()
    local flat = self._flat or {}
    local interval = self._pendingInterval or (MemDebug.GetInterval and MemDebug:GetInterval()) or 10
    interval = tonumber(interval) or 10
    if interval <= 0 then interval = 10 end

    local cpu = MemDebug and MemDebug.CPU

    local MAX_ROWS = 600
    local nRows = #flat
    if nRows > MAX_ROWS then nRows = MAX_ROWS end

    local lines = {}
    lines[1] = table.concat({
      "path",
      "name",
      "depth",
      "calls",
      "calls_per_sec",
      "mem_avg_kb",
      "mem_max_kb",
      "cpu_avg_ms",
      "cpu_max_ms",
      "hot_tables",
      "str_ops_avg",
      "tbl_ops_avg",
    }, "\t")

    for i = 1, nRows do
      local entry = flat[i]
      local node = entry and entry.node
      if node and node.path then
        local depth = entry.depth or 0
        local path = tostring(node.path or "")
        local name = tostring(node.name or "")

        local count = tonumber(node.count) or 0
        local rate = count / interval

        local memAvgKB, memMaxKB = "", ""
        local cpuAvgMs, cpuMaxMs = "", ""
        local hotTables = 0
        local strAvg, tblAvg = "", ""

        local hasChildren = node.children and next(node.children) ~= nil

        local partCount = 0
        for _ in path:gmatch("[^%.]+") do
          partCount = partCount + 1
        end

        local isFuncLeaf = path:match("^Funcs%.") and (partCount >= 3) and (not hasChildren)
        local isEventLeaf = path:match("^Events%.") and (partCount >= 3) and (not hasChildren)

        local statKey = nil
        if isFuncLeaf then
          statKey = path:gsub("^Funcs%.", "")
        elseif isEventLeaf then
          statKey = path
        end

        if (isFuncLeaf or isEventLeaf) and cpu and cpu.GetStat and statKey then
          local st = cpu:GetStat(statKey)
          if st and st.n and st.n > 0 then
            local n = tonumber(st.n) or 1
            if n <= 0 then n = 1 end

            local avgMs = (tonumber(st.timeSum) or 0) / n
            local maxMs = tonumber(st.timeMax) or tonumber(st.timeLast) or 0

            cpuAvgMs = string.format("%.6f", avgMs)
            cpuMaxMs = string.format("%.6f", maxMs)

            if st.native ~= true then
              local avgMem = (tonumber(st.memSum) or 0) / n
              local maxMem = tonumber(st.memMax) or tonumber(st.memLast) or 0
              memAvgKB = string.format("%.3f", avgMem)
              memMaxKB = string.format("%.3f", maxMem)
            end

            if st.hotTables then
              hotTables = 1
            end

            if st.strOpsSum and st.tblOpsSum then
              local aS = (tonumber(st.strOpsSum) or 0) / n
              local aT = (tonumber(st.tblOpsSum) or 0) / n
              strAvg = string.format("%.3f", aS)
              tblAvg = string.format("%.3f", aT)
            end
          end
        end

        lines[#lines + 1] = table.concat({
          path,
          name,
          tostring(depth),
          tostring(count),
          string.format("%.6f", rate),
          tostring(memAvgKB),
          tostring(memMaxKB),
          tostring(cpuAvgMs),
          tostring(cpuMaxMs),
          tostring(hotTables),
          tostring(strAvg),
          tostring(tblAvg),
        }, "\t")
      end
    end

    return table.concat(lines, "\n")
  end

  function W:OpenExportWindow()
    _EnsureExportFrame()
    if not (ExportFrame and ExportEditBox) then return end

    local txt = self:BuildExportText() or ""
    ExportEditBox:SetText(txt)
    ExportEditBox:HighlightText()
    ExportEditBox:SetFocus()
    ExportFrame:Show()
  end

  -- Controls
  local startBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")

  startBtn:SetSize(90, 22)
  startBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -38)
  startBtn:SetText("Start")
  startBtn:SetScript("OnClick", function()
    MemDebug:SetEnabled(true)
    W:Refresh()
  end)



  local stopBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  stopBtn:SetSize(90, 22)
  stopBtn:SetPoint("LEFT", startBtn, "RIGHT", 8, 0)
  stopBtn:SetText("Stop")
  stopBtn:SetScript("OnClick", function()
    MemDebug:SetEnabled(false)
    W:Refresh()
  end)


  local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  clearBtn:SetSize(90, 22)
  clearBtn:SetPoint("LEFT", stopBtn, "RIGHT", 8, 0)
  clearBtn:SetText("Clear")
  clearBtn:SetScript("OnClick", function()
    MemDebug:Clear()
    W.lastSnapshot = {}
    W._flatBuiltFor = nil
    W._flat = {}
    W._buildInProgress = false
    W._buildIterKey = nil
    W._buildRoot = nil
    W:Refresh()
  end)


  local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  exportBtn:SetSize(90, 22)
  exportBtn:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0)
  exportBtn:SetText("Export")
  exportBtn:SetScript("OnClick", function()
    if W and W.OpenExportWindow then
      W:OpenExportWindow()
    end
  end)

  local settingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  settingsBtn:SetSize(110, 22)
  settingsBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
  settingsBtn:SetText("Settings")
  settingsBtn:SetScript("OnClick", function()
    if W and W.ToggleSettings then
      W:ToggleSettings()
    end
  end)

  -- Built-in skin (square, 1px border, dark bg, accent hover)
  _skinButton(startBtn)
  _skinButton(stopBtn)
  _skinButton(clearBtn)
  _skinButton(exportBtn)
  _skinButton(settingsBtn)



  for _, b in ipairs({ startBtn, stopBtn, clearBtn, exportBtn, settingsBtn }) do


    if b then
      b:EnableMouse(true)
      local bg = b._bg or b._backdrop or b._back
      if bg and bg.EnableMouse then
        bg:EnableMouse(false)
      end
    end
  end



  -- Interval slider (native)
  local sf = f._settingsFrame

  local intervalSlider = _makeLabeledSlider(
    sf,
    "Window (sec)",
    5, 60, 1,
    (MemDebug.GetInterval and MemDebug:GetInterval()) or 10,
    function(val)
      if MemDebug and MemDebug.SetInterval then
        MemDebug:SetInterval(val)
      end
      W:Refresh()
    end
  )
  intervalSlider:ClearAllPoints()
  intervalSlider:SetPoint("TOPLEFT", sf, "TOPLEFT", 12, -38)
  intervalSlider:SetWidth(356)
  intervalSlider:Show()
  f._intervalSlider = intervalSlider



  -- Font size slider (native)
  local fontSlider = _makeLabeledSlider(
    sf,
    "Font Size",
    10, 22, 1,
    (MemDebug.GetFontSize and MemDebug:GetFontSize()) or (W.fontSize or 14),
    function(val)
      val = tonumber(val) or 14
      val = math.floor(val + 0.5)
      if val < 10 then val = 10 end
      if val > 22 then val = 22 end

      W.fontSize = val
      W.rowHeight = math.max(18, math.floor((val * (W.uiScale or 1)) + 0.5) + 10)

      if MemDebug and MemDebug.SetFontSize then
        MemDebug:SetFontSize(val)
      end

      W:Refresh()
    end
  )
  fontSlider:ClearAllPoints()
  fontSlider:SetPoint("TOPLEFT", intervalSlider, "BOTTOMLEFT", 0, -10)
  fontSlider:SetWidth(356)
  fontSlider:Show()
  f._fontSlider = fontSlider



  -- Debug/profile mode controls
  local sf = f._settingsFrame or f
  local cpu = MemDebug and MemDebug.CPU

  local modeLabel = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  modeLabel:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 8, -12)
  modeLabel:SetText("Debug mode: " .. ((MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode()) or "light"))
  _applyFontSafe(modeLabel, math.max(12, (W.fontSize or 14)), "OUTLINE")
  _colorText(modeLabel)
  f._debugModeLabel = modeLabel

  local lightBtn = CreateFrame("Button", nil, sf, "UIPanelButtonTemplate")
  lightBtn:SetSize(172, 22)
  lightBtn:SetPoint("TOPLEFT", modeLabel, "BOTTOMLEFT", -8, -6)
  lightBtn:SetText("Light debug")
  lightBtn:SetScript("OnClick", function()
    if MemDebug and MemDebug.SetDebugModeAndReload then
      MemDebug:SetDebugModeAndReload("light")
    end
  end)
  _skinButton(lightBtn)
  f._lightModeBtn = lightBtn

  local fullBtn = CreateFrame("Button", nil, sf, "UIPanelButtonTemplate")
  fullBtn:SetSize(172, 22)
  fullBtn:SetPoint("LEFT", lightBtn, "RIGHT", 8, 0)
  fullBtn:SetText("Full debug")
  fullBtn:SetScript("OnClick", function()
    if MemDebug and MemDebug.SetDebugModeAndReload then
      MemDebug:SetDebugModeAndReload("full")
    end
  end)
  _skinButton(fullBtn)
  f._fullModeBtn = fullBtn

  local spText = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  spText:SetPoint("TOPLEFT", lightBtn, "BOTTOMLEFT", 8, -8)
  local spOn = cpu and cpu.IsScriptProfileEnabled and cpu:IsScriptProfileEnabled() or false
  spText:SetText("scriptProfile CVar: " .. (spOn and "ON" or "OFF"))
  _applyFontSafe(spText, math.max(12, (W.fontSize or 14)), "OUTLINE")
  _colorText(spText)
  f._scriptProfileText = spText

  local modeHelp = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  modeHelp:SetPoint("TOPLEFT", spText, "BOTTOMLEFT", 0, -6)
  modeHelp:SetWidth(360)
  modeHelp:SetJustifyH("LEFT")
  modeHelp:SetText("Light mode uses Blizzard native CPU counters and needs scriptProfile. Full debug uses Pleebug wrappers, disables scriptProfile, and records CPU/mem debug stats.")
  _applyFontSafe(modeHelp, math.max(11, (W.fontSize or 14) - 1), nil)
  _colorText(modeHelp)
  f._modeHelpText = modeHelp

  -- Presets own these flags now. Keep the old fields nil so the UI does not expose
  -- half-overridden legacy switches that create confusing mixed states.
  f._scriptProfileEnableBtn = nil
  f._scriptProfileDisableBtn = nil
  f._cpuEnableBox = nil
  f._nativeFuncBox = nil
  f._nativeEventBox = nil
  f._nativeScriptBox = nil
  f._eventMeasureBox = nil
  f._cpuEventBox = nil

  -- Reference line options removed (timeline graph no longer exists).
  f._cpuRefBox = nil
  f._cpuFpsInput = nil
  f._cpuBudgetText = nil
  f._cpuRefExplain = modeHelp

  -- Modules panel (auto-populated from MemDebug:Attach registrations)
  do
local panel = CreateFrame("Frame", nil, sf, "BackdropTemplate")
    panel:SetSize(0, 0)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", f._cpuRefExplain or cpuEnableBox, "BOTTOMLEFT", 0, -12)
    panel:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", -12, 12)
    f._modulesPanel = panel


    panel:SetBackdrop({
      bgFile   = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
      insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.25)
    panel:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.9)


    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    title:SetText("Modules")
    _applyFontSafe(title, math.max(12, (W.fontSize or 14)), "OUTLINE")
    _colorText(title)
    panel._title = title

    local enableAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    enableAll:SetSize(80, 18)
    enableAll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    enableAll:SetText("Enable All")
    enableAll:SetScript("OnClick", function()
      if MemDebug and MemDebug.EnableAllModules then
        MemDebug:EnableAllModules()
      end
      if W and W.Refresh then
        W:Refresh()
      end
    end)

    local disableAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    disableAll:SetSize(80, 18)
    disableAll:SetPoint("LEFT", enableAll, "RIGHT", 6, 0)
    disableAll:SetText("Disable All")
    disableAll:SetScript("OnClick", function()
      if MemDebug and MemDebug.DisableAllModules then
        MemDebug:DisableAllModules()
      end
      if W and W.Refresh then
        W:Refresh()
      end
    end)

    _skinButton(enableAll)
    _skinButton(disableAll)


    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", enableAll, "BOTTOMLEFT", 0, -6)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 0)



    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    content:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    panel._scroll = scroll
    panel._content = content
    panel._checks = panel._checks or {}
  end

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")

  status:SetPoint("TOPLEFT", startBtn, "BOTTOMLEFT", 0, -10)

  status:SetText("No data yet - press Start.")
    f._statusText = status
  _applyFontSafe(status, W.fontSize or 14, nil)
  _colorText(status)
  -- Body: LIST only (timeline is its own window)
  local listHolder = CreateFrame("Frame", nil, f, "BackdropTemplate")
  listHolder:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -10)
  listHolder:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)
  f._listHolder = listHolder

  listHolder:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets   = { left = 6, right = 6, top = 6, bottom = 6 },
  })
  listHolder:SetBackdropColor(0, 0, 0, 0.18)
  listHolder:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.9)





  -- Keep top controls above scroll region and any shell art.
  local base = f:GetFrameLevel() or 0
  local strata = f:GetFrameStrata() or "FULLSCREEN_DIALOG"

  for _, r in ipairs({ startBtn, stopBtn, clearBtn, exportBtn, settingsBtn }) do
    if r then
      if r.SetFrameStrata then
        r:SetFrameStrata(strata)
      end
      if r.SetFrameLevel then
        r:SetFrameLevel(base + 80)
      end
    end
  end

  if intervalSlider and intervalSlider.SetFrameLevel then
    intervalSlider:SetFrameLevel(base + 30)
  end
  if fontSlider and fontSlider.SetFrameLevel then
    fontSlider:SetFrameLevel(base + 30)
  end

  if status and status.SetFrameLevel then
    status:SetFrameLevel(base + 30)
  end


-- Column header (fixed, not scrolled)
  local header = CreateFrame("Frame", nil, f._listHolder, "BackdropTemplate")
  header:SetPoint("TOPLEFT", f._listHolder, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", f._listHolder, "TOPRIGHT", -32, 0)
  header:SetHeight(W.rowHeight or 24)

  header:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  header:SetBackdropColor(0, 0, 0, 0.35)
  header:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.9)

  local function _mkHeaderText()
    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    _applyFontSafe(fs, math.max(12, (W.fontSize or 14) - 1), "OUTLINE")
    _colorText(fs)
    return fs
  end

  header.hTrack = _mkHeaderText()
  header.hTrack:SetPoint("RIGHT", header, "RIGHT", -6, 0)
  header.hTrack:SetText("Track")

  header.hCPU = _mkHeaderText()
  header.hCPU:SetPoint("RIGHT", header.hTrack, "LEFT", -6, 0)
  header.hCPU:SetText("CPU avg (max)")

  header.hMem = _mkHeaderText()
  header.hMem:SetPoint("RIGHT", header.hCPU, "LEFT", -10, 0)
  header.hMem:SetText("Mem avg (max)")

  header.hCalls = _mkHeaderText()
  header.hCalls:SetPoint("RIGHT", header.hMem, "LEFT", -10, 0)
  header.hCalls:SetText("Calls")

  header.hName = _mkHeaderText()
  header.hName:SetPoint("LEFT", header, "LEFT", 6, 0)
  header.hName:SetText("Name")

  f._listHeader = header

  -- Scroll area (LIST pane)
  local scroll = CreateFrame("ScrollFrame", nil, f._listHolder, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", f._listHolder, "BOTTOMRIGHT", -32, 0)


  local content = CreateFrame("Frame", nil, scroll)

  -- IMPORTANT:
  -- If content is left at width 1, your row buttons become ~1px clickable even though text renders wider.
  -- Anchor content to the scroll frame so rows get a real width/hitbox.
  content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
  content:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -26, 0) -- leave space for the scrollbar
  content:SetSize(1, 1) -- height is driven by Refresh; width is driven by anchors above
  scroll:SetScrollChild(content)

  local function _SyncContentWidth()
    if not (content and content.SetWidth and scroll and scroll.GetWidth) then return end

    local sbw = 26
    if scroll.ScrollBar and scroll.ScrollBar.GetWidth then
      sbw = math.floor(scroll.ScrollBar:GetWidth() + 0.5) + 4
    end

    local w = (scroll:GetWidth() or 1) - sbw
    if w < 1 then w = 1 end
    content:SetWidth(w)
  end

  -- IMPORTANT: do this immediately so row buttons get a real hitbox on first show
  _SyncContentWidth()

  -- Keep width stable if the window is resized
  scroll:SetScript("OnSizeChanged", function()
    _SyncContentWidth()
  end)

  -- Also resync on show (some layouts do not trigger OnSizeChanged the first time)
  f:HookScript("OnShow", function()
    _SyncContentWidth()
  end)


  f._scroll = scroll
  f._content = content


  W.frame = f
  f:Hide()
  return f
end


local function _refreshModulePanel(f)
  if not f or not f._modulesPanel or not MemDebug then return end

  local panel = f._modulesPanel
  local content = panel._content
  if not content then return end

  local names = (MemDebug.GetKnownModules and MemDebug:GetKnownModules()) or {}
  local grouped = {}
  local topLevel = {}

  for i = 1, #names do
    local name = names[i]
    local groupName = MemDebug.GetModuleGroup and MemDebug:GetModuleGroup(name) or nil
    if groupName then
      grouped[groupName] = grouped[groupName] or {}
      grouped[groupName][#grouped[groupName] + 1] = name
    else
      topLevel[#topLevel + 1] = { kind = "module", name = name }
    end
  end

  for groupName, members in pairs(grouped) do
    if #members > 1 then
      topLevel[#topLevel + 1] = {
        kind = "group",
        name = groupName,
        members = members,
      }
    else
      topLevel[#topLevel + 1] = { kind = "module", name = members[1] }
    end
  end

  table.sort(topLevel, function(a, b)
    return tostring(a.name or "") < tostring(b.name or "")
  end)

  panel._groupExpanded = panel._groupExpanded or {}

  local entries = {}
  for i = 1, #topLevel do
    local entry = topLevel[i]
    entries[#entries + 1] = entry

    if entry.kind == "group" then
      local groupName = entry.name
      if panel._groupExpanded[groupName] == nil then
        panel._groupExpanded[groupName] = true
      end

      if panel._groupExpanded[groupName] then
        for j = 1, #entry.members do
          entries[#entries + 1] = {
            kind = "module",
            name = entry.members[j],
            group = groupName,
          }
        end
      end
    end
  end

  panel._rows = panel._rows or {}

  -- StaticPopup for rename
  if not StaticPopupDialogs.PLEEBUG_RENAME then
    StaticPopupDialogs.PLEEBUG_RENAME =

    {
      text = "Friendly name",
      button1 = "Save",
      button2 = "Clear",
      button3 = "Cancel",
      hasEditBox = true,
      timeout = 0,
      whileDead = 1,
      hideOnEscape = 1,
      preferredIndex = 3,

      OnShow = function(self)
        local data = self.data
        local mod = data and data.module
        if not mod then return end
        local cur = (MemDebug.GetModuleAlias and MemDebug:GetModuleAlias(mod)) or ""
        self.editBox:SetText(cur)
        self.editBox:HighlightText()
      end,

      OnAccept = function(self)
        local data = self.data
        local mod = data and data.module
        if not mod then return end
        local txt = self.editBox:GetText()
        if MemDebug and MemDebug.SetModuleAlias then
          MemDebug:SetModuleAlias(mod, txt)
        end
        if W and W.Refresh then
          W:Refresh()
        end
      end,

      OnAlt = function(self)
        local data = self.data
        local mod = data and data.module
        if not mod then return end
        if MemDebug and MemDebug.SetModuleAlias then
          MemDebug:SetModuleAlias(mod, nil)
        end
        if W and W.Refresh then
          W:Refresh()
        end
      end,
    }
  end

  local rowH = 18
  local y = -2

  for i = 1, #entries do
    local entry = entries[i]
    local row = panel._rows[i]
    if not row then
      row = CreateFrame("Frame", nil, content)
      row:SetHeight(rowH)

      local expand = CreateFrame("Button", nil, row)
      expand:SetSize(18, 18)
      expand:SetPoint("LEFT", row, "LEFT", 0, 0)

      local expandText = expand:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      expandText:SetAllPoints(expand)
      expandText:SetJustifyH("CENTER")
      _applyFontSafe(expandText, math.max(12, (W.fontSize or 14)), nil)
      _colorText(expandText)

      local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
      cb:SetSize(18, 18)

      local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
      _applyFontSafe(text, math.max(12, (W.fontSize or 14)), nil)
      _colorText(text)

      local gear = CreateFrame("Button", nil, row)
      gear:SetSize(18, 18)
      gear:SetPoint("RIGHT", row, "RIGHT", 0, 0)

      -- Gear icon (no emoji): Interface/HUD/UIGroupManager2x
      if gear.SetNormalAtlas then
        gear:SetNormalAtlas("GM-icon-settings", true)
      end
      if gear.SetHighlightAtlas then
        gear:SetHighlightAtlas("GM-icon-settings-hover")
      end

      if gear.SetPushedAtlas then
        gear:SetPushedAtlas("GM-icon-settings-pressed", true)
      end

      -- Slightly dim default state so hover reads better
      local nt = gear.GetNormalTexture and gear:GetNormalTexture() or nil
      if nt and nt.SetAlpha then
        nt:SetAlpha(0.9)
      end


      -- AutoWrap toggle (per-module)
      local aw = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
      aw:SetSize(18, 18)
      aw:SetPoint("RIGHT", gear, "LEFT", -4, 0)
      aw:SetScale(0.85)
      if aw.Text then aw.Text:Hide() end
      if aw.text then aw.text:Hide() end

      row._expand = expand
      row._expandText = expandText
      row._cb = cb
      row._text = text
      row._gear = gear
      row._aw = aw

      expand:SetScript("OnClick", function()
        local groupName = row._groupName
        if not groupName then return end
        panel._groupExpanded[groupName] = not panel._groupExpanded[groupName]
        if W and W.Refresh then
          W:Refresh()
        end
      end)

      cb:SetScript("OnClick", function()
        if row._kind == "group" then
          local groupName = row._groupName
          local enableGroup = (row._groupEnabledCount or 0) == 0
          if groupName and MemDebug and MemDebug.SetModuleGroupEnabled then
            MemDebug:SetModuleGroupEnabled(groupName, enableGroup)
          end
        else
          local moduleName = row._moduleName
          local v = cb:GetChecked() and true or false
          if moduleName and MemDebug and MemDebug.SetModuleEnabled then
            MemDebug:SetModuleEnabled(moduleName, v)
          end
        end
        if W and W.Refresh then
          W:Refresh()
        end
      end)

      aw:SetScript("OnClick", function()
        local moduleName = row._moduleName
        local v = aw:GetChecked() and true or false
        if moduleName and MemDebug and MemDebug.SetModuleAutoWrapEnabled then
          MemDebug:SetModuleAutoWrapEnabled(moduleName, v)
        end
        if W and W.Refresh then
          W:Refresh()
        end
      end)

      gear:SetScript("OnClick", function()
        local moduleName = row._moduleName
        if not moduleName then return end
        local dlg = StaticPopup_Show("PLEEBUG_RENAME")
        if dlg then
          dlg.data = { module = moduleName }
        end
      end)

      panel._rows[i] = row
    end

    row._kind = entry.kind
    row._moduleName = nil
    row._groupName = nil
    row._groupEnabledCount = nil

    row._cb:ClearAllPoints()
    row._cb:SetAlpha(1)

    if entry.kind == "group" then
      local groupName = entry.name
      row._groupName = groupName

      local expanded = panel._groupExpanded[groupName] == true
      row._expandText:SetText(expanded and "-" or "+")
      row._expand:Show()

      row._cb:SetPoint("LEFT", row._expand, "RIGHT", 0, 0)

      local allEnabled, enabledCount, totalCount = false, 0, 0
      if MemDebug.GetModuleGroupState then
        allEnabled, enabledCount, totalCount = MemDebug:GetModuleGroupState(groupName)
      end
      row._groupEnabledCount = enabledCount
      row._cb:SetChecked(enabledCount > 0)
      if not allEnabled and enabledCount > 0 then
        row._cb:SetAlpha(0.55)
      end

      row._text:SetText(string.format("%s (%d/%d)", groupName, enabledCount, totalCount))
      row._aw:Hide()
      row._gear:Hide()
    else
      local moduleName = entry.name
      row._moduleName = moduleName

      row._expand:Hide()
      row._cb:SetPoint("LEFT", row, "LEFT", entry.group and 36 or 18, 0)

      local label = moduleName
      if MemDebug and MemDebug.GetModuleDisplayName then
        label = MemDebug:GetModuleDisplayName(moduleName)
      end
      if label == moduleName and (entry.group == "PCM" or entry.group == "PRD" or entry.group == "PUIModules") then
        label = label:gsub("^PUI_", "")
      end
      row._text:SetText(label)

      local enabled = true
      if MemDebug and MemDebug.IsModuleEnabled then
        enabled = MemDebug:IsModuleEnabled(moduleName)
      end
      row._cb:SetChecked(enabled)

      local awEnabled = false
      if MemDebug and MemDebug.IsModuleAutoWrapEnabled then
        awEnabled = MemDebug:IsModuleAutoWrapEnabled(moduleName)
      end
      row._aw:SetChecked(awEnabled)
      row._aw:Show()
      row._gear:Show()
    end

    row._text:SetAlpha(1)
    row._text:Show()

    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
    row:Show()

    y = y - rowH
  end

  for i = #entries + 1, #panel._rows do
    local row = panel._rows[i]
    if row then row:Hide() end
  end

  content:SetHeight(math.max(1, (#entries * rowH) + 6))
end


function _ensureRow(i)

  local f = W.frame
  local parent = f._content
  local row = W.rows[i]
  if row then return row end

  row = CreateFrame("Button", nil, parent)
  row:SetHeight(W.rowHeight or 24)
  row:SetPoint("LEFT", parent, "LEFT", 0, 0)
  row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

  -- Background (zebra set in Refresh)
  row.BG = row:CreateTexture(nil, "BACKGROUND")
  row.BG:SetAllPoints()

  -- Hover highlight
  row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
  local hl = row:GetHighlightTexture()
  if hl then
    hl:SetVertexColor(0.18, 0.18, 0.18, 0.55)
  end

  row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
  _applyFontSafe(row.label, W.fontSize or 14, nil)
  _colorText(row.label)

  -- CPU measure toggle checkbox (only shown on function leaf rows)
  row.cpuToggle = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.cpuToggle:SetSize(18, 18)
  row.cpuToggle:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.cpuToggle:Hide()

  -- CPU avg ms column (separate from calls/sec)
  row.cpuValue = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.cpuValue:SetPoint("RIGHT", row.cpuToggle, "LEFT", -6, 0)
  _applyFontSafe(row.cpuValue, W.fontSize or 14, nil)
  _colorText(row.cpuValue)

  -- Memory avg kB column 
  row.memValue = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.memValue:SetPoint("RIGHT", row.cpuValue, "LEFT", -10, 0)
  _applyFontSafe(row.memValue, W.fontSize or 14, nil)
  _colorText(row.memValue)

  row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  -- leave room for Memory + CPU + checkbox when shown
  row.value:SetPoint("RIGHT", row.memValue, "LEFT", -10, 0)
  _applyFontSafe(row.value, W.fontSize or 14, nil)
  _colorText(row.value)

  row.cpuToggle:SetScript("OnClick", function(self)
    local data = row._data
    local node = data and data.node
    if not node or not node.path then return end

    local cpu = MemDebug and MemDebug.CPU
    if not (cpu and cpu.SetMeasuredPath) then return end

    -- Window tree uses "Funcs.<Module>....", CPU uses "<Module>...."
    local cpuPath = tostring(node.path):gsub("^Funcs%.", "")

    local enabled = self:GetChecked() and true or false
    cpu:SetMeasuredPath(cpuPath, enabled)

    -- make sure sampler is running if CPU exists
    if cpu.EnsureSampler then cpu:EnsureSampler() end

    W:Refresh()
  end)

  row:SetScript("OnClick", function(self)
    local data = self._data
    if not data or not data.node then return end
    local node = data.node
    if not node.children or not next(node.children) then return end

    local path = node.path
    W.expanded[path] = not W.expanded[path]
    W:Refresh()
  end)

  W.rows[i] = row
  return row
end

-- === BLOCK: MemDebugWindow - UI Factory Ends ===


-- === BLOCK: MemDebugWindow - Render Starts ===
function W:OnSnapshot(snapshot)
  self.lastSnapshot = snapshot or {}
  self._stoppedSnapshot = nil
  self._traceSeq = (self._traceSeq or 0) + 1
  self._flatBuiltFor = nil
  if self.frame and self.frame:IsShown() then
    self:Refresh()
  end
end

local function _copyPositiveSnapshot(src, dst)
  dst = dst or {}
  _wipe(dst)

  if type(src) ~= "table" then
    return dst
  end

  for k, v in pairs(src) do
    if type(k) == "string" then
      if k:match("^__") then
        dst[k] = v
      elseif type(v) == "number" and v > 0 then
        dst[k] = v
      end
    end
  end

  return dst
end

function W:FreezeForStop()
  local now = _nowPrecise()
  local cpu = MemDebug and MemDebug.CPU
  local debugMode = (MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode()) or "light"
  local nativeMode = false
  if debugMode ~= "full" then
    nativeMode = cpu and cpu.NativeFunctionSamplingEnabled and cpu:NativeFunctionSamplingEnabled() or false
  end
  local snap

  if nativeMode and cpu then
    if cpu.PollNative then
      cpu:PollNative(now)
    end
    if cpu.BuildNativeLiveSnapshot then
      self._stoppedSnapshot = self._stoppedSnapshot or {}
      snap = cpu:BuildNativeLiveSnapshot((MemDebug.GetInterval and MemDebug:GetInterval()) or 10, now, self._stoppedSnapshot)
    end
  end

  if not snap and debugMode == "full" and MemDebug and MemDebug.BuildRollingSnapshot then
    self._stoppedSnapshot = self._stoppedSnapshot or {}
    snap = MemDebug:BuildRollingSnapshot((MemDebug.GetInterval and MemDebug:GetInterval()) or 10, now, self._stoppedSnapshot)
  end

  if not snap then
    snap = self._pendingSnapshot or self.lastSnapshot or (MemDebug and MemDebug.GetLastSnapshot and MemDebug:GetLastSnapshot()) or nil
    self._stoppedSnapshot = _copyPositiveSnapshot(snap, self._stoppedSnapshot)
    snap = self._stoppedSnapshot
  end

  if type(snap) == "table" then
    snap.__time = snap.__time or now
    snap.__interval = snap.__interval or ((MemDebug and MemDebug.GetInterval and MemDebug:GetInterval()) or 10)
    self.lastSnapshot = snap
    self._flatBuiltFor = nil
    self._buildInProgress = false
    self._traceSeq = (self._traceSeq or 0) + 1
    if MemDebug then
      MemDebug._lastSnapshot = snap
    end
  end
end

local function _UpdateTimelineTimeLabels(holder, windowSec, fillMode)
  if not holder then return end
  windowSec = tonumber(windowSec) or 10
  if windowSec <= 0 then return end

  local w = holder:GetWidth() or 1


  local padL, padR = 8, 8
  local innerW = math.max(1, w - (padL + padR))

  -- Pixels-per-second controls both tick density and label density.
  local pxPerSec = innerW / windowSec

  -- Minor tick step (ruler "mm"):
  -- zoomed out: 1s ticks
  -- zoom in: 0.1s ticks
  -- deeper: 0.01s ticks
  -- never 0.001s ticks
  local minorStep
  if pxPerSec >= 120 then
    minorStep = 0.01
  elseif pxPerSec >= 60 then
    minorStep = 0.1
  else
    minorStep = 1
  end

  -- If the window is very narrow, avoid insane tick spam
  if pxPerSec < 4 then
    minorStep = 5
  elseif pxPerSec < 10 and minorStep < 1 then
    minorStep = 1
  elseif pxPerSec < 10 then
    minorStep = 2
  end

  -- Hard cap ticks (safety)
  local maxTicks = 700
  while (windowSec / minorStep) > maxTicks do
    minorStep = minorStep * 2
  end

  -- Major tick / label step (ruler "cm"):
  -- Goal: at 60s + zoom=1 => labels every 5s (if there is room).
  -- Otherwise scale density by available width + duration + zoom.
  local desiredLabelPx = 90
  local desiredLabelSec = desiredLabelPx / math.max(1, pxPerSec)

  -- Duration/zoom preference:
  local zoomNow = tonumber(W.timelineZoom) or 1
  local preferred
  if windowSec >= 55 and zoomNow <= 1 then
    preferred = 5
  elseif windowSec >= 45 and zoomNow <= 1 then
    preferred = 5
  elseif windowSec >= 30 and zoomNow <= 1 then
    preferred = 2
  elseif windowSec >= 20 and zoomNow <= 2 then
    preferred = 1
  elseif windowSec >= 10 and zoomNow <= 3 then
    preferred = 0.5
  elseif windowSec >= 10 then
    preferred = 0.2
  else
    preferred = 0.1
  end

  -- Choose the larger of (pixel-safe) and (preferred), then snap to a nice step.
  local target = desiredLabelSec
  if preferred and preferred > target then
    target = preferred
  end

  -- Pick the *smallest* "nice" step that is >= target.
  -- IMPORTANT: candidates must be ascending for this logic.
  local candidates = { 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60 }
  local labelStep = candidates[#candidates]
  for i = 1, #candidates do
    if candidates[i] >= target then
      labelStep = candidates[i]
      break
    end
  end


  -- Ensure labelStep is >= minorStep and aligned to minorStep
  if labelStep < minorStep then
    labelStep = minorStep
  end
  local majorEvery = math.floor((labelStep / minorStep) + 0.5)
  if majorEvery < 1 then majorEvery = 1 end
  labelStep = majorEvery * minorStep

  -- Final guard: if labels would overlap at current width, back off step (increase it)
  local labelsCount = math.max(1, math.floor((windowSec / labelStep) + 0.5))
  local approxLabelPx = innerW / labelsCount
  while approxLabelPx < 55 and labelStep < 60 do
    labelStep = labelStep * 2
    majorEvery = math.floor((labelStep / minorStep) + 0.5)
    if majorEvery < 1 then majorEvery = 1 end
    labelStep = majorEvery * minorStep
    labelsCount = math.max(1, math.floor((windowSec / labelStep) + 0.5))
    approxLabelPx = innerW / labelsCount
  end


  local decimals
  if labelStep >= 1 then
    decimals = 0
  elseif labelStep >= 0.1 then
    decimals = 1
  else
    decimals = 2
  end

  -- Pools: labels + tick textures
  local labels = holder.__pleebugTimeLabels or {}
  holder.__pleebugTimeLabels = labels

  local ticks = holder.__pleebugTimeTicks or {}
  holder.__pleebugTimeTicks = ticks


  local function ensureLabel(i)
    if labels[i] then return labels[i] end
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("CENTER")
    _applyFontSafe(fs, math.max(10, (W.fontSize or 14) - 2), nil)
    _colorText(fs)
    labels[i] = fs
    return fs
  end

  local function ensureTick(i)
    if ticks[i] then return ticks[i] end
    local tx = holder:CreateTexture(nil, "OVERLAY")
    tx:SetColorTexture(1, 1, 1, 0.35)
    ticks[i] = tx
    return tx
  end

  local tStart, tEnd
  if fillMode then
    tStart, tEnd = 0, windowSec
  else
    tStart, tEnd = -windowSec, 0
  end

  -- Tick baseline (a little above the bottom edge so it reads like a ruler)
  local tickBaseY = 18
  local minorH = 6
  local majorH = 10

  local tickIdx = 0
  local labelIdx = 0

  -- Iterate in integer tick steps to avoid float drift
  local nTicks = math.floor((windowSec / minorStep) + 0.5)
  for i = 0, nTicks do
    local t = tStart + (i * minorStep)
    if t > (tEnd + (minorStep * 0.5)) then
      break
    end

    local xNorm
    if fillMode then
      xNorm = t / windowSec
    else
      xNorm = (t + windowSec) / windowSec
    end

    local x = padL + (xNorm * innerW)

    local isMajor = (i % majorEvery) == 0

    tickIdx = tickIdx + 1
    local tx = ensureTick(tickIdx)
    tx:ClearAllPoints()
    tx:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", x, tickBaseY)
    tx:SetSize(1, isMajor and majorH or minorH)
    tx:SetAlpha(isMajor and 0.65 or 0.35)
    tx:Show()

    if isMajor then
      labelIdx = labelIdx + 1
      local fs = ensureLabel(labelIdx)

      fs:ClearAllPoints()
      fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", x - 22, 2)
      fs:SetWidth(44)

      fs:SetText(string.format("%." .. decimals .. "f", t) .. "s")
      fs:Show()
    end
  end

  -- Hide unused pool members
  for i = tickIdx + 1, #ticks do
    if ticks[i] then ticks[i]:Hide() end
  end
  for i = labelIdx + 1, #labels do
    if labels[i] then labels[i]:Hide() end
  end
end

local function _UpdateVerticalScale(tf, maxV, unit)
  if not tf or not tf._diagram then return end

  local holder = tf._diagram
  local w = holder:GetWidth() or 0
  local h = holder:GetHeight() or 0
  if w < 80 or h < 80 then return end

  maxV = tonumber(maxV) or 0
  if maxV < 0 then maxV = 0 end

  unit = unit or ""

  -- Keep grid stable even when nearly flat
  if maxV <= 0 then
    maxV = 1
  end

  local padL, padR = 8, 8
  local padTop = 10
  local padBottom = 26 -- leave room for the ruler labels/ticks at the bottom
  local innerH = math.max(1, h - (padTop + padBottom))
  local innerW = math.max(1, w - (padL + padR))

  tf._vGridLines = tf._vGridLines or {}
  tf._vGridLabels = tf._vGridLabels or {}

  local lines = tf._vGridLines
  local labels = tf._vGridLabels

  local function ensureLine(i)
    if lines[i] then return lines[i] end
    local tx = holder:CreateTexture(nil, "OVERLAY")
    tx:SetColorTexture(1, 1, 1, 0.12)
    lines[i] = tx
    return tx
  end

  local function ensureLabel(i)
    if labels[i] then return labels[i] end
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    _applyFontSafe(fs, math.max(10, (W.fontSize or 14) - 3), nil)
    _colorText(fs)
    labels[i] = fs
    return fs
  end

  local decimals
  if maxV >= 100 then
    decimals = 0
  elseif maxV >= 10 then
    decimals = 1
  else
    decimals = 2
  end

  local idx = 0
  for step = 0, 4 do
    local frac = step / 4
    local v = maxV * frac
    local y = padBottom + (frac * innerH)

    idx = idx + 1
    local line = ensureLine(idx)
    line:ClearAllPoints()
    line:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", padL, y)
    line:SetSize(innerW, 1)
    line:SetAlpha((step == 0) and 0.20 or 0.12)
    line:Show()

    local lab = ensureLabel(idx)
    lab:ClearAllPoints()
    lab:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 2, y - 6)
    lab:SetWidth(90)
    lab:SetText(string.format("%." .. decimals .. "f%s", v, (unit ~= "" and (" " .. unit) or "")))
    lab:Show()
  end

  for i = idx + 1, #lines do
    if lines[i] then lines[i]:Hide() end
  end
  for i = idx + 1, #labels do
    if labels[i] then labels[i]:Hide() end
  end
end


function W:Refresh()

  if self._inRefresh then return end
  self._inRefresh = true


  local f = _ensureFrame()

  -- Module discovery is owned by DropIn/Attach during source-file load.

  -- The module picker is settings-only; do not rebuild it on the stats refresh while hidden.
  if f._settingsFrame and f._settingsFrame:IsShown() then
    _refreshModulePanel(f)
  end

  local enabled = MemDebug:IsEnabled()



  local snap
  local liveMode = false
  local debugMode = (MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode()) or "light"
  local cpu = MemDebug and MemDebug.CPU
  local nativeMode = false
  if debugMode ~= "full" then
    nativeMode = cpu and cpu.NativeFunctionSamplingEnabled and cpu:NativeFunctionSamplingEnabled() or false
  end

  -- Light mode: build a rolling live stats window from native cumulative CPU counters.
  -- This keeps calls/sec live without putting Pleebug wrappers in the profiled call path.
  if enabled and nativeMode and cpu and cpu.BuildNativeLiveSnapshot then
    self._nativeLiveSnapshot = self._nativeLiveSnapshot or {}
    snap = cpu:BuildNativeLiveSnapshot((MemDebug.GetInterval and MemDebug:GetInterval()) or 10, nil, self._nativeLiveSnapshot)
    liveMode = true
  end

  -- Full debug mode: Pleebug wrappers push timestamped call deltas.
  -- Build a sliding rolling window instead of showing the current bucket that gets
  -- wiped every interval by SnapshotAndReset().
  if not snap and enabled and debugMode == "full" and MemDebug.BuildRollingSnapshot then
    self._fullLiveSnapshot = self._fullLiveSnapshot or {}
    snap = MemDebug:BuildRollingSnapshot((MemDebug.GetInterval and MemDebug:GetInterval()) or 10, nil, self._fullLiveSnapshot)
    liveMode = true
  end

  -- When stopped, freeze the last live view captured by Stop().
  if not snap and not enabled and self._stoppedSnapshot then
    snap = self._stoppedSnapshot
  end

  -- Prefer snapshot view, but fall back to live counters so the UI is never "blank".
  if not snap then
    snap = self.lastSnapshot
    if not snap or next(snap) == nil then
      snap = MemDebug:GetLastSnapshot()
    end

    if not snap or next(snap) == nil then
      snap = MemDebug._counts or {}
      liveMode = true
    end
  end

  snap = snap or {}



  -- Build tree is deferred over frames to avoid /pleebug freezing on large data.
  self._pendingSnapshot = snap
  self._pendingInterval = snap.__interval or (MemDebug.GetInterval and MemDebug:GetInterval()) or 10
  self._pendingEnabled = enabled
  self._pendingLiveMode = liveMode

  if not self._buildInProgress then
    self:_StartDeferredBuild(snap)
  end

  -- If we already have a built flat list for this snapshot, render it now.
  if self._flatBuiltFor == snap and not self._buildInProgress then
    self:_RenderFlat()
  else
    -- Fast path: show an immediate status so the window appears instantly.
    if f._statusText then
      f._statusText:SetText("Status: Building tree...")
    end
  end


  local interval = snap.__interval or MemDebug:GetInterval()
  local total = 0
  if type(snap["Events.Total"]) == "number" then total = total + snap["Events.Total"] end
  if type(snap["Funcs.Total"]) == "number" then total = total + snap["Funcs.Total"] end

  if f._statusText then
    local statusWord
    if liveMode then
      statusWord = enabled and "Live (Running)" or "Live (Stopped)"
    else
      statusWord = enabled and "Running" or "Stopped"
    end

    local heapKB, heapPerSec = 0, 0
    if MemDebug and MemDebug.GetHeapTrend then
      heapKB, heapPerSec = MemDebug:GetHeapTrend(60)
    end

    f._statusText:SetText(string.format("Status: %s   Interval: %.2fs   Total: %d   Heap: %.0fkb (%.1fkb/s)",
      statusWord, interval, total, heapKB or 0, heapPerSec or 0))


  end
  -- Graph/timeline rendering was removed.
  
  -- Render list from the last completed deferred build (if any).
  if not self._buildInProgress and self._flatBuiltFor == snap then
    self:_RenderFlat()
  end

  -- keep the UI ticker "no-change" fast-path in sync
  self._lastUiSeq = self._traceSeq or 0

  self._inRefresh = nil
end


function W:Open()
  local f = _ensureFrame()
  if not f:IsShown() then
    f:Show()
  end
  self:Refresh()

  if not self._uiTicker then
    self._uiTicker = C_Timer.NewTicker(1.00, function()
      if not (f and f:IsShown()) then return end

      -- PERF: When not recording, avoid continuous redraw + allocations.
      if MemDebug and MemDebug.IsEnabled and (not MemDebug:IsEnabled()) then
        return
      end

      local cpu = MemDebug and MemDebug.CPU
      local debugMode = (MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode()) or "light"
      local nativeMode = false
      if debugMode ~= "full" then
        nativeMode = cpu and cpu.NativeFunctionSamplingEnabled and cpu:NativeFunctionSamplingEnabled() or false
      end

      -- Light/native mode has no wrapper calls to drive the UI, so poll the native
      -- cumulative counters from the visible-window ticker and refresh once per tick.
      if nativeMode and cpu and cpu.PollNative then
        cpu:PollNative(_nowPrecise())
        W._lastUiSeq = W._traceSeq or 0
        W._flatBuiltFor = nil
        W:Refresh()
        return
      end

      -- Full debug mode uses Pleebug wrappers. Refresh once per tick while running so
      -- calls/sec updates from the current _counts bucket.
      if debugMode == "full" then
        W._lastUiSeq = W._traceSeq or 0
        W._flatBuiltFor = nil
        W:Refresh()
        return
      end

      -- PERF: If enabled but nothing new happened, do not rebuild UI/timelines.
      local seq = W._traceSeq or 0
      if W._lastUiSeq == seq then
        return
      end
      W._lastUiSeq = seq

      W:Refresh()
    end)
  end
end

function W:Toggle()
  local f = _ensureFrame()

  -- Tables-only mode: do NOT create/show the timeline window at all.
  -- (Timeline is a separate window created by _ensureTimelineFrame().)

  if f:IsShown() then
    f:Hide()

    if self._uiTicker then
      self._uiTicker:Cancel()
      self._uiTicker = nil
    end
  else
    f:Show()

    self:Refresh()

    if not self._uiTicker then
      self._uiTicker = C_Timer.NewTicker(1.00, function()
        if not (f and f:IsShown()) then return end

        -- PERF: When not recording, avoid continuous redraw + allocations.
        if MemDebug and MemDebug.IsEnabled and (not MemDebug:IsEnabled()) then
          return
        end

        local cpu = MemDebug and MemDebug.CPU
        local debugMode = (MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode()) or "light"
        local nativeMode = false
        if debugMode ~= "full" then
          nativeMode = cpu and cpu.NativeFunctionSamplingEnabled and cpu:NativeFunctionSamplingEnabled() or false
        end

        -- Light/native mode has no wrapper calls to drive the UI, so poll the native
        -- cumulative counters from the visible-window ticker and refresh once per tick.
        if nativeMode and cpu and cpu.PollNative then
          cpu:PollNative(_nowPrecise())
          W._lastUiSeq = W._traceSeq or 0
          W._flatBuiltFor = nil
          W:Refresh()
          return
        end

        -- Full debug mode uses Pleebug wrappers. Refresh on changes; also refresh once per
        -- tick while running so calls/sec decays correctly inside the current bucket.
        if debugMode == "full" then
          W._lastUiSeq = W._traceSeq or 0
          W._flatBuiltFor = nil
          W:Refresh()
          return
        end

        -- PERF: If enabled but nothing new happened, do not rebuild UI/timelines.
        local seq = W._traceSeq or 0
        if W._lastUiSeq == seq then
          return
        end
        W._lastUiSeq = seq

        W:Refresh()
      end)
    end
  end
end


-- === BLOCK: MemDebugWindow - Render Ends ===
