local addonName, ns = ...

ns.Mounts = ns.Mounts or {}
local Mounts = ns.Mounts
local Catalog = ns.Catalog
local DB = ns.DB

local STATE_IDLE = "idle"
local STATE_SCANNING = "scanning"
local STATE_READY = "ready"

-- Last fully completed scan (kept across MarkDirty / mid-rescan for stable UI).
local cachedRows
local dirty = true
local scanState = STATE_IDLE
local scanGeneration = 0
local scanByKey
local scanWork
local scanIndex = 0
local scanTotal = 0
local scanProgressLabel
local scanLootOffset = 0
local scanLootTotal = 0
local slicesSinceNotify = 0

-- Item-load resolve: dedupe by itemID; accumulate hit contexts; never full-rescan.
local pendingItemIds = {}
local pendingItemContexts = {} -- [itemID] = { hitContext, ... }
local pendingItemLoads = 0
-- Legacy flags kept for tests / debug introspection; full auto-rescan is disabled.
local itemLoadRescanScheduled = false
local rescanAfterFinish = false
local itemRescanBudget = 0
local catalogFingerprint
local persistedLoaded = false

-- Throttle Options UI rebuilds during a long scan (not every difficulty).
local REFRESH_EVERY_N_SLICES = 4
-- Sub-chunk loot within a single raid×difficulty to keep slices short.
local LOOT_PER_SLICE = 40
--- Bump when mountsCache.rows shape changes (forces disk invalidate).
local MOUNTS_CACHE_VERSION = 6

local function PersistCache()
    if type(cachedRows) ~= "table" then
        return
    end
    if DB and DB.SaveMountsCache then
        DB.SaveMountsCache(catalogFingerprint, cachedRows)
    end
end

--- Load account-wide mounts cache from SavedVariables (ALInfoDB).
--- Safe to call often; only reads disk state once per session unless forced.
function Mounts.LoadPersistedCache(force)
    if persistedLoaded and not force then
        return type(cachedRows) == "table" and #cachedRows > 0
    end
    persistedLoaded = true
    if not DB or not DB.GetMountsCache then
        return false
    end
    local cache = DB.GetMountsCache()
    if type(cache) ~= "table" or type(cache.rows) ~= "table" or #cache.rows == 0 then
        return false
    end
    if (cache.version or 0) ~= MOUNTS_CACHE_VERSION then
        if DB.ClearMountsCache then
            DB.ClearMountsCache()
        end
        return false
    end
    cachedRows = cache.rows
    catalogFingerprint = cache.fingerprint
    dirty = false
    scanState = STATE_READY
    return true
end

local function EnsurePersistedLoaded()
    if not persistedLoaded then
        Mounts.LoadPersistedCache(false)
    end
end

local function RowKey(itemID, instanceId)
    return tostring(itemID) .. "|" .. tostring(instanceId)
end

local function SortDiffs(diffs)
    table.sort(diffs, function(a, b)
        return Catalog.GetDifficultyOrder(a) < Catalog.GetDifficultyOrder(b)
    end)
    return diffs
end

local function FingerprintTiers(tiers)
    if Catalog.TiersFingerprint then
        return Catalog.TiersFingerprint(tiers)
    end
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

local function CancelScan()
    scanGeneration = scanGeneration + 1
    scanState = STATE_IDLE
    scanByKey = nil
    scanWork = nil
    scanIndex = 0
    scanTotal = 0
    scanProgressLabel = nil
    scanLootOffset = 0
    scanLootTotal = 0
    slicesSinceNotify = 0
    -- Pending Blizzard callbacks cannot be cancelled; generation check ignores them.
    -- Clear dedupe set so a new scan may re-queue the same itemIDs.
    wipe(pendingItemIds)
    wipe(pendingItemContexts)
    pendingItemLoads = 0
    itemLoadRescanScheduled = false
    rescanAfterFinish = false
end

function Mounts.MarkDirty()
    dirty = true
    itemRescanBudget = 0
    -- Keep cachedRows so UI can still show the last complete list while rescanning.
    CancelScan()
end

function Mounts.IsDirty()
    EnsurePersistedLoaded()
    return dirty == true or cachedRows == nil
end

function Mounts.IsScanning()
    return scanState == STATE_SCANNING
end

function Mounts.IsReady()
    EnsurePersistedLoaded()
    return scanState == STATE_READY and not dirty and type(cachedRows) == "table"
end

--- Optional UI progress: current slice label and N/M totals.
function Mounts.GetScanProgress()
    if scanState ~= STATE_SCANNING then
        return nil
    end
    return {
        label = scanProgressLabel,
        index = scanIndex,
        total = scanTotal,
        lootOffset = scanLootOffset,
        lootTotal = scanLootTotal,
    }
end

function Mounts.IsCollected(mountID)
    if not mountID or not C_MountJournal or not C_MountJournal.GetMountInfoByID then
        return false
    end
    local ok, collected = pcall(function()
        return select(11, C_MountJournal.GetMountInfoByID(mountID))
    end)
    return ok and collected == true
end

function Mounts.GetMountFromItem(itemID)
    if not itemID or not C_MountJournal or not C_MountJournal.GetMountFromItem then
        return nil
    end
    local ok, mountID = pcall(C_MountJournal.GetMountFromItem, itemID)
    if ok and type(mountID) == "number" and mountID > 0 then
        return mountID
    end
    return nil
end

local function GetLootItemID(index)
    if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
        local ok, info = pcall(C_EncounterJournal.GetLootInfoByIndex, index)
        if ok and type(info) == "table" and info.itemID then
            return info.itemID, info.name, info.icon
        end
    end
    -- Legacy: name, icon, slot, armorType, itemID, link, encounterID
    if EJ_GetLootInfoByIndex then
        local ok, name, icon, _, _, itemID = pcall(EJ_GetLootInfoByIndex, index)
        if ok and type(itemID) == "number" and itemID > 0 then
            return itemID, name, icon
        end
    end
    return nil
end

local function ClearLootFilters()
    if EJ_ResetLootFilter then
        pcall(EJ_ResetLootFilter)
    end
    -- Explicitly show all classes/specs; Reset alone is not always enough on retail.
    if EJ_SetLootFilter then
        pcall(EJ_SetLootFilter, 0, 0)
    end
    local noFilter = 15
    if Enum and Enum.ItemSlotFilterType and Enum.ItemSlotFilterType.NoFilter then
        noFilter = Enum.ItemSlotFilterType.NoFilter
    end
    if EJ_SetSlotFilter then
        pcall(EJ_SetSlotFilter, noFilter)
    end
end

local function FindRaidInCatalog(journalInstanceId, mapId)
    local tiers = Catalog.GetTiersForUI and Catalog.GetTiersForUI() or Catalog.GetTiers and Catalog.GetTiers(false)
    for _, tier in ipairs(tiers or {}) do
        for _, raid in ipairs(tier.raids or {}) do
            if journalInstanceId and raid.instanceId == journalInstanceId then
                return tier, raid
            end
        end
    end
    if mapId then
        for _, tier in ipairs(tiers or {}) do
            for _, raid in ipairs(tier.raids or {}) do
                if raid.mapId == mapId or raid.dungeonAreaMapID == mapId then
                    return tier, raid
                end
            end
        end
    end
    return nil, nil
end

--- True when Catalog has at least one raid (difficulties optional for mounts scan).
local function EnsureCatalogRaidsReady()
    if Catalog.IsReady and Catalog.IsReady() then
        return true
    end
    if Catalog.Build then
        Catalog.Build()
    end
    return Catalog.IsReady and Catalog.IsReady()
end

local function CatalogInstanceIdSet()
    local set = {}
    local tiers = Catalog.GetTiersForUI and Catalog.GetTiersForUI() or Catalog.GetTiers and Catalog.GetTiers(false)
    for _, tier in ipairs(tiers or {}) do
        for _, raid in ipairs(tier.raids or {}) do
            if raid.instanceId then
                set[raid.instanceId] = true
            end
        end
    end
    return set
end

--- Drop seeded cache keys whose raid is no longer in the catalog (stale after remaps).
local function PruneOrphanKeys(byKey)
    if type(byKey) ~= "table" or not Catalog.IsReady or not Catalog.IsReady() then
        return
    end
    local allow = CatalogInstanceIdSet()
    for key, row in pairs(byKey) do
        local id = row and row.instanceId
        if id and not allow[id] then
            byKey[key] = nil
        end
    end
end

local function RaidIsWorldBoss(raid)
    if Catalog.IsWorldBossInstance then
        return Catalog.IsWorldBossInstance(raid)
    end
    if type(raid) ~= "table" then
        return false
    end
    if raid.isWorldBoss == true then
        return true
    end
    if raid.shouldDisplayDifficulty == false then
        return true
    end
    return false
end

local function InstanceIsWorldBoss(instanceId)
    if not instanceId then
        return false
    end
    local _, raid = FindRaidInCatalog(instanceId, nil)
    return RaidIsWorldBoss(raid)
end

--- Strip bogus raid DifficultyIDs from world-boss mount rows (keep encounter IDs).
local function SanitizeCachedWorldBossRows()
    if type(cachedRows) ~= "table" then
        return
    end
    if not Catalog.IsReady or not Catalog.IsReady() then
        return
    end
    local changed = false
    for _, row in ipairs(cachedRows) do
        if InstanceIsWorldBoss(row.instanceId) then
            local cleaned = {}
            local hadRaidDiff = false
            for _, d in ipairs(row.difficulties or {}) do
                local id = tonumber(d) or d
                if Catalog.IsRaidDifficultyId and Catalog.IsRaidDifficultyId(id) then
                    hadRaidDiff = true
                else
                    cleaned[#cleaned + 1] = id
                end
            end
            if hadRaidDiff then
                row.difficulties = cleaned
                changed = true
            end
        end
    end
    if changed then
        PersistCache()
    end
end

local function IntersectDiffs(wanted, available)
    if type(wanted) ~= "table" or #wanted == 0 then
        return available or {}
    end
    if type(available) ~= "table" or #available == 0 then
        return wanted
    end
    local allow = {}
    for _, d in ipairs(available) do
        allow[d] = true
    end
    local out = {}
    local have = {}
    for _, d in ipairs(wanted) do
        if allow[d] and not have[d] then
            out[#out + 1] = d
            have[d] = true
        end
    end
    -- Keep explicit 10N/10H from the static list when 25-man exists (catalog probe often omits them).
    if allow[4] or allow[6] then
        for _, d in ipairs(wanted) do
            if (d == 3 or d == 5) and not have[d] then
                out[#out + 1] = d
                have[d] = true
            end
        end
    end
    -- If none of the catalog diffs match (legacy↔modern id drift), use catalog diffs.
    if #out == 0 then
        for _, d in ipairs(available) do
            out[#out + 1] = d
        end
    end
    return SortDiffs(out)
end

local function GetMountDisplay(mountID, fallbackName, fallbackIcon)
    local name, icon = fallbackName, fallbackIcon
    if mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        local ok, mName, _, mIcon = pcall(C_MountJournal.GetMountInfoByID, mountID)
        if ok then
            if mName and mName ~= "" then
                name = mName
            end
            if mIcon then
                icon = mIcon
            end
        end
    end
    return name or ("Mount " .. tostring(mountID or "?")), icon
end

--- Merge one loot hit into an aggregation map keyed by itemID|instanceId.
--- diffId is optional (nil = world boss / no difficulty).
--- Exported for headless tests.
function Mounts.AddLootHit(byKey, hit)
    if type(byKey) ~= "table" or type(hit) ~= "table" then
        return nil
    end
    local itemID = hit.itemID
    local instanceId = hit.instanceId
    local mountID = hit.mountID
    local diffId = hit.diffId
    if not itemID or not instanceId or not mountID then
        return nil
    end
    local key = RowKey(itemID, instanceId)
    local row = byKey[key]
    if not row then
        row = {
            itemID = itemID,
            mountID = mountID,
            name = hit.name,
            icon = hit.icon,
            tierIndex = hit.tierIndex,
            tierName = hit.tierName,
            instanceId = instanceId,
            raidName = hit.raidName,
            difficulties = {},
            _diffSet = {},
        }
        byKey[key] = row
    end
    if hit.name and (not row.name or row.name == "") then
        row.name = hit.name
    end
    if hit.icon and not row.icon then
        row.icon = hit.icon
    end
    if diffId ~= nil and not row._diffSet[diffId] then
        row._diffSet[diffId] = true
        row.difficulties[#row.difficulties + 1] = diffId
        SortDiffs(row.difficulties)
    end
    return row
end

--- Re-hydrate aggregation map from a previous published row list (preserves finds across rescans).
local function ByKeyFromRows(rows)
    local byKey = {}
    if type(rows) ~= "table" then
        return byKey
    end
    for _, row in ipairs(rows) do
        if row.itemID and row.instanceId and row.mountID then
            local diffs = row.difficulties or {}
            if #diffs == 0 then
                Mounts.AddLootHit(byKey, {
                    itemID = row.itemID,
                    mountID = row.mountID,
                    name = row.name,
                    icon = row.icon,
                    tierIndex = row.tierIndex,
                    tierName = row.tierName,
                    instanceId = row.instanceId,
                    raidName = row.raidName,
                    -- no diffId: world boss / no difficulty
                })
            else
                for _, diffId in ipairs(diffs) do
                    Mounts.AddLootHit(byKey, {
                        itemID = row.itemID,
                        mountID = row.mountID,
                        name = row.name,
                        icon = row.icon,
                        tierIndex = row.tierIndex,
                        tierName = row.tierName,
                        instanceId = row.instanceId,
                        raidName = row.raidName,
                        diffId = diffId,
                    })
                end
            end
        end
    end
    return byKey
end

--- Build published rows without mutating scan aggregation (_diffSet stays internal).
local function MaterializeRows(byKey)
    local rows = {}
    for _, row in pairs(byKey) do
        local name, icon = row.name, row.icon
        if not name or name == "" then
            name, icon = GetMountDisplay(row.mountID, row.name, row.icon)
        end
        local diffs = {}
        for i, d in ipairs(row.difficulties or {}) do
            diffs[i] = d
        end
        rows[#rows + 1] = {
            itemID = row.itemID,
            mountID = row.mountID,
            name = name,
            icon = icon,
            tierIndex = row.tierIndex,
            tierName = row.tierName,
            instanceId = row.instanceId,
            raidName = row.raidName,
            difficulties = diffs,
        }
    end
    table.sort(rows, function(a, b)
        if (a.tierIndex or 0) ~= (b.tierIndex or 0) then
            return (a.tierIndex or 0) < (b.tierIndex or 0)
        end
        local an = a.name or ""
        local bn = b.name or ""
        if an ~= bn then
            return an < bn
        end
        return (a.raidName or "") < (b.raidName or "")
    end)
    return rows
end

local function NotifyOptionsIfMountsOpen()
    if not ns.UI_Options or not ns.UI_Options.IsShown or not ns.UI_Options.IsShown() then
        return
    end
    local ui = DB.GetUI and DB.GetUI()
    if ui and ui.optionsTab == "mounts" then
        -- Never fall back to full Refresh here — that path touches Catalog and can
        -- restart the scan via MarkDirty.
        if ns.UI_Options.RefreshMountsProgress then
            ns.UI_Options.RefreshMountsProgress()
        end
    end
end

--- Coalesce late item→mount discovery into the current aggregation — never restart a full EJ scan.
local function PublishResolvedHit(hit)
    if type(hit) ~= "table" or not hit.itemID or not hit.mountID or not hit.instanceId then
        return
    end
    if scanState == STATE_SCANNING and type(scanByKey) == "table" then
        Mounts.AddLootHit(scanByKey, hit)
        return
    end
    -- Scan already finished: merge into published cache without a second EJ pass.
    local byKey = ByKeyFromRows(cachedRows)
    Mounts.AddLootHit(byKey, hit)
    cachedRows = MaterializeRows(byKey)
    dirty = false
    scanState = STATE_READY
    PersistCache()
    NotifyOptionsIfMountsOpen()
end

local function QueueItemResolve(itemID, gen, hitContext)
    if not itemID or not Item or not Item.CreateFromItemID then
        return
    end
    -- Already known as a mount — apply immediately if we have loot context.
    local existing = Mounts.GetMountFromItem(itemID)
    if existing then
        if hitContext then
            hitContext.mountID = existing
            hitContext.itemID = itemID
            PublishResolvedHit(hitContext)
        end
        return
    end
    if pendingItemIds[itemID] then
        -- Load already queued: attach context for the in-flight callback.
        if hitContext then
            local list = pendingItemContexts[itemID]
            if not list then
                list = {}
                pendingItemContexts[itemID] = list
            end
            list[#list + 1] = hitContext
        end
        return
    end
    local ok, item = pcall(Item.CreateFromItemID, Item, itemID)
    if not ok or not item then
        return
    end
    if item.IsItemDataCached and item:IsItemDataCached() then
        -- Cached but not a mount (or API still nil): do not orphan contexts.
        local mountID = Mounts.GetMountFromItem(itemID)
        if mountID and hitContext then
            hitContext.mountID = mountID
            hitContext.itemID = itemID
            PublishResolvedHit(hitContext)
        end
        return
    end
    if not item.ContinueOnItemLoad then
        return
    end
    -- Only retain contexts when a load callback is actually scheduled.
    if hitContext then
        local list = pendingItemContexts[itemID]
        if not list then
            list = {}
            pendingItemContexts[itemID] = list
        end
        list[#list + 1] = hitContext
    end
    pendingItemIds[itemID] = true
    pendingItemLoads = pendingItemLoads + 1
    item:ContinueOnItemLoad(function()
        pendingItemIds[itemID] = nil
        pendingItemLoads = math.max(0, pendingItemLoads - 1)
        local contexts = pendingItemContexts[itemID]
        pendingItemContexts[itemID] = nil
        if gen ~= scanGeneration then
            return
        end
        local mountID = Mounts.GetMountFromItem(itemID)
        if not mountID or type(contexts) ~= "table" then
            return
        end
        local name, icon = GetMountDisplay(mountID, nil, nil)
        for _, ctx in ipairs(contexts) do
            ctx.itemID = itemID
            ctx.mountID = mountID
            if name and (not ctx.name or ctx.name == "") then
                ctx.name = name
            end
            if icon and not ctx.icon then
                ctx.icon = icon
            end
            PublishResolvedHit(ctx)
        end
    end)
end

--- Apply static world-boss boss names / synthetic encounter ids from MountsSupplement.
--- mutateCatalog: when true, also append ids onto raid.difficulties (Catalog.Build only).
--- When EJ already lists the same boss by name, reuse that encounter id (no Rukhmar×2).
local function ApplyStaticWorldBossEntry(entry, raid, mutateCatalog)
    local encDiffs = entry.difficulties
    if type(encDiffs) ~= "table" or #encDiffs == 0 then
        return
    end
    local bossNames = Catalog.BossNameCandidates and Catalog.BossNameCandidates(entry) or {}
    local label = bossNames[1]
    for _, encId in ipairs(encDiffs) do
        local resolved = encId
        if raid and Catalog.FindEncounterIdByName then
            for _, bn in ipairs(bossNames) do
                local existing = Catalog.FindEncounterIdByName(raid, bn)
                if existing then
                    resolved = existing
                    break
                end
            end
        end
        if label and Catalog.SetEncounterLabel then
            Catalog.SetEncounterLabel(resolved, label)
        end
        -- Never mutate the live catalog during MergeSupplement / UI — that changes
        -- TiersFingerprint and kicks a second mounts scan after the first finishes.
        if mutateCatalog and raid and type(raid.difficulties) == "table" and resolved == encId then
            local have = false
            for _, d in ipairs(raid.difficulties) do
                if d == encId then
                    have = true
                    break
                end
            end
            if not have then
                raid.difficulties[#raid.difficulties + 1] = encId
            end
        end
    end
end

--- Encounter ids to use for a WB supplement entry (real EJ id when name matches).
local function SupplementEncounterIds(entry, raid)
    local encDiffs = entry.difficulties
    if type(encDiffs) ~= "table" then
        return {}
    end
    local bossNames = Catalog.BossNameCandidates and Catalog.BossNameCandidates(entry) or {}
    local out = {}
    local seen = {}
    for _, encId in ipairs(encDiffs) do
        local resolved = encId
        if raid and Catalog.FindEncounterIdByName then
            for _, bn in ipairs(bossNames) do
                local existing = Catalog.FindEncounterIdByName(raid, bn)
                if existing then
                    resolved = existing
                    break
                end
            end
        end
        if not seen[resolved] then
            seen[resolved] = true
            out[#out + 1] = resolved
        end
    end
    return out
end

--- Tracking diffs for a mount row: scanned diffs, else static supplement, else catalog WB.
function Mounts.GetTrackingDiffs(row)
    if type(row) ~= "table" then
        return {}
    end
    local diffs = row.difficulties
    if type(diffs) == "table" and #diffs > 0 then
        local cleaned = {}
        for _, d in ipairs(diffs) do
            if not (Catalog.IsRaidDifficultyId and Catalog.IsRaidDifficultyId(d)) then
                cleaned[#cleaned + 1] = d
            elseif not InstanceIsWorldBoss(row.instanceId) then
                cleaned[#cleaned + 1] = d
            end
        end
        if #cleaned > 0 then
            return cleaned
        end
    end
    local list = ns.MountsSupplement
    if type(list) == "table" and row.itemID then
        for _, entry in ipairs(list) do
            if entry.itemID == row.itemID and type(entry.difficulties) == "table" and #entry.difficulties > 0 then
                local _, raid = FindRaidInCatalog(entry.journalInstanceId, entry.mapId)
                ApplyStaticWorldBossEntry(entry, raid)
                return SupplementEncounterIds(entry, raid)
            end
        end
    end
    if InstanceIsWorldBoss(row.instanceId) then
        local _, raid = FindRaidInCatalog(row.instanceId, nil)
        if raid and type(raid.difficulties) == "table" and #raid.difficulties > 0 then
            local out = {}
            for i, d in ipairs(raid.difficulties) do
                out[i] = d
            end
            return out
        end
    end
    return {}
end

--- Merge static MountsSupplement into an aggregation map (fills EJ gaps like Invincible).
function Mounts.MergeSupplement(byKey)
    local list = ns.MountsSupplement
    if type(byKey) ~= "table" or type(list) ~= "table" then
        return 0
    end
    local added = 0
    for _, entry in ipairs(list) do
        local itemID = entry.itemID
        if itemID then
            -- Prefer journal API, fall back to static mountID (no item-load / no rescan).
            local mountID = Mounts.GetMountFromItem(itemID) or entry.mountID
            if mountID then
                local tier, raid = FindRaidInCatalog(entry.journalInstanceId, entry.mapId)
                if raid then
                    local name, icon = GetMountDisplay(mountID, entry.name, nil)
                    local key = RowKey(itemID, raid.instanceId)
                    local before = byKey[key]
                    if RaidIsWorldBoss(raid) then
                        ApplyStaticWorldBossEntry(entry, raid, false)
                        local encDiffs = SupplementEncounterIds(entry, raid)
                        if type(encDiffs) == "table" and #encDiffs > 0 then
                            for _, encId in ipairs(encDiffs) do
                                Mounts.AddLootHit(byKey, {
                                    itemID = itemID,
                                    mountID = mountID,
                                    name = name,
                                    icon = icon,
                                    tierIndex = tier and tier.index,
                                    tierName = tier and tier.name,
                                    instanceId = raid.instanceId,
                                    raidName = raid.name,
                                    diffId = encId,
                                })
                            end
                        else
                            Mounts.AddLootHit(byKey, {
                                itemID = itemID,
                                mountID = mountID,
                                name = name,
                                icon = icon,
                                tierIndex = tier and tier.index,
                                tierName = tier and tier.name,
                                instanceId = raid.instanceId,
                                raidName = raid.name,
                            })
                        end
                    else
                        local diffs = IntersectDiffs(entry.difficulties, raid.difficulties)
                        if type(diffs) == "table" and #diffs > 0 then
                            for _, diffId in ipairs(diffs) do
                                Mounts.AddLootHit(byKey, {
                                    itemID = itemID,
                                    mountID = mountID,
                                    name = name,
                                    icon = icon,
                                    tierIndex = tier and tier.index,
                                    tierName = tier and tier.name,
                                    instanceId = raid.instanceId,
                                    raidName = raid.name,
                                    diffId = diffId,
                                })
                            end
                        else
                            Mounts.AddLootHit(byKey, {
                                itemID = itemID,
                                mountID = mountID,
                                name = name,
                                icon = icon,
                                tierIndex = tier and tier.index,
                                tierName = tier and tier.name,
                                instanceId = raid.instanceId,
                                raidName = raid.name,
                            })
                        end
                    end
                    if not before and byKey[key] then
                        added = added + 1
                    end
                end
            end
            -- No QueueItemResolve here: that used to force a second full EJ scan.
        end
    end
    return added
end

--- True when every drop difficulty for this mount/raid is tracked.
function Mounts.IsFullyTracked(instanceId, difficulties)
    if type(difficulties) ~= "table" or #difficulties == 0 then
        return false
    end
    for _, diffId in ipairs(difficulties) do
        if not DB.IsTracked(instanceId, diffId) then
            return false
        end
    end
    return true
end

--- Master checkbox: toggle all drop difficulties for this mount/raid.
function Mounts.SetFullyTracked(instanceId, difficulties, enabled)
    DB.SetRaidTracked(instanceId, difficulties, enabled)
end

--- Process up to LOOT_PER_SLICE loot entries for one raid×difficulty [×encounter].
--- diffId may be nil for world bosses / instances with no EJ difficulties.
--- Returns true when more loot remains for the same job.
local function ScanLootChunk(byKey, tier, raid, diffId, startOffset, gen, encounterIndex)
    local instanceId = raid.instanceId
    -- Do NOT restore EJ mid-job: that cleared encounter selection between loot
    -- chunks and dropped mounts (e.g. Invincible) from later slices.

    if instanceId and EJ_SelectInstance then
        pcall(EJ_SelectInstance, instanceId)
    end
    if diffId ~= nil and EJ_SetDifficulty then
        pcall(EJ_SetDifficulty, diffId)
    end
    -- Always re-apply filters + encounter on every chunk (not only offset 0).
    ClearLootFilters()
    -- World bosses: treat journal encounterID as the tracked "difficulty".
    local effectiveDiffId = diffId
    if encounterIndex and encounterIndex > 0 and EJ_GetEncounterInfoByIndex and EJ_SelectEncounter then
        local ok, encName, _, encounterID = pcall(EJ_GetEncounterInfoByIndex, encounterIndex)
        if ok and encounterID then
            pcall(EJ_SelectEncounter, encounterID)
            if RaidIsWorldBoss(raid) and effectiveDiffId == nil then
                effectiveDiffId = encounterID
                if Catalog.SetEncounterLabel then
                    Catalog.SetEncounterLabel(encounterID, encName)
                end
            end
        end
    elseif EJ_SelectEncounter then
        -- Instance-wide pass: clear encounter filter left by a previous job.
        pcall(EJ_SelectEncounter, nil)
    end

    local numLoot = 0
    if EJ_GetNumLoot then
        local ok, n = pcall(EJ_GetNumLoot)
        if ok and type(n) == "number" then
            numLoot = n
        end
    end
    scanLootTotal = numLoot

    local from = startOffset + 1
    local to = math.min(startOffset + LOOT_PER_SLICE, numLoot)
    for i = from, to do
        local itemID, lootName, lootIcon = GetLootItemID(i)
        if itemID then
            local mountID = Mounts.GetMountFromItem(itemID)
            if mountID then
                local name, icon = GetMountDisplay(mountID, lootName, lootIcon)
                Mounts.AddLootHit(byKey, {
                    itemID = itemID,
                    mountID = mountID,
                    name = name,
                    icon = icon,
                    tierIndex = tier.index,
                    tierName = tier.name,
                    instanceId = instanceId,
                    raidName = raid.name,
                    diffId = effectiveDiffId,
                })
            else
                QueueItemResolve(itemID, gen, {
                    itemID = itemID,
                    name = lootName,
                    icon = lootIcon,
                    tierIndex = tier.index,
                    tierName = tier.name,
                    instanceId = instanceId,
                    raidName = raid.name,
                    diffId = effectiveDiffId,
                })
            end
        end
    end

    if to < numLoot then
        scanLootOffset = to
        return true
    end
    scanLootOffset = 0
    scanLootTotal = 0
    return false
end

--- Difficulties to scan for mounts: fresh EJ probe (catalog cache can miss 10N).
local function DiffsForMountScan(raid)
    -- World bosses must not inherit LFR/N/H/M (or legacy 10/25) checkboxes.
    if RaidIsWorldBoss(raid) then
        return {}
    end
    local diffs = {}
    if raid.instanceId and Catalog.GetValidDifficulties then
        diffs = Catalog.GetValidDifficulties(raid.instanceId) or {}
    end
    if #diffs == 0 and type(raid.difficulties) == "table" then
        for _, d in ipairs(raid.difficulties) do
            diffs[#diffs + 1] = d
        end
    end
    -- If 25-man legacy is present but 10-man is missing from the probe, still try 10N/10H
    -- for mount loot (empty loot is harmless; some EJ caches omit 10-man validity).
    local have = {}
    for _, d in ipairs(diffs) do
        have[d] = true
    end
    if (have[4] or have[6]) and not have[3] then
        diffs[#diffs + 1] = 3
        have[3] = true
    end
    if (have[4] or have[6]) and not have[5] then
        diffs[#diffs + 1] = 5
        have[5] = true
    end
    return SortDiffs(diffs)
end

--- Map a mount item to the world-boss encounter that lists it in EJ loot.
local function FindEncounterDroppingItem(journalInstanceId, itemID)
    if not journalInstanceId or not itemID or not EJ_GetEncounterInfoByIndex then
        return nil
    end
    if EJ_SelectInstance then
        pcall(EJ_SelectInstance, journalInstanceId)
    end
    ClearLootFilters()
    local e = 1
    while e <= 40 do
        local ok, encName, _, encounterID = pcall(EJ_GetEncounterInfoByIndex, e)
        if not ok or not encName then
            break
        end
        if encounterID and EJ_SelectEncounter then
            pcall(EJ_SelectEncounter, encounterID)
            ClearLootFilters()
            local numLoot = 0
            if EJ_GetNumLoot then
                local okN, n = pcall(EJ_GetNumLoot)
                if okN and type(n) == "number" then
                    numLoot = n
                end
            end
            for i = 1, numLoot do
                local lootItemID = GetLootItemID(i)
                if lootItemID == itemID then
                    if Catalog.SetEncounterLabel then
                        Catalog.SetEncounterLabel(encounterID, encName)
                    end
                    return encounterID, encName
                end
            end
        end
        e = e + 1
    end
    return nil
end

--- WB rows often arrive from instance-wide loot with no diffId; bind to boss encounter.
--- Returns how many rows were attributed.
local function AttributeWorldBossMountEncounters(byKey)
    local attributed = 0
    if type(byKey) ~= "table" then
        return attributed
    end
    for _, row in pairs(byKey) do
        if row and row.itemID and row.instanceId and InstanceIsWorldBoss(row.instanceId) then
            local hasEncounterDiff = false
            for _, d in ipairs(row.difficulties or {}) do
                if not (Catalog.IsRaidDifficultyId and Catalog.IsRaidDifficultyId(d)) then
                    hasEncounterDiff = true
                    break
                end
            end
            if not hasEncounterDiff then
                local encId = FindEncounterDroppingItem(row.instanceId, row.itemID)
                if encId then
                    row.difficulties = {}
                    row._diffSet = {}
                    Mounts.AddLootHit(byKey, {
                        itemID = row.itemID,
                        mountID = row.mountID,
                        name = row.name,
                        icon = row.icon,
                        tierIndex = row.tierIndex,
                        tierName = row.tierName,
                        instanceId = row.instanceId,
                        raidName = row.raidName,
                        diffId = encId,
                    })
                    attributed = attributed + 1
                end
            end
        end
    end
    return attributed
end

local function AppendEncounterJobs(work, tier, raid, diffId)
    -- Instance-wide first: many WB mounts only appear here in EJ.
    work[#work + 1] = {
        tier = tier,
        raid = raid,
        diffId = diffId,
        encounterIndex = 0,
    }
    if not raid.instanceId or not EJ_SelectInstance or not EJ_GetEncounterInfoByIndex then
        return
    end
    pcall(EJ_SelectInstance, raid.instanceId)
    if diffId ~= nil and EJ_SetDifficulty then
        pcall(EJ_SetDifficulty, diffId)
    end
    local e = 1
    while e <= 40 do
        local ok, name = pcall(EJ_GetEncounterInfoByIndex, e)
        if not ok or not name then
            break
        end
        work[#work + 1] = {
            tier = tier,
            raid = raid,
            diffId = diffId,
            encounterIndex = e,
        }
        e = e + 1
    end
end

local function BuildWorkList()
    local work = {}
    local tiers = Catalog.GetTiersForUI and Catalog.GetTiersForUI() or Catalog.GetTiers()
    for _, tier in ipairs(tiers or {}) do
        for _, raid in ipairs(tier.raids or {}) do
            if RaidIsWorldBoss(raid) then
                -- No EJ_SetDifficulty; instance-wide + per-boss (encounter = difficulty).
                AppendEncounterJobs(work, tier, raid, nil)
            else
                local diffs = DiffsForMountScan(raid)
                if #diffs == 0 then
                    AppendEncounterJobs(work, tier, raid, nil)
                else
                    for _, diffId in ipairs(diffs) do
                        AppendEncounterJobs(work, tier, raid, diffId)
                    end
                end
            end
        end
    end
    return work
end

local function CurrentCatalogFingerprint()
    if not Catalog.IsReady or not Catalog.IsReady() then
        return nil
    end
    return FingerprintTiers(Catalog.GetTiers and Catalog.GetTiers(false))
end

local function FinishScan(gen, byKey)
    if gen ~= scanGeneration then
        return
    end
    byKey = byKey or {}
    PruneOrphanKeys(byKey)
    Mounts.MergeSupplement(byKey)
    AttributeWorldBossMountEncounters(byKey)
    cachedRows = MaterializeRows(byKey)
    dirty = false
    scanState = STATE_READY
    scanByKey = nil
    scanWork = nil
    scanIndex = scanTotal
    scanProgressLabel = nil
    scanLootOffset = 0
    scanLootTotal = 0
    slicesSinceNotify = 0

    -- Intentionally no automatic second EJ pass. Late item→mount resolves merge
    -- into scanByKey / cachedRows via QueueItemResolve context instead.
    rescanAfterFinish = false
    -- Re-sync fingerprint after finish so UI refresh cannot see a spurious catalog
    -- drift (e.g. labels-only) and restart a full scan.
    catalogFingerprint = CurrentCatalogFingerprint() or catalogFingerprint
    PersistCache()
    NotifyOptionsIfMountsOpen()
end

local function ScheduleNextSlice(gen)
    local function run()
        Mounts._ProcessScanSlice(gen)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, run)
    else
        run()
    end
end

--- One cooperative slice: process a loot sub-chunk of one raid×difficulty, then yield.
function Mounts._ProcessScanSlice(gen)
    if gen ~= scanGeneration or scanState ~= STATE_SCANNING then
        return
    end
    local work = scanWork
    local byKey = scanByKey
    if type(work) ~= "table" or type(byKey) ~= "table" then
        FinishScan(gen, byKey or {})
        return
    end

    -- Advance to next difficulty only when previous loot is fully processed.
    if scanLootOffset == 0 then
        scanIndex = scanIndex + 1
    end
    local job = work[scanIndex]
    if not job then
        FinishScan(gen, byKey)
        return
    end

    local tier = job.tier
    local raid = job.raid
    scanProgressLabel = (tier and tier.name) or (raid and raid.name) or nil
    local moreLoot = ScanLootChunk(
        byKey, tier, raid, job.diffId, scanLootOffset, gen, job.encounterIndex)

    -- Do NOT publish partial MaterializeRows to cachedRows — keep last complete list.

    if moreLoot then
        slicesSinceNotify = slicesSinceNotify + 1
        if slicesSinceNotify >= REFRESH_EVERY_N_SLICES then
            slicesSinceNotify = 0
            NotifyOptionsIfMountsOpen()
        end
        ScheduleNextSlice(gen)
        return
    end

    local nextJob = work[scanIndex + 1]
    if not nextJob then
        FinishScan(gen, byKey)
        return
    end

    slicesSinceNotify = slicesSinceNotify + 1
    local tierDone = nextJob.tier and tier and nextJob.tier.index ~= tier.index
    if tierDone or slicesSinceNotify >= REFRESH_EVERY_N_SLICES then
        slicesSinceNotify = 0
        NotifyOptionsIfMountsOpen()
    end

    ScheduleNextSlice(gen)
end

--- Kick a non-blocking EJ scan if cache is dirty / missing. Safe to call often.
function Mounts.StartScanIfNeeded()
    EnsurePersistedLoaded()
    SanitizeCachedWorldBossRows()
    -- While a pass is running: never restart unless the catalog tree truly changed.
    -- Progress UI calls this every few slices — must be a no-op for the common case.
    if scanState == STATE_SCANNING then
        local fp = CurrentCatalogFingerprint()
        if fp and (not catalogFingerprint or fp ~= catalogFingerprint) then
            CancelScan()
            dirty = true
            -- fall through and start a fresh pass
        else
            return cachedRows or {}
        end
    end

    if not dirty and type(cachedRows) == "table" and scanState == STATE_READY then
        local fp = CurrentCatalogFingerprint()
        if fp then
            -- Missing fingerprint on disk/memory cache is dirty (never skip invalidate).
            if not catalogFingerprint or fp ~= catalogFingerprint then
                dirty = true
                catalogFingerprint = fp
            else
                return cachedRows
            end
        else
            -- Catalog not ready yet: keep serving cache.
            return cachedRows
        end
    end

    -- Mounts only need raids present; empty difficulties (world bosses) are OK.
    if not EnsureCatalogRaidsReady() then
        return cachedRows or {}
    end
    if not Catalog.EnsureEJ() then
        return cachedRows or {}
    end

    -- Capture fingerprint for this scan generation.
    catalogFingerprint = CurrentCatalogFingerprint() or FingerprintTiers(Catalog.GetTiers(false))

    scanGeneration = scanGeneration + 1
    local gen = scanGeneration
    -- Drop stale pending-item tracking; Blizzard callbacks still ignore via gen.
    wipe(pendingItemIds)
    wipe(pendingItemContexts)
    pendingItemLoads = 0
    -- Keep prior finds so a flaky EJ pass cannot erase mounts already discovered
    -- (Invincible previously vanished when rescans started from an empty map).
    scanByKey = ByKeyFromRows(cachedRows)
    scanWork = BuildWorkList()
    scanTotal = #scanWork
    scanIndex = 0
    scanProgressLabel = nil
    scanLootOffset = 0
    scanLootTotal = 0
    slicesSinceNotify = 0
    rescanAfterFinish = false
    scanState = STATE_SCANNING

    if scanTotal == 0 then
        FinishScan(gen, scanByKey)
        return cachedRows or {}
    end

    ScheduleNextSlice(gen)
    return cachedRows or {}
end

--- Synchronous full EJ scan (tests / explicit rebuild). Cancels any async scan.
function Mounts.BuildFromEJSync()
    CancelScan()
    if not EnsureCatalogRaidsReady() then
        return cachedRows or {}
    end
    if not Catalog.EnsureEJ() then
        return cachedRows or {}
    end

    catalogFingerprint = FingerprintTiers(Catalog.GetTiers(false))
    -- Preserve prior rows across sync rebuilds as well.
    local byKey = ByKeyFromRows(cachedRows)
    local work = BuildWorkList()
    local gen = scanGeneration
    for _, job in ipairs(work) do
        local offset = 0
        repeat
            local more = ScanLootChunk(
                byKey, job.tier, job.raid, job.diffId, offset, gen, job.encounterIndex)
            offset = scanLootOffset
            if not more then
                break
            end
        until false
    end
    FinishScan(gen, byKey)
    return cachedRows
end

--- Alias kept for call sites / older tests.
function Mounts.BuildFromEJ()
    return Mounts.BuildFromEJSync()
end

function Mounts.GetRows(forceRebuild)
    EnsurePersistedLoaded()
    if forceRebuild then
        Mounts.MarkDirty()
    end
    if not dirty and type(cachedRows) == "table" and scanState == STATE_READY then
        return cachedRows
    end
    Mounts.StartScanIfNeeded()
    -- While scanning / waiting: keep showing last complete rows (may be empty).
    return cachedRows or {}
end

--- Non-blocking: start scan if needed, return true only when cache is complete.
function Mounts.EnsureReady()
    EnsurePersistedLoaded()
    if not dirty and type(cachedRows) == "table" and scanState == STATE_READY then
        return true
    end
    if not EnsureCatalogRaidsReady() then
        return type(cachedRows) == "table" and #cachedRows > 0 and not dirty
    end
    Mounts.StartScanIfNeeded()
    return scanState == STATE_READY and type(cachedRows) == "table" and not dirty
end

--- Rows for UI, optionally filtered by collected status. Does not block.
function Mounts.GetRowsForUI(showCollected)
    EnsurePersistedLoaded()
    SanitizeCachedWorldBossRows()
    local rows = Mounts.GetRows(false)
    if showCollected then
        return rows
    end
    local filtered = {}
    for _, row in ipairs(rows) do
        if not Mounts.IsCollected(row.mountID) then
            filtered[#filtered + 1] = row
        end
    end
    return filtered
end

function Mounts.HasPendingItemLoads()
    return pendingItemLoads > 0
end

--- Called when Catalog.Build commits a changed tier tree.
--- Must not be triggered by mounts progress UI (that path must not Catalog.Build).
function Mounts.OnCatalogChanged()
    local fp = CurrentCatalogFingerprint()
    -- Ignore no-op / same-tree notifications so a rebuild cannot bounce an active scan.
    if fp and catalogFingerprint and fp == catalogFingerprint and not dirty then
        return
    end
    catalogFingerprint = nil
    -- True tree change: invalidate. If currently scanning, cancel+restart is intentional.
    Mounts.MarkDirty()
end

--- Test helpers
function Mounts._GetCachedRows()
    return cachedRows
end

function Mounts._SetLootPerSlice(n)
    LOOT_PER_SLICE = math.max(1, tonumber(n) or LOOT_PER_SLICE)
end

function Mounts._GetPendingItemIds()
    return pendingItemIds
end

function Mounts._GetScanIndex()
    return scanIndex, scanTotal, scanGeneration
end

function Mounts._IsRescanAfterFinish()
    return rescanAfterFinish == true
end

--- Test helper: reset persisted-load gate (headless).
function Mounts._ResetPersistedLoaded()
    persistedLoaded = false
end

--- Wipe disk + memory mounts cache (debug / manual invalidate).
function Mounts.ClearPersistedCache()
    CancelScan()
    cachedRows = nil
    dirty = true
    catalogFingerprint = nil
    persistedLoaded = true
    scanState = STATE_IDLE
    if DB and DB.ClearMountsCache then
        DB.ClearMountsCache()
    end
end
