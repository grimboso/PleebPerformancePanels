
-- Addon: Pleeb Performance Panel (PPP)
-- Credits to Numy for teaching me how to use the profiler API.
local ADDON_NAME = ...
local LibStub = LibStub
local PPP = {
  name = "PPP",
}

function PPP:GetName()
  return self.name
end

_G.PleebPerformancePanels = PPP

local AceGUI = LibStub("AceGUI-3.0")
local LSM = LibStub("LibSharedMedia-3.0")

local MemDebug = LibStub and LibStub("LibPleebug-1", true)
local P
if MemDebug and MemDebug.DropIn then
  P = MemDebug:DropIn(PPP, {
    name = ADDON_NAME,
    addonName = ADDON_NAME,
  })
end

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local tinsert, tremove, tsort = table.insert, table.remove, table.sort
local format = string.format
local UIParent = UIParent

local C_AddOnProfiler_IsEnabled = C_AddOnProfiler and C_AddOnProfiler.IsEnabled
local C_AddOnProfiler_GetOverallMetric = C_AddOnProfiler and C_AddOnProfiler.GetOverallMetric
local C_AddOnProfiler_GetAddOnMetric = C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric
local C_AddOnProfiler_GetTopKAddOnsForMetric = C_AddOnProfiler and C_AddOnProfiler.GetTopKAddOnsForMetric

local optionsWindow = nil
local optionsInitialized = false
local pleebUIPlugin
local cachedDurabilityPct = nil

local PPP_StyleOptionsWidget

local function _PPP_CreateOptionsWidget(widgetType)
  return PPP_StyleOptionsWidget(AceGUI:Create(widgetType))
end

local function PPP_HasPleeBar()
  if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
    if _G.C_AddOns.IsAddOnLoaded("PleeBar") then return true end
    if _G.C_AddOns.IsAddOnLoaded("Pleebar") then return true end -- just in case folder name differs
  elseif _G.IsAddOnLoaded then
    if _G.IsAddOnLoaded("PleeBar") then return true end
    if _G.IsAddOnLoaded("Pleebar") then return true end
  end

  return (_G and _G.PleeBarAPI ~= nil) and true or false
end

PPPDB = PPPDB or {}

local DEFAULTS = {
  options = {
    enabled = true,

    -- Panel layout
    layout = "vertical", -- vertical|horizontal
    showFPS = true,
    showMS  = true,
    showDur = true,
    showCPU = true,

    -- Logging is opt-in. The panel still shows live snapshots while this is false.
    loggingEnabled = false,

    -- Sampling
    sampleInterval = 0.5,

    msSource = "world", -- world|home

    -- Tooltip
    rollingMinutes = 5,

    -- Font (panel + tooltip)
    font = {
      fontKey  = nil,     -- LSM font name
      size     = 12,
      outline  = "OUTLINE", -- NONE|OUTLINE|THICKOUTLINE|MONOCHROMEOUTLINE
    },

    -- Theme preset (built-in)
    theme = "modern", -- modern|modernDark|modernLight

    -- Coloring
    colorize = true,
    fpsGoal = 144,
    fpsOrangePct = 0.50,
    fpsRedPct    = 0.32,

    pingBaseline  = 40,
    pingOrangeAdd = 10,
    pingRedAdd    = 150,

    colors = {
      -- 54F23E
      fpsGood  = { 0.32941176470588, 0.94901960784314, 0.24313725490196 },
      -- FFA633
      fpsWarn  = { 1.00, 0.65098039215686, 0.20 },
      -- FF4040
      fpsBad   = { 1.00, 0.25098039215686, 0.25098039215686 },

      -- 54F23E
      pingGood = { 0.32941176470588, 0.94901960784314, 0.24313725490196 },
      -- FFA633
      pingWarn = { 1.00, 0.65098039215686, 0.20 },
      -- FF4040
      pingBad  = { 1.00, 0.25098039215686, 0.25098039215686 },
    },

    cpuTopN = 6,

    apIgnoreFirstSec = 10,
  },

  session = nil,
}

local function DeepCopyInto(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = dst[k] or {}
      DeepCopyInto(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local function Clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function GetOptions()
  PPPDB.options = PPPDB.options or {}

  if not optionsInitialized then
    DeepCopyInto(PPPDB.options, DEFAULTS.options)

    local o = PPPDB.options
    o.layout = (o.layout == "horizontal") and "horizontal" or "vertical"
    o.rollingMinutes = Clamp(o.rollingMinutes, 1, 30)

    o.font = o.font or {}
    o.font.size = Clamp(o.font.size, 8, 24)
    o.font.outline = o.font.outline or "OUTLINE"
    if o.font.outline == "NONE" then o.font.outline = "" end

    o.fpsGoal = Clamp(o.fpsGoal, 10, 300)
    o.fpsOrangePct = Clamp(o.fpsOrangePct, 0.10, 1.00)
    o.fpsRedPct = Clamp(o.fpsRedPct, 0.10, 1.00)

    o.pingBaseline = Clamp(o.pingBaseline, 0, 300)
    o.pingOrangeAdd = Clamp(o.pingOrangeAdd, 0, 300)
    o.pingRedAdd = Clamp(o.pingRedAdd, 0, 600)

    o.cpuTopN = Clamp(o.cpuTopN, 3, 12)
    o.apIgnoreFirstSec = Clamp(o.apIgnoreFirstSec, 0, 30)

    if o.msSource ~= "home" and o.msSource ~= "world" then
      o.msSource = "world"
    end

    if o.theme ~= "modern" and o.theme ~= "modernDark" and o.theme ~= "modernLight" then
      o.theme = "modern"
    end

    optionsInitialized = true
  end

  return PPPDB.options
end

local THEME_PRESETS = {
  modern = {
    bg      = { 0.07, 0.07, 0.07, 0.92 },
    border  = { 0.16, 0.16, 0.16, 1.00 },
    accent  = { 0.30, 0.70, 1.00, 1.00 },
    textDim = { 0.75, 0.75, 0.75, 1.00 },
  },
  modernDark = {
    bg      = { 0.05, 0.05, 0.05, 0.94 },
    border  = { 0.12, 0.12, 0.12, 1.00 },
    accent  = { 0.30, 0.70, 1.00, 1.00 },
    textDim = { 0.72, 0.72, 0.72, 1.00 },
  },
  modernLight = {
    bg      = { 0.92, 0.92, 0.92, 0.95 },
    border  = { 0.70, 0.70, 0.70, 1.00 },
    accent  = { 0.12, 0.42, 0.90, 1.00 },
    textDim = { 0.25, 0.25, 0.25, 1.00 },
  },
}

local function GetTheme()
  local o = GetOptions()
  return THEME_PRESETS[o.theme] or THEME_PRESETS.modern
end

local function EnsureBackdrop(f)
  if not f or not f.SetBackdrop then return end
  if f.GetBackdrop and f:GetBackdrop() then return end
  f:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile     = false,
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
  })
end

local function ApplyFrameBackdrop(f)
  if not f then return end
  EnsureBackdrop(f)
  local t = GetTheme()
  local bg = t.bg or { 0.07, 0.07, 0.07, 0.92 }
  local bd = t.border or { 0.16, 0.16, 0.16, 1.0 }
  if f.SetBackdropColor then f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1) end
  if f.SetBackdropBorderColor then f:SetBackdropBorderColor(bd[1], bd[2], bd[3], bd[4] or 1) end
end

local function ResolveFont()
  local o = GetOptions()
  local fontKey  = o.font and o.font.fontKey
  local size     = (o.font and o.font.size) or 12
  local outline  = (o.font and o.font.outline) or "OUTLINE"
  if outline == "NONE" then outline = "" end

  local path = LSM:Fetch(LSM.MediaType.FONT, fontKey, true)
  if not path or path == "" then
    path = "Fonts\\FRIZQT__.TTF"
  end
  return path, size, outline
end


local function StatsReset(s)
  s.n, s.sum, s.min, s.max = 0, 0, nil, nil
end

local function StatsAdd(s, v)
  if v == nil then return end
  v = v + 0

  local n = s.n + 1
  s.n = n
  s.sum = s.sum + v

  local mn = s.min
  if mn == nil or v < mn then s.min = v end

  local mx = s.max
  if mx == nil or v > mx then s.max = v end
end

local function StatsAvg(s)
  local n = tonumber(s.n) or 0
  if n <= 0 then return nil end
  return (tonumber(s.sum) or 0) / n
end

local function RollingTrim(samples, windowSec, nowT)
  if not samples then return end

  local tArr = samples._t
  local vArr = samples._v
  if not tArr or not vArr then
    -- Legacy fallback (old { {t=,v=} } storage): do nothing.
    return
  end

  local n = #tArr
  if n == 0 then
    samples._head = 1
    return
  end

  local cutoff = (nowT or GetTime()) - (windowSec or 60)

  local head = samples._head or 1
  if head < 1 then head = 1 end
  if head > n then head = n end

  while head <= n do
    local t = tArr[head]
    if (not t) or t >= cutoff then
      break
    end
    head = head + 1
  end

  samples._head = head

  if head > n then
    for i = n, 1, -1 do
      tArr[i] = nil
      vArr[i] = nil
    end
    samples._head = 1
    return
  end

  if head > 256 and head > (n * 0.5) then
    local dst = 1
    for i = head, n do
      tArr[dst] = tArr[i]
      vArr[dst] = vArr[i]
      dst = dst + 1
    end
    for i = dst, n do
      tArr[i] = nil
      vArr[i] = nil
    end
    samples._head = 1
  end
end

local function RollingCompute(samples)
  if not samples then return nil, nil, nil end

  local tArr = samples._t
  local vArr = samples._v
  if not tArr or not vArr then
    return nil, nil, nil
  end

  local head = samples._head or 1
  if head < 1 then head = 1 end

  local n, sum, minV, maxV = 0, 0, nil, nil
  for i = head, #vArr do
    local v = vArr[i]
    if v ~= nil then
      n = n + 1
      sum = sum + v
      if minV == nil or v < minV then minV = v end
      if maxV == nil or v > maxV then maxV = v end
    end
  end

  if n <= 0 then return nil, nil, nil end
  return (sum / n), minV, maxV
end

-- "10% low" / "1% low" average for FPS:
-- coveragePct=0.90 -> average of worst 10% frames
-- coveragePct=0.99 -> average of worst  1% frames
local _ROLL_COUNTS = {}
local _ROLL_USED   = {}

local function RollingLowAvg(samples, coveragePct)
  if not samples then return nil end

  local vArr = samples._v
  if not vArr or #vArr == 0 then return nil end

  coveragePct = tonumber(coveragePct) or 0.90
  if coveragePct < 0.01 then coveragePct = 0.01 end
  if coveragePct > 0.9999 then coveragePct = 0.9999 end

  local total = 0
  local maxBin = 500

  local head = samples._head or 1
  if head < 1 then head = 1 end

  for i = head, #vArr do
    local v = vArr[i]
    if v ~= nil then
      local b = floor(v + 0.5)
      b = Clamp(b, 0, maxBin)

      if _ROLL_COUNTS[b] == nil then
        _ROLL_USED[#_ROLL_USED + 1] = b
        _ROLL_COUNTS[b] = 1
      else
        _ROLL_COUNTS[b] = _ROLL_COUNTS[b] + 1
      end

      total = total + 1
    end
  end

  if total <= 0 then
    for i = 1, #_ROLL_USED do
      _ROLL_COUNTS[_ROLL_USED[i]] = nil
    end
    for i = #_ROLL_USED, 1, -1 do
      _ROLL_USED[i] = nil
    end
    return nil
  end

  local frac = 1 - coveragePct
  local take = ceil(total * frac)
  take = Clamp(take, 1, total)

  local sum, got = 0, 0
  for b = 0, maxBin do
    local c = _ROLL_COUNTS[b]
    if c and c > 0 then
      local remaining = take - got
      local use = (c > remaining) and remaining or c
      sum = sum + (b * use)
      got = got + use
      if got >= take then break end
    end
  end

  -- Clear touched bins (fast, no full wipe).
  for i = 1, #_ROLL_USED do
    _ROLL_COUNTS[_ROLL_USED[i]] = nil
  end
  for i = #_ROLL_USED, 1, -1 do
    _ROLL_USED[i] = nil
  end

  if got <= 0 then return nil end
  return sum / got
end

-- Session low-avg using a small integer FPS histogram.
local function HistLowAvg(hist, coveragePct)
  if not hist or not hist.counts then return nil end
  local total = tonumber(hist.total) or 0
  if total <= 0 then return nil end

  coveragePct = tonumber(coveragePct) or 0.90
  if coveragePct < 0.01 then coveragePct = 0.01 end
  if coveragePct > 0.9999 then coveragePct = 0.9999 end

  local frac = 1 - coveragePct
  local take = ceil(total * frac)
  take = Clamp(take, 1, total)

  local sum, got = 0, 0
  local maxBin = tonumber(hist.maxBin) or 500

  for b = 0, maxBin do
    local c = hist.counts[b] or 0
    if c > 0 then
      local remaining = take - got
      local use = (c > remaining) and remaining or c
      sum = sum + (b * use)
      got = got + use
      if got >= take then break end
    end
  end

  if got <= 0 then return nil end
  return sum / got
end

local function FormatUptime(sec)
  sec = max(0, tonumber(sec) or 0)
  local h = floor(sec / 3600)
  local m = floor((sec - (h * 3600)) / 60)
  return format("%02d:%02d", h, m)
end


local function _hex(r, g, b)
  r = Clamp((tonumber(r) or 1) * 255, 0, 255)
  g = Clamp((tonumber(g) or 1) * 255, 0, 255)
  b = Clamp((tonumber(b) or 1) * 255, 0, 255)
  return format("|cff%02x%02x%02x", r, g, b)
end

local function ColorForFPS(o, fps)
  if not o or not o.colorize or not fps then return 1, 1, 1 end
  local goal = tonumber(o.fpsGoal) or 100
  local warn = goal * (tonumber(o.fpsOrangePct) or 0.5)
  local bad  = goal * (tonumber(o.fpsRedPct) or 0.3)

  local c = (o.colors or {})
  if fps <= bad then
    local t = c.fpsBad or { 1, 0.25, 0.25 }
    return t[1], t[2], t[3]
  elseif fps <= warn then
    local t = c.fpsWarn or { 1, 0.65, 0.20 }
    return t[1], t[2], t[3]
  end
  local t = c.fpsGood or { 0.85, 0.95, 0.85 }
  return t[1], t[2], t[3]
end

local function ColorForPing(o, ms)
  if not o or not o.colorize or not ms then return 1, 1, 1 end
  local base   = tonumber(o.pingBaseline) or 30
  local warnAt = base + (tonumber(o.pingOrangeAdd) or 10)
  local badAt  = base + (tonumber(o.pingRedAdd) or 150)

  local c = (o.colors or {})
  if ms >= badAt then
    local t = c.pingBad or { 1, 0.25, 0.25 }
    return t[1], t[2], t[3]
  elseif ms >= warnAt then
    local t = c.pingWarn or { 1, 0.65, 0.20 }
    return t[1], t[2], t[3]
  end
  local t = c.pingGood or { 0.85, 0.95, 0.85 }
  return t[1], t[2], t[3]
end

local METRIC = Enum and Enum.AddOnProfilerMetric or nil
local METRIC_SESSION_AVG = METRIC and METRIC.SessionAverageTime or nil
local METRIC_RECENT_AVG  = METRIC and METRIC.RecentAverageTime  or nil
local METRIC_LAST_TIME   = METRIC and METRIC.LastTime           or nil
local METRIC_PEAK_TIME   = METRIC and METRIC.PeakTime           or nil

local function AddOnProfilerEnabled()
  if C_AddOnProfiler_IsEnabled then
    return C_AddOnProfiler_IsEnabled()
  end
  if _G.AddOnProfilerEnabled then
    return _G.AddOnProfilerEnabled()
  end
  return false
end

local function AP_GetOverall(metricEnum)
  if not metricEnum or not C_AddOnProfiler_GetOverallMetric then return nil end
  return C_AddOnProfiler_GetOverallMetric(metricEnum)
end

local function AP_GetAddon(addonName, metricEnum)
  if not addonName or not metricEnum or not C_AddOnProfiler_GetAddOnMetric then return nil end
  return C_AddOnProfiler_GetAddOnMetric(addonName, metricEnum)
end

local function AP_GetTopK(metricEnum, k)
  if not metricEnum or not C_AddOnProfiler_GetTopKAddOnsForMetric then return nil end
  k = tonumber(k) or 10
  if k < 1 then k = 1 end
  if k > 100 then k = 100 end
  return C_AddOnProfiler_GetTopKAddOnsForMetric(metricEnum, k)
end

function PPP:HideTooltip()
  local t = PPP._tooltip
  if t and t.frame and t.frame.Hide then
    t.frame:Hide()
  end
end

local function NewEmptySession()
  return {
    sessionStartT = nil,

    -- FPS
    fpsSamples = {},
    sessFPS = { n = 0, sum = 0, min = nil, max = nil },
    sessFPSHist = { counts = {}, total = 0, maxBin = 0 },

    -- PING (network latency)
    msSamples  = {},
    sessMS     = { n = 0, sum = 0, min = nil, max = nil },

    -- CPU (new)
    cpuSamples = {},
    sessCPU    = { n = 0, sum = 0, min = nil, max = nil },


    -- Combat tracking
    inCombat = false,
    combatFPS = { n = 0, sum = 0, min = nil, max = nil, active = false },
    combatFPSsamples = {},
    combatCPU = { n = 0, sum = 0, min = nil, max = nil, active = false },
    combatCPUsamples = {},

    -- Encounter tracking
    inEncounter = false,
    encFPS = { n = 0, sum = 0, min = nil, max = nil, active = false },
    encFPSsamples = {},
    encCPU = { n = 0, sum = 0, min = nil, max = nil, active = false },
    encCPUsamples = {},

    lastCombatFPS = nil,
    lastCombatCPU = nil,
    lastCombatFPSsamples = {},
    lastCombatCPUsamples = {},

    lastEncFPS = nil,
    lastEncCPU = nil,
    lastEncFPSsamples = {},
    lastEncCPUsamples = {},

    apIgnoreUntilT = nil,
  }
end

local function GetSession()
  PPPDB.session = PPPDB.session or NewEmptySession()
  return PPPDB.session
end

local cStrong = "|cffffffff"
local cDim    = "|cffbfbfbf"
local cAccent = "|cff4db2ff"

local function RefreshColorCodes()
  local t = GetTheme()
  if t and t.textDim then
    cDim = _hex(t.textDim[1], t.textDim[2], t.textDim[3])
  end
  if t and t.accent then
    cAccent = _hex(t.accent[1], t.accent[2], t.accent[3])
  end
end

local function SavePosition(f)
  if not f then return end
  PPPDB.options = PPPDB.options or {}
  local point, _, relPoint, x, y = f:GetPoint(1)
  PPPDB.options.panelPos = {
    point = point or "CENTER",
    relPoint = relPoint or "CENTER",
    x = tonumber(x) or 0,
    y = tonumber(y) or 0,
  }
end

local function RestorePosition(f)
  if not f then return end
  local o = GetOptions()
  local p = o.panelPos
  f:ClearAllPoints()
  if p and p.point then
    f:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local function ApplyPanelFont(f)
  if not f then return end
  local path, size, outline = ResolveFont()
  if f.text then
    for _, fs in pairs(f.text) do
      if fs and fs.SetFont then
        fs:SetFont(path, size or 12, outline or "")
      end
    end
  end
end

local function ApplyPanelTheme(f)
  if not f then return end

  RefreshColorCodes()

  local t = GetTheme()
  local bg = (t and t.bg) or { 0.07, 0.07, 0.07, 0.92 }
  local bd = (t and t.border) or { 0.16, 0.16, 0.16, 1.00 }

  if f.bg and f.bg.SetColorTexture then
    f.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1)
  end

  if f.border then
    EnsureBackdrop(f.border)
    if f.border.SetBackdropColor then f.border:SetBackdropColor(0, 0, 0, 0) end
    if f.border.SetBackdropBorderColor then f.border:SetBackdropBorderColor(bd[1], bd[2], bd[3], bd[4] or 1) end
  end
end

local function GetPingMS(o)
  local _, _, home, world = GetNetStats()
  if o and o.msSource == "home" then
    return tonumber(home) or nil
  end
  return tonumber(world) or nil
end

local function ColorForDur(o, pct)
  if not (o and o.colorize) or not pct then return 1, 1, 1 end
  if pct <= 25 then return 1.00, 0.25, 0.25 end
  if pct <= 50 then return 1.00, 0.65, 0.20 end
  return 0.85, 0.95, 0.85
end

local function ColorForCPU(o, ms)
  if not (o and o.colorize) or not ms then return 1, 1, 1 end
  if ms >= 5.0 then return 1.00, 0.25, 0.25 end
  if ms >= 1.0 then return 1.00, 0.65, 0.20 end
  return 0.85, 0.95, 0.85
end

local function AvgBottomPercent(arr, frac)
  if not arr or #arr == 0 then return nil end
  frac = Clamp(tonumber(frac) or 0.10, 0.001, 1.0)

  local vals, n = {}, 0
  for i = 1, #arr do
    local v = tonumber(arr[i])
    if v then
      n = n + 1
      vals[n] = v
    end
  end
  if n <= 0 then return nil end

  table.sort(vals)
  local take = Clamp(math.ceil(n * frac), 1, n)

  local sum = 0
  for i = 1, take do
    sum = sum + (vals[i] or 0)
  end
  return sum / take
end

local function BuildTopAddons(o)
  if PPP._profilerEnabled ~= true then return nil end

  local want = Clamp(tonumber(o.cpuTopN) or 6, 1, 12)
  local topRecent = AP_GetTopK(METRIC_RECENT_AVG, want)
  if type(topRecent) ~= "table" then
    return nil
  end

  local out = {}
  for i = 1, min(want, #topRecent) do
    local row = topRecent[i]
    local name = row and row.addOnName
    local recent = row and tonumber(row.metricValue)
    if name and recent then
      out[#out + 1] = {
        name = name,
        avg = format("%.3f", recent),
        peak = format("%.3f", tonumber(AP_GetAddon(name, METRIC_PEAK_TIME)) or 0),
      }
    end
  end

  return out
end

function PPP:ApplyLayout()
  local o = self._options or GetOptions()
  local f = self._frame
  if not f then return end

  self._lastFPSDisplayKey = nil
  self._lastMSDisplayKey = nil
  self._lastDurDisplayKey = nil
  self._lastCPUDisplayKey = nil
  self._lastCPULoggingState = nil

  if self._cpuLogButton then
    self._cpuLogButton:SetShown(o.showCPU == true)
  end

  -- Cache sampling interval for the snapshot ticker.
  self._sampleInterval = Clamp(tonumber(o.sampleInterval) or 0.5, 0.05, 1.0)

  ApplyPanelFont(f)
  ApplyPanelTheme(f)

  local lines = {}
  if o.showFPS and self._textFPS then lines[#lines + 1] = self._textFPS end
  if o.showMS  and self._textMS  then lines[#lines + 1] = self._textMS end
  if o.showDur and self._textDur then lines[#lines + 1] = self._textDur end
  if o.showCPU and self._textCPU then lines[#lines + 1] = self._textCPU end

  local padX, padY = 6, 6
  local gap = 2

  if o.layout == "horizontal" then
    local x = padX
    local slotGap = 18
    local totalWidth = x
    local fontScale = (tonumber(o.font and o.font.size) or 12) / 12
    local slotWidths = {
      [self._textFPS] = ceil(72 * fontScale),
      [self._textMS] = ceil(82 * fontScale),
      [self._textDur] = ceil(72 * fontScale),
      [self._textCPU] = ceil(108 * fontScale),
    }

    for i = 1, #lines do
      local fs = lines[i]
      fs:ClearAllPoints()
      fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -padY)
      x = x + (slotWidths[fs] or ceil(82 * fontScale)) + slotGap
      totalWidth = x
    end

    f:SetWidth(math.max(140, totalWidth + padX))
    f:SetHeight(24 + padY)
  else
    local y = -padY
    for i = 1, #lines do
      local fs = lines[i]
      fs:ClearAllPoints()
      fs:SetPoint("TOPLEFT", f, "TOPLEFT", padX, y)
      y = y - (fs:GetStringHeight() or 12) - gap
    end
    f:SetWidth(140)
    f:SetHeight(math.max(22, (-y) + padY))
  end
end

function PPP:OpenConfig()
  if self.OpenOptions then
    return self:OpenOptions()
  end
end


function PPP:StopTicker()
  if self._ticker then
    self._ticker:Cancel()
    self._ticker = nil
  end
end

local function PPP_CPUOnUpdate(_, elapsed)
  if PPP._loggingEnabled ~= true then
    return
  end

  local frame = PPP._frame
  if not frame or not frame:IsVisible() then
    return
  end

  local s = PPPDB.session
  if not s or not C_AddOnProfiler_GetOverallMetric or not METRIC_LAST_TIME then
    return
  end

  local ignoreRemaining = PPP._cpuLogIgnoreRemaining
  if ignoreRemaining and ignoreRemaining > 0 then
    ignoreRemaining = ignoreRemaining - (elapsed or 0)
    PPP._cpuLogIgnoreRemaining = ignoreRemaining
    if ignoreRemaining > 0 then
      return
    end
  end

  local cpuLast = C_AddOnProfiler_GetOverallMetric(METRIC_LAST_TIME)
  if cpuLast == nil then
    return
  end

  StatsAdd(s.sessCPU, cpuLast)

  s._cpuBucketSum = (s._cpuBucketSum or 0) + cpuLast
  s._cpuBucketCount = (s._cpuBucketCount or 0) + 1

  if s.inCombat and s.combatCPU and s.combatCPU.active then
    StatsAdd(s.combatCPU, cpuLast)
  end

  if s.inEncounter and s.encCPU and s.encCPU.active then
    StatsAdd(s.encCPU, cpuLast)
  end
end

function PPP:IsLogging()
  return self._loggingEnabled == true
end

function PPP:StartCPULogger()
  if not self._cpuLogDriver then
    self._cpuLogDriver = CreateFrame("Frame", "PPP_CPULogDriver")
  end

  local o = self._options or GetOptions()
  if o.enabled == true
    and o.showCPU == true
    and self._profilerEnabled == true
    and self._loggingEnabled == true
  then
    local s = GetSession()
    local ignoreUntil = tonumber(s.apIgnoreUntilT)

    self._cpuLogIgnoreRemaining = ignoreUntil and math.max(0, ignoreUntil - GetTime()) or 0
    self._cpuLogDriver:SetScript("OnUpdate", PPP_CPUOnUpdate)
  else
    self._cpuLogIgnoreRemaining = nil
    self._cpuLogDriver:SetScript("OnUpdate", nil)
  end
end

function PPP:StopCPULogger()
  self._cpuLogIgnoreRemaining = nil

  if self._cpuLogDriver then
    self._cpuLogDriver:SetScript("OnUpdate", nil)
  end
end

function PPP:SetLoggingEnabled(enabled)
  local o = self._options or GetOptions()
  enabled = enabled == true

  if self._loggingEnabled == enabled and o.loggingEnabled == enabled then
    return
  end

  o.loggingEnabled = enabled
  self._loggingEnabled = enabled
  self._lastCPUDisplayKey = nil
  self._lastCPULoggingState = nil

  if enabled then
    self:ResetSession()
    self._profilerEnabled = AddOnProfilerEnabled()
    self._profilerStateCheckT = GetTime()
  else
    self._cpuLogIgnoreRemaining = nil
  end

  -- Keep the lightweight frame collector running for the live CPU snapshot.
  self:StartCPULogger()

  if self._frame then
    self:OnSampleTick(GetTime())
  end

  if self._tooltip and self._tooltip:IsShown() then
    self:ShowTooltip(nil, true)
  end
end

function PPP:StartTicker()
  self:StopTicker()

  local o = self._options or GetOptions()
  if not o.enabled then
    return
  end

  local interval = Clamp(tonumber(self._sampleInterval) or tonumber(o.sampleInterval) or 0.5, 0.05, 1.0)
  self._sampleInterval = interval

  -- Kick one immediate sample so the panel updates instantly.
  self:OnSampleTick(GetTime())

  self._ticker = C_Timer.NewTicker(interval, function()
    if PPP and PPP._frame and PPP._frame:IsVisible() then
      PPP:OnSampleTick(GetTime())
    end
  end)
end

function PPP:BuildFrame()

  if self._frame then return self._frame end

  local f = CreateFrame("Frame", "PPP_MainFrame", UIParent, "BackdropTemplate")
  self._frame = f

  f:SetClampedToScreen(true)
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)

  f:SetScript("OnEnter", function() PPP:OnEnterFrame() end)
  f:SetScript("OnLeave", function() PPP:OnLeaveFrame() end)

  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints(true)

  f.border = CreateFrame("Frame", nil, f, "BackdropTemplate")
  f.border:SetAllPoints(true)

  f.text = {}

  local function MakeLine(anchor, dy)
    local fs = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 6, dy)
    fs:SetJustifyH("LEFT")
    fs:SetText(anchor .. ": -")
    return fs
  end

  -- Lines (toggleable)
  f.text.fps = MakeLine("FPS", -6)
  f.text.ping = MakeLine("PING", -20)
  f.text.dur = MakeLine("DUR", -34)
  f.text.cpu = MakeLine("CPU", -48)

  self._textFPS = f.text.fps
  self._textMS  = f.text.ping
  self._textDur = f.text.dur
  self._textCPU = f.text.cpu

  local cpuLogButton = CreateFrame("Button", nil, f)
  cpuLogButton:SetFrameLevel((f:GetFrameLevel() or 1) + 5)
  cpuLogButton:RegisterForClicks("LeftButtonUp")
  cpuLogButton:SetPoint("TOPLEFT", f.text.cpu, "TOPLEFT", -6, 2)
  cpuLogButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  cpuLogButton:SetScript("OnEnter", function()
    PPP:OnEnterFrame()
  end)
  cpuLogButton:SetScript("OnLeave", function()
    if not f:IsMouseOver() then
      PPP:OnLeaveFrame()
    end
  end)
  cpuLogButton:SetScript("OnClick", function()
    PPP:SetLoggingEnabled(not PPP:IsLogging())
  end)
  self._cpuLogButton = cpuLogButton

  ApplyPanelFont(f)
  ApplyPanelTheme(f)

  RestorePosition(f)
  return f
end


local function StatsPush(stats, v)
  if not stats then return end
  StatsAdd(stats, v)
end

local function RollingPush(samples, nowT, v, windowSec)
  if not samples then return end
  v = tonumber(v)
  if not v then return end

  -- Store as 2 flat numeric arrays to avoid per-sample table allocations.
  local tArr = samples._t
  local vArr = samples._v
  if not tArr or not vArr then
    samples._t = samples._t or {}
    samples._v = samples._v or {}
    samples._head = samples._head or 1
    tArr = samples._t
    vArr = samples._v
  end

  local n = #tArr + 1
  tArr[n] = nowT
  vArr[n] = v

  if windowSec then
    RollingTrim(samples, windowSec, nowT)
  end
end

local function HistPush(hist, v)
  if not hist or not hist.counts then return end
  v = tonumber(v)
  if not v then return end

  local maxBin = tonumber(hist.maxBin) or 500
  if maxBin < 1 then maxBin = 500 end

  local b = floor(v + 0.5)
  b = Clamp(b, 0, maxBin)

  hist.counts[b] = (hist.counts[b] or 0) + 1
  hist.total = (tonumber(hist.total) or 0) + 1

  -- IMPORTANT: ensure the session histogram has a valid loop ceiling for low-avg calcs
  local prevMax = tonumber(hist._seenMax) or 0
  if b > prevMax then
    hist._seenMax = b
  end
end


local function GetLowestDurabilityPct()
  if not GetInventoryItemDurability then return nil end

  local low = nil
  for slot = 1, 18 do
    local cur, maxV = GetInventoryItemDurability(slot)
    if cur and maxV and maxV > 0 then
      local pct = (cur / maxV) * 100
      if low == nil or pct < low then
        low = pct
      end
    end
  end
  return low
end

local function PublishDurabilityPct()
  local dataBar = _G and _G.PleeBarAPI or nil
  if dataBar and dataBar.OnPerformancePanelDurabilityChanged then
    dataBar:OnPerformancePanelDurabilityChanged(cachedDurabilityPct or nil)
  end
end

local function RefreshDurabilityPct(forcePublish)
  local previous = cachedDurabilityPct
  cachedDurabilityPct = GetLowestDurabilityPct() or false

  if forcePublish or previous ~= cachedDurabilityPct then
    PublishDurabilityPct()
  end
end

function PPP:GetDurabilityPercent()
  if cachedDurabilityPct == nil then
    RefreshDurabilityPct(true)
  end

  return cachedDurabilityPct or nil
end

local function ApplyFrameState(self, o, fps, ms, dur, cpuRecent)
  local f = self._frame
  if not f then return end

  local showAny = false

  if o.showFPS then
    local key = fps and floor(fps + 0.5) or false
    if self._lastFPSDisplayKey ~= key then
      self._lastFPSDisplayKey = key
      if key then
        local r, g, b = ColorForFPS(o, key)
        self._textFPS:SetText(_hex(r, g, b) .. "FPS|r: " .. cStrong .. format("%d", key) .. "|r")
      else
        self._textFPS:SetText("FPS: -")
      end
    end
    if not self._textFPS:IsShown() then self._textFPS:Show() end
    showAny = true
  elseif self._textFPS:IsShown() then
    self._textFPS:Hide()
  end

  if o.showMS then
    local key = ms and floor(ms + 0.5) or false
    if self._lastMSDisplayKey ~= key then
      self._lastMSDisplayKey = key
      if key then
        local r, g, b = ColorForPing(o, key)
        self._textMS:SetText(_hex(r, g, b) .. "Ping|r: " .. cStrong .. format("%d", key) .. "|r")
      else
        self._textMS:SetText("PING: -")
      end
    end
    if not self._textMS:IsShown() then self._textMS:Show() end
    showAny = true
  elseif self._textMS:IsShown() then
    self._textMS:Hide()
  end

  if o.showDur then
    local key = dur and floor(dur + 0.5) or false
    if self._lastDurDisplayKey ~= key then
      self._lastDurDisplayKey = key
      if key then
        local r, g, b = ColorForDur(o, key)
        self._textDur:SetText(_hex(r, g, b) .. "DUR|r: " .. cStrong .. format("%d%%", key) .. "|r")
      else
        self._textDur:SetText("DUR: -")
      end
    end
    if not self._textDur:IsShown() then self._textDur:Show() end
    showAny = true
  elseif self._textDur:IsShown() then
    self._textDur:Hide()
  end

  if o.showCPU then
    local key = cpuRecent and floor((cpuRecent * 1000) + 0.5) or false
    local logging = self._loggingEnabled == true
    if self._lastCPUDisplayKey ~= key or self._lastCPULoggingState ~= logging then
      self._lastCPUDisplayKey = key
      self._lastCPULoggingState = logging
      local label = logging and "CPU*" or "CPU"
      if key then
        local value = key / 1000
        local r, g, b = ColorForCPU(o, value)
        self._textCPU:SetText(_hex(r, g, b) .. label .. "|r: " .. cStrong .. format("%.3f ms", value) .. "|r")
      else
        self._textCPU:SetText(label .. ": -")
      end
    end
    if not self._textCPU:IsShown() then self._textCPU:Show() end
    if self._cpuLogButton and not self._cpuLogButton:IsShown() then self._cpuLogButton:Show() end
    showAny = true
  else
    if self._textCPU:IsShown() then self._textCPU:Hide() end
    if self._cpuLogButton and self._cpuLogButton:IsShown() then self._cpuLogButton:Hide() end
  end

  if f:IsShown() ~= showAny then
    f:SetShown(showAny)
  end
end


function PPP:OnSample(nowT)
  self:OnSampleTick(nowT)
end


local function ShouldIgnoreInitialSamples(nowT, o, s)
  local ignoreSec = tonumber(o and o.apIgnoreFirstSec) or 0
  if ignoreSec <= 0 then return false end

  -- Preferred: use the explicit window set on PLAYER_ENTERING_WORLD
  local ignoreUntil = tonumber(s and s.apIgnoreUntilT)
  if ignoreUntil and nowT < ignoreUntil then
    return true
  end

  -- Fallback: if ignoreUntil is missing, ignore based on sessionStartT
  if (not ignoreUntil) and s and s.sessionStartT and (nowT - s.sessionStartT) < ignoreSec then
    return true
  end

  return false
end



function PPP:OnSampleTick(nowT)
  if not self._frame then return end

  local o = self._options or GetOptions()
  if not o.enabled then
    if self._frame:IsShown() then self._frame:Hide() end
    return
  end

  local s = GetSession()
  nowT = nowT or GetTime()
  if not s.sessionStartT then
    s.sessionStartT = nowT
  end

  local lastProfilerCheck = tonumber(self._profilerStateCheckT) or 0
  if self._profilerEnabled == nil or (nowT - lastProfilerCheck) >= 5 then
    local wasEnabled = self._profilerEnabled
    self._profilerEnabled = AddOnProfilerEnabled()
    self._profilerStateCheckT = nowT
    if wasEnabled ~= self._profilerEnabled then
      self:StartCPULogger()
      self._lastCPUDisplayKey = nil
    end
  end

  local logging = self._loggingEnabled == true
  local ignoreInitial = logging and ShouldIgnoreInitialSamples(nowT, o, s) or false
  local windowSec = logging and ((tonumber(o.rollingMinutes) or 8) * 60) or nil

  if logging and not ignoreInitial then
    local lastTrim = tonumber(s._lastTrimT) or 0
    if (nowT - lastTrim) >= 5 then
      if o.showFPS then RollingTrim(s.fpsSamples, windowSec, nowT) end
      if o.showMS  then RollingTrim(s.msSamples,  windowSec, nowT) end
      if o.showCPU then RollingTrim(s.cpuSamples, windowSec, nowT) end
      s._lastTrimT = nowT
    end
  end

  local fps = nil
  local ms = nil
  local dur = nil
  local cpuRecent = nil

  if o.showFPS and GetFramerate then
    fps = GetFramerate()

    if logging and not ignoreInitial then
      StatsPush(s.sessFPS, fps)
      RollingPush(s.fpsSamples, nowT, fps, windowSec)
      HistPush(s.sessFPSHist, fps)

      if s.inCombat and s.combatFPS and s.combatFPS.active then
        StatsAdd(s.combatFPS, fps)
        tinsert(s.combatFPSsamples, fps)
      end

      if s.inEncounter and s.encFPS and s.encFPS.active then
        StatsAdd(s.encFPS, fps)
        tinsert(s.encFPSsamples, fps)
      end
    end
  end

  if o.showMS then
    ms = GetPingMS(o)

    if logging and not ignoreInitial and ms then
      StatsPush(s.sessMS, ms)
      RollingPush(s.msSamples, nowT, ms, windowSec)
    end
  end

  if o.showDur then
    if cachedDurabilityPct == nil then
      RefreshDurabilityPct(true)
    end

    dur = cachedDurabilityPct or nil
    if dur then
      s.lastDurLow = dur
    end
  end

  if o.showCPU and self._profilerEnabled == true then
    cpuRecent = AP_GetOverall(METRIC_RECENT_AVG)
  end

  if logging and not ignoreInitial and o.showCPU then
    local bucketCount = tonumber(s._cpuBucketCount) or 0
    if bucketCount > 0 then
      local bucketAverage = (tonumber(s._cpuBucketSum) or 0) / bucketCount
      RollingPush(s.cpuSamples, nowT, bucketAverage, windowSec)
      s._cpuBucketSum = 0
      s._cpuBucketCount = 0
    end
  end

  ApplyFrameState(self, o, fps, ms, (s.lastDurLow or dur), cpuRecent)

  if logging and self._tooltip and self._tooltip:IsShown() then
    local lastTooltipRefresh = tonumber(self._lastTooltipRefreshT) or 0
    if (nowT - lastTooltipRefresh) >= 5 then
      self._lastTooltipRefreshT = nowT
      self:ShowTooltip(nil, true)
    end
  end
end

function PPP:OnEnterFrame()
  self:ShowTooltip()
end

function PPP:OnLeaveFrame()
  self:HideTooltip()
end


function PPP:EnsureTooltip()
  if self._tooltip and self._tooltip._isPPPTooltip then
    return self._tooltip
  end

  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f._isPPPTooltip = true
  f:SetFrameStrata("TOOLTIP")
  f:SetFrameLevel(1000)
  f:SetClampedToScreen(true)
  f:EnableMouse(false)
  f:Hide()

  local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  header:SetJustifyH("LEFT")
  header:SetText("Performance Panel")
  f._header = header

  -- 6 rows, 2 columns
  f._cells = {}
  for r = 1, 6 do
    f._cells[r] = {}
    for c = 1, 2 do
      local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetJustifyH("LEFT")
      fs:SetJustifyV("TOP")
      fs:SetSpacing(2)
      fs:SetText("")
      if fs.SetWordWrap then fs:SetWordWrap(true) end
      fs:Hide()
      f._cells[r][c] = fs
    end
  end

  function f:ApplyTheme()
    ApplyFrameBackdrop(self)

    local font, size, flags = ResolveFont()
    header:SetFont(font, (size or 12) + 3, flags or "")

    for r = 1, 6 do
      for c = 1, 2 do
        local fs = self._cells[r][c]
        fs:SetFont(font, size or 12, flags or "")
      end
    end

    local theme = GetTheme()
    local accent = theme.accent or { 0.30, 0.70, 1.00, 1 }
    header:SetTextColor(accent[1], accent[2], accent[3], 1)
  end

  function f:ClearCells()
    for r = 1, 6 do
      for c = 1, 2 do
        local fs = self._cells[r][c]
        fs:SetText("")
        fs:Hide()
      end
    end
  end

  function f:SetCell(r, c, text)
    local fs = self._cells[r] and self._cells[r][c]
    if not fs then return end
    text = text or ""
    fs:SetText(text)
    if text ~= "" then
      fs:Show()
    else
      fs:Hide()
    end
  end

  function f:Layout(expanded)
    local padL, padR = 12, 12
    local padT, padB = 10, 12
    local gapHeader = 8
    local rowGap = 12
    local colGap = 22

    local colW = expanded and 340 or 260
    local showRight = expanded and true or false

    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", self, "TOPLEFT", padL, -padT)

    local headerH = header:GetStringHeight() or 0
    local y = -padT - headerH - gapHeader

    local xL = padL
    local xR = padL + colW + colGap

    for r = 1, 6 do
      local left = self._cells[r][1]
      local right = self._cells[r][2]

      left:ClearAllPoints()
      left:SetPoint("TOPLEFT", self, "TOPLEFT", xL, y)
      left:SetWidth(colW)

      if showRight and right and right:IsShown() then
        right:ClearAllPoints()
        right:SetPoint("TOPLEFT", self, "TOPLEFT", xR, y)
        right:SetWidth(colW)
      else
        if right then
          right:SetText("")
          right:Hide()
        end
      end

      local hL = (left and left:IsShown()) and (left:GetStringHeight() or 0) or 0
      local hR = (right and right:IsShown()) and (right:GetStringHeight() or 0) or 0
      local rowH = math.max(hL, hR)

      if rowH > 0 then
        y = y - rowH - rowGap
      end
    end

    local w = padL + colW + padR
    if showRight then
      w = padL + colW + colGap + colW + padR
    end

    local h = (-y) + padB
    self:SetSize(Clamp(w, 280, 780), Clamp(h, 80, 1200))
  end

  local altWatcher = CreateFrame("Frame", nil, UIParent)
  altWatcher:Hide()
  altWatcher:EnableMouse(false)
  altWatcher._expanded = false
  altWatcher:RegisterEvent("MODIFIER_STATE_CHANGED")
  altWatcher:SetScript("OnEvent", function(selfWatcher, event, key, down)
    if not (PPP and PPP._tooltip and PPP._tooltip.IsShown and PPP._tooltip:IsShown()) then return end
    if key ~= "LALT" and key ~= "RALT" then return end
    local expanded = IsAltKeyDown() and true or false
    if expanded ~= selfWatcher._expanded then
      selfWatcher._expanded = expanded
      PPP:ShowTooltip(expanded, true)
    end
  end)
  self._tipAltWatcher = altWatcher

  self._tooltip = f
  f:ApplyTheme()

  return f
end


function PPP:HideTooltip()
  if self._tooltip then
    self._tooltip:Hide()
  end
  if self._tipAltWatcher then
    self._tipAltWatcher:Hide()
  end
end


local function PPP_Tip_UptimeSec(s, nowT)
  local startT = (s and s.sessionStartT) or nowT
  return math.max(0, (nowT or 0) - (startT or 0))
end

local function PPP_Tip_KV(cDim, cStrong, label, value)
  value = (value == nil or value == "") and "-" or value
  return "  " .. cDim .. label .. "|r " .. cStrong .. value .. "|r"
end

local function PPP_Tip_AvgLine(o, cDim, cStrong, label, v, colorFunc, fmt)
  if not v then
    return PPP_Tip_KV(cDim, cStrong, label, "-")
  end
  local text = string.format(fmt or "%.1f", v)
  if colorFunc then
    local r, g, b = colorFunc(o, v)
    return "  " .. cDim .. label .. "|r " .. _hex(r, g, b) .. text .. "|r"
  end
  return PPP_Tip_KV(cDim, cStrong, label, text)
end

local function PPP_Tip_BlockSession(o, s, nowT, expanded, cStrong, cDim, cAccent)
  local lines = {}
  lines[#lines + 1] = cAccent .. "Session|r " .. cDim .. "(uptime " .. FormatUptime(PPP_Tip_UptimeSec(s, nowT)) .. ")|r"

  if o.showFPS then
    local sessFPS = StatsAvg(s.sessFPS)
    local low1  = HistLowAvg({ counts = s.sessFPSHist.counts, total = s.sessFPSHist.total, maxBin = (s.sessFPSHist._seenMax or 500) }, 0.99)
    local low10 = HistLowAvg({ counts = s.sessFPSHist.counts, total = s.sessFPSHist.total, maxBin = (s.sessFPSHist._seenMax or 500) }, 0.90)

    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "FPS avg:", sessFPS, ColorForFPS, "%.1f")

    if s.sessFPS and s.sessFPS.min and s.sessFPS.max then
      lines[#lines + 1] = PPP_Tip_KV(cDim, cStrong, "FPS min/max:", string.format("%.0f / %.0f", s.sessFPS.min, s.sessFPS.max))
    end

    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "FPS 1% low:", low1, ColorForFPS, "%.1f")
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "FPS 10% low:", low10, ColorForFPS, "%.1f")
  end

  if o.showMS then
    local pingAvg = StatsAvg(s.sessMS)
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "Ping avg:", pingAvg, ColorForPing, "%.0f")
  end

  if o.showCPU then
    local cpuAvg = StatsAvg(s.sessCPU)
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "CPU avg:", cpuAvg, nil, "%.3f ms")
    if s.sessCPU and s.sessCPU.min and s.sessCPU.max then
      lines[#lines + 1] = PPP_Tip_KV(cDim, cStrong, "CPU min/max:", string.format("%.3f / %.3f ms", s.sessCPU.min, s.sessCPU.max))
    end
  end


  return table.concat(lines, "\n")
end

local function PPP_Tip_BlockRolling(o, s, nowT, windowSec, expanded, cStrong, cDim, cAccent)
  local lines = {}
  lines[#lines + 1] = cAccent .. "Rolling|r " .. cDim .. "(" .. tostring(o.rollingMinutes or 8) .. "m)|r"

  local now = nowT

  if o.showFPS then
    RollingTrim(s.fpsSamples, windowSec, now)
    local rollFPS, rollMin, rollMax = RollingCompute(s.fpsSamples)
    local rollLow1  = RollingLowAvg(s.fpsSamples, 0.99)
    local rollLow10 = RollingLowAvg(s.fpsSamples, 0.90)

    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "FPS avg:", rollFPS, ColorForFPS, "%.1f")
    if rollMin and rollMax then
      lines[#lines + 1] = PPP_Tip_KV(cDim, cStrong, "FPS min/max:", string.format("%.0f / %.0f", rollMin, rollMax))
    end
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "FPS 1% low:", rollLow1, ColorForFPS, "%.1f")
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "FPS 10% low:", rollLow10, ColorForFPS, "%.1f")
  end

  if o.showMS then
    RollingTrim(s.msSamples, windowSec, now)
    local rollPing = RollingCompute(s.msSamples)
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "Ping avg:", rollPing, ColorForPing, "%.0f")
  end

  if o.showCPU then
    RollingTrim(s.cpuSamples, windowSec, now)
    local rollCPU, cpuMin, cpuMax = RollingCompute(s.cpuSamples)
    lines[#lines + 1] = PPP_Tip_AvgLine(o, cDim, cStrong, "CPU avg:", rollCPU, nil, "%.3f ms")
    if cpuMin and cpuMax then
      lines[#lines + 1] = PPP_Tip_KV(cDim, cStrong, "CPU min/max:", string.format("%.3f / %.3f ms", cpuMin, cpuMax))
    end
  end


  return table.concat(lines, "\n")
end

function PPP:ShowTooltip(forceExpanded, fromAltWatcher)

  if not self._frame then return end

  local o = GetOptions()
  local s = GetSession()
  local nowT = GetTime()
  local windowSec = (tonumber(o.rollingMinutes) or 8) * 60

  -- Keep color codes in sync with theme.
  if RefreshColorCodes then
    RefreshColorCodes()
  end

  local t = self:EnsureTooltip()
  t:ApplyTheme()

  -- Position near cursor
  local mx, my = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  mx, my = mx / scale, my / scale

  t:ClearAllPoints()
  t:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", mx + 16, my - 16)

  local expanded = (forceExpanded == true)
  if forceExpanded == nil then
    expanded = IsAltKeyDown() and true or false
  end

  local logging = self:IsLogging()
  if t._header then
    t._header:SetText(logging and "Performance Panel - Logging" or "Performance Panel - Snapshot")
  end

  if not logging then
    t:ClearCells()
    t:SetCell(1, 1, cAccent .. "Snapshot mode|r\n  " .. cDim .. "FPS, ping, durability, and current CPU are displayed live.|r")
    t:SetCell(2, 1, cStrong .. "Click the CPU line to start logging.|r\n  " .. cDim .. "No session, rolling, combat, encounter, or addon history is being recorded.|r")
    t:Layout(false)
    t:Show()
    if self._tipAltWatcher then
      self._tipAltWatcher:Hide()
    end
    return
  end

  local function uptimeSec()
    return PPP_Tip_UptimeSec(s, nowT)
  end

  local function kv(label, value)
    return PPP_Tip_KV(cDim, cStrong, label, value)
  end

  local function avgLine(label, v, colorFunc, fmt)
    return PPP_Tip_AvgLine(o, cDim, cStrong, label, v, colorFunc, fmt)
  end


  local function blockSession()
    return PPP_Tip_BlockSession(o, s, nowT, expanded, cStrong, cDim, cAccent)
  end



  local function blockRolling()
    local lines = {}
    lines[#lines + 1] = cAccent .. "Rolling|r " .. cDim .. "(" .. tostring(o.rollingMinutes or 8) .. "m)|r"

    local now = nowT

    if o.showFPS then
      RollingTrim(s.fpsSamples, windowSec, now)
      local rollFPS, rollMin, rollMax = RollingCompute(s.fpsSamples)
      local rollLow1  = RollingLowAvg(s.fpsSamples, 0.99)
      local rollLow10 = RollingLowAvg(s.fpsSamples, 0.90)

      lines[#lines + 1] = avgLine("FPS avg:", rollFPS, ColorForFPS, "%.1f")
      lines[#lines + 1] = avgLine("FPS 1% low:", rollLow1, ColorForFPS, "%.1f")

      if expanded then
        if rollMin and rollMax then
          lines[#lines + 1] = kv("FPS min/max:", format("%.0f / %.0f", rollMin, rollMax))
        end
        lines[#lines + 1] = avgLine("FPS 10% low:", rollLow10, ColorForFPS, "%.1f")
      end
    end


    if o.showMS then
      RollingTrim(s.msSamples, windowSec, now)
      local rollPing = RollingCompute(s.msSamples)
      lines[#lines + 1] = avgLine("Ping avg:", rollPing, ColorForPing, "%.0f")
    end

    if o.showCPU then
      RollingTrim(s.cpuSamples, windowSec, now)
      local rollCPU, cpuMin, cpuMax = RollingCompute(s.cpuSamples)
      lines[#lines + 1] = avgLine("CPU avg:", rollCPU, nil, "%.3f ms")
      if cpuMin and cpuMax then
        lines[#lines + 1] = kv("CPU min/max:", format("%.3f / %.3f ms", cpuMin, cpuMax))
      end
    end


    return table.concat(lines, "\n")

  end

  local function blockLastCombat()
    local lines = {}
    lines[#lines + 1] = cAccent .. "Last Combat|r"

    local fpsS = s.lastCombatFPS
    local fpsArr = s.lastCombatFPSsamples or {}
    local cpuS = s.lastCombatCPU

    if not fpsS and not cpuS then
      lines[#lines + 1] = "  " .. cDim .. "No combat recorded yet (enter combat once to populate).|r"
      return table.concat(lines, "\n")
    end

    if fpsS then
      lines[#lines + 1] = avgLine("FPS avg:", StatsAvg(fpsS), ColorForFPS, "%.1f")
      if fpsS.min and fpsS.max then
        lines[#lines + 1] = kv("FPS min/max:", format("%.0f / %.0f", fpsS.min, fpsS.max))
      end
      lines[#lines + 1] = avgLine("FPS 1% low:", AvgBottomPercent(fpsArr, 0.01), ColorForFPS, "%.1f")
      lines[#lines + 1] = avgLine("FPS 10% low:", AvgBottomPercent(fpsArr, 0.10), ColorForFPS, "%.1f")
    end

    if cpuS then
      lines[#lines + 1] = avgLine("CPU avg:", StatsAvg(cpuS), nil, "%.3f ms")
      if cpuS.min and cpuS.max then
        lines[#lines + 1] = kv("CPU min/max:", format("%.3f / %.3f ms", cpuS.min, cpuS.max))
      end
    end

    return table.concat(lines, "\n")

  end

  local function blockLastEncounter()
    local lines = {}
    lines[#lines + 1] = cAccent .. "Last Encounter|r"

    local fpsS = s.lastEncFPS
    local fpsArr = s.lastEncFPSsamples or {}
    local cpuS = s.lastEncCPU

    if not fpsS and not cpuS then
      lines[#lines + 1] = "  " .. cDim .. "No encounter recorded yet.|r"
      return table.concat(lines, "\n")
    end

    if fpsS then
      lines[#lines + 1] = avgLine("FPS avg:", StatsAvg(fpsS), ColorForFPS, "%.1f")
      if fpsS.min and fpsS.max then
        lines[#lines + 1] = kv("FPS min/max:", format("%.0f / %.0f", fpsS.min, fpsS.max))
      end
      lines[#lines + 1] = avgLine("FPS 1% low:", AvgBottomPercent(fpsArr, 0.01), ColorForFPS, "%.1f")
      lines[#lines + 1] = avgLine("FPS 10% low:", AvgBottomPercent(fpsArr, 0.10), ColorForFPS, "%.1f")
    end

    if cpuS then
      lines[#lines + 1] = avgLine("CPU avg:", StatsAvg(cpuS), nil, "%.3f ms")
      if cpuS.min and cpuS.max then
        lines[#lines + 1] = kv("CPU min/max:", format("%.3f / %.3f ms", cpuS.min, cpuS.max))
      end
    end

    return table.concat(lines, "\n")

  end

  local function blockLegend()
    local lines = {}

    lines[#lines + 1] = cAccent .. "Legend - Frame budget|r"
    lines[#lines + 1] = "  " .. cDim .. "ms per frame|r"
    lines[#lines + 1] = "  " .. cAccent .. "60 FPS" .. cDim .. " = 16.7 ms|r"
    lines[#lines + 1] = "  " .. cAccent .. "100 FPS" .. cDim .. " = 10.0 ms|r"
    lines[#lines + 1] = "  " .. cAccent .. "144 FPS" .. cDim .. " = 6.9 ms|r"

    lines[#lines + 1] = ""
    lines[#lines + 1] = cAccent .. "Legend - FPS lows|r"
    lines[#lines + 1] = "  " .. cAccent .. "Average FPS" .. cDim .. " = general smoothness.|r"
    lines[#lines + 1] = "  " .. cAccent .. "1% low" .. cDim .. " = avg of the worst 1% frames (stutter indicator).|r"
    lines[#lines + 1] = "  " .. cAccent .. "10% low" .. cDim .. " = typical dips (less extreme than 1% low).|r"


    return table.concat(lines, "\n")
  end

  local function blockLegendAddonCPU()
    local lines = {}

    lines[#lines + 1] = cAccent .. "Legend - AddOn CPU|r"
    lines[#lines + 1] = "  " .. cDim .. "rough guidance (ms per frame)|r"
    lines[#lines + 1] = "  " .. cAccent .. "~0.05 ms" .. cDim .. " = tiny|r"
    lines[#lines + 1] = "  " .. cAccent .. "~0.5 ms" .. cDim .. " = noticeable|r"
    lines[#lines + 1] = "  " .. cAccent .. "2 ms+" .. cDim .. " = heavy|r"

    lines[#lines + 1] = ""
    lines[#lines + 1] = cAccent .. "Note|r"
    lines[#lines + 1] = "  " .. cDim .. "Higher FPS means less ms budget per frame,|r"
    lines[#lines + 1] = "  " .. cDim .. "so the same addon cost matters more at 144|r"
    lines[#lines + 1] = "  " .. cDim .. "than at 60.|r"


    return table.concat(lines, "\n")
  end

  local function blockAddonCPU()
    local lines = {}
    lines[#lines + 1] = cAccent .. "Top AddOns (CPU)|r " .. cDim .. "(recent / peak)|r"

    if PPP._profilerEnabled ~= true then
      lines[#lines + 1] = "  " .. cDim .. "AddOnProfiler is disabled.|r"
      return table.concat(lines, "\n")
    end

    local overallPeak = AP_GetOverall(METRIC_PEAK_TIME)
    if overallPeak then
      lines[#lines + 1] = kv("Overall peak:", format("%.3f ms", tonumber(overallPeak) or 0))
    end

    local list = BuildTopAddons and BuildTopAddons(o) or nil
    if not list or #list == 0 then
      lines[#lines + 1] = "  " .. cDim .. "No data yet (give it a few seconds).|r"
      return table.concat(lines, "\n")
    end

    for i = 1, #list do
      local r = list[i]
      lines[#lines + 1] = "  " .. cStrong .. (r.name or "?") .. "|r " .. cDim .. "recent|r " .. cStrong .. (r.avg or "-") .. "|r " .. cDim .. "peak|r " .. cStrong .. (r.peak or "-") .. "|r"
    end

    return table.concat(lines, "\n")
  end


  t:ClearCells()

  if not expanded then
    t:SetCell(1, 1, blockSession())
    t:SetCell(2, 1, blockRolling())
    t:SetCell(3, 1, blockLastCombat())
    t:SetCell(4, 1, blockLastEncounter())
    t:SetCell(5, 1, cDim .. "Hold ALT for more details. Click CPU to stop logging.|r")
    t:Layout(false)
  else

    -- Row 1: Session + Rolling
    t:SetCell(1, 1, blockSession())
    t:SetCell(1, 2, blockRolling())

    -- Row 2: Last Combat + Last Encounter
    t:SetCell(2, 1, blockLastCombat())
    t:SetCell(2, 2, blockLastEncounter())

    -- Row 3: Legend + controls
    t:SetCell(3, 1, blockLegend())
    t:SetCell(3, 2, blockLegendAddonCPU())

    -- Row 4: CPU Top AddOns + Controls
    t:SetCell(4, 1, blockAddonCPU())
    t:SetCell(4, 2, (cAccent .. "Controls|r\n  " .. cDim ..
      "ALT: expand/collapse\n  Click CPU: stop logging\n  Drag: move panel\n  /pp: options\n  /pp reset\n  /pp toggle|r"))


    t:Layout(true)
  end

  t:Show()

  if self._tipAltWatcher and not fromAltWatcher then
    self._tipAltWatcher._expanded = expanded
    self._tipAltWatcher:Show()
  end
end

function PPP:EnsureDriver()
  if self._driver then return self._driver end

  local d = CreateFrame("Frame", "PPP_EventDriver")
  self._driver = d

  d:RegisterEvent("PLAYER_ENTERING_WORLD")
  d:RegisterEvent("PLAYER_REGEN_DISABLED")
  d:RegisterEvent("PLAYER_REGEN_ENABLED")
  d:RegisterEvent("ENCOUNTER_START")
  d:RegisterEvent("ENCOUNTER_END")
  d:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
  d:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

  d:SetScript("OnEvent", function(_, event, ...)
    local s = GetSession()

    if event == "PLAYER_ENTERING_WORLD" then
      local isInitialLogin, isReloadingUi = ...
      local o = PPP._options or GetOptions()

      if isInitialLogin and not isReloadingUi then
        PPPDB.session = nil
        s = GetSession()
      end

      if isReloadingUi then
        s.sessionStartT = GetTime()
      end

      local ignoreSec = tonumber(o.apIgnoreFirstSec) or 0
      if ignoreSec > 0 then
        s.apIgnoreUntilT = GetTime() + ignoreSec
      end

      RefreshDurabilityPct(true)
      PPP._loggingEnabled = o.loggingEnabled == true
      PPP._profilerEnabled = AddOnProfilerEnabled()
      PPP._profilerStateCheckT = GetTime()

      if PPP.OnPlayerEnteringWorld then
        PPP:OnPlayerEnteringWorld()
      end

      PPP:EnsurePerfPanel(true)
      PPP:StartCPULogger()
      return
    end

    if event == "UPDATE_INVENTORY_DURABILITY" or event == "PLAYER_EQUIPMENT_CHANGED" then
      RefreshDurabilityPct(false)
      return
    end

    if event == "PLAYER_REGEN_DISABLED" then
      s.inCombat = true
      if PPP:IsLogging() then
        StatsReset(s.combatFPS)
        StatsReset(s.combatCPU)
        s.combatFPSsamples = {}
        s.combatCPUsamples = {}
        s.combatFPS.active = true
        s.combatCPU.active = true
      end
      return
    end

    if event == "PLAYER_REGEN_ENABLED" then
      s.inCombat = false

      if PPP:IsLogging() then
        if s.combatFPS and (s.combatFPS.n or 0) > 0 then
          s.lastCombatFPS = { n = s.combatFPS.n, sum = s.combatFPS.sum, min = s.combatFPS.min, max = s.combatFPS.max }
        end
        if s.combatCPU and (s.combatCPU.n or 0) > 0 then
          s.lastCombatCPU = { n = s.combatCPU.n, sum = s.combatCPU.sum, min = s.combatCPU.min, max = s.combatCPU.max }
        end

        s.lastCombatFPSsamples = s.combatFPSsamples or {}
        s.lastCombatCPUsamples = s.combatCPUsamples or {}
      end

      if s.combatFPS then s.combatFPS.active = false end
      if s.combatCPU then s.combatCPU.active = false end
      return
    end

    if event == "ENCOUNTER_START" then
      s.inEncounter = true
      if PPP:IsLogging() then
        StatsReset(s.encFPS)
        StatsReset(s.encCPU)
        s.encFPSsamples = {}
        s.encCPUsamples = {}
        s.encFPS.active = true
        s.encCPU.active = true
      end
      return
    end

    if event == "ENCOUNTER_END" then
      s.inEncounter = false

      if PPP:IsLogging() then
        if s.encFPS and (s.encFPS.n or 0) > 0 then
          s.lastEncFPS = { n = s.encFPS.n, sum = s.encFPS.sum, min = s.encFPS.min, max = s.encFPS.max }
        end
        if s.encCPU and (s.encCPU.n or 0) > 0 then
          s.lastEncCPU = { n = s.encCPU.n, sum = s.encCPU.sum, min = s.encCPU.min, max = s.encCPU.max }
        end

        s.lastEncFPSsamples = s.encFPSsamples or {}
        s.lastEncCPUsamples = s.encCPUsamples or {}
      end

      if s.encFPS then s.encFPS.active = false end
      if s.encCPU then s.encCPU.active = false end
      return
    end
  end)

  return d
end

function PPP:EnsurePerfPanel(force)
  if self._frame and not force then return self._frame end
  self:BuildFrame()
  self:EnsureDriver()
  self:ApplyLayout()
  return self._frame
end

function PPP:SetEnabled(enabled)
  local o = self._options or GetOptions()
  o.enabled = not not enabled

  -- Ensure runtime objects exist when enabling.
  if o.enabled then
    self:EnsurePerfPanel(true)
    self:EnsureDriver()

    if self._frame then
      self._frame:Show()
    end

    self:StartTicker()
    self:StartCPULogger()
  else
    self:StopTicker()
    self:StopCPULogger()

    -- Disable instantly: hide panel + any tooltip.
    if self._frame then
      self._frame:Hide()
    end
    if self.HideTooltip then
      self:HideTooltip()
    end
  end
end

function PPP:ResetSession()
  PPPDB.session = nil

  local s = GetSession()
  local nowT = GetTime()
  local o = GetOptions()

  s.sessionStartT = nowT
  s.inCombat = (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player")) and true or false
  s.inEncounter = (_G.IsEncounterInProgress and _G.IsEncounterInProgress()) and true or false

  if s.inCombat then
    s.combatFPS.active = true
    s.combatCPU.active = true
  end
  if s.inEncounter then
    s.encFPS.active = true
    s.encCPU.active = true
  end

  local ignoreSec = tonumber(o.apIgnoreFirstSec) or 0
  if ignoreSec > 0 then
    s.apIgnoreUntilT = nowT + ignoreSec
  else
    s.apIgnoreUntilT = nil
  end
end


local function GetLSMFontValues()

  local t = {}

  -- Always include a sentinel entry for default.
  t["Default"] = "Default"

  if LSM and LSM.MediaType and LSM.MediaType.FONT and LSM.HashTable then
    local ht = LSM:HashTable(LSM.MediaType.FONT)
    for k in pairs(ht) do
      t[k] = k
    end
  end

  return t
end


local function GetOutlineValues()
  return {
    [""]                 = "None",
    ["OUTLINE"]          = "Outline",
    ["THICKOUTLINE"]     = "Thick Outline",
    ["MONOCHROMEOUTLINE"]= "Mono Outline",
  }
end

function PPP:BuildOptions()
  local o = GetOptions()

  local opts = {
    type = "group",
    name = "Pleeb Performance Panel",
    args = {
      general = {
        type = "group", order = 1, name = "General", inline = true,
        args = {
          enabled = {
            type = "toggle", order = 1,
            name = "Enabled",
            get = function() return o.enabled end,
            set = function(_, v) PPP:SetEnabled(v) end,
          },

          layout = {
            type = "select", order = 2,
            name = "Layout",
            values = { vertical = "Vertical", horizontal = "Horizontal" },
            get = function() return o.layout end,
            set = function(_, v) o.layout = v; PPP:ApplyLayout(true) end,
          },
        },
      },

      metrics = {
        type = "group", order = 2, name = "Panel Metrics", inline = true,
        args = {
          showFPS = {
            type = "toggle", order = 1,
            name = "FPS",
            get = function() return o.showFPS end,
            set = function(_, v) o.showFPS = v; PPP:ApplyLayout(true) end,
          },
          showMS = {
            type = "toggle", order = 2,
            name = "Ping",
            get = function() return o.showMS end,
            set = function(_, v) o.showMS = v; PPP:ApplyLayout(true) end,
          },
          msSource = {
            type = "select", order = 3,
            name = "Ping source",
            values = { home = "Home", world = "World" },
            get = function() return o.msSource end,
            set = function(_, v) o.msSource = v end,
          },
          showDur = {
            type = "toggle", order = 4,
            name = "Durability",
            get = function() return o.showDur end,
            set = function(_, v) o.showDur = v; PPP:ApplyLayout(true) end,
          },
          showCPU = {
            type = "toggle", order = 5,
            name = "CPU",
            get = function() return o.showCPU end,
            set = function(_, v)
              o.showCPU = v
              PPP:ApplyLayout(true)
              PPP:StartCPULogger()
            end,
          },
          loggingEnabled = {
            type = "toggle", order = 6,
            name = "Enable logging",
            desc = "Off by default. The panel still shows live snapshots. Click the CPU line to toggle logging.",
            get = function() return PPP:IsLogging() end,
            set = function(_, v) PPP:SetLoggingEnabled(v) end,
          },
        },
      },

      tooltip = {
        type = "group", order = 3, name = "Tooltip", inline = true,
        args = {
          rollingMinutes = {
            type = "range", order = 1,
            name = "Rolling window (minutes)",
            min = 1, max = 30, step = 1,
            get = function() return o.rollingMinutes end,
            set = function(_, v) o.rollingMinutes = v end,
          },
          cpuTopN = {
            type = "range", order = 2,
            name = "Top AddOns count",
            min = 3, max = 12, step = 1,
            get = function() return o.cpuTopN end,
            set = function(_, v) o.cpuTopN = v end,
          },

          apIgnoreFirstSec = {
            type = "range", order = 3,
            name = "Ignore peak first seconds",
            min = 0, max = 30, step = 1,
            get = function() return o.apIgnoreFirstSec end,
            set = function(_, v) o.apIgnoreFirstSec = v end,
          },
        },
      },

      font = {
        type = "group", order = 4, name = "Font", inline = true,
        args = {
          fontKey = {
            type = "select", order = 1,
            name = "Font",
            dialogControl = "LSM30_Font",
            values = GetLSMFontValues,
            get = function() return o.font.fontKey or "Default" end,
            set = function(_, v)
              o.font.fontKey = (v ~= "Default" and v or nil)
              PPP:ApplyLayout(true)
            end,
          },

          fontSize = {
            type = "range", order = 2,
            name = "Size",
            min = 8, max = 24, step = 1,
            get = function() return o.font.size end,
            set = function(_, v) o.font.size = v; PPP:ApplyLayout(true) end,
          },
          fontOutline = {
            type = "select", order = 3,
            name = "Outline",
            values = GetOutlineValues,
            get = function() return (o.font.outline == "NONE") and "" or (o.font.outline or "OUTLINE") end,
            set = function(_, v)
              o.font.outline = (v == "" and "NONE" or v)
              PPP:ApplyLayout(true)
            end,
          },
        },
      },

      theme = {
        type = "group", order = 5, name = "Theme", inline = true,
        args = {
          themePreset = {
            type = "select", order = 1,
            name = "Preset",
            values = { modern = "Modern", modernDark = "Modern Dark", modernLight = "Modern Light" },
            get = function() return o.theme end,
            set = function(_, v) o.theme = v; PPP:ApplyLayout(true) end,
          },
          colorize = {
            type = "toggle", order = 2,
            name = "Colorize",
            get = function() return o.colorize end,
            set = function(_, v) o.colorize = v; PPP:ApplyLayout(true) end,
          },
        },
      },

      thresholds = {
        type = "group", order = 6, name = "Thresholds", inline = true,
        args = {
          fpsGoal = {
            type = "range", order = 1,
            name = "FPS goal",
            min = 10, max = 300, step = 1,
            get = function() return o.fpsGoal end,
            set = function(_, v) o.fpsGoal = v; PPP:ApplyLayout(true) end,
          },
          fpsOrangePct = {
            type = "range", order = 2,
            name = "FPS orange percent",
            min = 0.10, max = 1.00, step = 0.01,
            get = function() return o.fpsOrangePct end,
            set = function(_, v) o.fpsOrangePct = v; PPP:ApplyLayout(true) end,
          },
          fpsRedPct = {
            type = "range", order = 3,
            name = "FPS red percent",
            min = 0.10, max = 1.00, step = 0.01,
            get = function() return o.fpsRedPct end,
            set = function(_, v) o.fpsRedPct = v; PPP:ApplyLayout(true) end,
          },

          pingBaseline = {
            type = "range", order = 4,
            name = "Ping baseline",
            min = 0, max = 300, step = 1,
            get = function() return o.pingBaseline end,
            set = function(_, v) o.pingBaseline = v; PPP:ApplyLayout(true) end,
          },
          pingOrangeAdd = {
            type = "range", order = 5,
            name = "Ping orange add",
            min = 0, max = 300, step = 1,
            get = function() return o.pingOrangeAdd end,
            set = function(_, v) o.pingOrangeAdd = v; PPP:ApplyLayout(true) end,
          },
          pingRedAdd = {
            type = "range", order = 6,
            name = "Ping red add",
            min = 0, max = 600, step = 1,
            get = function() return o.pingRedAdd end,
            set = function(_, v) o.pingRedAdd = v; PPP:ApplyLayout(true) end,
          },
        },
      },

      colors = {
        type = "group", order = 7, name = "Colors", inline = true,
        args = {
          fpsGood = {
            type = "color", order = 1, name = "FPS good",
            dialogControl = "ColorPicker",
            hasAlpha = false,
            get = function()
              local c = o.colors.fpsGood or { 1, 1, 1 }
              return c[1], c[2], c[3]
            end,
            set = function(_, r, g, b)
              o.colors.fpsGood = { r, g, b }
              PPP:ApplyLayout(true)
            end,
          },
          fpsWarn = {
            type = "color", order = 2, name = "FPS warn",
            dialogControl = "ColorPicker",
            hasAlpha = false,
            get = function()
              local c = o.colors.fpsWarn or { 1, 1, 1 }
              return c[1], c[2], c[3]
            end,
            set = function(_, r, g, b)
              o.colors.fpsWarn = { r, g, b }
              PPP:ApplyLayout(true)
            end,
          },
          fpsBad = {
            type = "color", order = 3, name = "FPS bad",
            dialogControl = "ColorPicker",
            hasAlpha = false,
            get = function()
              local c = o.colors.fpsBad or { 1, 1, 1 }
              return c[1], c[2], c[3]
            end,
            set = function(_, r, g, b)
              o.colors.fpsBad = { r, g, b }
              PPP:ApplyLayout(true)
            end,
          },

          pingGood = {
            type = "color", order = 10, name = "Ping good",
            dialogControl = "ColorPicker",
            hasAlpha = false,
            get = function()
              local c = o.colors.pingGood or { 1, 1, 1 }
              return c[1], c[2], c[3]
            end,
            set = function(_, r, g, b)
              o.colors.pingGood = { r, g, b }
              PPP:ApplyLayout(true)
            end,
          },
          pingWarn = {
            type = "color", order = 11, name = "Ping warn",
            dialogControl = "ColorPicker",
            hasAlpha = false,
            get = function()
              local c = o.colors.pingWarn or { 1, 1, 1 }
              return c[1], c[2], c[3]
            end,
            set = function(_, r, g, b)
              o.colors.pingWarn = { r, g, b }
              PPP:ApplyLayout(true)
            end,
          },
          pingBad = {
            type = "color", order = 12, name = "Ping bad",
            dialogControl = "ColorPicker",
            hasAlpha = false,
            get = function()
              local c = o.colors.pingBad or { 1, 1, 1 }
              return c[1], c[2], c[3]
            end,
            set = function(_, r, g, b)
              o.colors.pingBad = { r, g, b }
              PPP:ApplyLayout(true)
            end,
          },
        },
      },
    },
  }

  self.__pppCachedOptionsTable = opts
end

function PPP:BuildAceGUIOptions(parent)
  if not parent or not parent.ReleaseChildren or not AceGUI then return end

  local optionsAceGUI = {
    Create = function(_, widgetType)
      return _PPP_CreateOptionsWidget(widgetType)
    end,
  }
  local AceGUI = optionsAceGUI

  parent:ReleaseChildren()

  local o = GetOptions()

  local function Mark(w)
    if type(w) == "table" then
      w.__puiPPPOptions = true
    end
    return w
  end

  local function Add(kind)
    local t
    if kind == "inlinegroup" then
      t = "InlineGroup"
    elseif kind == "toggle" then
      t = "CheckBox"
    elseif kind == "slider" then
      t = "Slider"
    elseif kind == "dropdown" then
      t = "Dropdown"
    elseif kind == "label" then
      t = "Label"
    else
      return nil
    end

    local w = AceGUI:Create(t)
    if type(w) ~= "table" or not w.frame then return nil end
    Mark(w)

    if kind == "inlinegroup" then
      if w.SetFullWidth then w:SetFullWidth(true) end
      if w.SetLayout then w:SetLayout("Flow") end
    else
      if w.SetRelativeWidth then w:SetRelativeWidth(1/3) end
    end

    parent:AddChild(w)
    return w
  end

  local function ApplyNow(force)
    if type(PPP.ApplyLayout) == "function" then
      PPP:ApplyLayout(force and true or false)
    end
    if type(PPP.EnsurePerfPanel) == "function" then
      PPP:EnsurePerfPanel(true)
    end
  end

  -- Header
  do
    local head = Add("label")
    if head then
      head:SetFullWidth(true)
      head:SetText("Pleeb Performance Panel (PPP)")
    end
  end

  -- General
  do
    local g = Add("inlinegroup")
    if g then
      g:SetTitle("General")
      g:SetLayout("Flow")

      local en = AceGUI:Create("CheckBox")
      if en then
        Mark(en)
        en:SetLabel("Enabled")
        en:SetValue(not not o.enabled)
        en:SetCallback("OnValueChanged", function(_, _, v)
          PPP:SetEnabled(v)
        end)
        en:SetRelativeWidth(1/3)
        g:AddChild(en)
      end

      local layout = AceGUI:Create("Dropdown")
      if layout then
        Mark(layout)
        layout:SetLabel("Layout")
        layout:SetList({ vertical = "Vertical", horizontal = "Horizontal" })
        layout:SetValue(o.layout)
        layout:SetCallback("OnValueChanged", function(_, _, v)
          o.layout = (v == "horizontal") and "horizontal" or "vertical"
          ApplyNow(true)
        end)
        layout:SetRelativeWidth(1/3)
        g:AddChild(layout)
      end

      local msSrc = AceGUI:Create("Dropdown")
      if msSrc then
        Mark(msSrc)
        msSrc:SetLabel("MS source")
        msSrc:SetList({ world = "World", home = "Home" })
        msSrc:SetValue(o.msSource)
        msSrc:SetCallback("OnValueChanged", function(_, _, v)
          if v ~= "home" and v ~= "world" then v = "world" end
          o.msSource = v
          ApplyNow(false)
        end)
        msSrc:SetRelativeWidth(1/3)
        g:AddChild(msSrc)
      end

      local samp = AceGUI:Create("Slider")
      if samp then
        Mark(samp)
        samp:SetLabel("Sample interval (sec)")
        samp:SetSliderValues(0.1, 2.0, 0.1)
        samp:SetValue(tonumber(o.sampleInterval) or 0.5)
        samp:SetCallback("OnValueChanged", function(_, _, v)
          o.sampleInterval = tonumber(v) or 0.5
          if type(PPP.StartTicker) == "function" then
            PPP:StartTicker()
          end
        end)
        samp:SetRelativeWidth(1/3)
        g:AddChild(samp)
      end
    end
  end

  -- Display
  do
    local d = Add("inlinegroup")
    if d then
      d:SetTitle("Display")
      d:SetLayout("Flow")

      local function AddToggle(label, key, relayout)
        local w = AceGUI:Create("CheckBox")
        if not w then return end
        Mark(w)
        w:SetLabel(label)
        w:SetValue(not not o[key])
        w:SetCallback("OnValueChanged", function(_, _, v)
          o[key] = not not v
          ApplyNow(relayout)
          if key == "showCPU" then
            PPP:StartCPULogger()
          end
        end)
        w:SetRelativeWidth(1/3)
        d:AddChild(w)
      end

      AddToggle("Show FPS", "showFPS", true)
      AddToggle("Show MS",  "showMS",  true)
      AddToggle("Show Durability", "showDur", true)
      AddToggle("Show CPU", "showCPU", true)

      local logging = AceGUI:Create("CheckBox")
      if logging then
        Mark(logging)
        logging:SetLabel("Enable logging")
        logging:SetDescription("Off by default. The panel still shows live snapshots. You can also click the CPU line.")
        logging:SetValue(PPP:IsLogging())
        logging:SetCallback("OnValueChanged", function(_, _, v)
          PPP:SetLoggingEnabled(v)
        end)
        logging:SetRelativeWidth(1/3)
        d:AddChild(logging)
      end
    end
  end

  -- Theme + Font
  do
    local tf = Add("inlinegroup")
    if tf then
      tf:SetTitle("Theme + Font")
      tf:SetLayout("Flow")

      local theme = AceGUI:Create("Dropdown")
      if theme then
        Mark(theme)
        theme:SetLabel("Theme")
        theme:SetList({ modern = "Modern", modernDark = "Modern Dark", modernLight = "Modern Light" })
        theme:SetValue(o.theme)
        theme:SetCallback("OnValueChanged", function(_, _, v)
          if v ~= "modern" and v ~= "modernDark" and v ~= "modernLight" then v = "modern" end
          o.theme = v
          ApplyNow(true)
        end)
        theme:SetRelativeWidth(1/3)
        tf:AddChild(theme)
      end

      local fontDD = AceGUI:Create("Dropdown")
      if fontDD then
        Mark(fontDD)
        fontDD:SetLabel("Font (LSM)")
        fontDD:SetList(GetLSMFontValues())
        fontDD:SetValue((o.font and o.font.fontKey) or "Default")
        fontDD:SetCallback("OnValueChanged", function(_, _, v)
          o.font = o.font or {}
          local vv = tostring(v or "")
          if vv == "" or vv == "Default" then
            o.font.fontKey = nil
          else
            o.font.fontKey = vv
          end
          ApplyNow(true)
        end)
        fontDD:SetRelativeWidth(1/3)
        tf:AddChild(fontDD)
      end

      local fsize = AceGUI:Create("Slider")
      if fsize then
        Mark(fsize)
        fsize:SetLabel("Font size")
        fsize:SetSliderValues(8, 24, 1)
        fsize:SetValue((o.font and tonumber(o.font.size)) or 12)
        fsize:SetCallback("OnValueChanged", function(_, _, v)
          o.font = o.font or {}
          o.font.size = tonumber(v) or 12
          ApplyNow(true)
        end)
        fsize:SetRelativeWidth(1/3)
        tf:AddChild(fsize)
      end

      local outline = AceGUI:Create("Dropdown")
      if outline then
        Mark(outline)
        outline:SetLabel("Font outline")
        outline:SetList({ [""] = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", MONOCHROMEOUTLINE = "Mono Outline" })
        outline:SetValue((o.font and o.font.outline) or "OUTLINE")
        outline:SetCallback("OnValueChanged", function(_, _, v)
          o.font = o.font or {}
          local vv = tostring(v or "OUTLINE")
          o.font.outline = vv
          ApplyNow(true)
        end)
        outline:SetRelativeWidth(1/3)
        tf:AddChild(outline)
      end
    end
  end

  -- Advanced
  do
    local a = Add("inlinegroup")
    if a then
      a:SetTitle("Advanced")
      a:SetLayout("Flow")

      local topn = AceGUI:Create("Slider")
      if topn then
        Mark(topn)
        topn:SetLabel("CPU Top N")
        topn:SetSliderValues(3, 12, 1)
        topn:SetValue(tonumber(o.cpuTopN) or 6)
        topn:SetCallback("OnValueChanged", function(_, _, v)
          o.cpuTopN = tonumber(v) or 6
          ApplyNow(false)
        end)
        topn:SetRelativeWidth(1/3)
        a:AddChild(topn)
      end

      local roll = AceGUI:Create("Slider")
      if roll then
        Mark(roll)
        roll:SetLabel("Tooltip rolling minutes")
        roll:SetSliderValues(1, 30, 1)
        roll:SetValue(tonumber(o.rollingMinutes) or 5)
        roll:SetCallback("OnValueChanged", function(_, _, v)
          o.rollingMinutes = tonumber(v) or 5
          ApplyNow(false)
        end)
        roll:SetRelativeWidth(1/3)
        a:AddChild(roll)
      end

      local ign = AceGUI:Create("Slider")
      if ign then
        Mark(ign)
        ign:SetLabel("Ignore first seconds (AP)")
        ign:SetSliderValues(0, 30, 1)
        ign:SetValue(tonumber(o.apIgnoreFirstSec) or 10)
        ign:SetCallback("OnValueChanged", function(_, _, v)
          o.apIgnoreFirstSec = tonumber(v) or 10
          ApplyNow(false)
        end)
        ign:SetRelativeWidth(1/3)
        a:AddChild(ign)
      end
    end
  end

  if parent.DoLayout then
    parent:DoLayout()
  end

end

local PPP_OPTIONS_COLORS = {
  window = { 0.12, 0.12, 0.16, 0.92 },
  panelRaised = { 0.070, 0.070, 0.090, 0.96 },
  border = { 0.20, 0.20, 0.24, 1 },
  accent = { 0.20, 0.65, 1.00, 1 },
  text = { 0.96, 0.96, 0.96, 1 },
  muted = { 0.96, 0.96, 0.96, 0.72 },
  edgeSize = 3,
}

local function PPP_SetOptionsBackdrop(frame, color, borderColor)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = PPP_OPTIONS_COLORS.edgeSize or 1,
  })
  frame:SetBackdropColor(color[1], color[2], color[3], color[4])
  frame:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
end

local function PPP_ApplyOptionsFont(fontString, size, outline)
  if not fontString then
    return
  end

  local font = GameFontNormal:GetFont()
  fontString:SetFont(font, size, outline or "")
end

local function PPP_SetOptionsTextColor(fontString, color)
  fontString:SetTextColor(color[1], color[2], color[3], color[4])
end

local function PPP_CreateControlChrome(frame)
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
  background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)

  local border = {
    frame:CreateTexture(nil, "BORDER"),
    frame:CreateTexture(nil, "BORDER"),
    frame:CreateTexture(nil, "BORDER"),
    frame:CreateTexture(nil, "BORDER"),
  }
  border[1]:SetPoint("TOPLEFT")
  border[1]:SetPoint("TOPRIGHT")
  border[1]:SetHeight(3)
  border[2]:SetPoint("BOTTOMLEFT")
  border[2]:SetPoint("BOTTOMRIGHT")
  border[2]:SetHeight(3)
  border[3]:SetPoint("TOPLEFT", 0, -3)
  border[3]:SetPoint("BOTTOMLEFT", 0, 3)
  border[3]:SetWidth(3)
  border[4]:SetPoint("TOPRIGHT", 0, -3)
  border[4]:SetPoint("BOTTOMRIGHT", 0, 3)
  border[4]:SetWidth(3)

  return {
    background = background,
    border = border,
  }
end

local function PPP_SetControlChromeColors(chrome, background, border)
  chrome.background:SetColorTexture(background[1], background[2], background[3], background[4])
  for i = 1, #chrome.border do
    chrome.border[i]:SetColorTexture(border[1], border[2], border[3], border[4])
  end
end

local function PPP_CreateCheckboxBorder(frame, anchor)
  local border = {
    frame:CreateTexture(nil, "OVERLAY"),
    frame:CreateTexture(nil, "OVERLAY"),
    frame:CreateTexture(nil, "OVERLAY"),
    frame:CreateTexture(nil, "OVERLAY"),
  }
  border[1]:SetPoint("TOPLEFT", anchor, "TOPLEFT")
  border[1]:SetPoint("TOPRIGHT", anchor, "TOPRIGHT")
  border[1]:SetHeight(3)
  border[2]:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT")
  border[2]:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT")
  border[2]:SetHeight(3)
  border[3]:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -3)
  border[3]:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 3)
  border[3]:SetWidth(3)
  border[4]:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -3)
  border[4]:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 3)
  border[4]:SetWidth(3)
  return border
end

local function PPP_SetBorderColor(border, color)
  for i = 1, #border do
    border[i]:SetColorTexture(color[1], color[2], color[3], color[4])
  end
end

local function PPP_StripButtonTextures(button)
  button:SetNormalTexture("")
  button:SetPushedTexture("")
  button:SetHighlightTexture("")
  button:SetDisabledTexture("")
  for _, region in ipairs({ button:GetRegions() }) do
    if region:GetObjectType() == "Texture" then
      region:SetTexture(nil)
      region:Hide()
    end
  end
end

PPP_StyleOptionsWidget = function(widget)
  local firstStyle = widget.__pppOptionsStyled ~= true
  widget.__pppOptionsStyled = true

  if widget.type == "Label" then
    PPP_ApplyOptionsFont(widget.label, 12, "")
    PPP_SetOptionsTextColor(widget.label, PPP_OPTIONS_COLORS.text)
  elseif widget.type == "InlineGroup" then
    PPP_SetOptionsBackdrop(widget.content:GetParent(), PPP_OPTIONS_COLORS.window, PPP_OPTIONS_COLORS.border)
    PPP_ApplyOptionsFont(widget.titletext, 12, "OUTLINE")
    PPP_SetOptionsTextColor(widget.titletext, PPP_OPTIONS_COLORS.text)
  elseif widget.type == "Button" then
    if firstStyle then
      PPP_StripButtonTextures(widget.frame)
      widget.__pppChrome = PPP_CreateControlChrome(widget.frame)
    end
    PPP_SetControlChromeColors(widget.__pppChrome, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)
    PPP_ApplyOptionsFont(widget.text, 12, "OUTLINE")
    PPP_SetOptionsTextColor(widget.text, PPP_OPTIONS_COLORS.text)
  elseif widget.type == "CheckBox" then
    widget.checkbg:SetTexture("Interface\\Buttons\\WHITE8x8")
    widget.checkbg:SetSize(18, 18)
    widget.checkbg:SetVertexColor(PPP_OPTIONS_COLORS.panelRaised[1], PPP_OPTIONS_COLORS.panelRaised[2], PPP_OPTIONS_COLORS.panelRaised[3], PPP_OPTIONS_COLORS.panelRaised[4])
    widget.check:SetTexture("Interface\\Buttons\\WHITE8x8")
    widget.check:ClearAllPoints()
    widget.check:SetPoint("TOPLEFT", widget.checkbg, "TOPLEFT", 4, -4)
    widget.check:SetPoint("BOTTOMRIGHT", widget.checkbg, "BOTTOMRIGHT", -4, 4)
    widget.check:SetVertexColor(PPP_OPTIONS_COLORS.accent[1], PPP_OPTIONS_COLORS.accent[2], PPP_OPTIONS_COLORS.accent[3], 1)
    widget.highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    widget.highlight:SetVertexColor(PPP_OPTIONS_COLORS.accent[1], PPP_OPTIONS_COLORS.accent[2], PPP_OPTIONS_COLORS.accent[3], 0.16)
    if firstStyle then
      widget.__pppCheckboxBorder = PPP_CreateCheckboxBorder(widget.frame, widget.checkbg)
    end
    PPP_SetBorderColor(widget.__pppCheckboxBorder, PPP_OPTIONS_COLORS.border)
    PPP_ApplyOptionsFont(widget.text, 12, "")
    PPP_SetOptionsTextColor(widget.text, PPP_OPTIONS_COLORS.text)
  elseif widget.type == "Slider" then
    PPP_SetOptionsBackdrop(widget.slider, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)
    widget.slider:SetThumbTexture("Interface\\Buttons\\WHITE8x8")
    widget.slider:GetThumbTexture():SetVertexColor(PPP_OPTIONS_COLORS.accent[1], PPP_OPTIONS_COLORS.accent[2], PPP_OPTIONS_COLORS.accent[3], 1)
    PPP_SetOptionsBackdrop(widget.editbox, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)
    PPP_ApplyOptionsFont(widget.label, 12, "")
    PPP_ApplyOptionsFont(widget.lowtext, 10, "")
    PPP_ApplyOptionsFont(widget.hightext, 10, "")
    PPP_ApplyOptionsFont(widget.editbox, 11, "")
    PPP_SetOptionsTextColor(widget.label, PPP_OPTIONS_COLORS.text)
    PPP_SetOptionsTextColor(widget.lowtext, PPP_OPTIONS_COLORS.muted)
    PPP_SetOptionsTextColor(widget.hightext, PPP_OPTIONS_COLORS.muted)
    PPP_SetOptionsTextColor(widget.editbox, PPP_OPTIONS_COLORS.text)
  elseif widget.type == "Dropdown" then
    if firstStyle then
      local dropdownName = widget.dropdown:GetName()
      for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
        local texture = _G[dropdownName .. suffix]
        if texture then
          texture:SetTexture(nil)
          texture:Hide()
        end
      end
      PPP_StripButtonTextures(widget.button)
      widget.__pppChrome = PPP_CreateControlChrome(widget.button_cover)
      widget.__pppArrow = widget.button_cover:CreateTexture(nil, "ARTWORK")
      widget.__pppArrow:SetPoint("RIGHT", widget.button_cover, "RIGHT", -5, 0)
      widget.__pppArrow:SetSize(16, 16)
      widget.__pppArrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    end
    PPP_SetControlChromeColors(widget.__pppChrome, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)
    widget.__pppArrow:SetVertexColor(PPP_OPTIONS_COLORS.accent[1], PPP_OPTIONS_COLORS.accent[2], PPP_OPTIONS_COLORS.accent[3], 1)
    PPP_ApplyOptionsFont(widget.label, 12, "")
    PPP_ApplyOptionsFont(widget.text, 12, "")
    PPP_SetOptionsTextColor(widget.label, PPP_OPTIONS_COLORS.text)
    PPP_SetOptionsTextColor(widget.text, PPP_OPTIONS_COLORS.text)
  elseif widget.type == "EditBox" then
    if firstStyle then
      for _, region in ipairs({ widget.editbox:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
          region:SetTexture(nil)
          region:Hide()
        end
      end
      widget.__pppChrome = PPP_CreateControlChrome(widget.editbox)
    end
    PPP_SetControlChromeColors(widget.__pppChrome, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)
    PPP_ApplyOptionsFont(widget.label, 12, "")
    PPP_ApplyOptionsFont(widget.editbox, 12, "")
    PPP_SetOptionsTextColor(widget.label, PPP_OPTIONS_COLORS.text)
    PPP_SetOptionsTextColor(widget.editbox, PPP_OPTIONS_COLORS.text)
  end

  return widget
end

local function PPP_StyleOptionsButton(button, text)
  PPP_SetOptionsBackdrop(button, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)

  local fontString = button:GetFontString()
  if not fontString then
    fontString = button:CreateFontString(nil, "OVERLAY")
    fontString:SetPoint("CENTER")
    button:SetFontString(fontString)
  end

  PPP_ApplyOptionsFont(fontString, 12, "OUTLINE")
  PPP_SetOptionsTextColor(fontString, PPP_OPTIONS_COLORS.text)
  button:SetText(text)

  button:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(PPP_OPTIONS_COLORS.accent[1], PPP_OPTIONS_COLORS.accent[2], PPP_OPTIONS_COLORS.accent[3], 1)
  end)
  button:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(PPP_OPTIONS_COLORS.border[1], PPP_OPTIONS_COLORS.border[2], PPP_OPTIONS_COLORS.border[3], 1)
  end)
end


local function _PPP_CreateOptionsShell()
  local shell = CreateFrame("Frame", "PPP_Options", UIParent, "BackdropTemplate")
  shell:SetSize(700, 600)
  shell:SetPoint("CENTER")
  shell:SetFrameStrata("DIALOG")
  shell:SetFrameLevel(50)
  shell:SetClampedToScreen(true)
  shell:SetMovable(true)
  shell:EnableMouse(true)
  shell:Hide()
  PPP_SetOptionsBackdrop(shell, PPP_OPTIONS_COLORS.window, PPP_OPTIONS_COLORS.border)

  local found = false
  for i = 1, #UISpecialFrames do
    if UISpecialFrames[i] == "PPP_Options" then
      found = true
      break
    end
  end
  if not found then
    tinsert(UISpecialFrames, "PPP_Options")
  end

  local header = CreateFrame("Frame", nil, shell, "BackdropTemplate")
  header:SetPoint("TOPLEFT", shell, "TOPLEFT", 1, -1)
  header:SetPoint("TOPRIGHT", shell, "TOPRIGHT", -1, -1)
  header:SetHeight(88)
  PPP_SetOptionsBackdrop(header, PPP_OPTIONS_COLORS.panelRaised, PPP_OPTIONS_COLORS.border)
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function()
    shell:StartMoving()
  end)
  header:SetScript("OnDragStop", function()
    shell:StopMovingOrSizing()
  end)

  local logo = header:CreateTexture(nil, "ARTWORK")
  logo:SetPoint("LEFT", header, "LEFT", 18, 0)
  logo:SetSize(54, 54)
  logo:SetTexture("Interface\\AddOns\\PleebPerformancePanels\\Media\\logo.tga")

  local title = header:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 14, -2)
  PPP_ApplyOptionsFont(title, 20, "OUTLINE")
  title:SetText("Pleeb Performance Panel")
  PPP_SetOptionsTextColor(title, PPP_OPTIONS_COLORS.accent)

  local description = header:CreateFontString(nil, "OVERLAY")
  description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  description:SetPoint("RIGHT", header, "RIGHT", -220, 0)
  description:SetJustifyH("LEFT")
  PPP_ApplyOptionsFont(description, 11, "")
  description:SetText("Configure performance metrics, logging, thresholds, and appearance.")
  PPP_SetOptionsTextColor(description, PPP_OPTIONS_COLORS.muted)

  local close = CreateFrame("Button", nil, header, "BackdropTemplate")
  close:SetSize(30, 30)
  close:SetPoint("TOPRIGHT", header, "TOPRIGHT", -12, -12)
  PPP_StyleOptionsButton(close, "×")
  close:SetScript("OnClick", function()
    shell:Hide()
  end)



  local contentHost = CreateFrame("Frame", nil, shell, "BackdropTemplate")
  contentHost:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
  contentHost:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -1, 1)
  PPP_SetOptionsBackdrop(contentHost, PPP_OPTIONS_COLORS.window, PPP_OPTIONS_COLORS.border)

  local contentRoot = AceGUI:Create("SimpleGroup")
  contentRoot:SetLayout("Fill")
  contentRoot.frame:SetParent(contentHost)
  contentRoot.frame:ClearAllPoints()
  contentRoot.frame:SetAllPoints(contentHost)

  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("Flow")
  scroll:SetFullWidth(true)
  scroll:SetFullHeight(true)
  contentRoot:AddChild(scroll)

  shell.contentRoot = contentRoot
  shell.contentScroll = scroll
  shell.header = header
  shell.closeButton = close

  return shell
end

local function RestoreStandaloneOptions()
  if not optionsWindow or optionsWindow.embedded ~= true then
    return
  end

  optionsWindow.embedded = nil
  optionsWindow:SetParent(UIParent)
  optionsWindow:SetFrameStrata("DIALOG")
  optionsWindow:SetFrameLevel(50)
  optionsWindow:SetClampedToScreen(true)
  optionsWindow:SetMovable(true)
  optionsWindow:ClearAllPoints()
  optionsWindow:SetSize(700, 600)
  optionsWindow:SetPoint("CENTER")
  optionsWindow.header:EnableMouse(true)
  optionsWindow.closeButton:Show()
end

function PPP:OpenOptions()
  if not optionsWindow then
    optionsWindow = _PPP_CreateOptionsShell()
  end

  RestoreStandaloneOptions()
  self:BuildAceGUIOptions(optionsWindow.contentScroll)
  optionsWindow:Show()
  optionsWindow:Raise()
end

local function MountPleebUIOptions(host)
  if not optionsWindow then
    optionsWindow = _PPP_CreateOptionsShell()
  end

  optionsWindow.embedded = true
  optionsWindow:SetParent(host)
  optionsWindow:SetFrameStrata(host:GetFrameStrata())
  optionsWindow:SetFrameLevel(host:GetFrameLevel() + 1)
  optionsWindow:SetClampedToScreen(false)
  optionsWindow:SetMovable(false)
  optionsWindow:ClearAllPoints()
  optionsWindow:SetAllPoints(host)
  optionsWindow.header:EnableMouse(false)
  optionsWindow.closeButton:Hide()
  PPP:BuildAceGUIOptions(optionsWindow.contentScroll)
  optionsWindow:Show()
  optionsWindow:Raise()
  return optionsWindow
end

local function RegisterPleebUIPlugin()
  local API = _G.PleebUIAPI
  if not API then
    return
  end

  pleebUIPlugin = API:RegisterPlugin("PleebPerformancePanels", {
    name = "Performance Panel",
    order = 30,
    navDescription = "Performance metrics and logging.",
    navGlyph = "PP",
  })

  pleebUIPlugin:RegisterOptionsPage("general", {
    name = "General",
    order = 10,
    buildPage = MountPleebUIOptions,
    customPageOwnsHeader = true,
  })
end

local function RegisterPleebUIMover()
  if not pleebUIPlugin or not PPP._frame then
    return
  end

  pleebUIPlugin:RegisterMover("panel", PPP._frame, {
    label = "Performance Panel",
    optionsPage = "general",
    savePosition = SavePosition,
    resetPosition = function(frame)
      PPPDB.options.panelPos = nil
      RestorePosition(frame)
    end,
  })
end

function PPP:ChatCommand(input)
  input = (input or ""):lower()

  if input == "reset" then
    self:ResetSession()
    self:EnsurePerfPanel(true)
    print("PPP: Session stats reset.")
    return

  elseif input == "toggle" then
    local o = GetOptions()
    PPP:SetEnabled(not o.enabled)
    print("PPP: " .. (GetOptions().enabled and "Enabled." or "Disabled."))
    return


  elseif input:match("^measure") then
    if not (C_AddOnProfiler and C_AddOnProfiler.MeasureCall) then
      print("PPP: MeasureCall not available.")
      return
    end

    local callResults = C_AddOnProfiler.MeasureCall(function()
      PPP:EnsurePerfPanel(true)
      PPP:OnSampleTick(GetTime())
    end)

    if callResults then
      local ms = tonumber(callResults.elapsedMilliseconds) or 0
      local allocKB = (tonumber(callResults.allocatedBytes) or 0) / 1024
      local deallocKB = (tonumber(callResults.deallocatedBytes) or 0) / 1024
      local ticks = callResults.elapsedTicks and tostring(callResults.elapsedTicks) or "?"
      local tps = (C_AddOnProfiler and C_AddOnProfiler.GetTicksPerSecond) and C_AddOnProfiler.GetTicksPerSecond() or nil
      if tps then
        print("PPP: " .. format("Measure: %.3f ms, alloc %.1f KB, dealloc %.1f KB, ticks %s (tps %.0f)", ms, allocKB, deallocKB, ticks, tps))

      else
        print("PPP: " .. format("Measure: %.3f ms, alloc %.1f KB, dealloc %.1f KB, ticks %s", ms, allocKB, deallocKB, ticks))
      end
    else
      print("PPP: MeasureCall returned no results.")
    end
    return
  end

  self:OpenConfig()
end

function PPP:OnInitialize()
  self._options = GetOptions()
  self._loggingEnabled = self._options.loggingEnabled == true
  RegisterPleebUIPlugin()

  -- Slash commands 
  local function _PPP_SlashHandler(msg)
    PPP:ChatCommand(msg)
  end

  SLASH_PPP1 = "/pp"
  SLASH_PPP2 = "/ppp"
  SlashCmdList.PPP = _PPP_SlashHandler

end

function PPP:OnEnable()
  self:ResetSession()
  self._profilerEnabled = AddOnProfilerEnabled()
  self._profilerStateCheckT = GetTime()
  self:EnsurePerfPanel(true)
  RegisterPleebUIMover()
  self:EnsureDriver()
  self:StartTicker()
  self:StartCPULogger()
end

function PPP:OnDisable()
  self:StopTicker()
  self:StopCPULogger()
  if pleebUIPlugin then
    pleebUIPlugin:UnregisterMover("panel")
  end
  if self._frame then
    self._frame:Hide()
  end
end

function PPP:OnPlayerEnteringWorld()
  local s = GetSession()

  -- Ensure histogram fields exist
  s.sessFPSHist = s.sessFPSHist or { counts = {}, total = 0, maxBin = 0 }
  s.sessFPSHist.counts = s.sessFPSHist.counts or {}
  s.sessFPSHist.total  = s.sessFPSHist.total or 0
  s.sessFPSHist._seenMax = s.sessFPSHist._seenMax or s.sessFPSHist.maxBin or nil

  -- Ping stats
  s.msSamples = s.msSamples or {}
  s.sessMS = s.sessMS or { n = 0, sum = 0, min = nil, max = nil }

  -- CPU stats
  s.cpuSamples = s.cpuSamples or {}
  s.sessCPU = s.sessCPU or { n = 0, sum = 0, min = nil, max = nil }

  -- Combat / Encounter tracking (FPS + CPU)
  s.combatFPS = s.combatFPS or { n = 0, sum = 0, min = nil, max = nil, active = false }
  s.combatCPU = s.combatCPU or { n = 0, sum = 0, min = nil, max = nil, active = false }
  s.encFPS = s.encFPS or { n = 0, sum = 0, min = nil, max = nil, active = false }
  s.encCPU = s.encCPU or { n = 0, sum = 0, min = nil, max = nil, active = false }

  s.combatFPSsamples = s.combatFPSsamples or {}
  s.combatCPUsamples = s.combatCPUsamples or {}
  s.encFPSsamples = s.encFPSsamples or {}
  s.encCPUsamples = s.encCPUsamples or {}

  s.lastCombatFPSsamples = s.lastCombatFPSsamples or {}
  s.lastCombatCPUsamples = s.lastCombatCPUsamples or {}
  s.lastEncFPSsamples = s.lastEncFPSsamples or {}
  s.lastEncCPUsamples = s.lastEncCPUsamples or {}

  s.apIgnoreUntilT = s.apIgnoreUntilT or nil
end

if P and P.Def then
  PPP.ApplyLayout = P:Def("ApplyLayout", PPP.ApplyLayout)
  PPP.BuildFrame = P:Def("BuildFrame", PPP.BuildFrame)
  PPP.EnsurePerfPanel = P:Def("EnsurePerfPanel", PPP.EnsurePerfPanel)

  GetLowestDurabilityPct = P:Def("GetLowestDurabilityPct", GetLowestDurabilityPct)
  PublishDurabilityPct = P:Def("PublishDurabilityPct", PublishDurabilityPct)
  RefreshDurabilityPct = P:Def("RefreshDurabilityPct", RefreshDurabilityPct)
  PPP.GetDurabilityPercent = P:Def("GetDurabilityPercent", PPP.GetDurabilityPercent)
  PPP.OnSampleTick = P:Def("OnSampleTick", PPP.OnSampleTick)
  PPP.StartTicker = P:Def("StartTicker", PPP.StartTicker)
  PPP.StopTicker = P:Def("StopTicker", PPP.StopTicker)
  PPP.StartCPULogger = P:Def("StartCPULogger", PPP.StartCPULogger)
  PPP.StopCPULogger = P:Def("StopCPULogger", PPP.StopCPULogger)

  PPP.EnsureTooltip = P:Def("EnsureTooltip", PPP.EnsureTooltip)
  PPP.ShowTooltip = P:Def("ShowTooltip", PPP.ShowTooltip)
  PPP.HideTooltip = P:Def("HideTooltip", PPP.HideTooltip)

  PPP.EnsureDriver = P:Def("EnsureDriver", PPP.EnsureDriver)
  PPP.SetEnabled = P:Def("SetEnabled", PPP.SetEnabled)
  PPP.SetLoggingEnabled = P:Def("SetLoggingEnabled", PPP.SetLoggingEnabled)

  PPP.OnInitialize = P:Def("OnInitialize", PPP.OnInitialize)
  PPP.OnEnable = P:Def("OnEnable", PPP.OnEnable)
  PPP.OnDisable = P:Def("OnDisable", PPP.OnDisable)
end

local lifecycleFrame = CreateFrame("Frame")
local initialized = false
local enabled = false

local function InitializeAddon()
  if initialized then
    return
  end
  initialized = true

  if type(PPP.OnInitialize) == "function" then
    PPP:OnInitialize()
  end
end

local function EnableAddon()
  if enabled then
    return
  end
  enabled = true

  if type(PPP.OnEnable) == "function" then
    PPP:OnEnable()
  end
end

lifecycleFrame:RegisterEvent("ADDON_LOADED")
lifecycleFrame:RegisterEvent("PLAYER_LOGIN")
lifecycleFrame:SetScript("OnEvent", function(self, event, loadedAddon)
  if event == "ADDON_LOADED" then
    if loadedAddon ~= ADDON_NAME then
      return
    end

    self:UnregisterEvent("ADDON_LOADED")
    InitializeAddon()

    if IsLoggedIn() then
      self:UnregisterEvent("PLAYER_LOGIN")
      EnableAddon()
    end
    return
  end

  self:UnregisterEvent("PLAYER_LOGIN")
  InitializeAddon()
  EnableAddon()
end)
