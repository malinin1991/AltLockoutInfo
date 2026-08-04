local addonName, ns = ...

ns.UI_Main = ns.UI_Main or {}
local UI = ns.UI_Main
local DB = ns.DB
local Data = ns.Data
local Catalog = ns.Catalog
local L = ns.L

local LABEL_W = 200
local CELL_W = 72
local CELL_H = 20
local ROW_H = 22
local RAID_ROW_H = 24
local PAD = 8
local HEADER_H = 48
local HEADER_NAME_H = 26
local HEADER_LEVEL_H = 14

local frame
local scrollFrame
local scrollChild
local weeklyText
local content
local buttonPool = {}
local fontPool = {}
local activeButtons = {}
local activeFonts = {}

local COLORS = {
    free = { 0.2, 0.85, 0.3 },
    progress = { 1.0, 0.82, 0.2 },
    complete = { 0.85, 0.25, 0.25 },
    empty = { 0.55, 0.55, 0.55 },
    -- Cooler slate grey so "—" blocked is distinct from unknown/NO_DATA empty grey.
    blocked = { 0.42, 0.48, 0.58 },
    header = { 1, 0.82, 0 },
    raid = { 0.9, 0.9, 1 },
}

local function ClassColor(classFile)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

local function ReleasePools()
    for i = #activeButtons, 1, -1 do
        local b = activeButtons[i]
        activeButtons[i] = nil
        b:Hide()
        b:ClearAllPoints()
        b:SetScript("OnEnter", nil)
        b:SetScript("OnClick", nil)
        b:SetParent(nil)
        buttonPool[#buttonPool + 1] = b
    end
    for i = #activeFonts, 1, -1 do
        local fs = activeFonts[i]
        activeFonts[i] = nil
        fs:Hide()
        fs:SetText("")
        fs:ClearAllPoints()
        fs:SetParent(nil)
        fontPool[#fontPool + 1] = fs
    end
end

local function AcquireFont(parent, template)
    local fs = table.remove(fontPool)
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    else
        fs:SetParent(parent)
        if fs.SetFontObject and template then
            fs:SetFontObject(template)
        end
    end
    -- Reset color so pooled strings don't keep class colors from character names.
    fs:SetTextColor(1, 1, 1)
    fs:Show()
    activeFonts[#activeFonts + 1] = fs
    return fs
end

local function AcquireButton(parent)
    local b = table.remove(buttonPool)
    if not b then
        b = CreateFrame("Button", nil, parent)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetAllPoints()
        fs:SetJustifyH("CENTER")
        b.text = fs
        b:SetScript("OnLeave", GameTooltip_Hide)
    else
        b:SetParent(parent)
    end
    b:Show()
    activeButtons[#activeButtons + 1] = b
    return b
end

local function GetEnabledCharacters()
    local list = {}
    for guid, char in pairs(DB.GetCharacters()) do
        if char.enabled ~= false then
            list[#list + 1] = { guid = guid, data = char }
        end
    end
    table.sort(list, function(a, b)
        local an = (a.data.name or "") .. "-" .. (a.data.realm or "")
        local bn = (b.data.name or "") .. "-" .. (b.data.realm or "")
        return an < bn
    end)
    return list
end

local function CharacterDisplayName(char)
    local display = char.name or "?"
    local playerRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or ""
    if char.realm and char.realm ~= "" and char.realm ~= playerRealm then
        display = display .. "-" .. char.realm
    end
    return display
end

local function FormatCell(status, progress, total)
    if status == "disabled" or status == "unknown" then
        return L["NO_DATA"], COLORS.empty
    end
    if status == "blocked" then
        return L["BLOCKED_CELL"] or "—", COLORS.blocked
    end
    if status == "free" then
        return L["FREE"], COLORS.free
    end
    if status == "complete" then
        return L["COMPLETE"], COLORS.complete
    end
    if status == "progress" then
        return string.format(L["PROGRESS"], progress or 0, total or 0), COLORS.progress
    end
    return L["NO_DATA"], COLORS.empty
end

local function BuildVisibleRaids()
    -- Show every tracked difficulty the user enabled — do not hide "Free" rows.
    local raw = Catalog.GetTrackedColumns()
    local result = {}
    for _, raid in ipairs(raw) do
        if raid.difficulties and #raid.difficulties > 0 then
            result[#result + 1] = {
                instanceId = raid.instanceId,
                name = raid.name,
                difficulties = raid.difficulties,
            }
        end
    end
    return result
end

local function ShowCellTooltip(owner, guid, instanceId, diffId, raidName)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local char = DB.GetCharacter(guid)
    local charName = char and CharacterDisplayName(char) or "?"
    GameTooltip:AddLine(charName .. " — " .. (raidName or "") .. " (" .. Catalog.GetDifficultyLabel(diffId) .. ")", 1, 0.82, 0)

    if DB.IsCharacterRaidDisabled(guid, instanceId) then
        GameTooltip:AddLine(L["NO_DATA"], 0.6, 0.6, 0.6)
        GameTooltip:Show()
        return
    end
    if not DB.HasLockoutsScan(guid) then
        GameTooltip:AddLine(L["UNKNOWN_LOCKOUT"], 0.6, 0.6, 0.6)
        GameTooltip:Show()
        return
    end

    local status, progress, total, blockedBy = Data.GetLockoutStatus(guid, instanceId, diffId)
    if status == "blocked" then
        local blockerLabel = Catalog.GetDifficultyLabel(blockedBy) or tostring(blockedBy)
        GameTooltip:AddLine(string.format(L["TOOLTIP_BLOCKED"] or "Blocked by %s", blockerLabel), 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["TOOLTIP_BLOCKED_HINT"] or "This difficulty shares a lockout with another difficulty.", 0.55, 0.55, 0.55, true)
        local otherLo = Data.GetEffectiveLockout(guid, instanceId, blockedBy)
        if otherLo then
            local left = math.max(0, (tonumber(otherLo.resetAt) or 0) - time())
            if left > 0 then
                GameTooltip:AddLine(string.format(L["TOOLTIP_RESET"], Data.FormatDuration(left)), 0.8, 0.8, 0.8)
            end
            local kills, encTotal = Data.CountKilledBosses(otherLo)
            if encTotal and encTotal > 0 then
                GameTooltip:AddLine(string.format(L["PROGRESS"], kills, encTotal), 1, 0.82, 0.2)
            end
        end
        GameTooltip:Show()
        return
    end

    local lo = DB.GetLockout(guid, instanceId, diffId)
    if not lo or Data.IsLockoutExpired(lo) or (not lo.locked and not lo.extended) then
        GameTooltip:AddLine(L["FREE"], 0.2, 0.85, 0.3)
        if lo and Data.IsLockoutExpired(lo) then
            GameTooltip:AddLine(L["TOOLTIP_EXPIRED"], 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
        return
    end

    local left = math.max(0, (tonumber(lo.resetAt) or 0) - time())
    GameTooltip:AddLine(string.format(L["TOOLTIP_RESET"], Data.FormatDuration(left)), 0.8, 0.8, 0.8)
    local kills, encTotal = Data.CountKilledBosses(lo)
    GameTooltip:AddLine(string.format(L["PROGRESS"], kills, encTotal), 1, 0.82, 0.2)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["TOOLTIP_BOSSES"], 1, 1, 1)
    if type(lo.bosses) == "table" and #lo.bosses > 0 then
        for _, boss in ipairs(lo.bosses) do
            if Data.IsEncounterKilledFlag(boss.killed) then
                GameTooltip:AddDoubleLine(boss.name or "?", L["TOOLTIP_KILLED"], 0.7, 0.7, 0.7, 0.85, 0.25, 0.25)
            else
                GameTooltip:AddDoubleLine(boss.name or "?", L["TOOLTIP_ALIVE"], 1, 1, 1, 0.2, 0.85, 0.3)
            end
        end
    else
        GameTooltip:AddLine(L["TOOLTIP_NO_BOSSES"], 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

function UI.Refresh()
    if not frame or not scrollChild then
        return
    end

    if not content then
        content = CreateFrame("Frame", nil, scrollChild)
        content:SetPoint("TOPLEFT", 0, 0)
        scrollChild.content = content
    end
    ReleasePools()

    local weeklySec = Data.GetSecondsUntilWeeklyReset()
    if weeklySec then
        weeklyText:SetText(string.format(L["WEEKLY_RESET"], Data.FormatDuration(weeklySec)))
    else
        weeklyText:SetText(L["WEEKLY_RESET_UNKNOWN"])
    end

    Catalog.GetTiers()
    local chars = GetEnabledCharacters()
    local raids = BuildVisibleRaids()

    if #chars == 0 then
        local hint = AcquireFont(content, "GameFontNormal")
        hint:SetPoint("TOPLEFT", PAD, -PAD)
        hint:SetText(L["NO_CHARACTERS"])
        content:SetSize(400, 60)
        scrollChild:SetSize(400, 60)
        return
    end

    if #raids == 0 then
        local hint = AcquireFont(content, "GameFontNormal")
        hint:SetPoint("TOPLEFT", PAD, -PAD)
        hint:SetText(L["NO_TRACKED"])
        content:SetSize(400, 60)
        scrollChild:SetSize(400, 60)
        return
    end

    local width = LABEL_W + (#chars * CELL_W) + PAD * 2
    local height = HEADER_H + PAD

    -- Header: empty corner + character names
    local corner = AcquireFont(content, "GameFontNormalSmall")
    corner:SetPoint("TOPLEFT", PAD, -PAD)
    corner:SetSize(LABEL_W - 4, HEADER_H)
    corner:SetJustifyV("BOTTOM")
    corner:SetText(L["COL_CHARACTERS"] or "Characters")

    for i, entry in ipairs(chars) do
        local colX = PAD + LABEL_W + (i - 1) * CELL_W
        local nameFS = AcquireFont(content, "GameFontNormalSmall")
        nameFS:SetPoint("TOPLEFT", colX, -PAD)
        nameFS:SetSize(CELL_W, HEADER_NAME_H)
        nameFS:SetJustifyH("CENTER")
        nameFS:SetJustifyV("BOTTOM")
        nameFS:SetWordWrap(true)
        nameFS:SetText(CharacterDisplayName(entry.data))
        local r, g, b = ClassColor(entry.data.class)
        nameFS:SetTextColor(r, g, b)

        local level = tonumber(entry.data.level) or 0
        if level > 0 then
            local lvlFS = AcquireFont(content, "GameFontHighlightSmall")
            lvlFS:SetPoint("TOPLEFT", colX, -(PAD + HEADER_NAME_H))
            lvlFS:SetSize(CELL_W, HEADER_LEVEL_H)
            lvlFS:SetJustifyH("CENTER")
            lvlFS:SetJustifyV("TOP")
            lvlFS:SetText(tostring(level))
            lvlFS:SetTextColor(0.7, 0.7, 0.7)
        end
    end

    local y = -(PAD + HEADER_H)
    height = height + PAD

    for _, raid in ipairs(raids) do
        local collapsed = DB.IsRaidCollapsedMain(raid.instanceId)
        local raidBtn = AcquireButton(content)
        raidBtn:SetSize(width - PAD * 2, RAID_ROW_H)
        raidBtn:SetPoint("TOPLEFT", PAD, y)
        local arrow = collapsed and L["COLLAPSED"] or L["EXPANDED"]
        raidBtn.text:SetJustifyH("LEFT")
        raidBtn.text:SetText(string.format("%s %s", arrow, raid.name))
        raidBtn.text:SetTextColor(COLORS.raid[1], COLORS.raid[2], COLORS.raid[3])
        local instanceId = raid.instanceId
        raidBtn:SetScript("OnClick", function()
            DB.SetRaidCollapsedMain(instanceId, not DB.IsRaidCollapsedMain(instanceId))
            UI.Refresh()
        end)
        y = y - RAID_ROW_H
        height = height + RAID_ROW_H

        if not collapsed then
            for _, diffId in ipairs(raid.difficulties) do
                local label = AcquireFont(content, "GameFontHighlightSmall")
                label:SetPoint("TOPLEFT", PAD + 14, y)
                label:SetSize(LABEL_W - 18, ROW_H)
                label:SetJustifyH("LEFT")
                label:SetJustifyV("MIDDLE")
                label:SetText(Catalog.GetDifficultyLabel(diffId))
                label:SetTextColor(1, 1, 1)

                for i, entry in ipairs(chars) do
                    local status, progress, total = Data.GetLockoutStatus(entry.guid, raid.instanceId, diffId)
                    local text, color = FormatCell(status, progress, total)
                    local btn = AcquireButton(content)
                    btn:SetSize(CELL_W - 2, CELL_H)
                    btn:SetPoint("TOPLEFT", PAD + LABEL_W + (i - 1) * CELL_W + 1, y - 1)
                    btn.text:SetJustifyH("CENTER")
                    btn.text:SetText(text)
                    btn.text:SetTextColor(color[1], color[2], color[3])
                    local guid, iid, did, rname = entry.guid, raid.instanceId, diffId, raid.name
                    btn:SetScript("OnEnter", function(self)
                        ShowCellTooltip(self, guid, iid, did, rname)
                    end)
                end

                y = y - ROW_H
                height = height + ROW_H
            end
        end
    end

    height = height + PAD
    content:SetSize(math.max(width, 400), math.max(height, 80))
    scrollChild:SetSize(math.max(width, 400), math.max(height, 80))
    if ns.UI and ns.UI.UpdateScroll then
        ns.UI.UpdateScroll(scrollFrame)
    end
end

local function CreateMainFrame()
    if frame then
        return frame
    end

    frame = CreateFrame("Frame", "ALIMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "ALIMainFrame")

    if ns.UI and ns.UI.EnableResize then
        ns.UI.EnableResize(frame, "main")
    else
        frame:SetSize(760, 460)
        frame:SetPoint("CENTER", -40, 20)
    end
    if not frame:GetPoint() then
        frame:SetPoint("CENTER", -40, 20)
    end

    frame.TitleText:SetText(L["OPEN_STATUS"] or "Raid Lockouts")

    -- Toolbar under title bar: weekly reset
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 12, -28)
    toolbar:SetPoint("TOPRIGHT", -30, -28)
    toolbar:SetHeight(22)

    weeklyText = toolbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    weeklyText:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    weeklyText:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    weeklyText:SetJustifyH("LEFT")
    weeklyText:SetJustifyV("MIDDLE")
    weeklyText:SetText("")

    -- Leave room for V scrollbar (right) and H scrollbar (bottom) + resize grip
    if ns.UI and ns.UI.CreateScrollArea then
        scrollFrame, scrollChild = ns.UI.CreateScrollArea(frame, "ALIMainScroll")
    else
        scrollFrame = CreateFrame("ScrollFrame", "ALIMainScroll", frame, "UIPanelScrollFrameTemplate")
        scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetSize(1, 1)
        scrollFrame:SetScrollChild(scrollChild)
    end
    scrollFrame:SetPoint("TOPLEFT", 12, -54)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 28)

    frame._aliOnResized = function()
        if ns.UI and ns.UI.UpdateScroll then
            ns.UI.UpdateScroll(scrollFrame)
        end
    end

    frame:SetScript("OnShow", function()
        frame:SetFrameStrata("HIGH")
        frame:SetFrameLevel(100)
        UI.Refresh()
        if frame.ticker then
            frame.ticker:Cancel()
        end
        frame.ticker = C_Timer.NewTicker(30, function()
            if frame:IsShown() then
                local weeklySec = Data.GetSecondsUntilWeeklyReset()
                if weeklySec and weeklyText then
                    weeklyText:SetText(string.format(L["WEEKLY_RESET"], Data.FormatDuration(weeklySec)))
                end
            end
        end)
    end)
    frame:SetScript("OnHide", function()
        if frame.ticker then
            frame.ticker:Cancel()
            frame.ticker = nil
        end
    end)

    return frame
end

function UI.Show()
    CreateMainFrame()
    frame:Show()
    UI.Refresh()
end

function UI.Hide()
    if frame then
        frame:Hide()
    end
end

function UI.Toggle()
    CreateMainFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        UI.Show()
    end
end

function UI.IsShown()
    return frame and frame:IsShown()
end
