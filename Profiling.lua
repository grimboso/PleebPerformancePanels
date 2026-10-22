local addonName = ...
local pleebug = _G.LibStub and _G.LibStub("LibPleebug-1", true)
if pleebug and pleebug.RegisterAddon then
  pleebug:RegisterAddon(addonName, "Performance Panels", {
    PPP = "Performance Panels",
  }, 10)
end
