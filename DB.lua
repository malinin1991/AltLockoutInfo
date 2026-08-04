local addonName, ns = ...

ns.DB = ns.DB or {}
local DB = ns.DB

local SCHEMA = 2

local function MigrateSchema(db, fromSchema)
    -- v1 → v2: existing characters already had a lockout scan lifecycle.
    if (fromSchema or 0) < 2 and type(db.characters) == "table" then
        for _, char in pairs(db.characters) do
            if type(char) == "table" and char.lockoutsScanned == nil then
                char.lockoutsScanned = true
            end
        end
    end
end

local function EnsureRoot()
    if type(ALInfoDB) ~= "table" then
        ALInfoDB = {}
    end
    local db = ALInfoDB
    local prevSchema = db.schema
    if prevSchema ~= SCHEMA then
        MigrateSchema(db, prevSchema)
        db.schema = SCHEMA
    end
    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    if type(db.settings.tracked) ~= "table" then
        db.settings.tracked = {}
    end
    if db.settings.defaultsApplied == nil then
        db.settings.defaultsApplied = false
    end
    if type(db.characters) ~= "table" then
        db.characters = {}
    end
    if type(db.minimap) ~= "table" then
        db.minimap = { angle = 220 }
    end
    if type(db.settings.ui) ~= "table" then
        db.settings.ui = {}
    end
    if type(db.settings.ui.collapsedTiers) ~= "table" then
        db.settings.ui.collapsedTiers = {}
    end
    if type(db.settings.ui.collapsedRaidsMain) ~= "table" then
        db.settings.ui.collapsedRaidsMain = {}
    end
    if type(db.settings.ui.collapsedWorldBossOptions) ~= "table" then
        db.settings.ui.collapsedWorldBossOptions = {}
    end
    if type(db.settings.ui.collapsedChars) ~= "table" then
        db.settings.ui.collapsedChars = {}
    end
    if db.settings.ui.showCollectedMounts == nil then
        db.settings.ui.showCollectedMounts = false
    end
    if type(db.settings.ui.collapsedMountTiers) ~= "table" then
        db.settings.ui.collapsedMountTiers = {}
    end
    if type(db.settings.ui.windows) ~= "table" then
        db.settings.ui.windows = {}
    end
    if type(db.mountsCache) ~= "table" then
        db.mountsCache = {
            version = 1,
            fingerprint = nil,
            rows = {},
            savedAt = 0,
        }
    end
    if type(db.mountsCache.rows) ~= "table" then
        db.mountsCache.rows = {}
    end
    return db
end

function DB.Init()
    return EnsureRoot()
end

function DB.Get()
    return EnsureRoot()
end

function DB.GetSettings()
    return EnsureRoot().settings
end

function DB.GetTracked()
    return EnsureRoot().settings.tracked
end

function DB.IsDefaultsApplied()
    return EnsureRoot().settings.defaultsApplied == true
end

function DB.SetDefaultsApplied(value)
    EnsureRoot().settings.defaultsApplied = value and true or false
end

function DB.IsTracked(instanceId, difficultyId)
    local tracked = DB.GetTracked()
    local byInst = tracked[instanceId] or tracked[tostring(instanceId)] or tracked[tonumber(instanceId)]
    if type(byInst) ~= "table" then
        return false
    end
    local diffKey = difficultyId
    local v = byInst[diffKey]
    if v == nil then
        v = byInst[tostring(diffKey)]
    end
    if v == nil and tonumber(diffKey) then
        v = byInst[tonumber(diffKey)]
    end
    return v == true
end

--- Return (and migrate) the tracked difficulty table for an instance, keyed by number id.
function DB.EnsureTrackedInstanceTable(instanceId)
    local tracked = DB.GetTracked()
    local id = tonumber(instanceId) or instanceId
    if type(tracked[id]) == "table" then
        return tracked[id]
    end
    local legacy = tracked[tostring(instanceId)]
    if type(legacy) ~= "table" and tonumber(instanceId) ~= nil then
        legacy = tracked[tonumber(instanceId)]
    end
    if type(legacy) == "table" then
        tracked[id] = legacy
    else
        tracked[id] = {}
    end
    if tostring(instanceId) ~= id then
        tracked[tostring(instanceId)] = nil
    end
    local num = tonumber(instanceId)
    if num ~= nil and num ~= id then
        tracked[num] = nil
    end
    return tracked[id]
end

function DB.SetTracked(instanceId, difficultyId, enabled)
    local bucket = DB.EnsureTrackedInstanceTable(instanceId)
    local diffId = tonumber(difficultyId) or difficultyId
    bucket[diffId] = enabled and true or false
    -- Drop string duplicate keys so only one entry exists
    if type(diffId) == "number" then
        bucket[tostring(diffId)] = nil
    end
end

function DB.SetRaidTracked(instanceId, difficultyIds, enabled)
    for _, diffId in ipairs(difficultyIds) do
        DB.SetTracked(instanceId, diffId, enabled)
    end
end

function DB.DisableAllTracked()
    local tracked = DB.GetTracked()
    for instanceId, diffs in pairs(tracked) do
        if type(diffs) == "table" then
            for diffId in pairs(diffs) do
                diffs[diffId] = false
            end
        end
    end
end

function DB.IsAnyDifficultyTracked(instanceId)
    local tracked = DB.GetTracked()
    local byInst = tracked[instanceId] or tracked[tostring(instanceId)] or tracked[tonumber(instanceId)]
    if type(byInst) ~= "table" then
        return false
    end
    for _, v in pairs(byInst) do
        if v == true then
            return true
        end
    end
    return false
end

function DB.GetCharacters()
    return EnsureRoot().characters
end

function DB.GetCharacter(guid)
    if not guid then
        return nil
    end
    return EnsureRoot().characters[guid]
end

function DB.EnsureCharacter(guid)
    local chars = DB.GetCharacters()
    local char = chars[guid]
    if type(char) ~= "table" then
        char = {
            name = UNKNOWN,
            realm = "",
            class = "PRIEST",
            level = 0,
            enabled = true,
            disabledRaids = {},
            lastSeen = 0,
            lockouts = {},
            lockoutsScanned = false,
        }
        chars[guid] = char
    end
    if type(char.disabledRaids) ~= "table" then
        char.disabledRaids = {}
    end
    if type(char.lockouts) ~= "table" then
        char.lockouts = {}
    end
    if char.enabled == nil then
        char.enabled = true
    end
    if char.lockoutsScanned == nil then
        char.lockoutsScanned = false
    end
    return char
end

function DB.UpdateCharacterMeta(guid, meta)
    local char = DB.EnsureCharacter(guid)
    if meta.name then char.name = meta.name end
    if meta.realm then char.realm = meta.realm end
    if meta.class then char.class = meta.class end
    if meta.level then char.level = meta.level end
    char.lastSeen = time()
    return char
end

function DB.SetCharacterEnabled(guid, enabled)
    local char = DB.EnsureCharacter(guid)
    char.enabled = enabled and true or false
end

function DB.IsCharacterEnabled(guid)
    local char = DB.GetCharacter(guid)
    if not char then
        return false
    end
    return char.enabled ~= false
end

function DB.SetCharacterRaidDisabled(guid, instanceId, disabled)
    local char = DB.EnsureCharacter(guid)
    local id = tonumber(instanceId) or instanceId
    -- Clear number/string aliases so a single key remains.
    char.disabledRaids[id] = nil
    char.disabledRaids[tostring(instanceId)] = nil
    if tonumber(instanceId) ~= nil then
        char.disabledRaids[tonumber(instanceId)] = nil
    end
    if disabled then
        char.disabledRaids[id] = true
    end
end

function DB.IsCharacterRaidDisabled(guid, instanceId)
    local char = DB.GetCharacter(guid)
    if not char or type(char.disabledRaids) ~= "table" then
        return false
    end
    local d = char.disabledRaids
    return d[instanceId] == true
        or d[tostring(instanceId)] == true
        or (tonumber(instanceId) ~= nil and d[tonumber(instanceId)] == true)
end

function DB.LockoutKey(instanceId, difficultyId)
    return tostring(instanceId) .. ":" .. tostring(difficultyId)
end

--- Prefer the stronger of two lockout rows (more kills, then fresher reset/recorded).
local function PreferLockout(a, b)
    if not a then
        return b
    end
    if not b then
        return a
    end
    local Data = ns.Data
    local ak, at = 0, 0
    local bk, bt = 0, 0
    if Data and Data.CountKilledBosses then
        ak, at = Data.CountKilledBosses(a)
        bk, bt = Data.CountKilledBosses(b)
    else
        ak = tonumber(a.encounterProgress) or 0
        at = tonumber(a.numEncounters) or 0
        bk = tonumber(b.encounterProgress) or 0
        bt = tonumber(b.numEncounters) or 0
    end
    if ak ~= bk then
        return ak > bk and a or b
    end
    local aProg = at > 0 and (ak / at) or 0
    local bProg = bt > 0 and (bk / bt) or 0
    if aProg ~= bProg then
        return aProg > bProg and a or b
    end
    local aReset = tonumber(a.resetAt) or 0
    local bReset = tonumber(b.resetAt) or 0
    if aReset ~= bReset then
        return aReset > bReset and a or b
    end
    local aRec = tonumber(a.recordedAt) or 0
    local bRec = tonumber(b.recordedAt) or 0
    if aRec ~= bRec then
        return aRec > bRec and a or b
    end
    return b
end

--- Re-key stored lockouts when a difficulty/encounter id changes (e.g. synthetic → EJ).
--- Walks every character so alts keep showing locked until their next scan.
--- Returns number of remapped lockout entries.
function DB.RemapDifficultyLockouts(instanceId, fromDifficultyId, toDifficultyId)
    if instanceId == nil or fromDifficultyId == nil or toDifficultyId == nil then
        return 0
    end
    if fromDifficultyId == toDifficultyId then
        return 0
    end
    local wantInst = tonumber(instanceId) or instanceId
    local wantFrom = tonumber(fromDifficultyId) or fromDifficultyId
    local toDiff = tonumber(toDifficultyId) or toDifficultyId
    local fromKey = DB.LockoutKey(instanceId, fromDifficultyId)
    local toKey = DB.LockoutKey(instanceId, toDifficultyId)
    local changed = 0

    for _, char in pairs(DB.GetCharacters()) do
        if type(char.lockouts) == "table" then
            local lo = char.lockouts[fromKey]
            local oldKey = fromKey
            if not lo then
                for key, entry in pairs(char.lockouts) do
                    local loDiff = tonumber(entry.difficultyId) or entry.difficultyId
                    local loInst = tonumber(entry.instanceId) or entry.instanceId
                    if loDiff == wantFrom
                        and (loInst == wantInst or entry.instanceId == instanceId
                            or entry.savedInstanceId == instanceId
                            or (tonumber(entry.savedInstanceId) or entry.savedInstanceId) == wantInst)
                    then
                        lo = entry
                        oldKey = key
                        break
                    end
                end
            end
            if lo then
                char.lockouts[oldKey] = nil
                lo.difficultyId = toDiff
                lo.instanceId = wantInst
                local existing = char.lockouts[toKey]
                if not existing then
                    char.lockouts[toKey] = lo
                else
                    -- Collision: keep the stronger row (do not drop a richer from-key lockout).
                    local winner = PreferLockout(lo, existing)
                    winner.difficultyId = toDiff
                    winner.instanceId = wantInst
                    char.lockouts[toKey] = winner
                end
                changed = changed + 1
            end
        end
    end
    return changed
end

function DB.SetLockouts(guid, lockoutsByKey)
    local char = DB.EnsureCharacter(guid)
    char.lockouts = lockoutsByKey or {}
    char.lockoutsScanned = true
    char.lastSeen = time()
    return char
end

function DB.HasLockoutsScan(guid)
    local char = DB.GetCharacter(guid)
    if not char then
        return false
    end
    return char.lockoutsScanned == true
end

function DB.GetLockout(guid, instanceId, difficultyId)
    local char = DB.GetCharacter(guid)
    if not char or type(char.lockouts) ~= "table" then
        return nil
    end
    local direct = char.lockouts[DB.LockoutKey(instanceId, difficultyId)]
    if direct then
        return direct
    end
    -- Fallback: entries still keyed by map InstanceID before journal remap.
    local wantDiff = tonumber(difficultyId) or difficultyId
    for _, lo in pairs(char.lockouts) do
        local loDiff = tonumber(lo.difficultyId) or lo.difficultyId
        if loDiff == wantDiff then
            if lo.instanceId == instanceId or lo.savedInstanceId == instanceId then
                return lo
            end
        end
    end
    return nil
end

function DB.GetUI()
    local db = EnsureRoot()
    if type(db.settings.ui) ~= "table" then
        db.settings.ui = {
            collapsedTiers = {},
            collapsedRaidsMain = {},
            collapsedWorldBossOptions = {},
            collapsedChars = {},
            showCollectedMounts = false,
            collapsedMountTiers = {},
        }
    end
    if type(db.settings.ui.collapsedTiers) ~= "table" then
        db.settings.ui.collapsedTiers = {}
    end
    if type(db.settings.ui.collapsedRaidsMain) ~= "table" then
        db.settings.ui.collapsedRaidsMain = {}
    end
    if type(db.settings.ui.collapsedWorldBossOptions) ~= "table" then
        db.settings.ui.collapsedWorldBossOptions = {}
    end
    if type(db.settings.ui.collapsedChars) ~= "table" then
        db.settings.ui.collapsedChars = {}
    end
    if db.settings.ui.showCollectedMounts == nil then
        db.settings.ui.showCollectedMounts = false
    end
    if type(db.settings.ui.collapsedMountTiers) ~= "table" then
        db.settings.ui.collapsedMountTiers = {}
    end
    if type(db.settings.ui.windows) ~= "table" then
        db.settings.ui.windows = {}
    end
    return db.settings.ui
end

function DB.IsTierCollapsed(tierIndex)
    return DB.GetUI().collapsedTiers[tierIndex] == true
end

function DB.SetTierCollapsed(tierIndex, collapsed)
    DB.GetUI().collapsedTiers[tierIndex] = collapsed and true or nil
end

function DB.GetShowCollectedMounts()
    return DB.GetUI().showCollectedMounts == true
end

function DB.SetShowCollectedMounts(value)
    DB.GetUI().showCollectedMounts = value and true or false
end

function DB.IsMountTierCollapsed(tierIndex)
    return DB.GetUI().collapsedMountTiers[tierIndex] == true
end

function DB.SetMountTierCollapsed(tierIndex, collapsed)
    DB.GetUI().collapsedMountTiers[tierIndex] = collapsed and true or nil
end

--- Account-wide persisted mount scan results (survives /reload and alt swaps).
function DB.GetMountsCache()
    return EnsureRoot().mountsCache
end

function DB.SaveMountsCache(fingerprint, rows)
    local cache = EnsureRoot().mountsCache
    cache.version = 6
    cache.fingerprint = fingerprint
    cache.rows = type(rows) == "table" and rows or {}
    cache.savedAt = (time and time()) or 0
    return cache
end

function DB.ClearMountsCache()
    local cache = EnsureRoot().mountsCache
    cache.version = nil
    cache.fingerprint = nil
    cache.rows = {}
    cache.savedAt = 0
end

function DB.IsRaidCollapsedMain(instanceId)
    -- Default expanded (nil/false). true = collapsed.
    local c = DB.GetUI().collapsedRaidsMain
    return c[instanceId] == true
        or c[tostring(instanceId)] == true
        or (tonumber(instanceId) ~= nil and c[tonumber(instanceId)] == true)
end

function DB.SetRaidCollapsedMain(instanceId, collapsed)
    local c = DB.GetUI().collapsedRaidsMain
    local id = tonumber(instanceId) or instanceId
    c[id] = nil
    c[tostring(instanceId)] = nil
    if tonumber(instanceId) ~= nil then
        c[tonumber(instanceId)] = nil
    end
    if collapsed then
        c[id] = true
    end
end

--- World-boss boss list under a location in Options → Raids (default collapsed).
function DB.IsWorldBossOptionsCollapsed(instanceId)
    local c = DB.GetUI().collapsedWorldBossOptions
    local id = tonumber(instanceId) or instanceId
    local v = c[id]
    if v == nil then
        v = c[tostring(instanceId)]
    end
    if v == nil and tonumber(instanceId) ~= nil then
        v = c[tonumber(instanceId)]
    end
    -- Default collapsed to avoid horizontal overflow on first open.
    if v == nil then
        return true
    end
    return v == true
end

function DB.SetWorldBossOptionsCollapsed(instanceId, collapsed)
    local c = DB.GetUI().collapsedWorldBossOptions
    local id = tonumber(instanceId) or instanceId
    c[id] = nil
    c[tostring(instanceId)] = nil
    if tonumber(instanceId) ~= nil then
        c[tonumber(instanceId)] = nil
    end
    -- Store explicit false so user-expanded state persists (default is collapsed).
    c[id] = collapsed and true or false
end

function DB.IsCharCollapsed(guid)
    -- Default collapsed for less clutter
    local v = DB.GetUI().collapsedChars[guid]
    if v == nil then
        return true
    end
    return v == true
end

function DB.SetCharCollapsed(guid, collapsed)
    DB.GetUI().collapsedChars[guid] = collapsed and true or false
end

function DB.GetWindowSize(key)
    local ui = DB.GetUI()
    if type(ui.windows) ~= "table" then
        ui.windows = {}
    end
    local w = ui.windows[key]
    if type(w) == "table" and tonumber(w.w) and tonumber(w.h) then
        return { w = tonumber(w.w), h = tonumber(w.h) }
    end
    return nil
end

function DB.SetWindowSize(key, width, height)
    local ui = DB.GetUI()
    if type(ui.windows) ~= "table" then
        ui.windows = {}
    end
    ui.windows[key] = {
        w = math.floor((tonumber(width) or 0) + 0.5),
        h = math.floor((tonumber(height) or 0) + 0.5),
    }
end

function DB.GetMinimap()
    local db = EnsureRoot()
    if type(db.minimap) ~= "table" then
        db.minimap = { angle = 220 }
    end
    return db.minimap
end
