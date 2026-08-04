local addonName, ns = ...

ns.Data = ns.Data or {}
local Data = ns.Data
local DB = ns.DB

local SECONDS_PER_WEEK = 7 * 24 * 60 * 60
-- Weekly raid lockouts are typically ~6.5–7.5 days when recorded.
local WEEKLY_RESET_MIN = 5 * 24 * 60 * 60
local WEEKLY_RESET_MAX = 9 * 24 * 60 * 60

function Data.FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if d > 0 then
        return string.format("%dd %dh", d, h)
    elseif h > 0 then
        return string.format("%dh %dm", h, m)
    else
        return string.format("%dm", m)
    end
end

function Data.GetSecondsUntilWeeklyReset()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local sec = C_DateAndTime.GetSecondsUntilWeeklyReset()
        if sec and sec >= 0 then
            return sec
        end
    end
    return nil
end

local function WasWeeklySizedWindow(lockout)
    local resetAt = tonumber(lockout.resetAt) or 0
    local recordedAt = tonumber(lockout.recordedAt) or 0
    if resetAt <= 0 or recordedAt <= 0 then
        return lockout.weeklyGuess == true
    end
    local window = resetAt - recordedAt
    return window >= WEEKLY_RESET_MIN and window <= WEEKLY_RESET_MAX
end

function Data.IsLockoutExpired(lockout, now)
    if not lockout then
        return true
    end
    now = now or time()
    local resetAt = tonumber(lockout.resetAt) or 0
    if resetAt > 0 then
        return now >= resetAt
    end
    -- No reliable resetAt: only apply weekly boundary for weekly-sized lockouts.
    if not WasWeeklySizedWindow(lockout) and lockout.weeklyGuess ~= true then
        return false
    end
    local recordedAt = tonumber(lockout.recordedAt) or 0
    if recordedAt > 0 then
        local weeklyLeft = Data.GetSecondsUntilWeeklyReset()
        if weeklyLeft then
            local lastWeeklyAt = now + weeklyLeft - SECONDS_PER_WEEK
            if recordedAt < lastWeeklyAt then
                return true
            end
        end
    end
    return false
end

function Data.GetEffectiveLockout(guid, instanceId, difficultyId)
    local lockout = DB.GetLockout(guid, instanceId, difficultyId)
    if not lockout then
        return nil
    end
    if Data.IsLockoutExpired(lockout) then
        return nil
    end
    if not Data.IsTruthyFlag(lockout.locked) and not Data.IsTruthyFlag(lockout.extended) then
        return nil
    end
    return lockout
end

--- Normalize GetSavedInstanceEncounterInfo isKilled (boolean or classic 1/0).
--- Lua treats 0 as truthy, so never use raw `if isKilled` / `isKilled and true or false`.
function Data.IsEncounterKilledFlag(isKilled)
    return isKilled == true or isKilled == 1
end

--- Normalize Blizzard 1/0 / boolean flags (locked, extended, isRaid, …).
function Data.IsTruthyFlag(v)
    return v == true or v == 1
end

--- bossName, killed, textureOrFileId, extra = Data.GetEncounterKillInfo(instanceIndex, encounterIndex)
function Data.GetEncounterKillInfo(instanceIndex, encounterIndex)
    local bossName, textureOrFileId, isKilled, extra = GetSavedInstanceEncounterInfo(instanceIndex, encounterIndex)
    return bossName, Data.IsEncounterKilledFlag(isKilled), textureOrFileId, extra
end

--- Count killed bosses from a lockout.bosses table (authoritative for status).
function Data.CountKilledBosses(lockout)
    if not lockout then
        return 0, 0
    end
    local total = tonumber(lockout.numEncounters) or 0
    local killed = 0
    if type(lockout.bosses) == "table" then
        local n = 0
        for _, boss in pairs(lockout.bosses) do
            n = n + 1
            if Data.IsEncounterKilledFlag(boss.killed) then
                killed = killed + 1
            end
        end
        if total < n then
            total = n
        end
        return killed, total
    end
    return tonumber(lockout.encounterProgress) or 0, total
end

--- Compute cell status for the status matrix.
--- Returns: status, progress, total
--- status: "disabled"|"unknown"|"free"|"complete"|"progress"
function Data.GetLockoutStatus(guid, instanceId, difficultyId)
    if DB.IsCharacterRaidDisabled(guid, instanceId) then
        return "disabled", 0, 0
    end
    if not DB.HasLockoutsScan(guid) then
        return "unknown", 0, 0
    end
    local lo = Data.GetEffectiveLockout(guid, instanceId, difficultyId)
    if not lo then
        return "free", 0, 0
    end
    local progress, total = Data.CountKilledBosses(lo)
    if total > 0 and progress >= total then
        return "complete", progress, total
    end
    if total > 0 and progress > 0 then
        return "progress", progress, total
    end
    if Data.IsTruthyFlag(lo.locked) or Data.IsTruthyFlag(lo.extended) then
        -- Locked but 0 kills yet (or boss list empty) — still show as in-progress.
        -- Do not invent total=1 when numEncounters is unknown.
        return "progress", progress, total
    end
    return "free", 0, 0
end

function Data.ComputeResetAt(now, resetSeconds)
    now = now or time()
    local resetSec = tonumber(resetSeconds) or 0
    if resetSec > 0 then
        return now + resetSec, resetSec >= WEEKLY_RESET_MIN and resetSec <= WEEKLY_RESET_MAX
    end
    local weeklyLeft = Data.GetSecondsUntilWeeklyReset()
    if weeklyLeft and weeklyLeft > 0 then
        return now + weeklyLeft, true
    end
    return 0, false
end

--- Remove expired lockout entries from SavedVariables.
function Data.PurgeExpiredLockouts()
    local chars = DB.GetCharacters()
    for _, char in pairs(chars) do
        if type(char.lockouts) == "table" then
            for key, lo in pairs(char.lockouts) do
                if Data.IsLockoutExpired(lo) then
                    char.lockouts[key] = nil
                end
            end
        end
    end
end

--- Re-key stored lockouts / disabledRaids from map InstanceID → journal instanceId once EJ is ready.
--- Returns number of remapped entries.
function Data.RemapLockoutsToJournalIds()
    if not ns.Catalog or not ns.Catalog.IsReady or not ns.Catalog.IsReady() then
        return 0
    end
    local changed = 0
    for _, char in pairs(DB.GetCharacters()) do
        if type(char.lockouts) == "table" then
            local remapped = {}
            for _, lo in pairs(char.lockouts) do
                local savedId = lo.savedInstanceId or lo.instanceId
                local journalId = ns.Catalog.ResolveJournalId(savedId, lo.name) or lo.instanceId
                if journalId ~= lo.instanceId then
                    lo.instanceId = journalId
                    changed = changed + 1
                end
                local key = DB.LockoutKey(lo.instanceId, lo.difficultyId)
                remapped[key] = lo
            end
            char.lockouts = remapped
        end
        -- Hide-flags may have been stored under map IDs before the catalog was ready.
        if type(char.disabledRaids) == "table" then
            local remappedDisabled = {}
            for raidId, disabled in pairs(char.disabledRaids) do
                if disabled then
                    local journalId = ns.Catalog.ResolveJournalId(raidId) or raidId
                    if journalId ~= raidId then
                        changed = changed + 1
                    end
                    remappedDisabled[journalId] = true
                end
            end
            char.disabledRaids = remappedDisabled
        end
    end
    return changed
end

--- Scan GetSavedInstanceInfo for raid lockouts of the current character.
--- Second return: true if catalog was not ready (IDs may still be map InstanceIDs).
function Data.ScanRaidLockouts()
    local guid = UnitGUID("player")
    if not guid then
        return
    end

    -- Soft-load catalog so we can map saved IDs → journal IDs
    local catalogReady = false
    if ns.Catalog then
        if ns.Catalog.EnsureReady then
            catalogReady = ns.Catalog.EnsureReady()
        else
            ns.Catalog.GetTiers()
            catalogReady = ns.Catalog.IsReady and ns.Catalog.IsReady()
        end
        if catalogReady then
            Data.RemapLockoutsToJournalIds()
        end
    end

    local lockouts = {}
    local num = GetNumSavedInstances() or 0
    local now = time()

    for i = 1, num do
        local name, _, reset, difficultyId, locked, extended, _, isRaid,
            maxPlayers, difficultyName, numEncounters, encounterProgress, _, instanceId =
            GetSavedInstanceInfo(i)

        -- Skip historic / unlocked / expired rows — they are not active lockouts.
        -- reset=0 is kept by Blizzard for old IDs; boss flags there are stale.
        local resetSec = tonumber(reset) or 0
        local isActive = (Data.IsTruthyFlag(locked) or Data.IsTruthyFlag(extended)) and resetSec > 0
        -- difficultyId may be 0 for world bosses (Lua 0 is truthy; still allow nil skip).
        if isRaid and difficultyId ~= nil and isActive then
            local journalId = instanceId
            local storeDiffId = difficultyId
            if ns.Catalog and ns.Catalog.ResolveWorldBossLockout then
                local wbJournal, wbEncounter = ns.Catalog.ResolveWorldBossLockout(name, instanceId)
                if wbJournal and wbEncounter then
                    journalId = wbJournal
                    storeDiffId = wbEncounter
                elseif ns.Catalog.ResolveJournalId then
                    journalId = ns.Catalog.ResolveJournalId(instanceId, name) or instanceId
                end
            elseif ns.Catalog and ns.Catalog.ResolveJournalId then
                journalId = ns.Catalog.ResolveJournalId(instanceId, name) or instanceId
            end
            if not journalId then
                journalId = instanceId or 0
            end

            local bosses = {}
            local encounters = tonumber(numEncounters) or 0
            local killedCount = 0
            for e = 1, encounters do
                local bossName, killed = Data.GetEncounterKillInfo(i, e)
                if killed then
                    killedCount = killedCount + 1
                end
                bosses[e] = {
                    name = bossName or ("#" .. e),
                    killed = killed,
                }
            end

            -- Blizzard's encounterProgress is "farthest boss index", not kill count.
            -- Status UI needs kills / total.
            local blizzardProgress = tonumber(encounterProgress) or 0
            local resetAt, weeklyGuess = Data.ComputeResetAt(now, reset)
            local key = DB.LockoutKey(journalId, storeDiffId)
            lockouts[key] = {
                instanceId = journalId,
                savedInstanceId = instanceId,
                difficultyId = storeDiffId,
                name = name,
                difficultyName = difficultyName,
                maxPlayers = maxPlayers,
                numEncounters = encounters,
                encounterProgress = killedCount,
                blizzardEncounterProgress = blizzardProgress,
                bosses = bosses,
                resetAt = resetAt,
                recordedAt = now,
                weeklyGuess = weeklyGuess and true or false,
                locked = Data.IsTruthyFlag(locked),
                extended = Data.IsTruthyFlag(extended),
            }
        end
    end

    DB.SetLockouts(guid, lockouts)
    Data.PurgeExpiredLockouts()
    return lockouts, not catalogReady
end

function Data.DumpDebugLockouts(skipRequest)
    local lines = {}
    local function add(fmt, ...)
        lines[#lines + 1] = string.format(fmt, ...)
    end
    add("[ALI debug] version=%s locale=%s time=%s",
        tostring(ns.version or "?"),
        tostring(GetLocale and GetLocale() or "?"),
        tostring(date and date("%Y-%m-%d %H:%M:%S") or time()))
    if not skipRequest and RequestRaidInfo then
        RequestRaidInfo()
        add("RequestRaidInfo() called")
    end
    local num = GetNumSavedInstances and GetNumSavedInstances() or 0
    add("GetNumSavedInstances = %d", num)
    for i = 1, num do
        local name, lockoutId, reset, difficultyId, locked, extended, instanceIDMostSig, isRaid,
            maxPlayers, difficultyName, numEncounters, encounterProgress, extendDisabled, instanceId =
            GetSavedInstanceInfo(i)
        add("--- [%d] %s | isRaid=%s locked=%s extended=%s",
            i, tostring(name), tostring(isRaid), tostring(locked), tostring(extended))
        local resetSec = tonumber(reset) or 0
        local active = (Data.IsTruthyFlag(locked) or Data.IsTruthyFlag(extended)) and resetSec > 0
        add("  difficultyId=%s (%s) maxPlayers=%s active=%s",
            tostring(difficultyId), tostring(difficultyName), tostring(maxPlayers),
            tostring(active))
        add("  reset=%ss numEncounters=%s blizzardEncounterProgress=%s instanceId=%s lockoutId=%s",
            tostring(reset), tostring(numEncounters), tostring(encounterProgress),
            tostring(instanceId), tostring(lockoutId))
        if not active then
            add("  (historic/expired - boss kill flags are not used for status)")
        end
        local kills = 0
        local enc = tonumber(numEncounters) or 0
        for e = 1, enc do
            local bossName, textureOrFileId, isKilledRaw, extra = GetSavedInstanceEncounterInfo(i, e)
            local killed = Data.IsEncounterKilledFlag(isKilledRaw)
            if killed then kills = kills + 1 end
            add("  boss[%d] %s killed=%s rawIsKilled=%s texture=%s extra=%s",
                e,
                tostring(bossName),
                tostring(killed),
                tostring(isKilledRaw),
                tostring(textureOrFileId),
                tostring(extra))
        end
        add("  killedCount=%d / %d", kills, enc)
        if ns.Catalog and ns.Catalog.ResolveJournalId then
            local jid = ns.Catalog.ResolveJournalId(instanceId, name)
            add("  ResolveJournalId => %s", tostring(jid))
        end
    end
    local guid = UnitGUID and UnitGUID("player")
    if guid and DB.GetCharacter(guid) then
        local char = DB.GetCharacter(guid)
        add("Stored lockouts for %s (%s) scanned=%s:",
            tostring(char.name), tostring(guid), tostring(char.lockoutsScanned))
        if type(char.lockouts) == "table" then
            local keys = {}
            for key in pairs(char.lockouts) do
                keys[#keys + 1] = key
            end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local lo = char.lockouts[key]
                add("  [%s] prog=%s/%s blizzardProg=%s locked=%s savedId=%s",
                    tostring(key),
                    tostring(lo.encounterProgress),
                    tostring(lo.numEncounters),
                    tostring(lo.blizzardEncounterProgress),
                    tostring(lo.locked),
                    tostring(lo.savedInstanceId))
                if type(lo.bosses) == "table" then
                    for bi, boss in ipairs(lo.bosses) do
                        add("    stored boss[%d] %s killed=%s",
                            bi, tostring(boss.name), tostring(Data.IsEncounterKilledFlag(boss.killed)))
                    end
                end
            end
        end
    else
        add("No stored character for current GUID")
    end
    return lines
end

function Data.UpdatePlayerMeta()
    local guid = UnitGUID("player")
    if not guid then
        return
    end
    local _, classFile = UnitClass("player")
    local name, realm = UnitFullName("player")
    realm = realm or GetNormalizedRealmName() or GetRealmName() or ""
    DB.UpdateCharacterMeta(guid, {
        name = name or UnitName("player") or UNKNOWN,
        realm = realm,
        class = classFile or "PRIEST",
        level = UnitLevel("player") or 0,
    })
end
