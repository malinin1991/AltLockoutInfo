local addonName, ns = ...

ns.MinimapButton = ns.MinimapButton or {}
local MB = ns.MinimapButton
local DB = ns.DB
local L = ns.L

local button
local ICON_SIZE = 32
local dragActive = false

local function GetMinimapRadius()
    -- Sit on the ring outside the minimap disc (not on the map art).
    local size = Minimap and Minimap.GetWidth and Minimap:GetWidth() or 140
    if size < 40 then
        size = 140
    end
    return (size / 2) + 10
end

local function UpdatePosition()
    if not button or not Minimap then
        return
    end
    local angle = math.rad(DB.GetMinimap().angle or 220)
    local radius = GetMinimapRadius()
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnUpdateDrag(self)
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    DB.GetMinimap().angle = angle
    UpdatePosition()
end

function MB.Create()
    if button or not Minimap then
        return button
    end

    button = CreateFrame("Button", "ALIMinimapButton", Minimap)
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap.GetFrameLevel and Minimap:GetFrameLevel() or 1) + 8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\Achievement_Boss_GeneralVezax_01")
    button.icon = icon

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(L["ADDON_NAME"] or "Alt Lockout Info", 1, 0.82, 0)
        GameTooltip:AddLine(L["MINIMAP_LEFT"] or "Left-click: status table", 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_RIGHT"] or "Right-click: settings", 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_DRAG"] or "Drag to move", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    button:SetScript("OnClick", function(_, mouseButton)
        if dragActive then
            dragActive = false
            button._dragToken = nil
            return
        end
        if mouseButton == "LeftButton" then
            if ns.UI_Main then
                ns.UI_Main.Toggle()
            end
        elseif mouseButton == "RightButton" then
            if ns.UI_Options then
                ns.UI_Options.Toggle()
            end
        end
    end)

    button:SetScript("OnDragStart", function(self)
        dragActive = true
        self:SetScript("OnUpdate", OnUpdateDrag)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if C_Timer and C_Timer.After then
            local token = {}
            button._dragToken = token
            C_Timer.After(0.05, function()
                if button and button._dragToken == token then
                    dragActive = false
                end
            end)
        else
            -- Fallback without C_Timer: brief OnUpdate delay so the release click is ignored.
            local t = 0
            self:SetScript("OnUpdate", function(s, elapsed)
                t = t + (elapsed or 0.01)
                if t >= 0.05 then
                    s:SetScript("OnUpdate", nil)
                    dragActive = false
                end
            end)
        end
    end)

    -- Keep on the border if minimap is resized (e.g. addon skins).
    if Minimap.HookScript then
        Minimap:HookScript("OnSizeChanged", UpdatePosition)
    end

    UpdatePosition()
    button:Show()
    return button
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
    MB.Create()
    self:UnregisterAllEvents()
end)
