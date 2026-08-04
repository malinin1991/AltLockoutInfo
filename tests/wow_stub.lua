-- Minimal WoW API stubs for headless unit tests.
local M = {}

function M.reset()
    _G.ALInfoDB = nil
    _G.UNKNOWN = "Unknown"
    _G.UIParent = { CreateFontString = function() return M.fontstring() end }
    _G.UISpecialFrames = {}
    _G.RAID_CLASS_COLORS = {
        PRIEST = { r = 1, g = 1, b = 1 },
        WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
    }

    _G.C_DateAndTime = nil
    _G.C_AddOns = {
        IsAddOnLoaded = function(name)
            return name == "Blizzard_EncounterJournal"
        end,
        LoadAddOn = function() return true end,
    }
    -- Queue timers so chunked C_Timer.After(0) work does not recurse / overflow stack.
    M._timerQueue = {}
    _G.C_Timer = {
        After = function(_, cb)
            if type(cb) == "function" then
                M._timerQueue[#M._timerQueue + 1] = cb
            end
        end,
        NewTicker = function() return { Cancel = function() end } end,
    }

    _G.GetTime = function() return os.clock() end
    _G.time = os.time
    _G.date = os.date
    _G.GetLocale = function() return "enUS" end
    _G.GetNormalizedRealmName = function() return "TestRealm" end
    _G.GetRealmName = function() return "TestRealm" end
    _G.GetDifficultyInfo = function(id)
        id = tonumber(id) or id
        -- Blizzard can error / refuse non-DifficultyIDs (e.g. EJ encounter ids used as WB columns).
        if type(id) ~= "number" or id < 1 or id > 50 then
            error("Usage: GetDifficultyInfo(difficultyID)")
        end
        local names = {
            [3] = "10 Player",
            [4] = "25 Player",
            [5] = "10 Player (Heroic)",
            [6] = "25 Player (Heroic)",
            [7] = "Looking For Raid",
            [9] = "40 Player",
            [14] = "Normal",
            [15] = "Heroic",
            [16] = "Mythic",
            [17] = "Looking For Raid",
        }
        -- Blizzard returns 0 (not nil) when there is no toggle partner; Lua treats 0 as truthy.
        local toggles = {
            [3] = 5,
            [5] = 3,
            [4] = 6,
            [6] = 4,
            [7] = 0,
            [14] = 0,
            [15] = 0,
            [16] = 0,
            [17] = 0,
        }
        -- name, groupType, isHeroic, isChallengeMode, displayHeroic, displayMythic, toggleDifficultyID
        return names[id] or ("Diff" .. tostring(id)), "raid", false, false, false, false, toggles[id] or 0
    end
    _G.UnitGUID = function() return "Player-1-00000001" end
    _G.UnitClass = function() return "Priest", "PRIEST" end
    _G.UnitFullName = function() return "Testchar", "TestRealm" end
    _G.UnitName = function() return "Testchar" end
    _G.UnitLevel = function() return 80 end
    _G.GetNumSavedInstances = function() return 0 end
    _G.GetSavedInstanceInfo = function() end
    _G.GetSavedInstanceEncounterInfo = function() return "Boss", nil, false end
    _G.RequestRaidInfo = function() end
    _G.Minimap = {
        GetCenter = function() return 0, 0 end,
        GetEffectiveScale = function() return 1 end,
        GetFrameLevel = function() return 1 end,
    }
    _G.GetCursorPosition = function() return 0, 0 end
    _G.GameTooltip_Hide = function() end
    _G.GameTooltip = {
        SetOwner = function() end,
        AddLine = function() end,
        AddDoubleLine = function() end,
        SetItemByID = function() end,
        SetHyperlink = function() end,
        Show = function() end,
    }
    _G.tinsert = table.insert
    _G.strmatch = string.match
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end end

    -- Encounter Journal stubs (overridden per-test as needed)
    _G.EJ_GetNumTiers = function() return 0 end
    _G.EJ_GetCurrentTier = function() return 0 end
    _G.EJ_SelectTier = function() end
    _G.EJ_GetTierInfo = function(i) return "Tier " .. i end
    _G.EJ_GetInstanceByIndex = function() return nil end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(diffId)
        -- Default modern set for tests unless overridden
        return diffId == 14 or diffId == 15 or diffId == 16 or diffId == 17
    end
    _G.EJ_SetDifficulty = function() end
    _G.EJ_ResetLootFilter = function() end
    _G.EJ_GetNumLoot = function() return 0 end
    _G.EJ_GetLootInfoByIndex = function() return nil end
    _G.EJ_GetEncounterInfoByIndex = function() return nil end
    _G.EJ_SelectEncounter = function() end
    _G.EJ_GetCurrentInstance = function() return nil end
    _G.EJ_GetDifficulty = function() return nil end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function() return nil end,
    }
    _G.C_MountJournal = {
        GetMountFromItem = function() return nil end,
        GetMountInfoByID = function()
            return nil
        end,
    }
    -- Item API for ContinueOnItemLoad dedupe tests
    _G.Item = {
        CreateFromItemID = function(_, itemID)
            return {
                _itemID = itemID,
                _cached = false,
                IsItemDataCached = function(self) return self._cached end,
                ContinueOnItemLoad = function(self, cb)
                    M._itemLoadCallbacks = M._itemLoadCallbacks or {}
                    M._itemLoadCallbacks[#M._itemLoadCallbacks + 1] = {
                        itemID = self._itemID,
                        cb = cb,
                        item = self,
                    }
                end,
            }
        end,
    }
    M._itemLoadCallbacks = {}
end

function M.flushItemLoads()
    local list = M._itemLoadCallbacks or {}
    M._itemLoadCallbacks = {}
    for _, entry in ipairs(list) do
        if entry.item then
            entry.item._cached = true
        end
        if type(entry.cb) == "function" then
            entry.cb()
        end
    end
    return #list
end

function M.fontstring()
    local fs = {
        _text = "",
        SetPoint = function() end,
        SetSize = function() end,
        SetJustifyH = function() end,
        SetJustifyV = function() end,
        SetTextColor = function() end,
        SetWordWrap = function() end,
        SetWidth = function() end,
        SetDrawLayer = function() end,
        SetFontObject = function() end,
        ClearAllPoints = function() end,
        SetParent = function() end,
        Show = function() end,
        Hide = function() end,
        GetStringHeight = function() return 20 end,
    }
    function fs:SetText(t) self._text = t end
    function fs:GetText() return self._text end
    return fs
end

function M.frame()
    local f = {
        scripts = {},
        SetSize = function() end,
        SetPoint = function() end,
        SetFrameStrata = function() end,
        SetFrameLevel = function() end,
        SetMovable = function() end,
        EnableMouse = function() end,
        RegisterForDrag = function() end,
        RegisterForClicks = function() end,
        SetHighlightTexture = function() end,
        StartMoving = function() end,
        StopMovingOrSizing = function() end,
        ClearAllPoints = function() end,
        SetParent = function() end,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        IsShown = function(self) return self._shown end,
        SetChecked = function(self, v) self._checked = v and true or false end,
        GetChecked = function(self) return self._checked end,
        SetText = function() end,
        CreateTexture = function()
            return {
                SetSize = function() end,
                SetTexture = function() end,
                SetPoint = function() end,
            }
        end,
    }
    function f:SetScript(ev, fn) self.scripts[ev] = fn end
    function f:GetScript(ev) return self.scripts[ev] end
    function f:RegisterEvent() end
    function f:CreateFontString()
        return M.fontstring()
    end
    f.Text = M.fontstring()
    f.TitleText = M.fontstring()
    return f
end

_G.CreateFrame = function()
    return M.frame()
end

--- Run queued C_Timer.After callbacks (chunked Mounts scan, etc.).
function M.flushTimers(maxSteps)
    maxSteps = maxSteps or 100000
    local steps = 0
    while M._timerQueue and #M._timerQueue > 0 and steps < maxSteps do
        local cb = table.remove(M._timerQueue, 1)
        steps = steps + 1
        if type(cb) == "function" then
            cb()
        end
    end
    return steps
end

return M
