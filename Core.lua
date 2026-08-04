local addonName, ns = ...

-- Global alias for debugging / external access
AltLockoutInfo = ns
ALI = ns

ns.addonName = addonName
ns.version = "1.0.1"

local DB = ns.DB
local Data = ns.Data
local Catalog = ns.Catalog
local L = ns.L

local eventFrame = CreateFrame("Frame")
local initialized = false
local requestThrottleAt = 0
local THROTTLE_SEC = 1.5
local catalogRetryPending = false

local function RequestRaidInfoThrottled(force)
    local now = GetTime()
    if not force and (now - requestThrottleAt) < THROTTLE_SEC then
        return
    end
    requestThrottleAt = now
    if RequestRaidInfo then
        RequestRaidInfo()
    end
end

--- When EJ becomes available: remap stored mapIDs → journal IDs, apply defaults, rescan.
local function OnCatalogReady()
    if not Catalog.IsReady() then
        return false
    end
    Data.RemapLockoutsToJournalIds()
    if not DB.IsDefaultsApplied() then
        Catalog.ApplyCurrentTierDefaults(false)
    end
    RequestRaidInfoThrottled(true)
    if ns.UI_Main and ns.UI_Main.IsShown and ns.UI_Main.IsShown() then
        ns.UI_Main.Refresh()
    end
    return true
end

local function ScheduleCatalogRetries()
    if catalogRetryPending or not C_Timer or not C_Timer.After then
        return
    end
    catalogRetryPending = true
    local delays = { 1, 3, 8 }
    local lastDelay = delays[#delays]
    for _, delay in ipairs(delays) do
        -- Capture per-iteration; Lua 5.1 loop vars are not closure-safe.
        local d = delay
        C_Timer.After(d, function()
            if Catalog.EnsureReady() then
                OnCatalogReady()
                catalogRetryPending = false
            elseif d == lastDelay then
                catalogRetryPending = false
            end
        end)
    end
end

local function OnPlayerReady()
    DB.Init()
    if ns.Mounts and ns.Mounts.LoadPersistedCache then
        ns.Mounts.LoadPersistedCache(false)
    end
    Data.UpdatePlayerMeta()
    Data.PurgeExpiredLockouts()

    if Catalog.EnsureReady() then
        OnCatalogReady()
    else
        ScheduleCatalogRetries()
        RequestRaidInfoThrottled(true)
    end
end

local function OnUpdateInstanceInfo()
    Data.UpdatePlayerMeta()
    local _, unresolved = Data.ScanRaidLockouts()
    if unresolved then
        -- Catalog was not ready to map IDs — keep retrying EJ + rescan.
        if Catalog.EnsureReady() then
            OnCatalogReady()
        else
            ScheduleCatalogRetries()
        end
    end
    if ns.UI_Main and ns.UI_Main.IsShown and ns.UI_Main.IsShown() then
        ns.UI_Main.Refresh()
    end
    if ns.UI_Debug and ns.UI_Debug.IsShown and ns.UI_Debug.IsShown() then
        ns.UI_Debug.Refresh()
    end
end

local function OnEncounterOrBoss()
    RequestRaidInfoThrottled(false)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= addonName then
            return
        end
        DB.Init()
        initialized = true
    elseif event == "PLAYER_LOGIN" then
        OnPlayerReady()
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin, isReloadingUi = ...
        if isInitialLogin or isReloadingUi then
            Data.UpdatePlayerMeta()
            RequestRaidInfoThrottled(true)
        end
    elseif event == "UPDATE_INSTANCE_INFO" then
        OnUpdateInstanceInfo()
    elseif event == "BOSS_KILL" then
        OnEncounterOrBoss()
    elseif event == "ENCOUNTER_END" then
        local _, _, _, _, success = ...
        if success == 1 or success == true then
            OnEncounterOrBoss()
        end
    end
end)

-- Separate listener: EJ may load after our addon.
local ejWatcher = CreateFrame("Frame")
ejWatcher:RegisterEvent("ADDON_LOADED")
ejWatcher:SetScript("OnEvent", function(_, _, name)
    if name == "Blizzard_EncounterJournal" then
        if Catalog.EnsureReady() then
            OnCatalogReady()
        end
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
eventFrame:RegisterEvent("BOSS_KILL")
eventFrame:RegisterEvent("ENCOUNTER_END")

-- Slash commands
SLASH_ALTLOCKOUTINFO1 = "/ali"
SLASH_ALTLOCKOUTINFO2 = "/altlockout"
SlashCmdList["ALTLOCKOUTINFO"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$") or ""
    msg = msg:lower()
    if msg == "options" or msg == "config" or msg == "opt" or msg == "настройки" then
        if ns.UI_Options then
            ns.UI_Options.Toggle()
        end
    elseif msg == "debug" or msg == "dump" or msg == "отладка" then
        if ns.UI_Debug then
            ns.UI_Debug.Show()
        else
            local lines = Data.DumpDebugLockouts and Data.DumpDebugLockouts() or { "debug unavailable" }
            for _, line in ipairs(lines) do
                print(line)
            end
        end
        RequestRaidInfoThrottled(true)
    elseif msg == "help" or msg == "?" then
        print("|cff00ccff" .. (L["ADDON_NAME"] or "Alt Lockout Info") .. "|r: " .. (L["SLASH_HELP"] or ""))
    else
        if ns.UI_Main then
            ns.UI_Main.Toggle()
        end
    end
end

ns.RequestRaidInfoThrottled = RequestRaidInfoThrottled
ns.OnCatalogReady = OnCatalogReady
