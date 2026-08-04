local addonName, ns = ...

ns.Catalog = ns.Catalog or {}
local Catalog = ns.Catalog
local DB = ns.DB
local L = ns.L

-- Standard modern raid difficulties + legacy 10/25 where applicable.
-- Difficulty 7 = Looking For Raid for pre-SoO raids (Dragon Soul, MoP except SoO).
-- Difficulty 17 = Looking For Raid for SoO and all later raids.
Catalog.STANDARD_DIFFICULTIES = { 17, 14, 15, 16 } -- LFR, Normal, Heroic, Mythic
Catalog.LEGACY_DIFFICULTIES = { 7, 3, 4, 5, 6, 9 } -- Legacy LFR, 10N, 25N, 10H, 25H, 40
Catalog.ALL_DIFFICULTIES = { 7, 17, 14, 15, 16, 3, 4, 5, 6, 9 }

local DIFF_ORDER = {
    [3] = 1, [4] = 2, [5] = 3, [6] = 4, [9] = 5,
    [7] = 6, [17] = 7, [14] = 8, [15] = 9, [16] = 10,
}

local DIFF_LOCALE_KEYS = {
    [7] = "DIFF_LFR",
    [17] = "DIFF_LFR",
    [14] = "DIFF_NORMAL",
    [15] = "DIFF_HEROIC",
    [16] = "DIFF_MYTHIC",
    [3] = "DIFF_10N",
    [4] = "DIFF_25N",
    [5] = "DIFF_10H",
    [6] = "DIFF_25H",
    [9] = "DIFF_40",
}

--- Outdoor world-boss EJ groups. Some still report shouldDisplayDifficulty=true
--- and a fake Normal (14) difficulty (notably Draenor=557) — must not use that.
local WORLD_BOSS_JOURNAL_IDS = {
    [322] = true,  -- Pandaria World Bosses
    [557] = true,  -- Draenor (Rukhmar, Drov, Tarlna, …)
    [822] = true,  -- Broken Isles World Bosses
    [959] = true,  -- Invasion Points / Argus
}

local cachedTiers
local ejLoaded
--- Journal encounterID → name (world bosses use encounter IDs as tracked "difficulties").
local encounterLabels = {}

local function NameLooksLikeWorldBossGroup(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local lower = string.lower(name)
    if lower:find("world boss", 1, true) then
        return true
    end
    -- ruRU: "Мировые боссы …"
    if lower:find("миров", 1, true) and lower:find("босс", 1, true) then
        return true
    end
    return false
end

function Catalog.IsWorldBossJournalId(instanceId)
    local id = tonumber(instanceId)
    return id ~= nil and WORLD_BOSS_JOURNAL_IDS[id] == true
end

--- True for outdoor WB journal groups (location = raid, boss = difficulty).
function Catalog.IsWorldBossInstance(parsedOrRaid)
    if type(parsedOrRaid) ~= "table" then
        return false
    end
    if parsedOrRaid.isWorldBoss == true then
        return true
    end
    if parsedOrRaid.shouldDisplayDifficulty == false then
        return true
    end
    if Catalog.IsWorldBossJournalId(parsedOrRaid.instanceId) then
        return true
    end
    if NameLooksLikeWorldBossGroup(parsedOrRaid.name) then
        return true
    end
    return false
end

function Catalog.GetDifficultyOrder(diffId)
    return DIFF_ORDER[diffId] or 99
end

function Catalog.GetDifficultyLabel(diffId)
    local encName = encounterLabels[diffId] or encounterLabels[tonumber(diffId)]
    if encName and encName ~= "" then
        return encName
    end
    local key = DIFF_LOCALE_KEYS[diffId]
    if key and L[key] then
        return L[key]
    end
    -- Never call GetDifficultyInfo with EJ encounter IDs (world-boss columns).
    local id = tonumber(diffId)
    if id and Catalog.IsRaidDifficultyId(id) and GetDifficultyInfo then
        local ok, name = pcall(GetDifficultyInfo, id)
        if ok and name then
            return name
        end
    end
    return tostring(diffId)
end

--- True when id is a Blizzard raid DifficultyID (not a journal encounter id).
function Catalog.IsRaidDifficultyId(diffId)
    local id = tonumber(diffId)
    if not id then
        return false
    end
    if DIFF_LOCALE_KEYS[id] then
        return true
    end
    -- Known retail/legacy difficulty range; journal encounter IDs are much larger.
    return id >= 1 and id <= 50
end

--- Official legacy N↔H partners (DifficultyID). Used if C API read fails.
local TOGGLE_FALLBACK = {
    [3] = 5,
    [5] = 3,
    [4] = 6,
    [6] = 4,
}

--- Other difficulty IDs that share an instance lockout with this one (empty if independent).
--- Per Blizzard: only GetDifficultyInfo toggleDifficultyID (legacy 10/25 N↔H: 3↔5, 4↔6).
--- Flexible Normal/Heroic (14/15), Mythic (16), LFR (7/17) are independent lockouts.
--- World-boss "difficulties" are journal encounter IDs — never pass them to GetDifficultyInfo
--- (can error and abort UI refresh after pools were already cleared).
function Catalog.GetSharedLockoutDifficulties(diffId)
    local id = tonumber(diffId)
    if not id then
        return {}
    end
    if not Catalog.IsRaidDifficultyId(id) then
        return {}
    end
    local toggle
    if GetDifficultyInfo then
        -- name, groupType, isHeroic, isChallengeMode, displayHeroic, displayMythic, toggleDifficultyID
        -- pcall(fn, id) + explicit locals — avoid select(n, GetDifficultyInfo(...)) on WoW C returns.
        local ok, _, _, _, _, _, _, apiToggle = pcall(GetDifficultyInfo, id)
        if ok then
            toggle = tonumber(apiToggle)
        end
    end
    -- Blizzard returns 0 when there is no partner; Lua treats 0 as truthy, so reject 0 explicitly.
    if not toggle or toggle == 0 then
        toggle = TOGGLE_FALLBACK[id]
    end
    if toggle and toggle ~= 0 and toggle ~= id then
        return { toggle }
    end
    return {}
end

--- Find an encounter id already listed on a raid whose label matches bossName.
function Catalog.FindEncounterIdByName(raid, bossName)
    if type(raid) ~= "table" or type(bossName) ~= "string" or bossName == "" then
        return nil
    end
    local lower = string.lower(bossName)
    for _, encId in ipairs(raid.difficulties or {}) do
        local encName = Catalog.GetEncounterLabel(encId)
        if encName and string.lower(encName) == lower then
            return encId
        end
    end
    return nil
end

--- Non-nil locale / EN boss name candidates for a MountsSupplement entry (no array holes).
function Catalog.BossNameCandidates(entry)
    local names = {}
    if type(entry) ~= "table" then
        return names
    end
    local L = ns.L
    local localeName = entry.bossLocaleKey and L and L[entry.bossLocaleKey]
    if type(localeName) == "string" and localeName ~= "" then
        names[#names + 1] = localeName
    end
    if type(entry.bossName) == "string" and entry.bossName ~= "" then
        local lower = string.lower(entry.bossName)
        local dup = false
        for i = 1, #names do
            if string.lower(names[i]) == lower then
                dup = true
                break
            end
        end
        if not dup then
            names[#names + 1] = entry.bossName
        end
    end
    return names
end

--- Map a synthetic / supplement encounter id onto a real EJ encounter when names match.
function Catalog.ResolveSupplementEncounterId(raid, syntheticId, bossName)
    local existing = Catalog.FindEncounterIdByName(raid, bossName)
    if existing then
        return existing
    end
    return syntheticId
end

--- Migrate tracked checkboxes + saved lockouts when synthetic encounter id → real EJ id.
function Catalog.MigrateSupplementEncounterId(instanceId, fromEncId, toEncId)
    if not instanceId or fromEncId == nil or toEncId == nil or fromEncId == toEncId then
        return
    end
    if DB and DB.IsTracked and DB.SetTracked then
        if DB.IsTracked(instanceId, fromEncId) then
            DB.SetTracked(instanceId, toEncId, true)
            DB.SetTracked(instanceId, fromEncId, false)
        end
    end
    if DB and DB.RemapDifficultyLockouts then
        DB.RemapDifficultyLockouts(instanceId, fromEncId, toEncId)
    end
end

function Catalog.SetEncounterLabel(encounterId, name)
    if encounterId and name and name ~= "" then
        encounterLabels[encounterId] = name
    end
end

function Catalog.GetEncounterLabel(encounterId)
    return encounterLabels[encounterId] or encounterLabels[tonumber(encounterId)]
end

--- EJ encounters for a world-boss journal instance (used as synthetic difficulties).
function Catalog.CollectWorldBossEncounters(journalInstanceId)
    local list = {}
    if not journalInstanceId or not EJ_GetEncounterInfoByIndex then
        return list
    end
    if EJ_SelectInstance then
        pcall(EJ_SelectInstance, journalInstanceId)
    end
    local e = 1
    while e <= 40 do
        -- Prefer (index, journalInstanceId); fall back to index-only after SelectInstance.
        local ok, name, _, encounterID = pcall(EJ_GetEncounterInfoByIndex, e, journalInstanceId)
        if not ok or not name then
            ok, name, _, encounterID = pcall(EJ_GetEncounterInfoByIndex, e)
        end
        if not ok or not name then
            break
        end
        if encounterID then
            Catalog.SetEncounterLabel(encounterID, name)
            list[#list + 1] = encounterID
        end
        e = e + 1
    end
    return list
end

--- Difficulties that are valid for a journal instance (requires EJ selected).
function Catalog.GetValidDifficulties(journalInstanceId)
    local list = {}
    if not journalInstanceId or not EJ_SelectInstance or not EJ_IsValidInstanceDifficulty then
        return list
    end
    pcall(EJ_SelectInstance, journalInstanceId)
    for _, diffId in ipairs(Catalog.ALL_DIFFICULTIES) do
        local ok, valid = pcall(EJ_IsValidInstanceDifficulty, diffId)
        if ok and valid then
            list[#list + 1] = diffId
        end
    end
    table.sort(list, function(a, b)
        return Catalog.GetDifficultyOrder(a) < Catalog.GetDifficultyOrder(b)
    end)
    return list
end

function Catalog.EnsureEJ()
    if ejLoaded then
        return true
    end
    if not C_AddOns then
        return false
    end
    local loaded = C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal")
    if not loaded then
        local ok = pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
        if not ok and LoadAddOn then
            pcall(LoadAddOn, "Blizzard_EncounterJournal")
        end
        loaded = C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal")
    end
    ejLoaded = loaded and true or false
    return ejLoaded
end

local function GetTierName(tierIndex)
    if EJ_GetTierInfo then
        local name = EJ_GetTierInfo(tierIndex)
        if name then
            return name
        end
    end
    return "Tier " .. tostring(tierIndex)
end

--- EJ "Current Season / Актуальное дополнение" duplicates the latest expansion raids.
function Catalog.IsSeasonShortcutTierName(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local lower = string.lower(name)
    -- en
    if lower:find("current season", 1, true)
        or lower:find("current expansion", 1, true)
        or lower == "current" then
        return true
    end
    -- de / fr / es / pt / it (latin lower works)
    if lower:find("aktuelle saison", 1, true)
        or lower:find("aktuelle erweiterung", 1, true)
        or lower:find("saison actuelle", 1, true)
        or lower:find("extension actuelle", 1, true)
        or lower:find("temporada actual", 1, true)
        or lower:find("expansi", 1, true) and lower:find("actual", 1, true)
        or lower:find("temporada atual", 1, true)
        or lower:find("expans", 1, true) and lower:find("atual", 1, true)
        or lower:find("stagione attuale", 1, true)
        or lower:find("espansione attuale", 1, true) then
        return true
    end
    -- Cyrillic / CJK: string.lower does not fold these letters
    if name:find("Актуальн", 1, true) or name:find("актуальн", 1, true)
        or name:find("Текущий сезон", 1, true) or name:find("текущий сезон", 1, true)
        or name:find("현재 시즌", 1, true) or name:find("当前赛季", 1, true)
        or name:find("目前賽季", 1, true) or name:find("現行シーズン", 1, true) then
        return true
    end
    return false
end

--- If a tier's raids are a strict subset of another tier, treat it as the season shortcut
--- (covers locales whose name we do not recognize). Equal-size duplicates rely on name
--- detection + GetTrackedColumns instanceId dedupe.
local function RefineSeasonShortcutsByOverlap(tiers)
    for _, tier in ipairs(tiers) do
        if not tier.isSeasonShortcut and type(tier.raids) == "table" and #tier.raids > 0 then
            for _, other in ipairs(tiers) do
                if other ~= tier and type(other.raids) == "table" and #other.raids > #tier.raids then
                    local otherIds = {}
                    for _, r in ipairs(other.raids) do
                        otherIds[r.instanceId] = true
                    end
                    local allFound = true
                    for _, r in ipairs(tier.raids) do
                        if not otherIds[r.instanceId] then
                            allFound = false
                            break
                        end
                    end
                    if allFound then
                        tier.isSeasonShortcut = true
                        break
                    end
                end
            end
        end
    end
end

local function CatalogHasUsableDifficulties(tiers)
    if type(tiers) ~= "table" then
        return false
    end
    for _, tier in ipairs(tiers) do
        for _, raid in ipairs(tier.raids or {}) do
            if type(raid.difficulties) == "table" and #raid.difficulties > 0 then
                return true
            end
        end
    end
    return false
end

--- Normalize EJ_GetInstanceByIndex returns into journal/map ids.
--- Return order (retail): journalInstanceID, name, description, bgImage,
--- buttonImage1, loreImage, buttonImage2, dungeonAreaMapID, link,
--- shouldDisplayDifficulty, mapID (InstanceID), ...
function Catalog.ParseEJInstance(...)
    local instanceID = select(1, ...)
    if not instanceID then
        return nil
    end
    local name = select(2, ...)
    local dungeonAreaMapID = select(8, ...)
    local shouldDisplayDifficulty = select(10, ...)
    local mapID = select(11, ...)
    local resolvedMap = mapID
    if not resolvedMap or resolvedMap == 0 then
        resolvedMap = dungeonAreaMapID
    end
    if resolvedMap == 0 then
        resolvedMap = nil
    end
    -- World bosses: EJ may hide difficulties, OR use a known outdoor group id
    -- (Draenor=557 still exposes Normal), OR name contains "World Boss(es)".
    local isWorldBoss = (shouldDisplayDifficulty == false)
        or Catalog.IsWorldBossJournalId(instanceID)
        or NameLooksLikeWorldBossGroup(name)
    return {
        instanceId = instanceID,
        name = name,
        mapId = resolvedMap,
        dungeonAreaMapID = dungeonAreaMapID,
        shouldDisplayDifficulty = (not isWorldBoss) and (shouldDisplayDifficulty ~= false),
        isWorldBoss = isWorldBoss,
    }
end

local function CatalogHasRaids(tiers)
    if type(tiers) ~= "table" or #tiers == 0 then
        return false
    end
    for _, tier in ipairs(tiers) do
        if type(tier.raids) == "table" and #tier.raids > 0 then
            return true
        end
    end
    return false
end

--- Build raid catalog from Encounter Journal. Call when options open.
function Catalog.Build()
    if not Catalog.EnsureEJ() then
        -- Do not cache a failed load — next GetTiers() must retry EnsureEJ/Build.
        return cachedTiers or {}
    end

    local tiers = {}
    local numTiers = EJ_GetNumTiers and EJ_GetNumTiers() or 0
    local currentTier = EJ_GetCurrentTier and EJ_GetCurrentTier() or numTiers

    for tierIndex = 1, numTiers do
        EJ_SelectTier(tierIndex)
        local raids = {}
        local index = 1
        while true do
            local parsed = Catalog.ParseEJInstance(EJ_GetInstanceByIndex(index, true))
            if not parsed then
                break
            end
            local diffs = {}
            local isWB = Catalog.IsWorldBossInstance(parsed)
            if isWB then
                -- Location = raid; each world boss encounter = synthetic "difficulty".
                diffs = Catalog.CollectWorldBossEncounters(parsed.instanceId)
            else
                diffs = Catalog.GetValidDifficulties(parsed.instanceId)
                if #diffs == 0 then
                    -- EJ may not expose validity until fully ready; keep empty rather than lie.
                    diffs = {}
                end
            end
            table.insert(raids, {
                instanceId = parsed.instanceId,
                mapId = parsed.mapId,
                name = parsed.name or ("Raid " .. parsed.instanceId),
                difficulties = diffs,
                shouldDisplayDifficulty = not isWB,
                isWorldBoss = isWB,
            })
            index = index + 1
        end
        local tierName = GetTierName(tierIndex)
        table.insert(tiers, {
            index = tierIndex,
            name = tierName,
            isCurrent = (tierIndex == currentTier),
            isSeasonShortcut = Catalog.IsSeasonShortcutTierName(tierName),
            raids = raids,
        })
    end

    RefineSeasonShortcutsByOverlap(tiers)

    -- Pin static WB supplement encounters (e.g. Rukhmar) before fingerprint commit
    -- so MergeSupplement cannot change the tree mid/after a mounts scan.
    -- Skip synthetic ids when EJ already exposed the same boss by name (avoids Rukhmar×2).
    if type(ns.MountsSupplement) == "table" then
        for _, entry in ipairs(ns.MountsSupplement) do
            if entry.journalInstanceId and type(entry.difficulties) == "table" then
                for _, tier in ipairs(tiers) do
                    for _, raid in ipairs(tier.raids or {}) do
                        if raid.instanceId == entry.journalInstanceId and raid.isWorldBoss then
                            local bossNames = Catalog.BossNameCandidates(entry)
                            local label = bossNames[1]
                            for _, encId in ipairs(entry.difficulties) do
                                local resolved = encId
                                for _, bn in ipairs(bossNames) do
                                    local existing = Catalog.FindEncounterIdByName(raid, bn)
                                    if existing then
                                        resolved = existing
                                        break
                                    end
                                end
                                if label then
                                    Catalog.SetEncounterLabel(resolved, label)
                                end
                                -- Migrate tracked + saved lockouts from synthetic id → real EJ id.
                                Catalog.MigrateSupplementEncounterId(raid.instanceId, encId, resolved)
                                if resolved == encId then
                                    local have = false
                                    for _, d in ipairs(raid.difficulties or {}) do
                                        if d == encId then
                                            have = true
                                            break
                                        end
                                    end
                                    if not have then
                                        raid.difficulties = raid.difficulties or {}
                                        raid.difficulties[#raid.difficulties + 1] = encId
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Only commit cache when EJ returned usable data.
    if CatalogHasRaids(tiers) or numTiers > 0 then
        local hadCache = cachedTiers ~= nil
        local changed = Catalog.TiersFingerprint(cachedTiers) ~= Catalog.TiersFingerprint(tiers)
        cachedTiers = tiers
        -- Invalidate mounts only when an existing catalog tree actually changes.
        -- Initial populate must not MarkDirty mid StartScanIfNeeded / progress UI.
        if hadCache and changed and ns.Mounts and ns.Mounts.OnCatalogChanged then
            ns.Mounts.OnCatalogChanged()
        end
    end
    return tiers
end

--- Stable fingerprint of tier/raid/difficulty tree (for cache invalidation).
function Catalog.TiersFingerprint(tiers)
    if type(tiers) ~= "table" then
        return ""
    end
    local parts = {}
    for _, tier in ipairs(tiers) do
        parts[#parts + 1] = tostring(tier.index or 0)
        for _, raid in ipairs(tier.raids or {}) do
            parts[#parts + 1] = tostring(raid.instanceId or 0)
            local diffs = raid.difficulties or {}
            parts[#parts + 1] = tostring(#diffs)
            for _, d in ipairs(diffs) do
                parts[#parts + 1] = tostring(d)
            end
        end
    end
    return table.concat(parts, ":")
end

function Catalog.IsReady()
    return CatalogHasRaids(cachedTiers)
end

function Catalog.HasDifficultyData()
    return CatalogHasUsableDifficulties(cachedTiers)
end

function Catalog.EnsureReady()
    if Catalog.IsReady() and Catalog.HasDifficultyData() then
        return true
    end
    Catalog.Build()
    -- Require at least one raid with difficulties so defaults/UI are usable.
    -- Remap can still use IsReady() alone if callers need IDs earlier.
    return Catalog.IsReady() and Catalog.HasDifficultyData()
end

function Catalog.GetTiers(forceRebuild)
    if forceRebuild or not Catalog.IsReady() then
        return Catalog.Build()
    end
    return cachedTiers
end

--- Tiers shown in settings (excludes "Current Season / Актуальное дополнение").
function Catalog.GetTiersForUI(forceRebuild)
    local tiers = Catalog.GetTiers(forceRebuild)
    local list = {}
    for _, tier in ipairs(tiers) do
        if not tier.isSeasonShortcut then
            list[#list + 1] = tier
        end
    end
    return list
end

--- Raids belonging to current season / latest expansion content.
function Catalog.GetCurrentContentRaids()
    local tiers = Catalog.GetTiers()
    local season, latestNonShortcut
    for _, tier in ipairs(tiers) do
        if tier.isSeasonShortcut then
            season = tier
        else
            latestNonShortcut = tier
        end
    end
    if season and type(season.raids) == "table" and #season.raids > 0 then
        return season.raids, season
    end
    if latestNonShortcut then
        return latestNonShortcut.raids or {}, latestNonShortcut
    end
    return {}, nil
end

function Catalog.IsCurrentContentFullyTracked()
    local raids = Catalog.GetCurrentContentRaids()
    local any = false
    for _, raid in ipairs(raids) do
        for _, diffId in ipairs(raid.difficulties or {}) do
            any = true
            if not DB.IsTracked(raid.instanceId, diffId) then
                return false
            end
        end
    end
    return any
end

--- Enable or disable all current-content difficulties. Returns new enabled state.
function Catalog.ToggleCurrentContentTracked()
    local raids = Catalog.GetCurrentContentRaids()
    if #raids == 0 then
        return false
    end
    local enable = not Catalog.IsCurrentContentFullyTracked()
    for _, raid in ipairs(raids) do
        for _, diffId in ipairs(raid.difficulties or {}) do
            DB.SetTracked(raid.instanceId, diffId, enable)
        end
    end
    DB.SetDefaultsApplied(true)
    return enable
end

function Catalog.GetCurrentTierIndex()
    Catalog.EnsureEJ()
    if EJ_GetCurrentTier then
        return EJ_GetCurrentTier()
    end
    local num = EJ_GetNumTiers and EJ_GetNumTiers() or 0
    return num
end

function Catalog.GetRaidByInstanceId(instanceId)
    local tiers = Catalog.GetTiers()
    for _, tier in ipairs(tiers) do
        for _, raid in ipairs(tier.raids) do
            if raid.instanceId == instanceId or raid.mapId == instanceId then
                return raid, tier
            end
        end
    end
    return nil, nil
end

--- Map a GetSavedInstanceInfo id/name onto the catalog's journal instanceId.
function Catalog.ResolveJournalId(savedInstanceId, savedName)
    if savedInstanceId then
        local raid = Catalog.GetRaidByInstanceId(savedInstanceId)
        if raid then
            return raid.instanceId
        end
    end
    if savedName and savedName ~= "" then
        local lower = string.lower(savedName)
        for _, tier in ipairs(Catalog.GetTiers()) do
            for _, raid in ipairs(tier.raids) do
                if raid.name and string.lower(raid.name) == lower then
                    return raid.instanceId
                end
            end
        end
        -- World boss lockouts often use the boss name as the saved instance name.
        local journalId = select(1, Catalog.ResolveWorldBossLockout(savedName, savedInstanceId))
        if journalId then
            return journalId
        end
    end
    return savedInstanceId
end

--- Match a saved lockout to a world-boss location + encounter ("difficulty").
--- Returns journalInstanceId, encounterId (or nil, nil).
function Catalog.ResolveWorldBossLockout(savedName, savedInstanceId)
    if not Catalog.IsReady or not Catalog.IsReady() then
        return nil, nil
    end
    local lower = savedName and string.lower(savedName) or nil

    local function matchRaid(raid)
        if not raid or not raid.isWorldBoss then
            return nil
        end
        if not lower then
            return nil
        end
        for _, encId in ipairs(raid.difficulties or {}) do
            local encName = Catalog.GetEncounterLabel(encId)
            if encName and string.lower(encName) == lower then
                return raid.instanceId, encId
            end
        end
        -- Saved name equals the location group name: single-boss groups only.
        if raid.name and string.lower(raid.name) == lower then
            local diffs = raid.difficulties or {}
            if #diffs == 1 then
                return raid.instanceId, diffs[1]
            end
        end
        return nil
    end

    if savedInstanceId then
        local raid = Catalog.GetRaidByInstanceId(savedInstanceId)
        local jid, enc = matchRaid(raid)
        if jid then
            return jid, enc
        end
    end

    for _, tier in ipairs(Catalog.GetTiers()) do
        for _, raid in ipairs(tier.raids or {}) do
            local jid, enc = matchRaid(raid)
            if jid then
                return jid, enc
            end
        end
    end

    -- Static MountsSupplement aliases (Rukhmar костыль etc.): match EN/locale boss names.
    -- Prefer a real EJ encounter already on the raid over the synthetic supplement id.
    if lower and type(ns.MountsSupplement) == "table" then
        for _, entry in ipairs(ns.MountsSupplement) do
            if type(entry.difficulties) == "table" and entry.difficulties[1] then
                local names = Catalog.BossNameCandidates(entry)
                for _, n in ipairs(names) do
                    if string.lower(n) == lower then
                        local jid = entry.journalInstanceId
                        if jid then
                            local raid = Catalog.GetRaidByInstanceId(jid)
                            local encId = Catalog.ResolveSupplementEncounterId(raid, entry.difficulties[1], n)
                            if names[1] then
                                Catalog.SetEncounterLabel(encId, names[1])
                            end
                            return jid, encId
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

--- True when ResolveJournalId mapped onto a known journal raid id.
function Catalog.IsJournalResolved(resolvedId)
    if not resolvedId or not Catalog.IsReady() then
        return false
    end
    local raid = Catalog.GetRaidByInstanceId(resolvedId)
    return raid ~= nil and raid.instanceId == resolvedId
end

function Catalog.GetAllRaidsFlat()
    local list = {}
    for _, tier in ipairs(Catalog.GetTiers()) do
        for _, raid in ipairs(tier.raids) do
            table.insert(list, {
                instanceId = raid.instanceId,
                name = raid.name,
                tierIndex = tier.index,
                tierName = tier.name,
                isCurrent = tier.isCurrent,
                difficulties = raid.difficulties,
            })
        end
    end
    return list
end

--- Apply default tracked set: only current-content raids (season / latest expansion).
function Catalog.ApplyCurrentTierDefaults(force)
    if DB.IsDefaultsApplied() and not force then
        return false
    end

    local tiers = Catalog.GetTiers(true)
    if not CatalogHasRaids(tiers) or not CatalogHasUsableDifficulties(tiers) then
        return false
    end

    local currentRaids = Catalog.GetCurrentContentRaids()
    if #currentRaids == 0 then
        return false
    end

    local currentIds = {}
    for _, raid in ipairs(currentRaids) do
        currentIds[raid.instanceId] = raid
    end

    if force then
        DB.DisableAllTracked()
    end

    local anySet = false
    -- Enable current-content raids; disable other known raids when applying defaults.
    for _, tier in ipairs(tiers) do
        if not tier.isSeasonShortcut then
            for _, raid in ipairs(tier.raids) do
                local enable = currentIds[raid.instanceId] ~= nil
                local diffs = (currentIds[raid.instanceId] and currentIds[raid.instanceId].difficulties) or raid.difficulties or {}
                for _, diffId in ipairs(diffs) do
                    DB.SetTracked(raid.instanceId, diffId, enable)
                    anySet = true
                end
            end
        end
    end
    -- Also set from season list directly (covers season-only entries)
    for _, raid in ipairs(currentRaids) do
        for _, diffId in ipairs(raid.difficulties or {}) do
            DB.SetTracked(raid.instanceId, diffId, true)
            anySet = true
        end
    end

    if not anySet then
        return false
    end

    DB.SetDefaultsApplied(true)
    return true
end

--- Ensure every known raid/diff has an entry in tracked (false if missing).
function Catalog.EnsureTrackedEntries()
    local tiers = Catalog.GetTiers()
    for _, tier in ipairs(tiers) do
        for _, raid in ipairs(tier.raids) do
            local bucket = DB.EnsureTrackedInstanceTable(raid.instanceId)
            for _, diffId in ipairs(raid.difficulties or {}) do
                local d = tonumber(diffId) or diffId
                if bucket[d] == nil then
                    if bucket[tostring(d)] ~= nil then
                        bucket[d] = bucket[tostring(d)] == true
                        bucket[tostring(d)] = nil
                    else
                        bucket[d] = false
                    end
                end
            end
        end
    end
end

function Catalog.GetTrackedColumns()
    -- Ordered list of { instanceId, name, tierIndex, tierName, difficulties = {diffId,...} }
    -- Only valid difficulties for that raid that are tracked=true.
    -- Skip season shortcut tiers and dedupe by instanceId (season duplicates expansion).
    local columns = {}
    local seen = {}
    local tiers = Catalog.GetTiers()
    for _, tier in ipairs(tiers) do
        if not tier.isSeasonShortcut then
            for _, raid in ipairs(tier.raids) do
                if not seen[raid.instanceId] then
                    local diffs = {}
                    for _, diffId in ipairs(raid.difficulties or {}) do
                        if DB.IsTracked(raid.instanceId, diffId) then
                            diffs[#diffs + 1] = diffId
                        end
                    end
                    if #diffs > 0 then
                        seen[raid.instanceId] = true
                        columns[#columns + 1] = {
                            instanceId = raid.instanceId,
                            name = raid.name,
                            tierIndex = tier.index,
                            tierName = tier.name,
                            difficulties = diffs,
                        }
                    end
                end
            end
        end
    end

    -- Orphan tracked instanceIds not in EJ (lockouts only)
    local known = {}
    for _, col in ipairs(columns) do
        known[col.instanceId] = true
        known[tonumber(col.instanceId) or col.instanceId] = true
        known[tostring(col.instanceId)] = true
    end
    local tracked = DB.GetTracked()
    for instanceId, diffs in pairs(tracked) do
        if type(diffs) == "table" and not known[instanceId] then
            local enabledDiffs = {}
            for diffId, on in pairs(diffs) do
                if on then
                    enabledDiffs[#enabledDiffs + 1] = tonumber(diffId) or diffId
                end
            end
            if #enabledDiffs > 0 then
                table.sort(enabledDiffs, function(a, b)
                    return Catalog.GetDifficultyOrder(a) < Catalog.GetDifficultyOrder(b)
                end)
                local displayName = tostring(instanceId)
                for _, char in pairs(DB.GetCharacters()) do
                    if type(char.lockouts) == "table" then
                        for _, lo in pairs(char.lockouts) do
                            if lo.instanceId == instanceId and lo.name then
                                displayName = lo.name
                                break
                            end
                        end
                    end
                    if displayName ~= tostring(instanceId) then break end
                end
                columns[#columns + 1] = {
                    instanceId = instanceId,
                    name = displayName,
                    tierIndex = 999,
                    tierName = "?",
                    difficulties = enabledDiffs,
                }
            end
        end
    end

    return columns
end
