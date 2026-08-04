#!/usr/bin/env lua
-- Headless unit tests for Alt Lockout Info core logic.
-- Run: lua tests/run.lua

local root = arg[0]:match("^(.*)[/\\]") or "."
if root == "." then
    -- when invoked as `lua tests/run.lua` from repo root
    root = "tests"
end
local repo = root:gsub("[/\\]tests$", ""):gsub("[/\\]tests[/\\]?$", "")
if repo == root then
    repo = ".."
end
-- Normalize: script lives in tests/, repo is parent
do
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
        local dir = src:match("^(.*)[/\\]") or "."
        root = dir
        repo = dir:match("^(.*)[/\\]tests$") or (dir .. "/..")
    end
end

package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local stub = dofile(root .. "/wow_stub.lua")
stub.reset()

local passed, failed = 0, 0
local failures = {}

local function assert_true(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg or "assert_true failed"
    end
end

local function assert_eq(a, b, msg)
    if a == b then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = string.format("%s (got %s, expected %s)",
            msg or "assert_eq", tostring(a), tostring(b))
    end
end

local function loadModule(rel)
    local path = repo .. "/" .. rel
    local chunk, err = loadfile(path)
    assert(chunk, err)
    return chunk
end

local function freshNs()
    stub.reset()
    local ns = { L = {} }
    loadModule("Locales/enUS.lua")("AltLockoutInfo", ns)
    loadModule("DB.lua")("AltLockoutInfo", ns)
    loadModule("Data.lua")("AltLockoutInfo", ns)
    loadModule("Catalog.lua")("AltLockoutInfo", ns)
    loadModule("MountsData.lua")("AltLockoutInfo", ns)
    loadModule("Mounts.lua")("AltLockoutInfo", ns)
    ns.DB.Init()
    return ns
end

----------------------------------------------------------------
-- Catalog.ParseEJInstance
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog

    -- Simulated EJ_GetInstanceByIndex returns (13 values)
    local journalId, name = 1234, "Manaforge Omega"
    local buttonImage2 = 111
    local dungeonAreaMapID = 222
    local link = "|Hjournal:0:1234|h"
    local shouldDisplayDifficulty = true
    local mapID = 2657 -- InstanceID matching GetSavedInstanceInfo

    local parsed = Catalog.ParseEJInstance(
        journalId, name, "desc", 1, 2, 3, buttonImage2,
        dungeonAreaMapID, link, shouldDisplayDifficulty, mapID
    )
    assert_eq(parsed.instanceId, 1234, "ParseEJ: journal id")
    assert_eq(parsed.name, "Manaforge Omega", "ParseEJ: name")
    assert_eq(parsed.mapId, 2657, "ParseEJ: mapId is InstanceID (11th return)")
    assert_eq(parsed.dungeonAreaMapID, 222, "ParseEJ: dungeonAreaMapID is 8th return")
    assert_eq(parsed.shouldDisplayDifficulty, true, "ParseEJ: shouldDisplayDifficulty")
    assert_eq(parsed.isWorldBoss, false, "ParseEJ: not world boss")

    -- Old buggy unpack would have treated shouldDisplayDifficulty as mapID
    assert_true(parsed.mapId ~= true, "ParseEJ: mapId must not be boolean")
    assert_true(parsed.mapId ~= buttonImage2, "ParseEJ: mapId must not be buttonImage2")

    local missing = Catalog.ParseEJInstance(nil)
    assert_eq(missing, nil, "ParseEJ: nil instance returns nil")

    local fallback = Catalog.ParseEJInstance(9, "Old Raid", nil, nil, nil, nil, nil, 50, nil, false, 0)
    assert_eq(fallback.mapId, 50, "ParseEJ: falls back to dungeonAreaMapID when mapID is 0")
    assert_eq(fallback.isWorldBoss, true, "ParseEJ: shouldDisplayDifficulty=false => world boss")

    local wb = Catalog.ParseEJInstance(
        99, "Sha of Anger", "d", 1, 2, 3, 4,
        0, "l", false, 0
    )
    assert_eq(wb.isWorldBoss, true, "ParseEJ: named world boss")
    assert_eq(wb.shouldDisplayDifficulty, false, "ParseEJ: world boss hides difficulties")

    -- Draenor outdoor group: EJ often reports shouldDisplayDifficulty=true + Normal,
    -- but journal id 557 must still be treated as world bosses.
    local draenor = Catalog.ParseEJInstance(
        557, "Draenor", "d", 1, 2, 3, 4,
        0, "l", true, 1116
    )
    assert_eq(draenor.isWorldBoss, true, "ParseEJ: journal 557 is world boss despite display flag")
    assert_eq(draenor.shouldDisplayDifficulty, false, "ParseEJ: 557 hides raid difficulties")
end

----------------------------------------------------------------
-- Draenor WB (557): fake Normal must not become mount difficulty
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Warlords of Draenor" end
    _G.EJ_SelectInstance = function() end
    -- EJ lies: Normal is "valid" for Draenor WB journal.
    _G.EJ_IsValidInstanceDifficulty = function(d) return d == 14 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 557, "Draenor", "d", 1, 2, 3, 4, 0, "l", true, 1116
        end
        return nil
    end
    local encounters = {
        [1] = { name = "Drov the Ruiner", id = 1291 },
        [2] = { name = "Rukhmar", id = 1262 },
    }
    _G.EJ_GetEncounterInfoByIndex = function(e)
        local enc = encounters[e]
        if not enc then return nil end
        return enc.name, "desc", enc.id, 0, "link", 557
    end
    _G.EJ_SelectEncounter = function() end
    _G.EJ_GetNumLoot = function() return 1 end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function()
            return { itemID = 116771, name = "Solar Spirehawk", icon = 1 }
        end,
    }
    _G.C_MountJournal = {
        GetMountFromItem = function(itemID)
            if itemID == 116771 then return 634 end
            return nil
        end,
        GetMountInfoByID = function(mountID)
            if mountID == 634 then
                return "Solar Spirehawk", 1, 2, false, true, 1, false, false, nil, false, false, 634
            end
            return nil
        end,
    }

    Catalog.Build()
    local raid = Catalog.GetRaidByInstanceId(557)
    assert_true(raid ~= nil and raid.isWorldBoss, "DraenorWB: classified as world boss")
    assert_true(#raid.difficulties >= 2, "DraenorWB: at least EJ encounters as difficulties")
    local haveDrov, haveRukhmarEj = false, false
    for _, d in ipairs(raid.difficulties) do
        if d == 1291 then haveDrov = true end
        if d == 1262 then haveRukhmarEj = true end
    end
    assert_eq(haveDrov, true, "DraenorWB: Drov encounter present")
    assert_eq(haveRukhmarEj, true, "DraenorWB: Rukhmar EJ encounter present")
    assert_eq(Catalog.GetDifficultyLabel(1262), "Rukhmar", "DraenorWB: label is Rukhmar")
    local haveSynthetic = false
    for _, d in ipairs(raid.difficulties) do
        if d == 900001 then haveSynthetic = true end
    end
    assert_eq(haveSynthetic, false, "DraenorWB: must not duplicate Rukhmar via synthetic 900001")

    local rows = Mounts.BuildFromEJSync()
    local mountRow
    for _, row in ipairs(rows) do
        if row.itemID == 116771 then
            mountRow = row
            break
        end
    end
    assert_true(mountRow ~= nil, "DraenorWB: Solar Spirehawk found")
    local hasNormal, hasRukhmar = false, false
    for _, d in ipairs(mountRow.difficulties or {}) do
        if d == 14 then hasNormal = true end
        if d == 1262 or d == 1291 then hasRukhmar = true end
    end
    assert_eq(hasNormal, false, "DraenorWB: mount must not use Normal (14)")
    assert_eq(hasRukhmar, true, "DraenorWB: mount bound to boss encounter")
    assert_eq(Catalog.GetDifficultyLabel(mountRow.difficulties[1]),
        Catalog.GetEncounterLabel(mountRow.difficulties[1]),
        "DraenorWB: UI label is boss name not Обычный")
end

----------------------------------------------------------------
-- Synthetic Rukhmar 900001 → EJ 1262: migrate tracked + lockouts
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local DB = ns.DB
    local Data = ns.Data

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Warlords of Draenor" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d) return d == 14 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 557, "Draenor", "d", 1, 2, 3, 4, 0, "l", true, 1116
        end
        return nil
    end
    local encounters = {
        [1] = { name = "Drov the Ruiner", id = 1291 },
        [2] = { name = "Rukhmar", id = 1262 },
    }
    _G.EJ_GetEncounterInfoByIndex = function(e)
        local enc = encounters[e]
        if not enc then return nil end
        return enc.name, "desc", enc.id, 0, "link", 557
    end
    _G.EJ_SelectEncounter = function() end
    _G.EJ_GetNumLoot = function() return 0 end

    -- Pre-migration SavedVariables: tracked + lockout under synthetic id.
    DB.SetTracked(557, 900001, true)
    local guid = "Player-1-RUKH"
    local guid2 = "Player-2-ALT"
    DB.EnsureCharacter(guid)
    DB.EnsureCharacter(guid2)
    local oldKey = DB.LockoutKey(557, 900001)
    local loPayload = {
        instanceId = 557,
        difficultyId = 900001,
        name = "Rukhmar",
        encounterProgress = 1,
        numEncounters = 1,
        bosses = { { name = "Rukhmar", killed = true } },
        resetAt = time() + 86400,
        recordedAt = time(),
        locked = true,
    }
    DB.SetLockouts(guid, { [oldKey] = loPayload })
    DB.SetLockouts(guid2, {
        [oldKey] = {
            instanceId = 557,
            difficultyId = 900001,
            name = "Rukhmar",
            encounterProgress = 1,
            numEncounters = 1,
            bosses = { { name = "Rukhmar", killed = true } },
            resetAt = time() + 86400,
            recordedAt = time(),
            locked = true,
        },
    })
    assert_eq(DB.IsTracked(557, 900001), true, "RukhmarMigrate: pre-build tracked under synthetic")
    assert_eq(select(1, Data.GetLockoutStatus(guid, 557, 900001)), "complete",
        "RukhmarMigrate: pre-build lockout under synthetic")

    Catalog.Build()

    assert_eq(DB.IsTracked(557, 1262), true, "RukhmarMigrate: tracked moved to EJ id")
    assert_eq(DB.IsTracked(557, 900001), false, "RukhmarMigrate: synthetic track cleared")
    local newKey = DB.LockoutKey(557, 1262)
    assert_true(DB.GetCharacter(guid).lockouts[newKey] ~= nil, "RukhmarMigrate: lockout re-keyed")
    assert_eq(DB.GetCharacter(guid).lockouts[oldKey], nil, "RukhmarMigrate: old key removed")
    assert_eq(DB.GetLockout(guid, 557, 1262).difficultyId, 1262, "RukhmarMigrate: difficultyId updated")
    assert_eq(select(1, Data.GetLockoutStatus(guid, 557, 1262)), "complete",
        "RukhmarMigrate: UI status via EJ id (not free)")
    assert_eq(select(1, Data.GetLockoutStatus(guid2, 557, 1262)), "complete",
        "RukhmarMigrate: alt lockout also remapped")
    -- BossNameCandidates must not hole-skip EN fallback when locale missing.
    local saved = ns.L["WB_BOSS_RUKHMAR"]
    ns.L["WB_BOSS_RUKHMAR"] = nil
    local names = Catalog.BossNameCandidates({
        bossLocaleKey = "WB_BOSS_RUKHMAR",
        bossName = "Rukhmar",
    })
    assert_eq(names[1], "Rukhmar", "RukhmarMigrate: EN bossName survives missing locale")
    ns.L["WB_BOSS_RUKHMAR"] = saved
end

----------------------------------------------------------------
-- World-boss options: default collapsed
----------------------------------------------------------------
do
    local ns = freshNs()
    local DB = ns.DB
    assert_eq(DB.IsWorldBossOptionsCollapsed(557), true, "WBCollapse: default collapsed")
    DB.SetWorldBossOptionsCollapsed(557, false)
    assert_eq(DB.IsWorldBossOptionsCollapsed(557), false, "WBCollapse: user expanded persists")
    DB.SetWorldBossOptionsCollapsed(557, true)
    assert_eq(DB.IsWorldBossOptionsCollapsed(557), true, "WBCollapse: user collapsed")
end

----------------------------------------------------------------
-- WB mount only in instance-wide loot → attribute to boss via per-encounter probe
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Warlords of Draenor" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d) return d == 14 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 557, "Draenor", "d", 1, 2, 3, 4, 0, "l", true, 1116
        end
        return nil
    end
    local encounters = {
        [1] = { name = "Drov the Ruiner", id = 1291 },
        [2] = { name = "Rukhmar", id = 1262 },
    }
    local selectedEnc
    _G.EJ_GetEncounterInfoByIndex = function(e)
        local enc = encounters[e]
        if not enc then return nil end
        return enc.name, "desc", enc.id, 0, "link", 557
    end
    _G.EJ_SelectEncounter = function(id) selectedEnc = id end
    -- Instance-wide (nil) and Rukhmar encounter both list the mount; Drov does not.
    _G.EJ_GetNumLoot = function()
        if selectedEnc == nil or selectedEnc == 1262 then
            return 1
        end
        return 0
    end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function()
            if selectedEnc == nil or selectedEnc == 1262 then
                return { itemID = 116771, name = "Solar Spirehawk", icon = 1 }
            end
            return nil
        end,
    }
    _G.C_MountJournal = {
        GetMountFromItem = function(itemID)
            if itemID == 116771 then return 634 end
            return nil
        end,
        GetMountInfoByID = function(mountID)
            if mountID == 634 then
                return "Solar Spirehawk", 1, 2, false, true, 1, false, false, nil, false, false, 634
            end
            return nil
        end,
    }

    Catalog.Build()
    -- Only instance-wide jobs would find loot if we skipped encounters; attribute must bind Rukhmar.
    selectedEnc = nil
    local rows = Mounts.BuildFromEJSync()
    local mountRow
    for _, row in ipairs(rows) do
        if row.itemID == 116771 then
            mountRow = row
            break
        end
    end
    assert_true(mountRow ~= nil, "WBAttr: mount present")
    assert_eq(mountRow.difficulties[1], 1262, "WBAttr: attributed to Rukhmar encounter")
    assert_eq(Catalog.GetDifficultyLabel(1262), "Rukhmar", "WBAttr: label Rukhmar")
end

----------------------------------------------------------------
-- Static костыль: Solar Spirehawk always trackable as Rukhmar
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts
    local DB = ns.DB
    local L = ns.L

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Warlords of Draenor" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function() return false end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 557, "Draenor", "d", 1, 2, 3, 4, 0, "l", true, 1116
        end
        return nil
    end
    -- EJ encounters/loot completely broken for this journal — supplement must carry the mount.
    _G.EJ_GetEncounterInfoByIndex = function() return nil end
    _G.EJ_GetNumLoot = function() return 0 end

    Catalog.Build()
    local byKey = {}
    Mounts.MergeSupplement(byKey)
    local row = byKey["116771|557"]
    assert_true(row ~= nil, "RukhmarHack: supplement row present")
    assert_eq(row.difficulties[1], 900001, "RukhmarHack: synthetic encounter id")
    assert_eq(Catalog.GetDifficultyLabel(900001), L["WB_BOSS_RUKHMAR"], "RukhmarHack: label from locale")

    local tracking = Mounts.GetTrackingDiffs({
        itemID = 116771,
        instanceId = 557,
        difficulties = {},
    })
    assert_eq(tracking[1], 900001, "RukhmarHack: GetTrackingDiffs falls back to static")
    assert_eq(Mounts.IsFullyTracked(557, tracking), false, "RukhmarHack: master off")
    Mounts.SetFullyTracked(557, tracking, true)
    assert_eq(DB.IsTracked(557, 900001), true, "RukhmarHack: can track Rukhmar")

    local jid, enc = Catalog.ResolveWorldBossLockout("Rukhmar", nil)
    assert_eq(jid, 557, "RukhmarHack: lockout resolves journal")
    assert_eq(enc, 900001, "RukhmarHack: lockout resolves synthetic id")
end

----------------------------------------------------------------
-- MergeSupplement must not change catalog fingerprint (no second scan)
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Warlords of Draenor" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function() return false end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 557, "Draenor", "d", 1, 2, 3, 4, 0, "l", true, 1116
        end
        return nil
    end
    _G.EJ_GetEncounterInfoByIndex = function() return nil end
    _G.EJ_GetNumLoot = function() return 0 end

    Catalog.Build()
    local fp1 = Catalog.TiersFingerprint(Catalog.GetTiers(false))
    Mounts.MergeSupplement({})
    local fp2 = Catalog.TiersFingerprint(Catalog.GetTiers(false))
    assert_eq(fp1, fp2, "NoSecondScan: MergeSupplement does not mutate catalog fingerprint")

    Mounts.MarkDirty()
    Mounts.StartScanIfNeeded()
    assert_eq(Mounts.IsScanning(), true, "NoSecondScan: first scan started")
    local _, _, gen1 = Mounts._GetScanIndex()
    stub.flushTimers()
    assert_eq(Mounts.IsReady(), true, "NoSecondScan: first scan done")
    Mounts.StartScanIfNeeded()
    assert_eq(Mounts.IsScanning(), false, "NoSecondScan: refresh must not start second scan")
    local _, _, gen2 = Mounts._GetScanIndex()
    assert_eq(gen2, gen1, "NoSecondScan: generation unchanged after finish+refresh")
end

----------------------------------------------------------------
-- Catalog.ResolveJournalId via mapId
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog

    -- Inject a fake catalog cache through Build with mocked EJ
    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    local calls = 0
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if not isRaid or index ~= 1 then return nil end
        calls = calls + 1
        return 100, "Test Raid", "d", 1, 2, 3, 4, 999, "link", true, 5001
    end
    local tiers = Catalog.GetTiers(true)
    assert_eq(#tiers, 1, "Resolve: one tier")
    assert_eq(#tiers[1].raids, 1, "Resolve: one raid")
    assert_eq(tiers[1].raids[1].mapId, 5001, "Resolve: raid.mapId from InstanceID")

    assert_eq(Catalog.ResolveJournalId(5001, "Other Name"), 100, "Resolve: by InstanceID/mapId")
    assert_eq(Catalog.ResolveJournalId(9999, "Test Raid"), 100, "Resolve: by name fallback")
    assert_eq(Catalog.ResolveJournalId(9999, "Missing"), 9999, "Resolve: passthrough when unknown")
end

----------------------------------------------------------------
-- Catalog.ApplyCurrentTierDefaults empty / success
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 0 end
    _G.EJ_GetCurrentTier = function() return 0 end
    _G.EJ_GetInstanceByIndex = function() return nil end

    local ok = Catalog.ApplyCurrentTierDefaults(false)
    assert_eq(ok, false, "Defaults: empty catalog returns false")
    assert_eq(DB.IsDefaultsApplied(), false, "Defaults: not stamped when empty")

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 42, "Current Raid", "d", 1, 2, 3, 4, 0, "l", true, 777
        end
        return nil
    end
    ok = Catalog.ApplyCurrentTierDefaults(false)
    assert_eq(ok, true, "Defaults: succeeds with raids")
    assert_eq(DB.IsDefaultsApplied(), true, "Defaults: stamped after success")
    assert_eq(DB.IsTracked(42, 14), true, "Defaults: current tier Normal tracked")
    assert_eq(DB.IsTracked(42, 16), true, "Defaults: current tier Mythic tracked")

    -- Second call without force is no-op
    DB.SetTracked(42, 14, false)
    ok = Catalog.ApplyCurrentTierDefaults(false)
    assert_eq(ok, false, "Defaults: skipped when already applied")
    assert_eq(DB.IsTracked(42, 14), false, "Defaults: left user change intact")
end

----------------------------------------------------------------
-- Data.IsLockoutExpired / ComputeResetAt
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local now = 1000000

    assert_eq(Data.IsLockoutExpired(nil, now), true, "Expired: nil lockout")

    local active = { resetAt = now + 3600, recordedAt = now - 100 }
    assert_eq(Data.IsLockoutExpired(active, now), false, "Expired: future resetAt")

    local past = { resetAt = now - 1, recordedAt = now - 10000 }
    assert_eq(Data.IsLockoutExpired(past, now), true, "Expired: past resetAt")

    -- resetAt == 0 without weekly guess must NOT expire via heuristic
    local legacy = { resetAt = 0, recordedAt = now - (8 * 24 * 3600), weeklyGuess = false }
    assert_eq(Data.IsLockoutExpired(legacy, now), false, "Expired: non-weekly without resetAt stays")

    _G.C_DateAndTime = {
        GetSecondsUntilWeeklyReset = function() return 2 * 24 * 3600 end,
    }
    local weeklyBroken = {
        resetAt = 0,
        recordedAt = now - (8 * 24 * 3600),
        weeklyGuess = true,
    }
    assert_eq(Data.IsLockoutExpired(weeklyBroken, now), true, "Expired: weeklyGuess uses boundary")

    local resetAt, weekly = Data.ComputeResetAt(now, 7 * 24 * 3600)
    assert_eq(resetAt, now + 7 * 24 * 3600, "ComputeResetAt: uses reset seconds")
    assert_eq(weekly, true, "ComputeResetAt: marks weekly-sized window")

    local resetAt2, weekly2 = Data.ComputeResetAt(now, 0)
    assert_eq(resetAt2, now + 2 * 24 * 3600, "ComputeResetAt: falls back to weekly API")
    assert_eq(weekly2, true, "ComputeResetAt: weekly fallback flagged")

    local resetAt3, weekly3 = Data.ComputeResetAt(now, 3600)
    assert_eq(weekly3, false, "ComputeResetAt: short reset not weekly")
    assert_eq(resetAt3, now + 3600, "ComputeResetAt: short reset preserved")
end

----------------------------------------------------------------
-- Data.GetLockoutStatus + scan locked filter
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local DB = ns.DB
    local guid = "Player-1-AAAA"

    DB.EnsureCharacter(guid)
    local status = Data.GetLockoutStatus(guid, 1, 16)
    assert_eq(status, "unknown", "Status: unscanned character is unknown")

    DB.SetLockouts(guid, {})
    status = Data.GetLockoutStatus(guid, 1, 16)
    assert_eq(status, "free", "Status: scanned empty is free")

    local key = DB.LockoutKey(1, 16)
    DB.SetLockouts(guid, {
        [key] = {
            instanceId = 1,
            difficultyId = 16,
            encounterProgress = 8,
            numEncounters = 8,
            bosses = {
                { name = "A", killed = true }, { name = "B", killed = true },
                { name = "C", killed = true }, { name = "D", killed = true },
                { name = "E", killed = true }, { name = "F", killed = true },
                { name = "G", killed = true }, { name = "H", killed = true },
            },
            resetAt = time() + 86400,
            recordedAt = time(),
            locked = true,
        },
    })
    status = select(1, Data.GetLockoutStatus(guid, 1, 16))
    assert_eq(status, "complete", "Status: full clear is complete")

    DB.SetLockouts(guid, {
        [key] = {
            instanceId = 1,
            difficultyId = 16,
            encounterProgress = 3,
            numEncounters = 8,
            bosses = {
                { name = "A", killed = true }, { name = "B", killed = true },
                { name = "C", killed = true }, { name = "D", killed = false },
                { name = "E", killed = false }, { name = "F", killed = false },
                { name = "G", killed = false }, { name = "H", killed = false },
            },
            resetAt = time() + 86400,
            recordedAt = time(),
            locked = true,
        },
    })
    local st, prog, tot = Data.GetLockoutStatus(guid, 1, 16)
    assert_eq(st, "progress", "Status: partial is progress")
    assert_eq(prog, 3, "Status: kill count from bosses")
    assert_eq(tot, 8, "Status: total encounters")

    -- blizzardEncounterProgress farthest-index must NOT drive status when bosses exist
    DB.SetLockouts(guid, {
        [key] = {
            instanceId = 1,
            difficultyId = 16,
            encounterProgress = 1,
            blizzardEncounterProgress = 8,
            numEncounters = 8,
            bosses = {
                { name = "A", killed = true }, { name = "B", killed = false },
                { name = "C", killed = false }, { name = "D", killed = false },
                { name = "E", killed = false }, { name = "F", killed = false },
                { name = "G", killed = false }, { name = "H", killed = false },
            },
            resetAt = time() + 86400,
            recordedAt = time(),
            locked = true,
        },
    })
    st, prog = Data.GetLockoutStatus(guid, 1, 16)
    assert_eq(st, "progress", "Status: uses kills not blizzard farthest")
    assert_eq(prog, 1, "Status: 1 kill from bosses table")

    -- Historic unlocked row must not count as active lockout
    DB.SetLockouts(guid, {
        [key] = {
            instanceId = 1,
            difficultyId = 16,
            encounterProgress = 8,
            numEncounters = 8,
            resetAt = time() + 86400,
            recordedAt = time(),
            locked = false,
            extended = false,
        },
    })
    status = select(1, Data.GetLockoutStatus(guid, 1, 16))
    assert_eq(status, "free", "Status: locked=false historic is free")

    DB.SetCharacterRaidDisabled(guid, 1, true)
    status = select(1, Data.GetLockoutStatus(guid, 1, 16))
    assert_eq(status, "disabled", "Status: per-character hide")
end

----------------------------------------------------------------
-- ScanRaidLockouts skips unlocked + resolves journal id
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local Catalog = ns.Catalog
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 100, "Raid A", "d", 1, 2, 3, 4, 0, "l", true, 9001
        end
        return nil
    end
    Catalog.GetTiers(true)

    _G.UnitGUID = function() return "Player-1-SCAN" end
    _G.GetNumSavedInstances = function() return 2 end
    _G.GetSavedInstanceInfo = function(i)
        if i == 1 then
            -- active lockout
            return "Raid A", 1, 1000, 16, true, false, 0, true,
                20, "Mythic", 8, 2, false, 9001
        elseif i == 2 then
            -- historic unlocked — must be ignored
            return "Raid A", 2, 1000, 15, false, false, 0, true,
                20, "Heroic", 8, 8, false, 9001
        end
    end
    _G.GetSavedInstanceEncounterInfo = function(_, e)
        return "Boss " .. e, nil, e <= 2
    end

    local lockouts = Data.ScanRaidLockouts()
    local mythicKey = DB.LockoutKey(100, 16)
    local heroicKey = DB.LockoutKey(100, 15)
    assert_true(lockouts[mythicKey] ~= nil, "Scan: stores locked mythic under journal id")
    assert_eq(lockouts[mythicKey].instanceId, 100, "Scan: journal id resolved from mapId")
    assert_eq(lockouts[heroicKey], nil, "Scan: skips locked=false historic")
    assert_eq(DB.HasLockoutsScan("Player-1-SCAN"), true, "Scan: marks lockoutsScanned")
    assert_eq(lockouts[mythicKey].encounterProgress, 2, "Scan: killedCount from isKilled flags")
    assert_eq(lockouts[mythicKey].bosses[1].killed, true, "Scan: boss1 killed")
    assert_eq(lockouts[mythicKey].bosses[3].killed, false, "Scan: boss3 alive")
end

----------------------------------------------------------------
-- isKilled 1/0 must not treat 0 as killed (Lua truthiness footgun)
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    assert_eq(Data.IsEncounterKilledFlag(true), true, "KillFlag: boolean true")
    assert_eq(Data.IsEncounterKilledFlag(false), false, "KillFlag: boolean false")
    assert_eq(Data.IsEncounterKilledFlag(1), true, "KillFlag: classic 1")
    assert_eq(Data.IsEncounterKilledFlag(0), false, "KillFlag: classic 0 is not killed")
    assert_eq(Data.IsEncounterKilledFlag(nil), false, "KillFlag: nil")
    assert_eq(Data.IsEncounterKilledFlag("x"), false, "KillFlag: random truthy ignored")

    local lo = {
        numEncounters = 3,
        bosses = {
            { name = "A", killed = 1 },
            { name = "B", killed = 0 },
            { name = "C", killed = false },
        },
    }
    local kills, total = Data.CountKilledBosses(lo)
    assert_eq(kills, 1, "CountKilled: 1/0 flags count only 1")
    assert_eq(total, 3, "CountKilled: total 3")

    assert_eq(Data.IsTruthyFlag(true), true, "TruthyFlag: boolean true")
    assert_eq(Data.IsTruthyFlag(1), true, "TruthyFlag: classic 1")
    assert_eq(Data.IsTruthyFlag(0), false, "TruthyFlag: classic 0 is false")
    assert_eq(Data.IsTruthyFlag(false), false, "TruthyFlag: boolean false")
    assert_eq(Data.IsTruthyFlag(nil), false, "TruthyFlag: nil")
end

----------------------------------------------------------------
-- locked/extended classic 1/0 must not treat 0 as locked
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    _G.UnitGUID = function() return "Player-1-LOCK0" end
    _G.GetNumSavedInstances = function() return 1 end
    -- Classic-style unlocked row: locked=0, extended=0, but reset still counting down.
    _G.GetSavedInstanceInfo = function()
        return "Raid A", 1, 3600, 16, 0, 0, 0, true,
            20, "Mythic", 2, 0, false, 9001
    end
    _G.GetSavedInstanceEncounterInfo = function(_, e)
        return "Boss " .. e, nil, 0, false
    end
    local lockouts = Data.ScanRaidLockouts()
    assert_eq(next(lockouts), nil, "Scan: locked=0/extended=0 not stored as active")

    -- locked=1 must store and normalize to boolean true
    _G.GetSavedInstanceInfo = function()
        return "Raid A", 1, 3600, 16, 1, 0, 0, true,
            20, "Mythic", 2, 1, false, 9001
    end
    _G.GetSavedInstanceEncounterInfo = function(_, e)
        return "Boss " .. e, nil, (e == 1) and 1 or 0, false
    end
    lockouts = Data.ScanRaidLockouts()
    local key = next(lockouts)
    assert_true(key ~= nil, "Scan: locked=1 stores lockout")
    assert_eq(lockouts[key].locked, true, "Scan: locked=1 normalized to true")
    assert_eq(lockouts[key].extended, false, "Scan: extended=0 normalized to false")

    -- Legacy SV with locked=0 must not count as effective lockout
    ns.DB.EnsureCharacter("Player-1-LEGACY").lockouts["9001:16"] = {
        locked = 0,
        extended = 0,
        resetAt = (time and time() or 0) + 3600,
        bosses = {},
        numEncounters = 0,
    }
    assert_eq(Data.GetEffectiveLockout("Player-1-LEGACY", 9001, 16), nil,
        "Effective: legacy locked=0 is inactive")
end

----------------------------------------------------------------
-- Real dump scenario: ICC locked + expired reset=0 rows not stored;
-- partial clear via 1/0 isKilled preserved
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local Catalog = ns.Catalog
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if not isRaid then return nil end
        if index == 1 then return 758, "Icecrown Citadel", "d", 1, 2, 3, 4, 0, "l", true, 631 end
        if index == 2 then return 755, "The Obsidian Sanctum", "d", 1, 2, 3, 4, 0, "l", true, 615 end
        if index == 3 then return 761, "The Ruby Sanctum", "d", 1, 2, 3, 4, 0, "l", true, 724 end
        if index == 4 then return 187, "Dragon Soul", "d", 1, 2, 3, 4, 0, "l", true, 967 end
        return nil
    end
    Catalog.GetTiers(true)

    _G.UnitGUID = function() return "Player-1602-DUMP" end
    _G.GetNumSavedInstances = function() return 4 end
    _G.GetSavedInstanceInfo = function(i)
        if i == 1 then
            -- ICC 25H active, farthest=12 but only first 3 bosses actually killed (1/0 API)
            return "Icecrown Citadel", 607019706, 152604, 6, true, false, 0, true,
                25, "25 Player (Heroic)", 12, 12, false, 631
        elseif i == 2 then
            return "The Obsidian Sanctum", 606159631, 0, 4, false, false, 0, true,
                25, "25 Player", 4, 4, false, 615
        elseif i == 3 then
            return "The Ruby Sanctum", 606159541, 0, 6, false, false, 0, true,
                25, "25 Player (Heroic)", 4, 4, false, 724
        elseif i == 4 then
            return "Dragon Soul", 606680647, 0, 6, false, false, 0, true,
                25, "25 Player (Heroic)", 8, 8, false, 967
        end
    end
    -- Simulate classic-style 1/0 booleans: only bosses 1-3 killed on ICC
    _G.GetSavedInstanceEncounterInfo = function(inst, e)
        local killed = (inst == 1 and e <= 3) and 1 or 0
        return "Boss " .. e, 12345, killed, 0
    end

    local lockouts = Data.ScanRaidLockouts()
    local iccKey = DB.LockoutKey(758, 6)
    assert_true(lockouts[iccKey] ~= nil, "DumpScan: stores active ICC")
    assert_eq(lockouts[DB.LockoutKey(755, 4)], nil, "DumpScan: skips OS reset=0 unlocked")
    assert_eq(lockouts[DB.LockoutKey(761, 6)], nil, "DumpScan: skips RS reset=0 unlocked")
    assert_eq(lockouts[DB.LockoutKey(187, 6)], nil, "DumpScan: skips DS reset=0 unlocked")
    assert_eq(lockouts[iccKey].encounterProgress, 3, "DumpScan: ICC killedCount is 3 not 12")
    assert_eq(lockouts[iccKey].blizzardEncounterProgress, 12, "DumpScan: keeps blizzard farthest index")
    assert_eq(select(1, Data.GetLockoutStatus("Player-1602-DUMP", 758, 6)), "progress",
        "DumpScan: partial clear is progress not complete")
    assert_eq(select(1, Data.GetLockoutStatus("Player-1602-DUMP", 755, 4)), "free",
        "DumpScan: expired OS is free")

    local lines = Data.DumpDebugLockouts(true)
    local blob = table.concat(lines, "\n")
    assert_true(blob:find("historic/expired", 1, true) ~= nil, "DumpDebug: marks historic rows")
    assert_true(blob:find("killed=false", 1, true) ~= nil, "DumpDebug: shows alive bosses")
    assert_true(blob:find("rawIsKilled=0", 1, true) ~= nil, "DumpDebug: exposes raw 0 flag")
end

----------------------------------------------------------------
-- locked=true but reset=0 must not be stored as active
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local DB = ns.DB
    _G.UnitGUID = function() return "Player-1-RESET0" end
    _G.GetNumSavedInstances = function() return 1 end
    _G.GetSavedInstanceInfo = function()
        return "Raid A", 1, 0, 16, true, false, 0, true,
            20, "Mythic", 2, 2, false, 9001
    end
    _G.GetSavedInstanceEncounterInfo = function(_, e)
        return "Boss " .. e, nil, true, false
    end
    local lockouts = Data.ScanRaidLockouts()
    assert_eq(next(lockouts), nil, "Scan: locked+reset=0 yields empty lockouts")
    assert_eq(select(1, Data.GetLockoutStatus("Player-1-RESET0", 9001, 16)), "free",
        "Scan: reset=0 lockout does not show complete")
end

----------------------------------------------------------------
-- DB schema migration marks old characters scanned
----------------------------------------------------------------
do
    stub.reset()
    _G.ALInfoDB = {
        schema = 1,
        settings = { tracked = {}, defaultsApplied = true },
        characters = {
            ["Player-1-OLD"] = {
                name = "Oldmain",
                realm = "TestRealm",
                lockouts = {},
            },
        },
        minimap = { angle = 220 },
    }
    local ns = { L = {} }
    loadModule("Locales/enUS.lua")("AltLockoutInfo", ns)
    loadModule("DB.lua")("AltLockoutInfo", ns)
    ns.DB.Init()
    assert_eq(ALInfoDB.schema, 2, "DB: schema bumped to 2")
    assert_eq(ns.DB.HasLockoutsScan("Player-1-OLD"), true, "DB: v1 chars migrated as scanned")

    local fresh = ns.DB.EnsureCharacter("Player-1-NEW")
    assert_eq(fresh.lockoutsScanned, false, "DB: new chars start unscanned")
end

----------------------------------------------------------------
-- PurgeExpiredLockouts
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local DB = ns.DB
    local guid = "Player-1-PURGE"
    local key = DB.LockoutKey(5, 14)
    DB.SetLockouts(guid, {
        [key] = {
            resetAt = time() - 10,
            recordedAt = time() - 1000,
            locked = true,
        },
    })
    Data.PurgeExpiredLockouts()
    assert_eq(DB.GetLockout(guid, 5, 14), nil, "Purge: removes expired lockout")
end

----------------------------------------------------------------
-- Empty EJ failure must not stick in cache
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local buildAttempts = 0

    _G.C_AddOns = {
        IsAddOnLoaded = function()
            return false
        end,
        LoadAddOn = function()
            return false
        end,
    }
    -- Force EnsureEJ to fail (reset ejLoaded by reloading module already done via freshNs)
    local empty = Catalog.GetTiers()
    assert_eq(Catalog.IsReady(), false, "Cache: not ready after EJ failure")
    assert_eq(#empty, 0, "Cache: empty tiers on failure")

    -- Later EJ becomes available — GetTiers without force must retry Build
    _G.C_AddOns = {
        IsAddOnLoaded = function(name)
            return name == "Blizzard_EncounterJournal"
        end,
        LoadAddOn = function() return true end,
    }
    _G.EJ_GetNumTiers = function()
        buildAttempts = buildAttempts + 1
        return 1
    end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 55, "Late Raid", "d", 1, 2, 3, 4, 0, "l", true, 8001
        end
        return nil
    end

    local tiers = Catalog.GetTiers() -- no forceRebuild
    assert_eq(Catalog.IsReady(), true, "Cache: becomes ready after EJ available")
    assert_eq(#tiers[1].raids, 1, "Cache: raids populated on retry")
    assert_eq(tiers[1].raids[1].instanceId, 55, "Cache: journal id present")
    assert_true(buildAttempts > 0, "Cache: Build retried")
end

----------------------------------------------------------------
-- Remap map InstanceID → journal + GetLockout fallback
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Data = ns.Data
    local DB = ns.DB
    local guid = "Player-1-REMAP"

    -- Store lockout under map ID (as if scanned before EJ ready)
    local mapKey = DB.LockoutKey(9001, 16)
    DB.SetLockouts(guid, {
        [mapKey] = {
            instanceId = 9001,
            savedInstanceId = 9001,
            difficultyId = 16,
            name = "Raid A",
            encounterProgress = 2,
            numEncounters = 8,
            resetAt = time() + 86400,
            recordedAt = time(),
            locked = true,
        },
    })

    -- Lookup by journal id should still find via savedInstanceId fallback once we
    -- only have map id stored — before remap, journal 100 won't match instanceId
    -- but GetLockout checks savedInstanceId only against the queried id.
    -- After catalog + remap, journal key works.
    assert_eq(select(1, Data.GetLockoutStatus(guid, 100, 16)), "free",
        "Remap: before catalog journal lookup misses (expected free/fallback miss)")

    -- Direct map-id lookup works
    assert_eq(select(1, Data.GetLockoutStatus(guid, 9001, 16)), "progress",
        "Remap: map-id lookup finds lockout before remap")

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 100, "Raid A", "d", 1, 2, 3, 4, 0, "l", true, 9001
        end
        return nil
    end
    -- Hide stored under map id before catalog was ready
    DB.SetCharacterRaidDisabled(guid, 9001, true)
    assert_eq(DB.IsCharacterRaidDisabled(guid, 9001), true, "Remap: hide under map id before")
    assert_eq(DB.IsCharacterRaidDisabled(guid, 100), false, "Remap: journal hide miss before")

    assert_eq(Catalog.EnsureReady(), true, "Remap: catalog ready")
    local n = Data.RemapLockoutsToJournalIds()
    assert_true(n >= 1, "Remap: remapped at least one entry")

    local journalKey = DB.LockoutKey(100, 16)
    assert_true(DB.GetCharacter(guid).lockouts[journalKey] ~= nil, "Remap: keyed by journal id")
    assert_eq(select(1, Data.GetLockoutStatus(guid, 100, 16)), "disabled",
        "Remap: journal hide works after remap")
    assert_eq(DB.IsCharacterRaidDisabled(guid, 100), true, "Remap: disabledRaids remapped to journal")
    assert_eq(DB.IsCharacterRaidDisabled(guid, 9001), false, "Remap: old map hide key cleared")

    -- Clear hide to assert lockout remap still works via journal key
    DB.SetCharacterRaidDisabled(guid, 100, false)
    assert_eq(select(1, Data.GetLockoutStatus(guid, 100, 16)), "progress",
        "Remap: journal lockout lookup works after remap")

    -- Fallback: still find if queried by saved map id
    local lo = DB.GetLockout(guid, 9001, 16)
    assert_true(lo ~= nil, "Remap: GetLockout fallback by savedInstanceId")
    assert_eq(lo.instanceId, 100, "Remap: fallback entry has journal instanceId")
end

----------------------------------------------------------------
-- Scan returns unresolved when catalog not ready
----------------------------------------------------------------
do
    local ns = freshNs()
    local Data = ns.Data
    local Catalog = ns.Catalog

    _G.C_AddOns = {
        IsAddOnLoaded = function() return false end,
        LoadAddOn = function() return false end,
    }
    _G.UnitGUID = function() return "Player-1-UNRES" end
    _G.GetNumSavedInstances = function() return 1 end
    _G.GetSavedInstanceInfo = function()
        return "Raid A", 1, 1000, 16, true, false, 0, true,
            20, "Mythic", 8, 2, false, 9001
    end
    _G.GetSavedInstanceEncounterInfo = function() return "Boss", nil, true end

    local lockouts, unresolved = Data.ScanRaidLockouts()
    assert_eq(unresolved, true, "Scan: unresolved when catalog down")
    assert_true(lockouts[ns.DB.LockoutKey(9001, 16)] ~= nil, "Scan: stored under map id")
    assert_eq(Catalog.IsReady(), false, "Scan: catalog still not ready")
end

----------------------------------------------------------------
-- GetValidDifficulties filters per-instance
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local selected
    _G.EJ_SelectInstance = function(id) selected = id end
    _G.EJ_IsValidInstanceDifficulty = function(diffId)
        if selected == 86 then -- ICC-like
            return diffId == 3 or diffId == 4 or diffId == 5 or diffId == 6
        end
        return diffId == 14 or diffId == 15 or diffId == 16 or diffId == 17
    end
    local icc = Catalog.GetValidDifficulties(86)
    assert_eq(#icc, 4, "ValidDiff: ICC has 4 diffs")
    assert_eq(icc[1], 3, "ValidDiff: ICC starts with 10N")
    local modern = Catalog.GetValidDifficulties(100)
    assert_eq(#modern, 4, "ValidDiff: modern has 4 diffs")
    local hasMythic = false
    for _, d in ipairs(modern) do if d == 16 then hasMythic = true end end
    assert_true(hasMythic, "ValidDiff: modern includes mythic")
    local hasMythicIcc = false
    for _, d in ipairs(icc) do if d == 16 then hasMythicIcc = true end end
    assert_eq(hasMythicIcc, false, "ValidDiff: ICC has no mythic")

    -- Legacy LFR (difficulty 7) for pre-SoO raids like Dragon Soul
    _G.EJ_IsValidInstanceDifficulty = function(diffId)
        if selected == 187 then
            return diffId == 7 or diffId == 3 or diffId == 4 or diffId == 5 or diffId == 6
        end
        return diffId == 14 or diffId == 15 or diffId == 16 or diffId == 17
    end
    local ds = Catalog.GetValidDifficulties(187)
    local hasLegacyLfr = false
    for _, d in ipairs(ds) do if d == 7 then hasLegacyLfr = true end end
    assert_eq(hasLegacyLfr, true, "ValidDiff: Dragon Soul includes legacy LFR (7)")
    assert_eq(Catalog.GetDifficultyLabel(7), ns.L["DIFF_LFR"], "ValidDiff: diff 7 labeled as LFR/СПР")
end

----------------------------------------------------------------
-- Multiple tracked difficulties all remain visible
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local DB = ns.DB
    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(diffId)
        return diffId == 14 or diffId == 15 or diffId == 16 or diffId == 17
    end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 42, "Test Raid", "d", 1, 2, 3, 4, 0, "l", true, 777
        end
        return nil
    end
    Catalog.GetTiers(true)
    DB.SetTracked(42, 14, true)
    DB.SetTracked(42, 15, true)
    DB.SetTracked(42, 16, true)
    local cols = Catalog.GetTrackedColumns()
    assert_eq(#cols, 1, "MultiDiff: one raid column")
    assert_eq(#cols[1].difficulties, 3, "MultiDiff: all three difficulties tracked")
end

----------------------------------------------------------------
-- Season shortcut detection + toggle current content
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local DB = ns.DB
    assert_eq(Catalog.IsSeasonShortcutTierName("Актуальное дополнение"), true, "Season: ru name")
    assert_eq(Catalog.IsSeasonShortcutTierName("Current Season"), true, "Season: en name")
    assert_eq(Catalog.IsSeasonShortcutTierName("The War Within"), false, "Season: expansion name")

    _G.EJ_GetNumTiers = function() return 2 end
    _G.EJ_GetCurrentTier = function() return 2 end
    _G.EJ_GetTierInfo = function(i)
        if i == 1 then return "The War Within" end
        if i == 2 then return "Current Season" end
        return "Tier " .. i
    end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 14 or d == 15 or d == 16
    end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if not isRaid or index ~= 1 then return nil end
        -- both tiers expose same raid id for simplicity
        return 99, "Raid Now", "d", 1, 2, 3, 4, 0, "l", true, 1234
    end
    Catalog.GetTiers(true)
    local uiTiers = Catalog.GetTiersForUI()
    assert_eq(#uiTiers, 1, "Season: UI hides shortcut tier")
    assert_eq(uiTiers[1].name, "The War Within", "Season: expansion remains")

    local enabled = Catalog.ToggleCurrentContentTracked()
    assert_eq(enabled, true, "Season: toggle enables when off")
    assert_eq(Catalog.IsCurrentContentFullyTracked(), true, "Season: fully tracked after enable")
    assert_eq(DB.IsTracked(99, 14), true, "Season: normal tracked")

    enabled = Catalog.ToggleCurrentContentTracked()
    assert_eq(enabled, false, "Season: toggle disables when on")
    assert_eq(Catalog.IsCurrentContentFullyTracked(), false, "Season: not fully tracked after disable")
    assert_eq(DB.IsTracked(99, 14), false, "Season: normal off")

    -- Re-enable and ensure columns are not duplicated across season + expansion
    Catalog.ToggleCurrentContentTracked()
    local cols = Catalog.GetTrackedColumns()
    assert_eq(#cols, 1, "Season: GetTrackedColumns dedupes instanceId")
end

----------------------------------------------------------------
-- EnsureTrackedEntries must not shadow legacy string tracked keys
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Tier" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 14 or d == 16
    end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 77, "Legacy Raid", "d", 1, 2, 3, 4, 0, "l", true, 7001
        end
        return nil
    end
    Catalog.GetTiers(true)

    -- Simulate SavedVariables with string instance keys
    local tracked = DB.GetTracked()
    tracked["77"] = { [14] = true, ["16"] = true }

    assert_eq(DB.IsTracked(77, 14), true, "Legacy: IsTracked sees string bucket")
    Catalog.EnsureTrackedEntries()
    assert_eq(DB.IsTracked(77, 14), true, "Legacy: still tracked after EnsureTrackedEntries")
    assert_eq(DB.IsTracked(77, 16), true, "Legacy: string diff migrated")
    assert_eq(type(tracked[77]), "table", "Legacy: migrated to number key")
    assert_eq(tracked["77"], nil, "Legacy: string bucket cleared")
end

----------------------------------------------------------------
-- ApplyCurrentTierDefaults must not stamp when difficulties are empty
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Tier" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function() return false end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 88, "Empty Diffs", "d", 1, 2, 3, 4, 0, "l", true, 8001
        end
        return nil
    end
    Catalog.GetTiers(true)
    assert_eq(Catalog.IsReady(), true, "EmptyDiff: raids present")
    assert_eq(Catalog.HasDifficultyData(), false, "EmptyDiff: no difficulties")
    assert_eq(Catalog.EnsureReady(), false, "EmptyDiff: EnsureReady false without diffs")
    assert_eq(Catalog.ApplyCurrentTierDefaults(false), false, "EmptyDiff: defaults not applied")
    assert_eq(DB.IsDefaultsApplied(), false, "EmptyDiff: defaultsApplied stays false")
end

----------------------------------------------------------------
-- Mounts: aggregate loot hits across difficulties
----------------------------------------------------------------
do
    local ns = freshNs()
    local Mounts = ns.Mounts
    local byKey = {}

    Mounts.AddLootHit(byKey, {
        itemID = 12345,
        mountID = 900,
        name = "Test Mount",
        icon = 1,
        tierIndex = 1,
        tierName = "Tier",
        instanceId = 42,
        raidName = "Test Raid",
        diffId = 14,
    })
    Mounts.AddLootHit(byKey, {
        itemID = 12345,
        mountID = 900,
        name = "Test Mount",
        icon = 1,
        tierIndex = 1,
        tierName = "Tier",
        instanceId = 42,
        raidName = "Test Raid",
        diffId = 16,
    })
    Mounts.AddLootHit(byKey, {
        itemID = 12345,
        mountID = 900,
        name = "Test Mount",
        icon = 1,
        tierIndex = 1,
        tierName = "Tier",
        instanceId = 42,
        raidName = "Test Raid",
        diffId = 14, -- duplicate should not double
    })
    -- Same mount in another raid → separate row
    Mounts.AddLootHit(byKey, {
        itemID = 12345,
        mountID = 900,
        name = "Test Mount",
        icon = 1,
        tierIndex = 1,
        tierName = "Tier",
        instanceId = 99,
        raidName = "Other Raid",
        diffId = 15,
    })

    local count = 0
    local row42, row99
    for _, row in pairs(byKey) do
        count = count + 1
        if row.instanceId == 42 then row42 = row end
        if row.instanceId == 99 then row99 = row end
    end
    assert_eq(count, 2, "MountsAgg: two rows for two raids")
    assert_eq(#row42.difficulties, 2, "MountsAgg: Normal+Mythic aggregated")
    assert_eq(row42.difficulties[1], 14, "MountsAgg: Normal first by order")
    assert_eq(row42.difficulties[2], 16, "MountsAgg: Mythic second")
    assert_eq(#row99.difficulties, 1, "MountsAgg: other raid one diff")
    assert_eq(row99.difficulties[1], 15, "MountsAgg: other raid Heroic")
end

----------------------------------------------------------------
-- Mounts: MergeSupplement fills EJ gaps (Invincible / ICC)
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts

    assert_true(type(ns.MountsSupplement) == "table" and #ns.MountsSupplement > 0,
        "MountsSupp: data table loaded")

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Wrath of the Lich King" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 3 or d == 4 or d == 5 or d == 6
    end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            -- journal 758, mapId 631 — Icecrown Citadel
            return 758, "Icecrown Citadel", "d", 1, 2, 3, 4, 0, "l", true, 631
        end
        return nil
    end
    _G.EJ_SetDifficulty = function() end
    _G.EJ_ResetLootFilter = function() end
    _G.EJ_GetNumLoot = function() return 0 end -- EJ misses Invincible
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function() return nil end,
    }
    _G.C_MountJournal = {
        GetMountFromItem = function(itemID)
            if itemID == 50818 then return 363 end
            return nil
        end,
        GetMountInfoByID = function(mountID)
            if mountID == 363 then
                return "Invincible", 1, 2, false, true, 1, false, false, nil, false, false, 363
            end
            return nil
        end,
    }

    Catalog.GetTiers(true)
    local rows = Mounts.BuildFromEJSync()
    local found
    for _, row in ipairs(rows) do
        if row.itemID == 50818 then
            found = row
            break
        end
    end
    assert_true(found ~= nil, "MountsSupp: Invincible present after empty EJ loot")
    assert_eq(found.mountID, 363, "MountsSupp: Invincible mountID")
    assert_eq(found.instanceId, 758, "MountsSupp: ICC journal id")
    assert_eq(#found.difficulties, 1, "MountsSupp: only 25H")
    assert_eq(found.difficulties[1], 6, "MountsSupp: difficulty 6 (25H)")

    -- Merge into existing map is idempotent
    local byKey = {}
    local n1 = Mounts.MergeSupplement(byKey)
    local n2 = Mounts.MergeSupplement(byKey)
    assert_true(n1 >= 1, "MountsSupp: merge adds at least Invincible")
    assert_eq(n2, 0, "MountsSupp: second merge adds no new rows")

    -- World boss / no difficulty rows are allowed
    local wb = {}
    Mounts.AddLootHit(wb, {
        itemID = 99901,
        mountID = 9001,
        name = "World Boss Mount",
        instanceId = 50,
        raidName = "World Boss",
        tierIndex = 1,
        tierName = "Tier",
        -- no diffId
    })
    local wbRow = wb["99901|50"]
    assert_true(wbRow ~= nil, "MountsWB: row without difficulty")
    assert_eq(#wbRow.difficulties, 0, "MountsWB: empty difficulties")

    -- Rescan must not erase previously found Invincible when EJ returns empty
    Mounts.MarkDirty()
    -- Force empty EJ again and rebuild — prior cached Invincible must survive seed+supplement
    local rows2 = Mounts.BuildFromEJSync()
    local found2
    for _, row in ipairs(rows2) do
        if row.itemID == 50818 then
            found2 = row
            break
        end
    end
    assert_true(found2 ~= nil, "MountsSupp: Invincible survives rescan with empty EJ")
end

----------------------------------------------------------------
-- Mounts: persisted disk cache (ALInfoDB.mountsCache)
----------------------------------------------------------------
do
    local ns = freshNs()
    local Mounts = ns.Mounts
    local DB = ns.DB

    DB.SaveMountsCache("fp-test", {
        {
            itemID = 50818,
            mountID = 363,
            name = "Invincible",
            instanceId = 758,
            raidName = "Icecrown Citadel",
            tierIndex = 1,
            tierName = "Wrath",
            difficulties = { 6 },
        },
    })

    -- Simulate /reload: new module state reading same ALInfoDB
    Mounts._ResetPersistedLoaded()
    -- Clear in-memory by marking dirty then loading from disk
    Mounts.MarkDirty()
    assert_eq(Mounts.LoadPersistedCache(true), true, "MountsDisk: load returns true")
    assert_eq(Mounts.IsReady(), true, "MountsDisk: ready from disk")
    assert_eq(Mounts.IsDirty(), false, "MountsDisk: not dirty after load")
    local rows = Mounts.GetRows(false)
    assert_eq(#rows, 1, "MountsDisk: one cached row")
    assert_eq(rows[1].itemID, 50818, "MountsDisk: Invincible from disk")
    assert_eq(DB.GetMountsCache().fingerprint, "fp-test", "MountsDisk: fingerprint stored")

    -- StartScanIfNeeded must not start a scan when cache is valid and catalog absent/unchanged
    assert_eq(Mounts.IsScanning(), false, "MountsDisk: not scanning")
    Mounts.StartScanIfNeeded()
    assert_eq(Mounts.IsScanning(), false, "MountsDisk: still not scanning with valid disk cache")
end

----------------------------------------------------------------
-- Mounts: ClearPersistedCache, nil fingerprint dirty, sanitize WB, prune orphans
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts
    local DB = ns.DB

    DB.SaveMountsCache("fp-old", {
        {
            itemID = 1,
            mountID = 1,
            name = "Old",
            instanceId = 42,
            raidName = "Raid",
            tierIndex = 1,
            tierName = "Exp",
            difficulties = { 14 },
        },
    })
    Mounts._ResetPersistedLoaded()
    assert_eq(Mounts.LoadPersistedCache(true), true, "MountsClear: loaded")
    Mounts.ClearPersistedCache()
    assert_eq(Mounts.IsDirty(), true, "MountsClear: dirty after clear")
    assert_eq(#(DB.GetMountsCache().rows or {}), 0, "MountsClear: disk rows wiped")
    assert_eq(Mounts._GetCachedRows(), nil, "MountsClear: memory rows nil")
end

do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Expansion" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 14
    end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 42, "Mount Raid", "d", 1, 2, 3, 4, 0, "l", true, 777
        end
        return nil
    end
    _G.EJ_SetDifficulty = function() end
    _G.EJ_ResetLootFilter = function() end
    _G.EJ_GetNumLoot = function() return 0 end
    _G.EJ_GetNumEncounters = function() return 0 end
    Catalog.Build()
    assert_eq(Catalog.IsReady(), true, "MountsFp: catalog ready")

    -- Seed READY cache with rows but nil fingerprint (old disk path).
    DB.SaveMountsCache(nil, {
        {
            itemID = 99,
            mountID = 9,
            name = "Stale",
            instanceId = 42,
            raidName = "Mount Raid",
            tierIndex = 1,
            tierName = "Expansion",
            difficulties = { 14 },
        },
    })
    Mounts._ResetPersistedLoaded()
    assert_eq(Mounts.LoadPersistedCache(true), true, "MountsFp: loaded nil-fp cache")
    assert_eq(Mounts.IsScanning(), false, "MountsFp: not scanning yet")
    Mounts.StartScanIfNeeded()
    assert_eq(Mounts.IsScanning(), true, "MountsFp: nil fingerprint forces rescan")
    stub.flushTimers()
end

do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Expansion" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function() return false end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            -- shouldDisplayDifficulty=false => world boss
            return 55, "World Boss", "d", 1, 2, 3, 4, 0, "l", false, 888
        end
        return nil
    end
    Catalog.Build()
    assert_eq(Catalog.IsReady(), true, "MountsWB: catalog ready")

    -- Inject cached row with bogus difficulties for a world boss.
    ns.DB.SaveMountsCache("wb-fp", {
        {
            itemID = 10,
            mountID = 10,
            name = "WB Mount",
            instanceId = 55,
            raidName = "World Boss",
            tierIndex = 1,
            tierName = "Expansion",
            difficulties = { 14, 15 },
        },
    })
    Mounts._ResetPersistedLoaded()
    Mounts.LoadPersistedCache(true)
    -- GetRowsForUI / StartScanIfNeeded sanitize when catalog is ready.
    local rows = Mounts.GetRowsForUI(true)
    local found
    for _, row in ipairs(rows) do
        if row.instanceId == 55 then
            found = row
            break
        end
    end
    assert_true(found ~= nil, "MountsWB: row present")
    assert_eq(#(found.difficulties or { 1 }), 0, "MountsWB: raid DifficultyIDs stripped")
end

do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Expansion" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 14
    end
    local raidId = 42
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return raidId, "Keep Raid", "d", 1, 2, 3, 4, 0, "l", true, 777
        end
        return nil
    end
    _G.EJ_SetDifficulty = function() end
    _G.EJ_ResetLootFilter = function() end
    _G.EJ_GetNumLoot = function() return 0 end
    _G.EJ_GetNumEncounters = function() return 0 end
    Catalog.Build()

    -- Seed orphan instance + current raid into cache, then resync.
    DB.SaveMountsCache("prune-fp", {
        {
            itemID = 1,
            mountID = 1,
            name = "Orphan",
            instanceId = 9999,
            raidName = "Gone",
            tierIndex = 1,
            tierName = "Expansion",
            difficulties = { 14 },
        },
        {
            itemID = 2,
            mountID = 2,
            name = "Keep",
            instanceId = 42,
            raidName = "Keep Raid",
            tierIndex = 1,
            tierName = "Expansion",
            difficulties = { 14 },
        },
    })
    Mounts._ResetPersistedLoaded()
    Mounts.LoadPersistedCache(true)
    Mounts.MarkDirty()
    local rows = Mounts.BuildFromEJSync()
    local hasOrphan, hasKeep = false, false
    for _, row in ipairs(rows) do
        if row.instanceId == 9999 then hasOrphan = true end
        if row.instanceId == 42 then hasKeep = true end
    end
    assert_eq(hasOrphan, false, "MountsPrune: orphan instance dropped")
    assert_eq(hasKeep, true, "MountsPrune: current raid kept")
end

do
    local ns = freshNs()
    local Mounts = ns.Mounts
    local DB = ns.DB
    -- Old schema version must not load
    local cache = DB.GetMountsCache()
    cache.version = 1
    cache.fingerprint = "v1"
    cache.rows = {
        {
            itemID = 1,
            mountID = 1,
            name = "OldSchema",
            instanceId = 1,
            difficulties = { 14 },
        },
    }
    Mounts._ResetPersistedLoaded()
    assert_eq(Mounts.LoadPersistedCache(true), false, "MountsVer: rejects version 1")
    assert_eq(#(DB.GetMountsCache().rows or {}), 0, "MountsVer: clears old schema rows")
end

----------------------------------------------------------------
-- World bosses: location=raid, boss name=difficulty (encounter id)
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts
    local Data = ns.Data
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Pandaria" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function() return false end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 322, "Pandaria World Bosses", "d", 1, 2, 3, 4, 0, "l", false, 870
        end
        return nil
    end
    local encounters = {
        [1] = { name = "Sha of Anger", id = 691 },
        [2] = { name = "Galleon", id = 725 },
    }
    _G.EJ_GetEncounterInfoByIndex = function(e)
        local enc = encounters[e]
        if not enc then return nil end
        return enc.name, "desc", enc.id, 0, "link", 322
    end
    _G.EJ_SelectEncounter = function() end
    _G.EJ_GetNumLoot = function() return 1 end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function(i)
            if i == 1 then
                return { itemID = 87771, name = "Heavenly Onyx Cloud Serpent", icon = 1 }
            end
            return nil
        end,
    }
    _G.C_MountJournal = {
        GetMountFromItem = function(itemID)
            if itemID == 87771 then return 473 end
            return nil
        end,
        GetMountInfoByID = function(mountID)
            if mountID == 473 then
                return "Heavenly Onyx Cloud Serpent", 1, 2, false, true, 1, false, false, nil, false, false, 473
            end
            return nil
        end,
    }

    Catalog.Build()
    local raid = Catalog.GetRaidByInstanceId(322)
    assert_true(raid ~= nil and raid.isWorldBoss, "WBTrack: raid is world boss")
    assert_true(#raid.difficulties >= 2, "WBTrack: at least two boss encounters as difficulties")
    assert_eq(raid.difficulties[1], 691, "WBTrack: Sha encounter id")
    assert_eq(Catalog.GetDifficultyLabel(691), "Sha of Anger", "WBTrack: label is boss name")
    assert_eq(Catalog.HasDifficultyData(), true, "WBTrack: encounters count as difficulty data")

    local jid, encId = Catalog.ResolveWorldBossLockout("Sha of Anger", 870)
    assert_eq(jid, 322, "WBTrack: resolve journal by boss name")
    assert_eq(encId, 691, "WBTrack: resolve encounter id")

    _G.UnitGUID = function() return "Player-1-WB" end
    _G.GetNumSavedInstances = function() return 1 end
    _G.GetSavedInstanceInfo = function()
        return "Sha of Anger", 1, 3600, 0, true, false, 0, true,
            40, "", 1, 1, false, 870
    end
    _G.GetSavedInstanceEncounterInfo = function()
        return "Sha of Anger", nil, true, false
    end
    local lockouts = Data.ScanRaidLockouts()
    local key = DB.LockoutKey(322, 691)
    assert_true(lockouts[key] ~= nil, "WBTrack: lockout stored under location:encounter")
    assert_eq(lockouts[key].difficultyId, 691, "WBTrack: synthetic difficulty is encounter")
    assert_eq(select(1, Data.GetLockoutStatus("Player-1-WB", 322, 691)), "complete",
        "WBTrack: killed boss shows complete")

    local rows = Mounts.BuildFromEJSync()
    local mountRow
    for _, row in ipairs(rows) do
        if row.itemID == 87771 then
            mountRow = row
            break
        end
    end
    assert_true(mountRow ~= nil, "WBTrack: mount row found")
    assert_true(#(mountRow.difficulties or {}) >= 1, "WBTrack: mount has encounter difficulty")
    local hasEnc = false
    for _, d in ipairs(mountRow.difficulties) do
        if d == 691 or d == 725 then
            hasEnc = true
            break
        end
    end
    assert_eq(hasEnc, true, "WBTrack: mount difficulty is a WB encounter id")

    assert_eq(Mounts.IsFullyTracked(322, mountRow.difficulties), false, "WBTrack: master off")
    Mounts.SetFullyTracked(322, mountRow.difficulties, true)
    assert_eq(Mounts.IsFullyTracked(322, mountRow.difficulties), true, "WBTrack: master on")
    assert_eq(DB.IsTracked(322, mountRow.difficulties[1]), true, "WBTrack: encounter tracked")

    local cols = Catalog.GetTrackedColumns()
    local foundCol
    for _, col in ipairs(cols) do
        if col.instanceId == 322 then
            foundCol = col
            break
        end
    end
    assert_true(foundCol ~= nil, "WBTrack: appears in tracked columns")
    assert_true(#foundCol.difficulties >= 1, "WBTrack: column has boss rows")
end

----------------------------------------------------------------
-- Mounts: BuildFromEJ scan + IsFullyTracked sync with DB
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts
    local DB = ns.DB

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Expansion" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 14 or d == 15 or d == 16
    end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if index == 1 and isRaid then
            return 42, "Mount Raid", "d", 1, 2, 3, 4, 0, "l", true, 777
        end
        return nil
    end

    local selectedDiff
    _G.EJ_SetDifficulty = function(d) selectedDiff = d end
    _G.EJ_ResetLootFilter = function() end
    _G.EJ_GetNumLoot = function()
        if selectedDiff == 14 or selectedDiff == 16 then
            return 2
        end
        return 1
    end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function(i)
            if i == 1 then
                return { itemID = 111, name = "Sword", icon = 1 }
            end
            if i == 2 and (selectedDiff == 14 or selectedDiff == 16) then
                return { itemID = 222, name = "Reins of Test", icon = 2 }
            end
            return nil
        end,
    }
    _G.C_MountJournal = {
        GetMountFromItem = function(itemID)
            if itemID == 222 then return 555 end
            return nil
        end,
        GetMountInfoByID = function(mountID)
            if mountID == 555 then
                return "Reins of Test", 1, 2, false, true, 1, false, false, nil, false, false, 555
            end
            return nil
        end,
    }

    Catalog.GetTiers(true)
    local rows = Mounts.BuildFromEJSync()
    assert_eq(#rows, 1, "MountsScan: one mount row")
    assert_eq(rows[1].itemID, 222, "MountsScan: mount itemID")
    assert_eq(rows[1].mountID, 555, "MountsScan: mountID")
    assert_eq(rows[1].instanceId, 42, "MountsScan: raid instance")
    assert_eq(#rows[1].difficulties, 2, "MountsScan: drops on Normal+Mythic")
    assert_eq(Mounts.IsCollected(555), false, "MountsScan: not collected")
    assert_eq(Mounts.IsReady(), true, "MountsScan: cache ready after sync build")
    assert_eq(Mounts.IsScanning(), false, "MountsScan: not scanning after sync build")
    assert_true(#(DB.GetMountsCache().rows or {}) >= 1, "MountsScan: persisted to ALInfoDB")

    assert_eq(Mounts.IsFullyTracked(42, rows[1].difficulties), false, "MountsSync: master off initially")
    Mounts.SetFullyTracked(42, rows[1].difficulties, true)
    assert_eq(DB.IsTracked(42, 14), true, "MountsSync: Normal tracked via master")
    assert_eq(DB.IsTracked(42, 16), true, "MountsSync: Mythic tracked via master")
    assert_eq(DB.IsTracked(42, 15), false, "MountsSync: Heroic untouched (no drop)")
    assert_eq(Mounts.IsFullyTracked(42, rows[1].difficulties), true, "MountsSync: master on")

    DB.SetTracked(42, 14, false)
    assert_eq(Mounts.IsFullyTracked(42, rows[1].difficulties), false, "MountsSync: master off when one diff cleared")

    assert_eq(#Mounts.GetRowsForUI(false), 1, "MountsFilter: uncollected shown when hide collected")
    _G.C_MountJournal.GetMountInfoByID = function(mountID)
        if mountID == 555 then
            return "Reins of Test", 1, 2, false, true, 1, false, false, nil, false, true, 555
        end
        return nil
    end
    assert_eq(#Mounts.GetRowsForUI(false), 0, "MountsFilter: collected hidden by default")
    assert_eq(#Mounts.GetRowsForUI(true), 1, "MountsFilter: collected shown when enabled")

    assert_eq(DB.GetShowCollectedMounts(), false, "MountsDB: showCollected default false")
    DB.SetShowCollectedMounts(true)
    assert_eq(DB.GetShowCollectedMounts(), true, "MountsDB: showCollected set")
    assert_eq(DB.IsMountTierCollapsed(1), false, "MountsDB: tier expanded by default")
    DB.SetMountTierCollapsed(1, true)
    assert_eq(DB.IsMountTierCollapsed(1), true, "MountsDB: tier collapsed")

    Mounts.MarkDirty()
    assert_eq(Mounts.IsReady(), false, "MountsAsync: dirty clears ready")
    local partial = Mounts.StartScanIfNeeded()
    assert_eq(Mounts.IsScanning(), true, "MountsAsync: scanning after start")
    assert_true(type(partial) == "table", "MountsAsync: returns table while scanning")
    stub.flushTimers()
    assert_eq(Mounts.IsScanning(), false, "MountsAsync: done after flush")
    assert_eq(Mounts.IsReady(), true, "MountsAsync: ready after flush")
    local asyncRows = Mounts.GetRows(false)
    assert_eq(#asyncRows, 1, "MountsAsync: one mount row after chunked scan")
    assert_eq(asyncRows[1].mountID, 555, "MountsAsync: mountID after chunked scan")
end

----------------------------------------------------------------
-- Mounts: cancel mid-scan / stale generation; item-load dedup;
-- catalog invalidate; partial cache kept; no restart loop
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Mounts = ns.Mounts

    _G.EJ_GetNumTiers = function() return 1 end
    _G.EJ_GetCurrentTier = function() return 1 end
    _G.EJ_GetTierInfo = function() return "Classic" end
    _G.EJ_SelectInstance = function() end
    _G.EJ_IsValidInstanceDifficulty = function(d)
        return d == 14 or d == 15 or d == 16
    end
    local raidCount = 4
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if not isRaid or index < 1 or index > raidCount then return nil end
        return 100 + index, "Raid " .. index, "d", 1, 2, 3, 4, 0, "l", true, 7000 + index
    end

    local selectedDiff
    _G.EJ_SetDifficulty = function(d) selectedDiff = d end
    _G.EJ_ResetLootFilter = function() end
    _G.EJ_GetNumLoot = function() return 3 end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function(i)
            if i == 1 then return { itemID = 1000 + (selectedDiff or 0), name = "Junk", icon = 1 } end
            if i == 2 then return { itemID = 222, name = "Reins", icon = 2 } end
            if i == 3 then return { itemID = 3333, name = "MoreJunk", icon = 3 } end
            return nil
        end,
    }
    local mountFromItemReady = false
    _G.C_MountJournal = {
        GetMountFromItem = function(itemID)
            if itemID == 222 and mountFromItemReady then return 555 end
            return nil
        end,
        GetMountInfoByID = function(mountID)
            if mountID == 555 then
                return "Reins", 1, 2, false, true, 1, false, false, nil, false, false, 555
            end
            return nil
        end,
    }

    Catalog.GetTiers(true)
    -- 4 raids × 3 diffs = 12 work items
    Mounts.MarkDirty()
    Mounts.StartScanIfNeeded()
    assert_eq(Mounts.IsScanning(), true, "MountsLoop: scanning started")
    local _, total1, gen1 = Mounts._GetScanIndex()
    assert_eq(total1, 12, "MountsLoop: 12 work items")

    -- Progress UI repeatedly calling StartScanIfNeeded must not restart
    for _ = 1, 5 do
        Mounts.StartScanIfNeeded()
    end
    local _, _, genAfter = Mounts._GetScanIndex()
    assert_eq(genAfter, gen1, "MountsLoop: progress calls must not bump generation")
    assert_eq(Mounts.IsScanning(), true, "MountsLoop: still scanning after progress calls")

    stub.flushTimers(3)
    local idxMid, _, genMid = Mounts._GetScanIndex()
    assert_eq(genMid, gen1, "MountsLoop: generation stable mid-scan")
    assert_true(idxMid >= 1, "MountsLoop: scan index advances")

    -- Item-load mid-scan must NOT CancelScan/restart (the Classic 4/212 loop)
    Mounts.MarkDirty()
    mountFromItemReady = false
    Mounts.StartScanIfNeeded()
    local _, _, gen2 = Mounts._GetScanIndex()
    stub.flushTimers(2)
    mountFromItemReady = true
    local nLoaded = stub.flushItemLoads()
    assert_true(nLoaded > 0, "MountsLoop: item loads were queued")
    assert_eq(Mounts._IsRescanAfterFinish(), false, "MountsLoop: must NOT schedule full rescan-after-finish")
    local _, _, genAfterItem = Mounts._GetScanIndex()
    assert_eq(genAfterItem, gen2, "MountsLoop: item-load must not restart scan generation")
    assert_eq(Mounts.IsScanning(), true, "MountsLoop: still scanning after item-load")

    stub.flushTimers()
    assert_eq(Mounts.IsScanning(), false, "MountsLoop: not scanning after full flush")
    assert_eq(Mounts.IsReady(), true, "MountsLoop: ready after flush")
    -- A second automatic EJ pass must not have started
    assert_eq(Mounts._IsRescanAfterFinish(), false, "MountsLoop: no deferred rescan after finish")
    local rows = Mounts.GetRows(false)
    assert_true(#rows >= 1, "MountsLoop: found mount rows after complete scan")
    for _, row in ipairs(rows) do
        assert_eq(row._diffSet, nil, "MountsLoop: published rows strip _diffSet")
    end

    -- Cancel mid-scan: stale generation ignored
    Mounts.MarkDirty()
    Mounts.StartScanIfNeeded()
    local _, _, gen3 = Mounts._GetScanIndex()
    stub.flushTimers(2)
    Mounts.MarkDirty()
    assert_eq(Mounts.IsScanning(), false, "MountsLoop: cancelled")
    Mounts._ProcessScanSlice(gen3)
    assert_eq(Mounts.IsScanning(), false, "MountsLoop: stale slice ignored")

    -- Catalog invalidate → dirty; keep last complete rows for display
    mountFromItemReady = true
    Mounts.StartScanIfNeeded()
    stub.flushTimers()
    assert_eq(Mounts.IsReady(), true, "MountsLoop: ready before catalog change")
    assert_true(Mounts._GetCachedRows() and #Mounts._GetCachedRows() >= 1, "MountsLoop: cached rows present")

    raidCount = 5
    Catalog.GetTiers(true)
    assert_eq(Mounts.IsDirty(), true, "MountsLoop: catalog change marks dirty")
    assert_true(Mounts._GetCachedRows() ~= nil, "MountsLoop: last complete rows kept after dirty")

    Mounts.StartScanIfNeeded()
    local displayDuring = Mounts.GetRows(false)
    assert_true(#displayDuring >= 1, "MountsLoop: previous rows visible mid-rescan")
    stub.flushTimers(1)
    local displayMid = Mounts.GetRows(false)
    assert_eq(#displayMid, #displayDuring, "MountsLoop: mid-scan does not shrink display to partial")
    stub.flushTimers()
    assert_eq(Mounts.IsReady(), true, "MountsLoop: ready after catalog-driven rescan")

    -- Item-id dedupe across many difficulties
    Mounts.MarkDirty()
    mountFromItemReady = false
    Mounts.StartScanIfNeeded()
    stub.flushTimers(8)
    local pending = Mounts._GetPendingItemIds()
    assert_eq(pending[222], true, "MountsLoop: item 222 pending exactly once (deduped)")
    stub.flushTimers()
end

----------------------------------------------------------------
-- Shared lockout difficulties: only Blizzard toggleDifficultyID
----------------------------------------------------------------
do
    local ns = freshNs()
    local Catalog = ns.Catalog
    local Data = ns.Data
    local DB = ns.DB

    -- Flexible N/H/M/LFR are independent (Blizzard toggleDifficultyID == 0; Lua 0 is truthy).
    local sharedNH = Catalog.GetSharedLockoutDifficulties(14)
    assert_eq(#sharedNH, 0, "Shared: Normal (14) is independent (toggle=0 → empty)")
    local sharedHN = Catalog.GetSharedLockoutDifficulties(15)
    assert_eq(#sharedHN, 0, "Shared: Heroic (15) is independent")

    local shared10 = Catalog.GetSharedLockoutDifficulties(3)
    assert_eq(shared10[1], 5, "Shared: 10N ↔ 10H via toggleDifficultyID")
    local shared25 = Catalog.GetSharedLockoutDifficulties(6)
    assert_eq(shared25[1], 4, "Shared: 25H ↔ 25N via toggleDifficultyID")
    local shared25n = Catalog.GetSharedLockoutDifficulties(4)
    assert_eq(shared25n[1], 6, "Shared: 25N ↔ 25H via toggleDifficultyID")

    local sharedLfr = Catalog.GetSharedLockoutDifficulties(17)
    assert_eq(#sharedLfr, 0, "Shared: LFR is independent")
    local sharedMythic = Catalog.GetSharedLockoutDifficulties(16)
    assert_eq(#sharedMythic, 0, "Shared: Mythic is independent")
    local sharedLegacyLfr = Catalog.GetSharedLockoutDifficulties(7)
    assert_eq(#sharedLegacyLfr, 0, "Shared: legacy LFR is independent")

    local guid = "Player-1-BLOCKED"
    DB.EnsureCharacter(guid)
    local now = time()
    -- Heroic (15) must NOT block Normal (14) — loot-based independent lockouts (SoO+).
    DB.SetLockouts(guid, {
        [DB.LockoutKey(187, 15)] = {
            instanceId = 187,
            difficultyId = 15,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 8,
            encounterProgress = 3,
            bosses = {
                { name = "Morchok", killed = true },
                { name = "Zon'ozz", killed = true },
                { name = "Yor'sahj", killed = true },
                { name = "Hagara", killed = false },
            },
        },
    })

    local statusH, pH, tH = Data.GetLockoutStatus(guid, 187, 15)
    assert_eq(statusH, "progress", "Blocked: Heroic shows progress")
    assert_eq(pH, 3, "Blocked: Heroic progress count")

    local statusN = Data.GetLockoutStatus(guid, 187, 14)
    assert_eq(statusN, "free", "Blocked: Normal stays free when only Heroic locked")

    local statusM = Data.GetLockoutStatus(guid, 187, 16)
    assert_eq(statusM, "free", "Blocked: Mythic remains free")

    local statusLfr = Data.GetLockoutStatus(guid, 187, 17)
    assert_eq(statusLfr, "free", "Blocked: LFR remains free")

    -- Legacy 10N blocks 10H
    local guid2 = "Player-1-LEGACY"
    DB.EnsureCharacter(guid2)
    DB.SetLockouts(guid2, {
        [DB.LockoutKey(758, 3)] = {
            instanceId = 758,
            difficultyId = 3,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 12,
            encounterProgress = 1,
            bosses = { { name = "Lord Marrowgar", killed = true } },
        },
    })
    local st10h, _, _, by10 = Data.GetLockoutStatus(guid2, 758, 5)
    assert_eq(st10h, "blocked", "Blocked: 10H blocked by 10N")
    assert_eq(by10, 3, "Blocked: blocker is 10N")
    local st25 = Data.GetLockoutStatus(guid2, 758, 4)
    assert_eq(st25, "free", "Blocked: 25N not blocked by 10N")

    -- Legacy 10H blocks 10N (symmetric)
    local guid10h = "Player-1-LEGACY-10H"
    DB.EnsureCharacter(guid10h)
    DB.SetLockouts(guid10h, {
        [DB.LockoutKey(758, 5)] = {
            instanceId = 758,
            difficultyId = 5,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 12,
            encounterProgress = 2,
            bosses = {
                { name = "Lord Marrowgar", killed = true },
                { name = "Lady Deathwhisper", killed = true },
            },
        },
    })
    local st10n, _, _, by10h = Data.GetLockoutStatus(guid10h, 758, 3)
    assert_eq(st10n, "blocked", "Blocked: 10N blocked by 10H")
    assert_eq(by10h, 5, "Blocked: blocker is 10H")

    -- Legacy 25N ↔ 25H symmetric (4 ↔ 6)
    local guid25n = "Player-1-LEGACY-25N"
    DB.EnsureCharacter(guid25n)
    DB.SetLockouts(guid25n, {
        [DB.LockoutKey(758, 4)] = {
            instanceId = 758,
            difficultyId = 4,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 12,
            encounterProgress = 1,
            bosses = { { name = "Lord Marrowgar", killed = true } },
        },
    })
    local st25h, _, _, by25n = Data.GetLockoutStatus(guid25n, 758, 6)
    assert_eq(st25h, "blocked", "Blocked: 25H blocked by 25N")
    assert_eq(by25n, 4, "Blocked: blocker is 25N")
    assert_eq(select(1, Data.GetLockoutStatus(guid25n, 758, 3)), "free",
        "Blocked: 10N not blocked by 25N")

    local guid25h = "Player-1-LEGACY-25H"
    DB.EnsureCharacter(guid25h)
    DB.SetLockouts(guid25h, {
        [DB.LockoutKey(758, 6)] = {
            instanceId = 758,
            difficultyId = 6,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 12,
            encounterProgress = 3,
            bosses = {
                { name = "Lord Marrowgar", killed = true },
                { name = "Lady Deathwhisper", killed = true },
                { name = "Gunship Battle", killed = true },
            },
        },
    })
    local st25n, _, _, by25h = Data.GetLockoutStatus(guid25h, 758, 4)
    assert_eq(st25n, "blocked", "Blocked: 25N blocked by 25H")
    assert_eq(by25h, 6, "Blocked: blocker is 25H")

    -- Debug dump includes toggle / blocks sections
    local lines = Data.DumpDebugLockouts(true)
    local blob = table.concat(lines, "\n")
    assert_true(blob:find("Shared lockouts", 1, true) ~= nil, "DumpDebug: shared lockouts section")
    assert_true(blob:find("toggle=", 1, true) ~= nil, "DumpDebug: shows toggleDifficultyID")
    assert_true(blob:find("independent", 1, true) ~= nil, "DumpDebug: marks independent diffs")
end

----------------------------------------------------------------
-- RemapDifficultyLockouts: collision keeps the stronger lockout
----------------------------------------------------------------
do
    local ns = freshNs()
    local DB = ns.DB
    local Data = ns.Data
    local now = time()
    local guid = "Player-1-REMAP"
    DB.EnsureCharacter(guid)

    local fromKey = DB.LockoutKey(557, 900001)
    local toKey = DB.LockoutKey(557, 1262)
    DB.SetLockouts(guid, {
        [fromKey] = {
            instanceId = 557,
            difficultyId = 900001,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 4,
            encounterProgress = 3,
            bosses = {
                { name = "Boss A", killed = true },
                { name = "Boss B", killed = true },
                { name = "Boss C", killed = true },
                { name = "Boss D", killed = false },
            },
        },
        [toKey] = {
            instanceId = 557,
            difficultyId = 1262,
            locked = true,
            extended = false,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now - 100,
            numEncounters = 4,
            encounterProgress = 1,
            bosses = {
                { name = "Boss A", killed = true },
                { name = "Boss B", killed = false },
                { name = "Boss C", killed = false },
                { name = "Boss D", killed = false },
            },
        },
    })

    local changed = DB.RemapDifficultyLockouts(557, 900001, 1262)
    assert_eq(changed, 1, "Remap: remapped one character")
    local char = DB.GetCharacter(guid)
    assert_eq(char.lockouts[fromKey], nil, "Remap: fromKey removed")
    local kept = char.lockouts[toKey]
    assert_true(kept ~= nil, "Remap: toKey present")
    local kills = Data.CountKilledBosses(kept)
    assert_eq(kills, 3, "Remap: collision keeps richer from-key lockout (3 kills)")
    assert_eq(kept.difficultyId, 1262, "Remap: winner has toDifficultyId")

    -- Weak from + strong to: keep to
    local guid2 = "Player-1-REMAP2"
    DB.EnsureCharacter(guid2)
    DB.SetLockouts(guid2, {
        [fromKey] = {
            instanceId = 557,
            difficultyId = 900001,
            locked = true,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 4,
            encounterProgress = 0,
            bosses = {
                { name = "A", killed = false },
                { name = "B", killed = false },
            },
        },
        [toKey] = {
            instanceId = 557,
            difficultyId = 1262,
            locked = true,
            resetAt = now + 7 * 24 * 3600,
            recordedAt = now,
            numEncounters = 4,
            encounterProgress = 2,
            bosses = {
                { name = "A", killed = true },
                { name = "B", killed = true },
            },
        },
    })
    DB.RemapDifficultyLockouts(557, 900001, 1262)
    local kept2 = DB.GetCharacter(guid2).lockouts[toKey]
    assert_eq(Data.CountKilledBosses(kept2), 2, "Remap: collision keeps stronger to-key lockout")
end

----------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    print("Failures:")
    for _, msg in ipairs(failures) do
        print("  - " .. msg)
    end
    os.exit(1)
end
print("All tests passed.")
os.exit(0)
