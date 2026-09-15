-- File: LibPleebug-1_CPU.lua
-- CPU support for Pleebug.
--
-- Light mode:
--   Uses Blizzard native CPU counters such as GetFunctionCPUUsage/GetEventCPUUsage.
--   Requires scriptProfile=1 and a reload.
--   Does not execute Pleebug wrappers for instrumented functions.
--   Provides CPU call counts/calls per second, but not per-call memory deltas.
--
-- Full debug mode:
--   Executes instrumented functions through Pleebug wrappers while profiling is running.
--   Uses debugprofilestop/collectgarbage sampling around each wrapped call.
--   Records per-call CPU, memory delta, and string/table helper churn.
--   Can taint and should only be used for short debug sessions.

local LibStub = _G.LibStub
local Pleebug = LibStub and LibStub("LibPleebug-1", true)
if not Pleebug then return end

-- Backwards-compatible alias (rest of file can keep using MemDebug)
local MemDebug = Pleebug


MemDebug.CPU = MemDebug.CPU or {}
local CPU = MemDebug.CPU

-- WoW Lua compatibility: table.pack/unpack may be nil in some clients
local t_pack = table.pack or function(...)
  return { n = select("#", ...), ... }
end
local t_unpack = table.unpack or unpack


---------------------
-- Tick hook: sample AddOn CPU once per Pleebug snapshot
-- Controlled by "Enable CPU logging"
---------------------
if MemDebug and MemDebug.RegisterTickHook then
  MemDebug:RegisterTickHook("CPU", function(self, now, interval, snap)
    local cpu = self.CPU
    if not cpu then
      return
    end

    local db = self:GetDB()
    local mods = db and db.modules

    -- Native samplers replace wrapper-based TrackFunc counts.
    -- They must run when Pleebug is started, even if the optional CPU chart checkbox is off.
    if cpu.SampleNativeFunctions then
      cpu:SampleNativeFunctions(now, interval, snap)
    end
    if cpu.SampleNativeEvents then
      cpu:SampleNativeEvents(now, interval, snap)
    end
    if cpu.SampleNativeScript then
      cpu:SampleNativeScript(now, interval)
    end

    -- The AddOn-profiler lane below is the optional CPU chart lane.
    if not (cpu.Enabled and cpu:Enabled()) then
      return
    end
    if not mods then
      return
    end

    local totalMs = 0

    -- AddOn-profiler lane is separate from native function/event sampling.
    if C_AddOnProfiler and C_AddOnProfiler.IsEnabled and C_AddOnProfiler.IsEnabled() then
      for moduleName, enabled in pairs(mods) do
        if enabled ~= false then
          local ms = cpu:OnTick(moduleName, now)
          if ms then
            totalMs = totalMs + (tonumber(ms) or 0)
          end
        end
      end

      -- One overall line for "total addon cost" across enabled modules.
      cpu:PushSample("CPU.Total", totalMs, now)
    end
  end)
end



local function _now()
  if GetTimePreciseSec then return GetTimePreciseSec() end
  if GetTime then return GetTime() end
  return 0
end

local METRIC = Enum and Enum.AddOnProfilerMetric or nil
local METRIC_LAST_TIME = METRIC and METRIC.LastTime or nil

local function _ProfilerEnabled()
  if C_AddOnProfiler and C_AddOnProfiler.IsEnabled then
    return C_AddOnProfiler.IsEnabled()
  end
  return false
end

local function _GetAddOnLastMs(addonName)
  if not addonName or addonName == "" then return nil end
  if not METRIC_LAST_TIME then return nil end
  if not (C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric) then return nil end
  return C_AddOnProfiler.GetAddOnMetric(addonName, METRIC_LAST_TIME)
end

local GetFunctionCPUUsage = _G.GetFunctionCPUUsage
local GetEventCPUUsage = _G.GetEventCPUUsage
local GetScriptCPUUsage = _G.GetScriptCPUUsage

local function _Trim(samples, windowSec, nowT)
  if not samples or #samples == 0 then return end
  local cutoff = (nowT or _now()) - (windowSec or 10)
  while #samples > 0 do
    local t = samples[1] and samples[1].t
    if not t or t >= cutoff then break end
    table.remove(samples, 1)
  end
end

local function _EnsureCDB()
  if not MemDebug.GetDB then return nil end
  local db = MemDebug:GetDB()
  if not db then return nil end

  db.cpu = db.cpu or {}
  local cdb = db.cpu

  if type(cdb.enabled) ~= "boolean" then cdb.enabled = false end

  cdb.keepSeconds = tonumber(cdb.keepSeconds) or 120
  if cdb.keepSeconds < 10 then cdb.keepSeconds = 10 end
  if cdb.keepSeconds > 600 then cdb.keepSeconds = 600 end

  if cdb.refLine == nil then cdb.refLine = false end
  cdb.refFps = tonumber(cdb.refFps) or 60
  if cdb.refFps < 1 then cdb.refFps = 1 end
  if cdb.refFps > 1000 then cdb.refFps = 1000 end

  -- Optional: record MeasureCall events[] via AddMeasuredCallEvent breadcrumbs.
  if type(cdb.eventMarks) ~= "boolean" then cdb.eventMarks = false end

  -- Native sampling is the safe default: P:Def registers original functions and returns them.
  if type(cdb.nativeFunctionSampling) ~= "boolean" then cdb.nativeFunctionSampling = true end
  if type(cdb.nativeEventSampling) ~= "boolean" then cdb.nativeEventSampling = true end
  if type(cdb.nativeScriptSampling) ~= "boolean" then cdb.nativeScriptSampling = true end

  -- Preferences are allowed to persist.
  cdb.measured  = cdb.measured  or {} -- [path] = true

  -- Tracking outputs must NEVER persist to SavedVariables.
  if cdb.funcStats ~= nil then cdb.funcStats = nil end
  if cdb.samples ~= nil then cdb.samples = nil end

  -- Runtime-only buffers (kept after Stop/closing window, cleared on Start/Clear/reload).
  CPU._rtFuncStats = CPU._rtFuncStats or {} -- [path] = { time/tick/alloc/dealloc stats }
  CPU._rtFuncLastEvents = CPU._rtFuncLastEvents or {} -- [path] = { n=, list={...} }
  CPU._rtSamples   = CPU._rtSamples   or {} -- [seriesKey] = { {t=, v=} , ... }
  CPU._nativeFuncs = CPU._nativeFuncs or {} -- [path] = original function sample state
  CPU._nativeEvents = CPU._nativeEvents or {} -- [eventName] = global event sample state
  CPU._nativeLive = CPU._nativeLive or {} -- [treeKey] = { {t=, c=} } native live call-count deltas

  return cdb
end


local function _WipeTable(t)
  if not t then return end
  for k in pairs(t) do
    t[k] = nil
  end
end

function CPU:ResetRuntime()
  _WipeTable(self._rtFuncStats)
  _WipeTable(self._rtFuncLastEvents)
  _WipeTable(self._rtSamples)

  -- Keep registered original function/event references, but reset baselines on Start/Clear.
  if self._nativeFuncs then
    for _, rec in pairs(self._nativeFuncs) do
      if type(rec) == "table" then
        rec.lastTime = nil
        rec.lastCount = nil
      end
    end
  end
  if self._nativeEvents then
    for _, rec in pairs(self._nativeEvents) do
      if type(rec) == "table" then
        rec.lastTime = nil
        rec.lastCount = nil
      end
    end
  end
  self._nativeScriptLast = nil
  if self._nativeLive then
    _WipeTable(self._nativeLive)
  end
end


local function _GetFuncStats()
  CPU._rtFuncStats = CPU._rtFuncStats or {}
  return CPU._rtFuncStats
end

local function _GetSamples()
  CPU._rtSamples = CPU._rtSamples or {}
  return CPU._rtSamples
end

local function _ToNumberEarly(v)
  if v == nil then return nil end
  if type(v) == "number" then return v end
  local ok, s = pcall(tostring, v)
  if not ok then return nil end
  return tonumber(s)
end

local function _BuildPathEarly(moduleName, bucket, funcName)
  local name = tostring(funcName or "Unknown"):gsub("%.", ":")
  return tostring(moduleName or "Unknown") .. "." .. name
end

local function _AddSnapshotCount(snap, key, amount)
  if type(snap) ~= "table" or type(key) ~= "string" or key == "" then
    return
  end
  amount = tonumber(amount) or 0
  if amount <= 0 then
    return
  end
  snap[key] = (tonumber(snap[key]) or 0) + amount
end

local function _NormalizeBucket(bucket)
  if bucket == nil then
    return nil
  end
  bucket = tostring(bucket)
  if bucket == "" then
    return nil
  end
  local out = {}
  for part in bucket:gmatch("[^%.]+") do
    if part ~= "" and part ~= "Funcs" then
      out[#out + 1] = part
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, ".")
end

local function _FuncTreeKey(path)
  return "Funcs." .. tostring(path or "Unknown")
end

local function _MarkWindowChanged()
  local W = MemDebug and MemDebug.Window
  if W then
    W._traceSeq = (W._traceSeq or 0) + 1
  end
end

local function _PushNativeLive(key, countDelta, nowT)
  key = tostring(key or "")
  countDelta = tonumber(countDelta) or 0
  if key == "" or countDelta <= 0 then
    return
  end

  local cdb = _EnsureCDB()
  CPU._nativeLive = CPU._nativeLive or {}
  local list = CPU._nativeLive[key]
  if not list then
    list = {}
    CPU._nativeLive[key] = list
  end

  nowT = tonumber(nowT) or _now()
  list[#list + 1] = { t = nowT, c = countDelta }

  local keep = tonumber(cdb and cdb.keepSeconds) or 120
  local interval = MemDebug and MemDebug.GetInterval and MemDebug:GetInterval() or 10
  interval = tonumber(interval) or 10
  if keep < (interval + 2) then
    keep = interval + 2
  end

  local cutoff = nowT - keep
  local drop = 0
  for i = 1, #list do
    local e = list[i]
    if e and e.t and e.t < cutoff then
      drop = i
    else
      break
    end
  end
  if drop > 0 then
    for i = drop + 1, #list do
      list[i - drop] = list[i]
    end
    for i = #list - drop + 1, #list do
      list[i] = nil
    end
  end

  _MarkWindowChanged()
end

local function _PushNativeFuncStat(path, msDelta, countDelta)
  local stats = _GetFuncStats()
  path = tostring(path or "Unknown")
  countDelta = tonumber(countDelta) or 0
  msDelta = _ToNumberEarly(msDelta) or 0
  if countDelta <= 0 then
    return
  end

  local st = stats[path]
  if not st then
    st = {
      n = 0,
      timeSum = 0,
      timeLast = 0,
      timeMax = 0,
      memSum = 0,
      memLast = 0,
      memMax = 0,
      hotTables = false,
      native = true,
    }
    stats[path] = st
  end

  st.native = true
  local perCall = msDelta / countDelta
  st.n = (st.n or 0) + countDelta
  st.timeSum = (st.timeSum or 0) + msDelta
  st.timeLast = perCall
  if st.timeMin == nil or perCall < st.timeMin then st.timeMin = perCall end
  if st.timeMax == nil or perCall > st.timeMax then st.timeMax = perCall end
end


function CPU:SetEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.enabled = (on == true)
end

function CPU:Enabled()
  local cdb = _EnsureCDB()
  return cdb and cdb.enabled == true
end

function CPU:NativeFunctionSamplingEnabled()
  local cdb = _EnsureCDB()
  if MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode() == "full" then
    return false
  end
  return cdb and cdb.nativeFunctionSampling == true and type(GetFunctionCPUUsage) == "function"
end

function CPU:SetNativeFunctionSamplingEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.nativeFunctionSampling = (on == true)
end

function CPU:NativeEventSamplingEnabled()
  local cdb = _EnsureCDB()
  if MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode() == "full" then
    return false
  end
  return cdb and cdb.nativeEventSampling == true and type(GetEventCPUUsage) == "function"
end

function CPU:SetNativeEventSamplingEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.nativeEventSampling = (on == true)
end

function CPU:NativeScriptSamplingEnabled()
  local cdb = _EnsureCDB()
  if MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode() == "full" then
    return false
  end
  return cdb and cdb.nativeScriptSampling == true and type(GetScriptCPUUsage) == "function"
end

function CPU:SetNativeScriptSamplingEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.nativeScriptSampling = (on == true)
end

function CPU:ApplyDebugModeDefaults(mode)
  local cdb = _EnsureCDB()
  if not cdb then return end

  mode = tostring(mode or "light")
  if mode == "full" then
    cdb.nativeFunctionSampling = false
    cdb.nativeEventSampling = false
    cdb.nativeScriptSampling = false
    cdb.enabled = true
    cdb.measureMode = "debug"
    if MemDebug and MemDebug.SetEventMeasureEnabled then
      MemDebug:SetEventMeasureEnabled(true)
    end
  else
    cdb.nativeFunctionSampling = true
    cdb.nativeEventSampling = true
    cdb.nativeScriptSampling = true
    cdb.enabled = true
    if MemDebug and MemDebug.SetEventMeasureEnabled then
      MemDebug:SetEventMeasureEnabled(false)
    end
  end
end

function CPU:IsScriptProfileEnabled()
  local v
  if C_CVar and C_CVar.GetCVar then
    v = C_CVar.GetCVar("scriptProfile")
  elseif GetCVar then
    v = GetCVar("scriptProfile")
  end
  return tostring(v or "0") == "1"
end

function CPU:SetScriptProfile(on)
  local value = (on == true) and "1" or "0"
  if C_CVar and C_CVar.SetCVar then
    C_CVar.SetCVar("scriptProfile", value)
  elseif SetCVar then
    SetCVar("scriptProfile", value)
  end
end

function CPU:SetScriptProfileAndReload(on)
  self:SetScriptProfile(on == true)
  local db = MemDebug and MemDebug.GetDB and MemDebug:GetDB() or nil
  if db then
    db.openAfterReload = true
    db.debugMode = nil
    db.__pleebugLoadMode = nil
    db.__pleebugForceFullDebug = nil
    db.fullDebugOnNextLoad = nil
    db.__pleebugInit = nil
  end
  if ReloadUI then
    ReloadUI()
  end
end

-- (removed duplicate EnsureSampler; keep the later definition)

function CPU:GetScaleMs()
  local cdb = _EnsureCDB()
  return cdb and (tonumber(cdb.scaleMs) or 16.7) or 16.7
end

function CPU:SetScaleMs(ms)
  local cdb = _EnsureCDB()
  if not cdb then return end
  ms = tonumber(ms) or 16.7
  if ms < 1 then ms = 1 end
  if ms > 100 then ms = 100 end
  cdb.scaleMs = ms
end


function CPU:EnsureSampler()
  local cdb = _EnsureCDB()
  if not cdb then return end

  if cdb.enabled ~= true then
    cdb.enabled = true
  end

  if cdb.overlay == nil then
    cdb.overlay = true
  end
end

function CPU:RegisterFunction(moduleName, bucket, funcName, fn)
  if type(fn) ~= "function" then return end
  moduleName = tostring(moduleName or "Unknown")
  funcName = tostring(funcName or "UnknownFunc"):gsub("%.", ":")
  bucket = nil

  local path = _BuildPathEarly(moduleName, bucket, funcName)
  self._nativeFuncs = self._nativeFuncs or {}
  local rec = self._nativeFuncs[path]
  if not rec then
    rec = {}
    self._nativeFuncs[path] = rec
  end

  rec.fn = fn
  rec.moduleName = moduleName
  rec.bucket = bucket
  rec.funcName = funcName
  rec.path = path

  if MemDebug and MemDebug._TouchSeries then
    MemDebug:_TouchSeries(_FuncTreeKey(path))
    MemDebug:_TouchSeries("CPU.Func." .. path)
  end
end

function CPU:RegisterTableFunctions(moduleName, tbl, opt)
  if type(tbl) ~= "table" then return end
  opt = opt or {}
  moduleName = tostring(moduleName or "Unknown")

  local deep = opt.deep == true
  local baseBucket = _NormalizeBucket(opt.bucket)
  local visited = {}
  local maxDepth = (type(opt.maxDepth) == "number" and opt.maxDepth) or 6

  local function scan(t, bucketPath, depth)
    if type(t) ~= "table" then return end
    if visited[t] then return end
    visited[t] = true
    if depth > maxDepth then return end

    for k, v in pairs(t) do
      if type(v) == "function" then
        self:RegisterFunction(moduleName, bucketPath, tostring(k), v)
      elseif deep and type(v) == "table" and k ~= "__index" and k ~= "prototype" then
        local keyName = tostring(k)
        if keyName ~= "parent"
          and keyName ~= "children"
          and keyName ~= "db"
          and keyName ~= "_G"
        then
          local nextBucket = bucketPath
          if nextBucket and nextBucket ~= "" then
            nextBucket = nextBucket .. "." .. keyName
          else
            nextBucket = keyName
          end
          scan(v, nextBucket, depth + 1)
        end
      end
    end
  end

  scan(tbl, baseBucket, 0)
end

function CPU:RegisterEvent(eventName)
  if type(eventName) ~= "string" or eventName == "" then return end
  self._nativeEvents = self._nativeEvents or {}
  self._nativeEvents[eventName] = self._nativeEvents[eventName] or { eventName = eventName }

  if MemDebug and MemDebug._TouchSeries then
    MemDebug:_TouchSeries("Events.Global." .. eventName)
    MemDebug:_TouchSeries("CPU.Event.Events.Global." .. eventName)
  end
end

function CPU:PrimeNativeBaselines()
  if self._nativeFuncs and type(GetFunctionCPUUsage) == "function" then
    for _, rec in pairs(self._nativeFuncs) do
      if type(rec) == "table" and type(rec.fn) == "function" then
        local total, count = GetFunctionCPUUsage(rec.fn, false)
        rec.lastTime = _ToNumberEarly(total)
        rec.lastCount = _ToNumberEarly(count)
      end
    end
  end

  if self._nativeEvents and type(GetEventCPUUsage) == "function" then
    for eventName, rec in pairs(self._nativeEvents) do
      if type(rec) == "table" then
        local total, count = GetEventCPUUsage(eventName)
        rec.lastTime = _ToNumberEarly(total)
        rec.lastCount = _ToNumberEarly(count)
      end
    end
  end

  if type(GetScriptCPUUsage) == "function" then
    self._nativeScriptLast = _ToNumberEarly(GetScriptCPUUsage())
  end
end

function CPU:SampleNativeFunctions(nowT, interval, snap)
  if not self:NativeFunctionSamplingEnabled() then return end
  if not self._nativeFuncs then return end

  nowT = nowT or _now()

  local totalMs = 0
  for path, rec in pairs(self._nativeFuncs) do
    local fn = rec and rec.fn
    local moduleEnabled = not (MemDebug and MemDebug.IsModuleEnabled)
      or MemDebug:IsModuleEnabled(rec and rec.moduleName)

    if moduleEnabled and type(fn) == "function" then
      local total, count = GetFunctionCPUUsage(fn, false)
      total = _ToNumberEarly(total)
      count = _ToNumberEarly(count)

      if total and count then
        if rec.lastTime ~= nil and rec.lastCount ~= nil then
          local msDelta = total - rec.lastTime
          local countDelta = count - rec.lastCount

          if msDelta < 0 or countDelta < 0 then
            msDelta = 0
            countDelta = 0
          end

          if countDelta > 0 then
            _PushNativeFuncStat(path, msDelta, countDelta)
            _PushNativeLive(_FuncTreeKey(path), countDelta, nowT)
            self:PushSample("CPU.Func." .. path, msDelta, nowT)
            _AddSnapshotCount(snap, "Funcs.Total", countDelta)
            _AddSnapshotCount(snap, _FuncTreeKey(path), countDelta)
            totalMs = totalMs + msDelta
          end
        end

        rec.lastTime = total
        rec.lastCount = count
      end
    elseif rec then
      -- Do not carry disabled-period calls into the first sample after re-enabling.
      rec.lastTime = nil
      rec.lastCount = nil
    end
  end

  if totalMs > 0 then
    self:PushSample("CPU.Func.Total", totalMs, nowT)
  end
end

function CPU:SampleNativeEvents(nowT, interval, snap)
  if not self:NativeEventSamplingEnabled() then return end
  if not self._nativeEvents then return end

  nowT = nowT or _now()

  local totalMs = 0
  for eventName, rec in pairs(self._nativeEvents) do
    local total, count = GetEventCPUUsage(eventName)
    total = _ToNumberEarly(total)
    count = _ToNumberEarly(count)

    if total and count then
      if rec.lastTime ~= nil and rec.lastCount ~= nil then
        local msDelta = total - rec.lastTime
        local countDelta = count - rec.lastCount

        if msDelta < 0 or countDelta < 0 then
          msDelta = 0
          countDelta = 0
        end

        if countDelta > 0 then
          local path = "Events.Global." .. tostring(eventName)
          _PushNativeFuncStat(path, msDelta, countDelta)
          _PushNativeLive(path, countDelta, nowT)
          self:PushSample("CPU.Event." .. path, msDelta, nowT)
          _AddSnapshotCount(snap, "Events.Global.Total", countDelta)
          _AddSnapshotCount(snap, path, countDelta)
          totalMs = totalMs + msDelta
        end
      end

      rec.lastTime = total
      rec.lastCount = count
    end
  end

  if totalMs > 0 then
    self:PushSample("CPU.Event.Total", totalMs, nowT)
  end
end

function CPU:SampleNativeScript(nowT, interval)
  if not self:NativeScriptSamplingEnabled() then return end

  nowT = nowT or _now()
  local total = GetScriptCPUUsage()
  total = _ToNumberEarly(total)
  if not total then return end

  local last = self._nativeScriptLast
  self._nativeScriptLast = total
  if last == nil then return end

  local msDelta = total - last
  if msDelta < 0 then return end
  if msDelta > 0 then
    self:PushSample("CPU.Script.Total", msDelta, nowT)
  end
end

function CPU:PollNative(nowT)
  nowT = tonumber(nowT) or _now()
  if self.SampleNativeFunctions then
    self:SampleNativeFunctions(nowT, nil, nil)
  end
  if self.SampleNativeEvents then
    self:SampleNativeEvents(nowT, nil, nil)
  end
  if self.SampleNativeScript then
    self:SampleNativeScript(nowT, nil)
  end
end

function CPU:BuildNativeLiveSnapshot(windowSec, nowT, out)
  out = out or {}
  for k in pairs(out) do out[k] = nil end

  windowSec = tonumber(windowSec) or (MemDebug and MemDebug.GetInterval and MemDebug:GetInterval()) or 10
  if windowSec < 0.1 then windowSec = 0.1 end
  nowT = tonumber(nowT) or _now()

  out.__interval = windowSec
  out.__time = nowT

  local cutoff = nowT - windowSec
  local fnTotal, eventTotal = 0, 0
  local live = self._nativeLive
  if type(live) == "table" then
    for key, list in pairs(live) do
      local sum = 0
      if type(list) == "table" then
        for i = #list, 1, -1 do
          local e = list[i]
          if not e or not e.t then
            break
          end
          if e.t < cutoff then
            break
          end
          sum = sum + (tonumber(e.c) or 0)
        end
      end

      if sum > 0 then
        out[key] = sum
        if key:sub(1, 6) == "Funcs." then
          fnTotal = fnTotal + sum
        elseif key:sub(1, 7) == "Events." then
          eventTotal = eventTotal + sum
        end
      end
    end
  end

  out["Funcs.Total"] = fnTotal
  out["Events.Total"] = eventTotal
  return out
end

-- Called by the core tick (SnapshotAndReset) when CPU logging is enabled.
function CPU:OnTick(moduleName, nowT)

  local cdb = _EnsureCDB()
  if not cdb or cdb.enabled ~= true then return end
  if not _ProfilerEnabled() then return end

  nowT = nowT or _now()

  local db = MemDebug:GetDB()
  local addonName = db and db.moduleAddonName and db.moduleAddonName[moduleName] or nil
  if not addonName then return end

  local ms = _GetAddOnLastMs(addonName)
  if not ms then return end

  local laneKey = "CPU.AddOn." .. tostring(moduleName or "Unknown")

  local all = _GetSamples()
  all[laneKey] = all[laneKey] or {}
  table.insert(all[laneKey], { t = nowT, v = tonumber(ms) or 0 })

  _Trim(all[laneKey], cdb.keepSeconds or 120, nowT)

  return tonumber(ms) or 0
end



function CPU:GetRecentSamples(a, b, c)
  local cdb = _EnsureCDB()
  if not cdb then
    return {}, _now()
  end

  local moduleName, windowSec, nowT

  -- Two supported call styles:
  -- 1) GetRecentSamples("ModuleName", windowSec, nowT)
  -- 2) GetRecentSamples(windowSec, nowT)  -- used by Diagram.lua
  if type(a) == "string" or a == nil then
    moduleName = a
    windowSec  = b
    nowT       = c
  else
    moduleName = nil
    windowSec  = a
    nowT       = b
  end

  windowSec = tonumber(windowSec) or 10
  if windowSec < 0.1 then windowSec = 0.1 end
  if windowSec > 600 then windowSec = 600 end

  nowT = tonumber(nowT) or _now()

  local key
  if moduleName and moduleName ~= "" then
    key = "CPU.AddOn." .. tostring(moduleName)
  else
    key = "CPU"
  end

  local all = _GetSamples()
  local samples = all[key] or {}
  local cutoff = nowT - windowSec

  local out = {}
  for i = 1, #samples do
    local e = samples[i]
    if e and e.t and e.v and e.t >= cutoff then
      out[#out+1] = e
    end
  end

  return out, nowT
end


-------------------
-- Multi-lane events for CPU timeline window
-- Returns events: { { t=, key=seriesKey, v=ms }, ... }, nowT
-------------------
function CPU:GetRecentEvents(windowSec, nowT)
  local cdb = _EnsureCDB()
  if not cdb then
    return {}, _now()
  end

  windowSec = tonumber(windowSec) or 10
  if windowSec < 0.1 then windowSec = 0.1 end

  nowT = nowT or _now()
  local cutoff = nowT - windowSec

  local all = _GetSamples()

  local out = {}
  for seriesKey, samples in pairs(all) do
    -- Skip the aggregate CPU.Total in the timeline view so it doesn't flatten the scale
    if seriesKey ~= "CPU.Total" and samples and #samples > 0 then
      for i = 1, #samples do
        local e = samples[i]
        if e and e.t and e.v and e.t >= cutoff then
          out[#out+1] = { t = e.t, key = seriesKey, v = e.v }
        end
      end
    end
  end

  table.sort(out, function(a, b)
    return (a.t or 0) < (b.t or 0)
  end)

  return out, nowT
end



-- Manual injection for MeasureCall (shares same timeline)
function CPU:PushSample(seriesKey, ms, nowT)
  local cdb = _EnsureCDB()
  if not cdb or not cdb.enabled then return end

  seriesKey = seriesKey or "CPU.Unknown"
  ms = tonumber(ms) or 0
  nowT = nowT or _now()

  local all = _GetSamples()
  all[seriesKey] = all[seriesKey] or {}
  local samples = all[seriesKey]

  samples[#samples+1] = { t = nowT, v = ms }

  _Trim(samples, cdb.keepSeconds or 120, nowT)
end



-------------------
-- Overlay toggle helpers
-------------------
function CPU:OverlayEnabled()
  local cdb = _EnsureCDB()
  return cdb and cdb.overlay == true
end

function CPU:IsOverlayEnabled()
  return self:OverlayEnabled()
end

function CPU:SetOverlayEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.overlay = (on == true)
end


-------------------
-- MeasureCall event breadcrumbs
-------------------
function CPU:EventMarksEnabled()
  local cdb = _EnsureCDB()
  return cdb and cdb.eventMarks == true
end

function CPU:SetEventMarksEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.eventMarks = (on == true)
end



-------------------
-- Optional reference line (frame budget derived from target FPS)
-------------------
function CPU:RefLineEnabled()
  local cdb = _EnsureCDB()
  return cdb and cdb.refLine == true
end

function CPU:SetRefLineEnabled(on)
  local cdb = _EnsureCDB()
  if not cdb then return end
  cdb.refLine = (on == true)
end

function CPU:GetRefFps()
  local cdb = _EnsureCDB()
  return cdb and tonumber(cdb.refFps) or 60
end

function CPU:SetRefFps(fps)
  local cdb = _EnsureCDB()
  if not cdb then return end
  fps = tonumber(fps) or 60
  if fps < 1 then fps = 1 end
  if fps > 1000 then fps = 1000 end
  cdb.refFps = fps
end

function CPU:GetRefBudgetMs()
  local cdb = _EnsureCDB()
  if not (cdb and cdb.refLine == true) then return nil end
  local fps = tonumber(cdb.refFps) or 0
  if fps <= 0 then return nil end
  return 1000 / fps
end



-------------------
-- Per-function measurement: path helpers + stats
-------------------
local function _BuildPath(moduleName, bucket, funcName)
  local name = tostring(funcName or "Unknown"):gsub("%.", ":")
  return tostring(moduleName or "Unknown") .. "." .. name
end

function CPU:IsMeasuredPath(path)
  if not path or path == "" then return false end
  local cdb = _EnsureCDB()
  local m = cdb and cdb.measured

  -- Default behavior: ON unless explicitly disabled for this path.
  if not m then return true end

  local v = m[path]
  if v == false then return false end
  return true
end


function CPU:SetMeasuredPath(path, state)
  if not path or path == "" then return end
  local cdb = _EnsureCDB()
  if not cdb then return end

  cdb.measured = cdb.measured or {}

  -- We store ONLY explicit disables to keep the table small.
  -- nil means "default (enabled)".
  if state then
    cdb.measured[path] = nil
  else
    cdb.measured[path] = false
  end
end


function CPU:GetFuncStat(path)
  if not path or path == "" then return nil end
  local s = _GetFuncStats()
  return s and s[path]
end

-- Generic accessor (Funcs.* or Events.*). Kept separate so Window can show stats for event leaves.
function CPU:GetStat(path)
  return self:GetFuncStat(path)
end


function CPU:GetFuncLastEvents(path)
  if not path or path == "" then return nil end
  local t = self._rtFuncLastEvents
  return t and t[path]
end



local function _ToNumber(v)
  if v == nil then return nil end
  if type(v) == "number" then return v end
  local ok, s = pcall(tostring, v)
  if not ok then return nil end
  return tonumber(s)
end

local function _StoreLastEvents(path, events)
  if not path or path == "" then return end
  if type(events) ~= "table" or #events == 0 then
    return
  end

  CPU._rtFuncLastEvents = CPU._rtFuncLastEvents or {}

  local out = { n = #events, list = {} }
  local want = 8
  local seen = {}

  for i = 1, #events do
    local e = events[i]
    local name
    if type(e) == "table" then
      name = e.event or e.name or e.type or e[1]
    end
    name = tostring(name or e or "?")

    if not seen[name] then
      seen[name] = true
      out.list[#out.list + 1] = name
      if #out.list >= want then
        break
      end
    end
  end

  CPU._rtFuncLastEvents[path] = out
end

local function _PushFuncStat(path, ms, ticks, allocBytes, deallocBytes, events, memKb, strOps, tblOps)
  local cdb = _EnsureCDB()
  if not cdb then return end

  local stats = _GetFuncStats()
  local st = stats[path]
  if not st then
    st = {
      n = 0,

      timeSum = 0,
      timeMin = nil,
      timeMax = nil,
      timeLast = nil,

      tickSum = 0,
      tickMax = nil,
      tickLast = nil,

      allocSum = 0,
      allocMax = nil,
      allocLast = nil,

      deallocSum = 0,
      deallocMax = nil,
      deallocLast = nil,

      -- memory per call (kB), clamped (GC negative -> 0)
      memSum  = 0,
      memMin  = nil,
      memMax  = nil,
      memLast = nil,

      -- Heuristics: string churn vs table churn (best-effort, debug mode)
      strOpsSum  = 0,
      strOpsMax  = nil,
      strOpsLast = nil,

      tblOpsSum  = 0,
      tblOpsMax  = nil,
      tblOpsLast = nil,

      hotTables = false,

    }
    stats[path] = st
  end

  st.n = (st.n or 0) + 1

  ms = _ToNumber(ms) or 0
  st.timeSum  = (st.timeSum or 0) + ms
  st.timeLast = ms
  if st.timeMin == nil or ms < st.timeMin then st.timeMin = ms end
  if st.timeMax == nil or ms > st.timeMax then st.timeMax = ms end

  ticks = _ToNumber(ticks)
  if ticks then
    st.tickSum  = (st.tickSum or 0) + ticks
    st.tickLast = ticks
    if st.tickMax == nil or ticks > st.tickMax then st.tickMax = ticks end
  end

  allocBytes = _ToNumber(allocBytes)
  if allocBytes then
    st.allocSum  = (st.allocSum or 0) + allocBytes
    st.allocLast = allocBytes
    if st.allocMax == nil or allocBytes > st.allocMax then st.allocMax = allocBytes end
  end

  deallocBytes = _ToNumber(deallocBytes)
  if deallocBytes then
    st.deallocSum  = (st.deallocSum or 0) + deallocBytes
    st.deallocLast = deallocBytes
    if st.deallocMax == nil or deallocBytes > st.deallocMax then st.deallocMax = deallocBytes end
  end

  -- Memory per call:
  -- Prefer explicit memKb (debug mode or precomputed), otherwise derive from alloc/dealloc.
  memKb = _ToNumber(memKb)
  if memKb == nil then
    local a = _ToNumber(allocBytes) or 0
    local d = _ToNumber(deallocBytes) or 0
    if a ~= 0 or d ~= 0 then
      memKb = (a - d) / 1024
    end
  end

  if memKb ~= nil then
    if memKb < 0 then memKb = 0 end
    st.memSum  = (st.memSum or 0) + memKb
    st.memLast = memKb
    if st.memMin == nil or memKb < st.memMin then st.memMin = memKb end
    if st.memMax == nil or memKb > st.memMax then st.memMax = memKb end
  end

  strOps = _ToNumber(strOps)
  if strOps then
    st.strOpsSum  = (st.strOpsSum or 0) + strOps
    st.strOpsLast = strOps
    if st.strOpsMax == nil or strOps > st.strOpsMax then st.strOpsMax = strOps end
  end

  tblOps = _ToNumber(tblOps)
  if tblOps then
    st.tblOpsSum  = (st.tblOpsSum or 0) + tblOps
    st.tblOpsLast = tblOps
    if st.tblOpsMax == nil or tblOps > st.tblOpsMax then st.tblOpsMax = tblOps end

    -- Simple flag for "table churn" hot paths.
    -- This cannot see literal "{}" allocations, but it catches common table-heavy code.
    if tblOps >= 25 then
      st.hotTables = true
    end
  end

  if cdb.eventMarks == true and type(events) == "table" and #events > 0 then
    _StoreLastEvents(path, events)
  end

end



-------------------
-- API used by LibPleebug-1.lua wrappers (Def / WrapAll)
-------------------
function CPU:ShouldMeasure(moduleName, bucket, funcName)
  -- Full debug mode owns the wrapper profiler and measures every wrapped call.
  -- Light mode does not execute this path because P:Def returns the original function.
  if MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode() == "full" then
    return true
  end

  local path = _BuildPath(moduleName, bucket, funcName)
  return self:IsMeasuredPath(path)
end

function CPU:CallMeasured(moduleName, bucket, funcName, fn, ...)
  local path = _BuildPath(moduleName, bucket, funcName)
  local cdb = _EnsureCDB()
  if not cdb or type(fn) ~= "function" then
    return fn(...)
  end

  -- Full debug mode measures wrapped calls even though the manual CPU checkbox is hidden.
  -- Outside full mode, keep the legacy opt-in gate.
  local fullDebug = MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode() == "full"
  if cdb.enabled ~= true and not fullDebug then
    return fn(...)
  end

  local mode = cdb.measureMode or "debug"
  if fullDebug then
    mode = "debug"
  end

  -- MeasureCall mode: use Blizzard profiler if available
  if mode == "measurecall"
     and C_AddOnProfiler and C_AddOnProfiler.MeasureCall
     and _ProfilerEnabled()
  then
    local packed = t_pack(...)
    local rets
    local results = C_AddOnProfiler.MeasureCall(function()
      rets = t_pack(fn(t_unpack(packed, 1, packed.n)))
    end)


    if results and results.elapsedMilliseconds then
      local ms      = _ToNumber(results.elapsedMilliseconds) or 0
      local ticks   = _ToNumber(results.elapsedTicks)
      local allocB  = _ToNumber(results.allocatedBytes)
      local dealloc = _ToNumber(results.deallocatedBytes)
      local events  = results.events

      -- memory per call (kB), clamp GC negatives to 0.
      local memKb
      if allocB ~= nil or dealloc ~= nil then
        memKb = ((allocB or 0) - (dealloc or 0)) / 1024
        if memKb < 0 then memKb = 0 end
      end

      _PushFuncStat(path, ms, ticks, allocB, dealloc, events, memKb)

      -- Feed into CPU timeline as a separate per-function lane (ms)
      self:PushSample("CPU.Func." .. path, ms)
    end


    if rets then
      return t_unpack(rets, 1, rets.n)
    end

    return
  end

-- Default: debugprofilestop timing
  local t0 = debugprofilestop and debugprofilestop() or 0
  local m0 = collectgarbage and collectgarbage("count") or 0

  -- Best-effort churn split: count calls to common string/table alloc helpers
  local strOps, tblOps = 0, 0
  local orig_sformat, orig_sgsub, orig_tconcat = string.format, string.gsub, table.concat
  local orig_tinsert, orig_tremove, orig_tsort = table.insert, table.remove, table.sort

  if type(orig_sformat) == "function" then
    string.format = function(...)
      strOps = strOps + 1
      return orig_sformat(...)
    end
  end
  if type(orig_sgsub) == "function" then
    string.gsub = function(...)
      strOps = strOps + 1
      return orig_sgsub(...)
    end
  end
  if type(orig_tconcat) == "function" then
    table.concat = function(...)
      strOps = strOps + 1
      return orig_tconcat(...)
    end
  end

  if type(orig_tinsert) == "function" then
    table.insert = function(...)
      tblOps = tblOps + 1
      return orig_tinsert(...)
    end
  end
  if type(orig_tremove) == "function" then
    table.remove = function(...)
      tblOps = tblOps + 1
      return orig_tremove(...)
    end
  end
  if type(orig_tsort) == "function" then
    table.sort = function(...)
      tblOps = tblOps + 1
      return orig_tsort(...)
    end
  end

  local packed = t_pack(...)
  local ok, retsOrErr = pcall(function()
    return t_pack(fn(t_unpack(packed, 1, packed.n)))
  end)

  -- Restore globals ASAP (even on error)
  string.format = orig_sformat
  string.gsub   = orig_sgsub
  table.concat  = orig_tconcat
  table.insert  = orig_tinsert
  table.remove  = orig_tremove
  table.sort    = orig_tsort

  if not ok then
    error(retsOrErr)
  end

  local rets = retsOrErr


  local t1 = debugprofilestop and debugprofilestop() or t0
  local m1 = collectgarbage and collectgarbage("count") or m0

  local ms = t1 - t0
  local memKb = (tonumber(m1) or 0) - (tonumber(m0) or 0)
  if memKb < 0 then memKb = 0 end

  _PushFuncStat(path, ms, nil, nil, nil, nil, memKb, strOps, tblOps)
  self:PushSample("CPU.Func." .. path, ms)

  return t_unpack(rets, 1, rets.n)

end

-------------------
-- Event handler measure (aggregated by event name)
-- Path format matches Window tree: "Events.<Module>.<EVENT_NAME>"
-------------------
function CPU:CallMeasuredEvent(moduleName, eventName, methodName, fn, ...)
  local path = "Events." .. tostring(moduleName or "Unknown") .. "." .. tostring(eventName or "?")

  local cdb = _EnsureCDB()
  if not cdb or type(fn) ~= "function" then
    return fn(...)
  end
  local fullDebug = MemDebug and MemDebug.GetDebugMode and MemDebug:GetDebugMode() == "full"
  if cdb.enabled ~= true and not fullDebug then
    return fn(...)
  end

  local mode = cdb.measureMode or "debug"
  if fullDebug then
    mode = "debug"
  end

  if mode == "measurecall"
     and C_AddOnProfiler and C_AddOnProfiler.MeasureCall
     and _ProfilerEnabled()
  then
    local packed = t_pack(...)
    local rets
    local results = C_AddOnProfiler.MeasureCall(function()
      rets = t_pack(fn(t_unpack(packed, 1, packed.n)))
    end)

    if results and results.elapsedMilliseconds then
      local ms      = _ToNumber(results.elapsedMilliseconds) or 0
      local ticks   = _ToNumber(results.elapsedTicks)
      local allocB  = _ToNumber(results.allocatedBytes)
      local dealloc = _ToNumber(results.deallocatedBytes)
      local events  = results.events

      local memKb
      if allocB ~= nil or dealloc ~= nil then
        memKb = ((allocB or 0) - (dealloc or 0)) / 1024
        if memKb < 0 then memKb = 0 end
      end

      _PushFuncStat(path, ms, ticks, allocB, dealloc, events, memKb)
      self:PushSample("CPU.Event." .. path, ms)
    end

    if rets then
      return t_unpack(rets, 1, rets.n)
    end
    return
  end

  local t0 = debugprofilestop and debugprofilestop() or 0
  local m0 = collectgarbage and collectgarbage("count") or 0

  local strOps, tblOps = 0, 0
  local orig_sformat, orig_sgsub, orig_tconcat = string.format, string.gsub, table.concat
  local orig_tinsert, orig_tremove, orig_tsort = table.insert, table.remove, table.sort

  if type(orig_sformat) == "function" then
    string.format = function(...)
      strOps = strOps + 1
      return orig_sformat(...)
    end
  end
  if type(orig_sgsub) == "function" then
    string.gsub = function(...)
      strOps = strOps + 1
      return orig_sgsub(...)
    end
  end
  if type(orig_tconcat) == "function" then
    table.concat = function(...)
      strOps = strOps + 1
      return orig_tconcat(...)
    end
  end

  if type(orig_tinsert) == "function" then
    table.insert = function(...)
      tblOps = tblOps + 1
      return orig_tinsert(...)
    end
  end
  if type(orig_tremove) == "function" then
    table.remove = function(...)
      tblOps = tblOps + 1
      return orig_tremove(...)
    end
  end
  if type(orig_tsort) == "function" then
    table.sort = function(...)
      tblOps = tblOps + 1
      return orig_tsort(...)
    end
  end

  local packed = t_pack(...)
  local ok, retsOrErr = pcall(function()
    return t_pack(fn(t_unpack(packed, 1, packed.n)))
  end)

  string.format = orig_sformat
  string.gsub   = orig_sgsub
  table.concat  = orig_tconcat
  table.insert  = orig_tinsert
  table.remove  = orig_tremove
  table.sort    = orig_tsort

  if not ok then
    error(retsOrErr)
  end

  local rets = retsOrErr

  local t1 = debugprofilestop and debugprofilestop() or t0
  local m1 = collectgarbage and collectgarbage("count") or m0

  local ms = t1 - t0
  local memKb = (tonumber(m1) or 0) - (tonumber(m0) or 0)
  if memKb < 0 then memKb = 0 end

  _PushFuncStat(path, ms, nil, nil, nil, nil, memKb, strOps, tblOps)
  self:PushSample("CPU.Event." .. path, ms)

  return t_unpack(rets, 1, rets.n)
end
