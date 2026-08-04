local addonName, ns = ...

ns.UI_Options = ns.UI_Options or {}
local UI = ns.UI_Options
local DB = ns.DB
local Catalog = ns.Catalog
local Mounts = ns.Mounts
local L = ns.L

local frame
local scrollFrame
local scrollChild
local content
local tabButtons = {}
local currentTab = "raids"
-- Reset scroll only on tab change / first show; preserve during progress refresh.
local resetScrollOnNextRefresh = true
local mountCollectedEventsRegistered = false
local debugPanel
local debugEditBox
local debugScroll
local debugPendingRefresh
local TAB_W = 100
local TAB_GAP = 4

local widgetPool = {
    check = {},
    button = {},
    toggle = {},
    font = {},
}
local active = {
    check = {},
    button = {},
    toggle = {},
    font = {},
}

local DIFF_COL_W = 110
local RAID_NAME_W = 170
local MOUNT_NAME_W = 160
local MOUNT_RAID_W = 140
local ROW_H = 24
local TAB_H = 24

local function RefreshMainIfOpen()
    if ns.UI_Main and ns.UI_Main.IsShown and ns.UI_Main.IsShown() then
        ns.UI_Main.Refresh()
    end
end

local function ReleasePools()
    for kind, list in pairs(active) do
        for i = #list, 1, -1 do
            local w = list[i]
            list[i] = nil
            w:Hide()
            w:ClearAllPoints()
            if w.SetScript and (kind == "check" or kind == "button" or kind == "toggle") then
                w:SetScript("OnClick", nil)
                w:SetScript("OnEnter", nil)
                w:SetScript("OnLeave", nil)
            end
            if kind == "check" then
                if w.Text then
                    w.Text:SetText("")
                    w.Text:Hide()
                end
            end
            w:SetParent(nil)
            widgetPool[kind][#widgetPool[kind] + 1] = w
        end
    end
end

local function AcquireFont(parent, template)
    local fs = table.remove(widgetPool.font)
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    else
        fs:SetParent(parent)
        if fs.SetFontObject and template then
            fs:SetFontObject(template)
        end
    end
    -- Force white for normal labels (pool may leak class colors); keep disable style gray.
    if template and string.find(template, "Disable", 1, true) then
        fs:SetTextColor(0.5, 0.5, 0.5)
    else
        fs:SetTextColor(1, 1, 1)
    end
    fs:Show()
    active.font[#active.font + 1] = fs
    return fs
end

local function AcquireCheckbox(parent)
    local cb = table.remove(widgetPool.check)
    if not cb then
        cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
    else
        cb:SetParent(parent)
    end
    if cb.Text then
        cb.Text:SetText("")
        cb.Text:Hide()
    end
    cb:Show()
    active.check[#active.check + 1] = cb
    return cb
end

local function AcquireButton(parent)
    local b = table.remove(widgetPool.button)
    if not b then
        b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(140, 22)
    else
        b:SetParent(parent)
    end
    b:Show()
    active.button[#active.button + 1] = b
    return b
end

local function AcquireToggle(parent)
    local b = table.remove(widgetPool.toggle)
    if not b then
        b = CreateFrame("Button", nil, parent)
        b:SetSize(500, 22)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetAllPoints()
        fs:SetJustifyH("LEFT")
        b:SetFontString(fs)
    else
        b:SetParent(parent)
    end
    b:Show()
    active.toggle[#active.toggle + 1] = b
    return b
end

local function MakeCheckbox(parent, onClick)
    local cb = AcquireCheckbox(parent)
    cb:SetScript("OnClick", function(self)
        onClick(self:GetChecked())
    end)
    return cb
end

local function MakeButton(parent, text, width, onClick)
    local b = AcquireButton(parent)
    b:SetSize(width or 140, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeToggleRow(parent, text, width, height, onClick)
    local b = AcquireToggle(parent)
    b:SetSize(width or 500, height or 22)
    local fs = b:GetFontString()
    if fs then
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
    end
    b:SetScript("OnClick", onClick)
    return b
end

--- Truncate by UTF-8 characters (not bytes) so Cyrillic realm names stay intact.
local function Truncate(text, maxLen)
    text = text or ""
    local chars = {}
    local i = 1
    local n = #text
    while i <= n do
        local c = text:byte(i)
        local len = 1
        if c >= 0xF0 then
            len = 4
        elseif c >= 0xE0 then
            len = 3
        elseif c >= 0xC0 then
            len = 2
        end
        chars[#chars + 1] = text:sub(i, i + len - 1)
        i = i + len
    end
    if #chars <= maxLen then
        return text
    end
    local out = {}
    for j = 1, maxLen - 1 do
        out[j] = chars[j]
    end
    return table.concat(out) .. "..."
end

local function GetTrackedRaidColumns()
    return Catalog.GetTrackedColumns() or {}
end

local function GetActiveTab()
    local ui = DB.GetUI and DB.GetUI()
    if ui and (ui.optionsTab == "raids" or ui.optionsTab == "chars"
        or ui.optionsTab == "notes" or ui.optionsTab == "mounts"
        or ui.optionsTab == "debug") then
        return ui.optionsTab
    end
    return currentTab or "raids"
end

local function SetActiveTab(tab)
    currentTab = tab
    local ui = DB.GetUI and DB.GetUI()
    if ui then
        ui.optionsTab = tab
    end
end

local function UpdateTabVisuals()
    local activeId = GetActiveTab()
    for id, btn in pairs(tabButtons) do
        if btn then
            if id == activeId then
                btn:Disable()
                btn:SetButtonState("DISABLED", true)
            else
                btn:Enable()
                btn:SetButtonState("NORMAL")
            end
        end
    end
end

local function EnsureCatalogReady()
    Catalog.EnsureEJ()
    -- Do not force-rebuild on every Options refresh (freezes UI during mounts scan).
    if Catalog.EnsureReady then
        Catalog.EnsureReady()
    else
        Catalog.GetTiers(false)
    end
    Catalog.EnsureTrackedEntries()
    if not DB.IsDefaultsApplied() then
        Catalog.ApplyCurrentTierDefaults(false)
    end
    if ns.Data and ns.Data.RemapLockoutsToJournalIds then
        ns.Data.RemapLockoutsToJournalIds()
    end
    if Catalog.IsReady() and ns.OnCatalogReady and not UI._catalogReadyNotified then
        UI._catalogReadyNotified = true
        ns.OnCatalogReady()
    end
end

local function CaptureScroll()
    local v, h = 0, 0
    if scrollFrame then
        if scrollFrame.GetVerticalScroll then
            v = scrollFrame:GetVerticalScroll() or 0
        end
        if scrollFrame.GetHorizontalScroll then
            h = scrollFrame:GetHorizontalScroll() or 0
        end
    end
    return v, h
end

local function ApplyScroll(v, h)
    if not scrollFrame then
        return
    end
    if scrollFrame.SetVerticalScroll then
        scrollFrame:SetVerticalScroll(v or 0)
    end
    if scrollFrame.SetHorizontalScroll then
        scrollFrame:SetHorizontalScroll(h or 0)
    end
end

local function LayoutContent(y, width)
    local totalH = math.abs(y) + 20
    content:SetSize(width, totalH)
    scrollChild:SetSize(width, totalH)
    if ns.UI and ns.UI.UpdateScroll then
        ns.UI.UpdateScroll(scrollFrame)
    end
end

local function BuildRaidsTab(y, width)
    local btnDisable = MakeButton(content, L["OPTIONS_DISABLE_ALL"], 150, function()
        DB.DisableAllTracked()
        UI.Refresh()
        RefreshMainIfOpen()
    end)
    btnDisable:SetPoint("TOPLEFT", 8, y)

    local currentOn = Catalog.IsCurrentContentFullyTracked and Catalog.IsCurrentContentFullyTracked()
    local currentLabel = currentOn and (L["OPTIONS_DISABLE_CURRENT"] or "Disable current")
        or (L["OPTIONS_ENABLE_CURRENT"] or "Enable current")
    local btnCurrent = MakeButton(content, currentLabel, 170, function()
        if Catalog.ToggleCurrentContentTracked then
            Catalog.ToggleCurrentContentTracked()
        else
            Catalog.ApplyCurrentTierDefaults(true)
        end
        UI.Refresh()
        RefreshMainIfOpen()
    end)
    btnCurrent:SetPoint("LEFT", btnDisable, "RIGHT", 8, 0)
    y = y - 30

    local raidsHeader = AcquireFont(content, "GameFontNormalLarge")
    raidsHeader:SetPoint("TOPLEFT", 8, y)
    raidsHeader:SetText(L["OPTIONS_RAIDS"])
    y = y - 24

    local tiers = Catalog.GetTiersForUI and Catalog.GetTiersForUI() or Catalog.GetTiers()
    for _, tier in ipairs(tiers) do
        local tierLabel = tier.name or ("Tier " .. tier.index)
        local collapsed = DB.IsTierCollapsed(tier.index)
        local arrow = collapsed and L["COLLAPSED"] or L["EXPANDED"]
        local tierIdx = tier.index
        local tierBtn = MakeToggleRow(content, string.format("|cffffd100%s %s|r", arrow, tierLabel), width - 20, 22, function()
            DB.SetTierCollapsed(tierIdx, not DB.IsTierCollapsed(tierIdx))
            UI.Refresh()
        end)
        tierBtn:SetPoint("TOPLEFT", 8, y)
        y = y - 24

        if not collapsed then
            for _, raid in ipairs(tier.raids) do
                local diffs = raid.difficulties or {}
                if #diffs == 0 then
                    local emptyFs = AcquireFont(content, "GameFontDisableSmall")
                    emptyFs:SetPoint("TOPLEFT", 24, y)
                    emptyFs:SetSize(width - 40, ROW_H)
                    emptyFs:SetJustifyH("LEFT")
                    emptyFs:SetText(string.format("%s — %s", raid.name, L["NO_DIFFICULTIES"] or "no difficulties"))
                    y = y - 18
                else
                    local allOn = true
                    for _, d in ipairs(diffs) do
                        if not DB.IsTracked(raid.instanceId, d) then
                            allOn = false
                            break
                        end
                    end

                    local raidCb = MakeCheckbox(content, function(checked)
                        DB.SetRaidTracked(raid.instanceId, diffs, checked)
                        UI.Refresh()
                        RefreshMainIfOpen()
                    end)
                    raidCb:SetPoint("TOPLEFT", 20, y)
                    raidCb:SetChecked(allOn)

                    local raidNameFS = AcquireFont(content, "GameFontHighlightSmall")
                    raidNameFS:SetPoint("LEFT", raidCb, "RIGHT", 4, 0)
                    raidNameFS:SetSize(RAID_NAME_W, ROW_H)
                    raidNameFS:SetJustifyH("LEFT")
                    raidNameFS:SetJustifyV("MIDDLE")
                    raidNameFS:SetText(raid.name or "?")

                    local dx = 28 + 24 + RAID_NAME_W
                    for _, diffId in ipairs(diffs) do
                        local dCb = MakeCheckbox(content, function(checked)
                            DB.SetTracked(raid.instanceId, diffId, checked)
                            RefreshMainIfOpen()
                            UI.Refresh()
                        end)
                        dCb:SetPoint("TOPLEFT", dx, y)
                        dCb:SetChecked(DB.IsTracked(raid.instanceId, diffId))

                        local dFS = AcquireFont(content, "GameFontHighlightSmall")
                        dFS:SetPoint("LEFT", dCb, "RIGHT", 1, 0)
                        dFS:SetSize(DIFF_COL_W - 26, ROW_H)
                        dFS:SetJustifyH("LEFT")
                        dFS:SetJustifyV("MIDDLE")
                        dFS:SetText(Catalog.GetDifficultyLabel(diffId))
                        dFS:SetTextColor(1, 1, 1)

                        dx = dx + DIFF_COL_W
                    end
                    y = y - ROW_H
                end
            end
            y = y - 6
        end
    end

    return y, width
end

local function BuildCharsTab(y, width)
    local trackedRaids = GetTrackedRaidColumns()
    width = math.max(width, 24 + 160 + 36 + 6 * 56)

    local hint = AcquireFont(content, "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 8, y)
    hint:SetSize(width - 16, 32)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText(L["OPTIONS_CHAR_TABLE_HINT"] or "Expand a character. Hide disables the whole raid.")
    y = y - 28

    local chars = {}
    for guid, char in pairs(DB.GetCharacters()) do
        chars[#chars + 1] = { guid = guid, data = char }
    end
    table.sort(chars, function(a, b)
        return (a.data.name or "") < (b.data.name or "")
    end)

    if #chars == 0 then
        local empty = AcquireFont(content, "GameFontHighlightSmall")
        empty:SetPoint("TOPLEFT", 16, y)
        empty:SetText(L["NO_CHARACTERS"])
        y = y - 20
        return y, width
    end

    local RAID_LABEL_W = 160
    local HIDE_COL_W = 36
    local DIFF_CELL_W = 56

    for _, entry in ipairs(chars) do
        local char = entry.data
        local guid = entry.guid
        local collapsed = DB.IsCharCollapsed(guid)
        local arrow = collapsed and L["COLLAPSED"] or L["EXPANDED"]

        local display = char.name or "?"
        if char.level and char.level > 0 then
            display = display .. " (" .. char.level .. ")"
        end
        local playerRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
        if char.realm and char.realm ~= "" and char.realm ~= playerRealm then
            display = display .. "-" .. Truncate(char.realm, 10)
        end

        local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.class]
        local colored = display
        if classColor then
            colored = string.format("|cff%02x%02x%02x%s|r",
                (classColor.r or 1) * 255,
                (classColor.g or 1) * 255,
                (classColor.b or 1) * 255,
                display)
        end

        local charBtn = MakeToggleRow(content,
            string.format("%s %s", arrow, colored),
            width - 60, 22,
            function()
                DB.SetCharCollapsed(guid, not DB.IsCharCollapsed(guid))
                UI.Refresh()
            end)
        charBtn:SetPoint("TOPLEFT", 8, y)

        local trackCb = MakeCheckbox(content, function(checked)
            DB.SetCharacterEnabled(guid, checked)
            RefreshMainIfOpen()
        end)
        trackCb:SetPoint("LEFT", charBtn, "RIGHT", 4, 0)
        trackCb:SetChecked(char.enabled ~= false)
        trackCb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(L["OPTIONS_CHAR_ENABLED"] or "Track character", 1, 0.82, 0)
            GameTooltip:Show()
        end)
        trackCb:SetScript("OnLeave", GameTooltip_Hide)

        y = y - ROW_H

        if not collapsed then
            if #trackedRaids == 0 then
                local noRaids = AcquireFont(content, "GameFontDisableSmall")
                noRaids:SetPoint("TOPLEFT", 28, y)
                noRaids:SetText(L["NO_TRACKED"] or "No raids tracked")
                y = y - 18
            else
                local diffCols = {}
                local seenDiff = {}
                for _, raid in ipairs(trackedRaids) do
                    for _, d in ipairs(raid.difficulties or {}) do
                        if not seenDiff[d] then
                            seenDiff[d] = true
                            diffCols[#diffCols + 1] = d
                        end
                    end
                end
                table.sort(diffCols, function(a, b)
                    return Catalog.GetDifficultyOrder(a) < Catalog.GetDifficultyOrder(b)
                end)

                local tableLeft = 24
                local hRaid = AcquireFont(content, "GameFontNormalSmall")
                hRaid:SetPoint("TOPLEFT", tableLeft, y)
                hRaid:SetSize(RAID_LABEL_W, ROW_H)
                hRaid:SetJustifyH("LEFT")
                hRaid:SetJustifyV("MIDDLE")
                hRaid:SetText(L["OPTIONS_COL_RAID"] or "Raid")
                hRaid:SetTextColor(1, 0.82, 0)

                local hHide = AcquireFont(content, "GameFontNormalSmall")
                hHide:SetPoint("TOPLEFT", tableLeft + RAID_LABEL_W, y)
                hHide:SetSize(HIDE_COL_W, ROW_H)
                hHide:SetJustifyH("CENTER")
                hHide:SetJustifyV("MIDDLE")
                hHide:SetText(L["OPTIONS_COL_HIDE"] or "Hide")
                hHide:SetTextColor(1, 0.82, 0)

                for i, diffId in ipairs(diffCols) do
                    local hDiff = AcquireFont(content, "GameFontNormalSmall")
                    hDiff:SetPoint("TOPLEFT", tableLeft + RAID_LABEL_W + HIDE_COL_W + (i - 1) * DIFF_CELL_W, y)
                    hDiff:SetSize(DIFF_CELL_W - 2, ROW_H)
                    hDiff:SetJustifyH("CENTER")
                    hDiff:SetJustifyV("MIDDLE")
                    hDiff:SetText(Catalog.GetDifficultyLabel(diffId))
                    hDiff:SetTextColor(1, 0.82, 0)
                end
                y = y - ROW_H

                for _, raid in ipairs(trackedRaids) do
                    local raidNameFS = AcquireFont(content, "GameFontHighlightSmall")
                    raidNameFS:SetPoint("TOPLEFT", tableLeft, y)
                    raidNameFS:SetSize(RAID_LABEL_W - 2, ROW_H)
                    raidNameFS:SetJustifyH("LEFT")
                    raidNameFS:SetJustifyV("MIDDLE")
                    raidNameFS:SetText(raid.name or "?")

                    local hideCb = MakeCheckbox(content, function(checked)
                        DB.SetCharacterRaidDisabled(guid, raid.instanceId, checked)
                        RefreshMainIfOpen()
                    end)
                    hideCb:SetPoint("TOPLEFT", tableLeft + RAID_LABEL_W + (HIDE_COL_W - 24) / 2, y)
                    hideCb:SetChecked(DB.IsCharacterRaidDisabled(guid, raid.instanceId))
                    local raidName = raid.name or "?"
                    hideCb:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(string.format(L["OPTIONS_CHAR_RAID_HIDE"], raidName), 1, 0.82, 0)
                        GameTooltip:Show()
                    end)
                    hideCb:SetScript("OnLeave", GameTooltip_Hide)

                    local trackedSet = {}
                    for _, d in ipairs(raid.difficulties or {}) do
                        trackedSet[d] = true
                    end

                    for i, diffId in ipairs(diffCols) do
                        local cell = AcquireFont(content, "GameFontHighlightSmall")
                        cell:SetPoint("TOPLEFT", tableLeft + RAID_LABEL_W + HIDE_COL_W + (i - 1) * DIFF_CELL_W, y)
                        cell:SetSize(DIFF_CELL_W - 2, ROW_H)
                        cell:SetJustifyH("CENTER")
                        cell:SetJustifyV("MIDDLE")
                        if trackedSet[diffId] then
                            cell:SetText("•")
                            cell:SetTextColor(0.7, 0.9, 0.7)
                        else
                            cell:SetText("—")
                            cell:SetTextColor(0.4, 0.4, 0.4)
                        end
                    end

                    y = y - ROW_H
                end
            end
            y = y - 6
        end
    end

    return y, width
end

local function BuildNotesTab(y, width)
    local notes = AcquireFont(content, "GameFontHighlightSmall")
    notes:SetPoint("TOPLEFT", 12, y)
    notes:SetWidth(width - 24)
    notes:SetJustifyH("LEFT")
    notes:SetText(L["NOTES_TEXT"] or "")
    local notesH = notes:GetStringHeight() or 60
    y = y - notesH - 16
    return y, width
end

local function SetDebugEditText(text)
    if not debugEditBox then
        return
    end
    text = text or ""
    debugEditBox:SetText(text)
    debugEditBox:SetCursorPosition(0)
    local lines = 1
    for _ in text:gmatch("\n") do
        lines = lines + 1
    end
    local fh = 14
    if debugEditBox.GetFont then
        local _, size = debugEditBox:GetFont()
        if size and size > 0 then
            fh = size
        end
    end
    local minH = (debugScroll and debugScroll.GetHeight and debugScroll:GetHeight()) or 200
    debugEditBox:SetHeight(math.max(minH, lines * (fh + 2) + 16))
    if debugScroll and debugScroll.SetVerticalScroll then
        debugScroll:SetVerticalScroll(0)
    end
end

local function RefreshDebugDump(requestRaidInfo)
    local Data = ns.Data
    local lines = Data and Data.DumpDebugLockouts and Data.DumpDebugLockouts(not requestRaidInfo)
        or { "debug unavailable" }
    SetDebugEditText(table.concat(lines, "\n"))
    if requestRaidInfo and C_Timer and C_Timer.After then
        local token = {}
        debugPendingRefresh = token
        C_Timer.After(0.6, function()
            if debugPendingRefresh ~= token or not frame or not frame:IsShown() then
                return
            end
            if GetActiveTab() ~= "debug" then
                return
            end
            local again = Data and Data.DumpDebugLockouts and Data.DumpDebugLockouts(true) or lines
            SetDebugEditText(table.concat(again, "\n"))
        end)
    end
end

local function EnsureDebugPanel()
    if debugPanel or not frame then
        return
    end

    debugPanel = CreateFrame("Frame", nil, frame)
    debugPanel:SetPoint("TOPLEFT", 12, -56)
    debugPanel:SetPoint("BOTTOMRIGHT", -28, 28)
    debugPanel:Hide()

    local hint = debugPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 0, 0)
    hint:SetPoint("TOPRIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["DEBUG_COPY_HINT"] or "Ctrl+A, then Ctrl+C to copy")

    local btnRefresh = CreateFrame("Button", nil, debugPanel, "UIPanelButtonTemplate")
    btnRefresh:SetSize(90, 22)
    btnRefresh:SetPoint("BOTTOMLEFT", 0, 0)
    btnRefresh:SetText(L["DEBUG_REFRESH"] or "Refresh")
    btnRefresh:SetScript("OnClick", function()
        RefreshDebugDump(true)
    end)

    local btnSelect = CreateFrame("Button", nil, debugPanel, "UIPanelButtonTemplate")
    btnSelect:SetSize(120, 22)
    btnSelect:SetPoint("LEFT", btnRefresh, "RIGHT", 8, 0)
    btnSelect:SetText(L["DEBUG_SELECT"] or "Select all")
    btnSelect:SetScript("OnClick", function()
        if debugEditBox then
            debugEditBox:SetFocus()
            debugEditBox:HighlightText()
        end
    end)

    local btnClearCache = CreateFrame("Button", nil, debugPanel, "UIPanelButtonTemplate")
    btnClearCache:SetSize(180, 22)
    btnClearCache:SetPoint("LEFT", btnSelect, "RIGHT", 8, 0)
    btnClearCache:SetText(L["DEBUG_CLEAR_MOUNTS_CACHE"] or "Clear mounts cache")
    btnClearCache:SetScript("OnClick", function()
        if Mounts and Mounts.ClearPersistedCache then
            Mounts.ClearPersistedCache()
        elseif DB and DB.ClearMountsCache then
            DB.ClearMountsCache()
        end
        if Mounts and Mounts.StartScanIfNeeded then
            Mounts.StartScanIfNeeded()
        end
        if UI.RefreshMountsProgress then
            UI.RefreshMountsProgress()
        end
        print("|cff00ccffALI|r " .. (L["DEBUG_MOUNTS_CACHE_CLEARED"] or "Mounts cache cleared."))
        RefreshDebugDump(false)
    end)

    debugScroll = CreateFrame("ScrollFrame", "ALIOptionsDebugScroll", debugPanel, "UIPanelScrollFrameTemplate")
    debugScroll:SetPoint("TOPLEFT", 0, -18)
    debugScroll:SetPoint("BOTTOMRIGHT", -22, 28)

    debugEditBox = CreateFrame("EditBox", "ALIOptionsDebugEdit", debugScroll)
    debugEditBox:SetMultiLine(true)
    debugEditBox:SetFontObject(ChatFontNormal)
    debugEditBox:SetAutoFocus(false)
    debugEditBox:EnableMouse(true)
    debugEditBox:SetTextInsets(4, 4, 4, 4)
    debugEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local function SyncEditWidth()
        local w = debugScroll:GetWidth()
        if w and w > 20 then
            debugEditBox:SetWidth(w - 8)
        end
    end
    debugScroll:SetScrollChild(debugEditBox)
    debugScroll:HookScript("OnSizeChanged", SyncEditWidth)
    SyncEditWidth()
end

local function ShowDebugPanel(show)
    EnsureDebugPanel()
    if not debugPanel then
        return
    end
    if show then
        if scrollFrame then
            scrollFrame:Hide()
        end
        debugPanel:Show()
        RefreshDebugDump(true)
    else
        debugPanel:Hide()
        if scrollFrame then
            scrollFrame:Show()
        end
    end
end

local function ShowMountItemTooltip(owner, itemID)
    if not GameTooltip or not itemID then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(itemID)
    elseif GameTooltip.SetHyperlink then
        GameTooltip:SetHyperlink("item:" .. tostring(itemID))
    else
        GameTooltip:AddLine(tostring(itemID), 1, 1, 1)
    end
    GameTooltip:Show()
end

local function BuildMountsTab(y, width)
    width = math.max(width, 28 + 24 + MOUNT_NAME_W + MOUNT_RAID_W + 4 * DIFF_COL_W)

    local showCollected = DB.GetShowCollectedMounts and DB.GetShowCollectedMounts() or false
    local showCb = MakeCheckbox(content, function(checked)
        if DB.SetShowCollectedMounts then
            DB.SetShowCollectedMounts(checked)
        end
        UI.Refresh()
    end)
    showCb:SetPoint("TOPLEFT", 8, y)
    showCb:SetChecked(showCollected)

    local showLabel = AcquireFont(content, "GameFontHighlightSmall")
    showLabel:SetPoint("LEFT", showCb, "RIGHT", 4, 0)
    showLabel:SetJustifyH("LEFT")
    showLabel:SetText(L["OPTIONS_MOUNTS_SHOW_COLLECTED"] or "Show collected")
    y = y - 28

    if not Mounts then
        local missing = AcquireFont(content, "GameFontDisableSmall")
        missing:SetPoint("TOPLEFT", 16, y)
        missing:SetText(L["OPTIONS_MOUNTS_EMPTY"] or "No raid mounts found.")
        return y - 20, width
    end

    -- Non-blocking: kick chunked EJ scan; keep last complete rows visible mid-scan.
    if Mounts.StartScanIfNeeded then
        Mounts.StartScanIfNeeded()
    elseif Mounts.EnsureReady then
        Mounts.EnsureReady()
    end

    local ready = Mounts.IsReady and Mounts.IsReady()
    local scanning = Mounts.IsScanning and Mounts.IsScanning()
    -- Dirty but not scanning: EJ/catalog not ready yet — do not claim "Collecting…".
    local waiting = (not ready) and (not scanning)
        and Mounts.IsDirty and Mounts.IsDirty()
    local rows = Mounts.GetRowsForUI and Mounts.GetRowsForUI(showCollected) or {}

    if scanning then
        local status = AcquireFont(content, "GameFontDisableSmall")
        status:SetPoint("TOPLEFT", 16, y)
        local statusText = L["OPTIONS_MOUNTS_COLLECTING"]
            or "Collecting mount data and caching..."
        local progress = Mounts.GetScanProgress and Mounts.GetScanProgress()
        if progress and progress.total and progress.total > 0 and progress.index then
            local detail = progress.label and (tostring(progress.label) .. " - ") or ""
            statusText = statusText .. " (" .. detail
                .. tostring(progress.index) .. "/" .. tostring(progress.total) .. ")"
        end
        status:SetText(statusText)
        y = y - 20
        if #rows == 0 then
            return y, width
        end
    elseif waiting then
        local status = AcquireFont(content, "GameFontDisableSmall")
        status:SetPoint("TOPLEFT", 16, y)
        status:SetText(L["OPTIONS_MOUNTS_SCANNING"] or "Scanning Encounter Journal...")
        y = y - 20
        if #rows == 0 then
            return y, width
        end
    elseif #rows == 0 then
        local empty = AcquireFont(content, "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", 16, y)
        empty:SetText(L["OPTIONS_MOUNTS_EMPTY"] or "No raid mounts found.")
        return y - 20, width
    end
    -- When ready and cached: no scanning message; show list immediately.

    -- Group rows by tierIndex while preserving sort order from Mounts.
    local groups = {}
    local groupOrder = {}
    for _, row in ipairs(rows) do
        local key = row.tierIndex or 0
        if not groups[key] then
            groups[key] = {
                tierIndex = key,
                tierName = row.tierName or ("Tier " .. tostring(key)),
                rows = {},
            }
            groupOrder[#groupOrder + 1] = key
        end
        groups[key].rows[#groups[key].rows + 1] = row
    end

    for _, tierKey in ipairs(groupOrder) do
        local group = groups[tierKey]
        local collapsed = DB.IsMountTierCollapsed and DB.IsMountTierCollapsed(group.tierIndex)
        local arrow = collapsed and L["COLLAPSED"] or L["EXPANDED"]
        local tierIdx = group.tierIndex
        local tierBtn = MakeToggleRow(content,
            string.format("|cffffd100%s %s|r", arrow, group.tierName),
            width - 20, 22,
            function()
                if DB.SetMountTierCollapsed then
                    DB.SetMountTierCollapsed(tierIdx, not DB.IsMountTierCollapsed(tierIdx))
                end
                UI.Refresh()
            end)
        tierBtn:SetPoint("TOPLEFT", 8, y)
        y = y - 24

        if not collapsed then
            for _, row in ipairs(group.rows) do
                local diffs = (Mounts.GetTrackingDiffs and Mounts.GetTrackingDiffs(row))
                    or row.difficulties
                    or {}
                local allOn = Mounts.IsFullyTracked(row.instanceId, diffs)

                local masterCb = MakeCheckbox(content, function(checked)
                    Mounts.SetFullyTracked(row.instanceId, diffs, checked)
                    UI.Refresh()
                    RefreshMainIfOpen()
                end)
                masterCb:SetPoint("TOPLEFT", 20, y)
                masterCb:SetChecked(allOn)

                local nameBtn = MakeToggleRow(content, row.name or "?", MOUNT_NAME_W, ROW_H, function() end)
                nameBtn:SetPoint("LEFT", masterCb, "RIGHT", 4, 0)
                nameBtn:SetScript("OnEnter", function(self)
                    ShowMountItemTooltip(self, row.itemID)
                end)
                nameBtn:SetScript("OnLeave", GameTooltip_Hide)

                local raidFS = AcquireFont(content, "GameFontHighlightSmall")
                raidFS:SetPoint("LEFT", nameBtn, "RIGHT", 6, 0)
                raidFS:SetSize(MOUNT_RAID_W, ROW_H)
                raidFS:SetJustifyH("LEFT")
                raidFS:SetJustifyV("MIDDLE")
                raidFS:SetText(row.raidName or "?")

                local dx = 20 + 24 + 4 + MOUNT_NAME_W + 6 + MOUNT_RAID_W
                if #diffs == 0 then
                    -- No encounter/difficulty ids yet (scan incomplete or empty EJ).
                    masterCb:Disable()
                    masterCb:SetChecked(false)
                    local noDiffFS = AcquireFont(content, "GameFontDisableSmall")
                    noDiffFS:SetPoint("TOPLEFT", dx, y)
                    noDiffFS:SetSize(DIFF_COL_W * 2, ROW_H)
                    noDiffFS:SetJustifyH("LEFT")
                    noDiffFS:SetJustifyV("MIDDLE")
                    noDiffFS:SetText(L["OPTIONS_MOUNTS_NO_DIFFICULTY"] or "No difficulties")
                else
                    for _, diffId in ipairs(diffs) do
                        local dCb = MakeCheckbox(content, function(checked)
                            DB.SetTracked(row.instanceId, diffId, checked)
                            UI.Refresh()
                            RefreshMainIfOpen()
                        end)
                        dCb:SetPoint("TOPLEFT", dx, y)
                        dCb:SetChecked(DB.IsTracked(row.instanceId, diffId))

                        local dFS = AcquireFont(content, "GameFontHighlightSmall")
                        dFS:SetPoint("LEFT", dCb, "RIGHT", 1, 0)
                        dFS:SetSize(DIFF_COL_W - 26, ROW_H)
                        dFS:SetJustifyH("LEFT")
                        dFS:SetJustifyV("MIDDLE")
                        dFS:SetText(Catalog.GetDifficultyLabel(diffId))
                        dFS:SetTextColor(1, 1, 1)

                        dx = dx + DIFF_COL_W
                    end
                end
                y = y - ROW_H
            end
            y = y - 6
        end
    end

    return y, width
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

    local preserveScroll = not resetScrollOnNextRefresh
    resetScrollOnNextRefresh = false
    local scrollV, scrollH = 0, 0
    if preserveScroll then
        scrollV, scrollH = CaptureScroll()
    end

    ReleasePools()
    EnsureCatalogReady()
    UpdateTabVisuals()

    local tab = GetActiveTab()
    if tab == "debug" then
        ShowDebugPanel(true)
        return
    end
    ShowDebugPanel(false)

    local width = 560
    local y = -4

    if tab == "chars" then
        y, width = BuildCharsTab(y, width)
    elseif tab == "notes" then
        y, width = BuildNotesTab(y, width)
    elseif tab == "mounts" then
        y, width = BuildMountsTab(y, width)
    else
        y, width = BuildRaidsTab(y, width)
    end

    LayoutContent(y, width)
    if preserveScroll then
        ApplyScroll(scrollV, scrollH)
    else
        ApplyScroll(0, 0)
    end
end

--- Light mounts-tab refresh during scan progress (no catalog force-rebuild).
function UI.RefreshMountsProgress()
    if not frame or not scrollChild or not frame:IsShown() then
        return
    end
    if GetActiveTab() ~= "mounts" then
        return
    end

    if not content then
        content = CreateFrame("Frame", nil, scrollChild)
        content:SetPoint("TOPLEFT", 0, 0)
        scrollChild.content = content
    end

    local scrollV, scrollH = CaptureScroll()
    ReleasePools()
    UpdateTabVisuals()

    local y, width = BuildMountsTab(-4, 560)
    LayoutContent(y, width)
    ApplyScroll(scrollV, scrollH)
end

local function SelectTab(tab)
    SetActiveTab(tab)
    resetScrollOnNextRefresh = true
    UI.Refresh()
end

local function RegisterMountCollectedEvents()
    if mountCollectedEventsRegistered or not frame then
        return
    end
    mountCollectedEventsRegistered = true
    if frame.RegisterEvent then
        frame:RegisterEvent("NEW_MOUNT_ADDED")
        frame:RegisterEvent("COMPANION_LEARNED")
    end
    if frame.SetScript then
        frame:SetScript("OnEvent", function(_, event)
            if event ~= "NEW_MOUNT_ADDED" and event ~= "COMPANION_LEARNED" then
                return
            end
            if not frame:IsShown() or GetActiveTab() ~= "mounts" then
                return
            end
            -- Collected filter / icons may change without rescanning EJ loot.
            if UI.RefreshMountsProgress then
                UI.RefreshMountsProgress()
            else
                UI.Refresh()
            end
        end)
    end
end

local function CreateOptionsFrame()
    if frame then
        return frame
    end

    frame = CreateFrame("Frame", "ALIOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(200)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "ALIOptionsFrame")

    if ns.UI and ns.UI.EnableResize then
        ns.UI.EnableResize(frame, "options")
    else
        frame:SetSize(640, 520)
    end
    if not frame:GetPoint() then
        frame:SetPoint("CENTER", 60, -30)
    end

    frame.TitleText:SetText(L["OPTIONS_TITLE"] or "Settings")

    -- Tab bar under title
    local tabBar = CreateFrame("Frame", nil, frame)
    tabBar:SetPoint("TOPLEFT", 12, -28)
    tabBar:SetPoint("TOPRIGHT", -30, -28)
    tabBar:SetHeight(TAB_H)

    local function MakeTab(id, label, x)
        local b = CreateFrame("Button", nil, tabBar, "UIPanelButtonTemplate")
        b:SetSize(TAB_W, TAB_H)
        b:SetPoint("LEFT", tabBar, "LEFT", x, 0)
        b:SetText(label)
        b:SetScript("OnClick", function()
            SelectTab(id)
        end)
        tabButtons[id] = b
        return b
    end

    local x = 0
    local step = TAB_W + TAB_GAP
    MakeTab("raids", L["OPTIONS_TAB_RAIDS"] or "Raids", x); x = x + step
    MakeTab("mounts", L["OPTIONS_TAB_MOUNTS"] or "Mounts", x); x = x + step
    MakeTab("chars", L["OPTIONS_TAB_CHARS"] or "Characters", x); x = x + step
    MakeTab("notes", L["OPTIONS_TAB_NOTES"] or "Notes", x); x = x + step
    MakeTab("debug", L["OPTIONS_TAB_DEBUG"] or "Debug", x)

    if ns.UI and ns.UI.CreateScrollArea then
        scrollFrame, scrollChild = ns.UI.CreateScrollArea(frame, "ALIOptionsScroll")
    else
        scrollFrame = CreateFrame("ScrollFrame", "ALIOptionsScroll", frame, "UIPanelScrollFrameTemplate")
        scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetSize(1, 1)
        scrollFrame:SetScrollChild(scrollChild)
    end
    scrollFrame:SetPoint("TOPLEFT", 12, -56)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 28)

    frame._aliOnResized = function()
        if ns.UI and ns.UI.UpdateScroll then
            ns.UI.UpdateScroll(scrollFrame)
        end
    end

    frame:SetScript("OnShow", function()
        frame:SetFrameStrata("DIALOG")
        frame:SetFrameLevel(200)
        currentTab = GetActiveTab()
        resetScrollOnNextRefresh = true
        UI.Refresh()
    end)

    RegisterMountCollectedEvents()

    return frame
end

function UI.Show()
    CreateOptionsFrame()
    frame:Show()
    UI.Refresh()
end

function UI.Hide()
    if frame then
        frame:Hide()
    end
end

function UI.Toggle()
    CreateOptionsFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        UI.Show()
    end
end

function UI.IsShown()
    return frame and frame:IsShown()
end

function UI.ShowDebugTab()
    SetActiveTab("debug")
    resetScrollOnNextRefresh = true
    UI.Show()
end

function UI.RefreshDebugIfShown()
    if frame and frame:IsShown() and GetActiveTab() == "debug" then
        RefreshDebugDump(false)
    end
end
