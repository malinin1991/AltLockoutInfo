local addonName, ns = ...

--- Static supplement for raid mounts that Encounter Journal loot often omits.
--- Keys use journal instanceId when known; mapId is a fallback matched via Catalog.
--- difficulties: DifficultyIDs where the mount can drop (legacy 3/4/5/6/9 + modern 14/15/16/17).
ns.MountsSupplement = {
    -- Wrath of the Lich King
    -- Invincible's Reins — The Lich King, Icecrown Citadel 25 Heroic only
    { itemID = 50818, mountID = 363, journalInstanceId = 758, mapId = 631, difficulties = { 6 } },
    -- Azure Drake — Malygos, Eye of Eternity
    { itemID = 43952, mountID = 168, journalInstanceId = 756, mapId = 616, difficulties = { 3, 4 } },
    -- Blue Drake — Malygos
    { itemID = 43953, mountID = 167, journalInstanceId = 756, mapId = 616, difficulties = { 3, 4 } },
    -- Twilight Drake — Sartharion + 2 drakes, Obsidian Sanctum
    { itemID = 43954, mountID = 156, journalInstanceId = 755, mapId = 615, difficulties = { 3, 4 } },
    -- Black Drake — Sartharion + 3 drakes
    { itemID = 43986, mountID = 159, journalInstanceId = 755, mapId = 615, difficulties = { 3, 4 } },
    -- Mimiron's Head — Yogg-Saron +0, Ulduar 25
    { itemID = 45693, mountID = 304, journalInstanceId = 759, mapId = 603, difficulties = { 4 } },
    -- Onyxian Drake — Onyxia's Lair
    { itemID = 49636, mountID = 349, journalInstanceId = 760, mapId = 249, difficulties = { 3, 4 } },

    -- Cataclysm
    -- Flametalon of Alysrazor — Firelands
    { itemID = 71665, mountID = 425, journalInstanceId = 78, mapId = 720, difficulties = { 14, 15, 16 } },
    -- Smoldering Egg of Millagazor — Ragnaros, Firelands
    { itemID = 69224, mountID = 415, journalInstanceId = 78, mapId = 720, difficulties = { 14, 15, 16 } },
    -- Experiment 12-B — Ultraxion, Dragon Soul
    { itemID = 78919, mountID = 445, journalInstanceId = 187, mapId = 967, difficulties = { 14, 15, 16 } },
    -- Reins of the Blazing Drake — Deathwing, Dragon Soul
    { itemID = 77067, mountID = 442, journalInstanceId = 187, mapId = 967, difficulties = { 14, 15, 16 } },
    -- Life-Binder's Handmaiden — Deathwing heroic, Dragon Soul
    { itemID = 77069, mountID = 444, journalInstanceId = 187, mapId = 967, difficulties = { 15, 16 } },

    -- Mists of Pandaria
    -- Astral Cloud Serpent — Elegon, Mogu'shan Vaults
    { itemID = 87777, mountID = 478, journalInstanceId = 317, mapId = 1008, difficulties = { 14, 15, 16 } },
    -- Spawn of Horridon — Horridon, Throne of Thunder
    { itemID = 93666, mountID = 531, journalInstanceId = 362, mapId = 1098, difficulties = { 14, 15, 16 } },
    -- Clutch of Ji-Kun — Ji-Kun, Throne of Thunder
    { itemID = 95059, mountID = 543, journalInstanceId = 362, mapId = 1098, difficulties = { 14, 15, 16 } },
    -- Kor'kron Juggernaut — Garrosh Mythic, Siege of Orgrimmar
    { itemID = 104253, mountID = 559, journalInstanceId = 369, mapId = 1136, difficulties = { 16 } },

    -- Warlords of Draenor
    -- Solar Spirehawk — Rukhmar. EJ often fails to expose encounter loot/diffs for
    -- Draenor journal 557, so we pin a synthetic encounter id + locale boss name.
    {
        itemID = 116771,
        mountID = 634,
        journalInstanceId = 557,
        difficulties = { 900001 },
        bossLocaleKey = "WB_BOSS_RUKHMAR",
        bossName = "Rukhmar",
    },
    -- Ironhoof Destroyer — Blackhand Mythic, Blackrock Foundry
    { itemID = 116660, mountID = 613, journalInstanceId = 457, mapId = 1205, difficulties = { 16 } },
    -- Felsteel Annihilator — Archimonde Mythic, Hellfire Citadel
    { itemID = 123890, mountID = 751, journalInstanceId = 669, mapId = 1448, difficulties = { 16 } },

    -- Legion
    -- Abyss Worm — Mistress Sassz'ine, Tomb of Sargeras
    { itemID = 143643, mountID = 955, journalInstanceId = 875, mapId = 1676, difficulties = { 14, 15, 16, 17 } },
    -- Antoran Charhound / Shackled Ur'zul — Antorus
    { itemID = 152789, mountID = 985, journalInstanceId = 946, mapId = 1712, difficulties = { 14, 15, 16, 17 } },
    { itemID = 152815, mountID = 995, journalInstanceId = 946, mapId = 1712, difficulties = { 16 } },

    -- Battle for Azeroth
    { itemID = 166518, mountID = 1217, journalInstanceId = 1176, mapId = 2070, difficulties = { 14, 15, 16, 17 } },
    { itemID = 166705, mountID = 1219, journalInstanceId = 1176, mapId = 2070, difficulties = { 16 } },
    { itemID = 174872, mountID = 1293, journalInstanceId = 1180, mapId = 2217, difficulties = { 16 } },

    -- Shadowlands
    { itemID = 186642, mountID = 1500, journalInstanceId = 1193, mapId = 2450, difficulties = { 16 } },
    { itemID = 190768, mountID = 1587, journalInstanceId = 1195, mapId = 2481, difficulties = { 16 } },

    -- Dragonflight
    { itemID = 192772, mountID = 1617, journalInstanceId = 1200, mapId = 2522, difficulties = { 16 } },
    { itemID = 205147, mountID = 1745, journalInstanceId = 1208, mapId = 2569, difficulties = { 16 } },
    { itemID = 210142, mountID = 1818, journalInstanceId = 1207, mapId = 2549, difficulties = { 16 } },

    -- The War Within
    { itemID = 224147, mountID = 2219, journalInstanceId = 1273, mapId = 2657, difficulties = { 16 } },
}
