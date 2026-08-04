local addonName, ns = ...

ns.UI = ns.UI or {}
local UI = ns.UI
local DB = ns.DB

local DEFAULTS = {
    -- Main: title + weekly line + scroll chrome (label column + 1 char cell).
    main = { w = 760, h = 460, minW = 480, minH = 300, maxW = 1600, maxH = 1000 },
    -- Options: 5 tabs × 100 + 4 gaps × 4 = 516, plus left/right chrome (~42) + slack.
    -- Also fits Debug bottom row (Refresh / Select all / Clear mounts cache).
    options = { w = 640, h = 520, minW = 580, minH = 360, maxW = 1600, maxH = 1000 },
    debug = { w = 560, h = 420, minW = 420, minH = 280, maxW = 1400, maxH = 900 },
}

function UI.GetWindowDefaults(key)
    return DEFAULTS[key] or DEFAULTS.main
end

--- Make a frame resizable; persist size under settings.ui.windows[key].
function UI.EnableResize(frame, key)
    local def = UI.GetWindowDefaults(key)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(def.minW, def.minH, def.maxW, def.maxH)
    else
        if frame.SetMinResize then frame:SetMinResize(def.minW, def.minH) end
        if frame.SetMaxResize then frame:SetMaxResize(def.maxW, def.maxH) end
    end

    local saved = DB.GetWindowSize(key)
    if saved and saved.w and saved.h then
        frame:SetSize(
            math.max(def.minW, math.min(def.maxW, saved.w)),
            math.max(def.minH, math.min(def.maxH, saved.h))
        )
    else
        frame:SetSize(def.w, def.h)
    end

    if frame._aliResizeGrip then
        return
    end

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetFrameLevel((frame:GetFrameLevel() or 1) + 20)
    grip:EnableMouse(true)
    grip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        DB.SetWindowSize(key, frame:GetWidth(), frame:GetHeight())
        if frame._aliOnResized then
            frame._aliOnResized()
        end
    end)
    frame:HookScript("OnSizeChanged", function()
        if frame._aliOnResized then
            frame._aliOnResized()
        end
    end)
    frame._aliResizeGrip = grip
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Create a scroll area with vertical + horizontal scrollbars.
--- Returns scrollFrame, scrollChild, updateFn
function UI.CreateScrollArea(parent, name)
    local scroll = CreateFrame("ScrollFrame", name, parent)
    scroll:EnableMouse(true)
    scroll:EnableMouseWheel(true)

    local child = CreateFrame("Frame", name and (name .. "Child") or nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)

    local vBar = CreateFrame("Slider", name and (name .. "VScroll") or nil, parent, "UIPanelScrollBarTemplate")
    vBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2, -16)
    vBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 2, 16)
    vBar:SetMinMaxValues(0, 0)
    vBar:SetValueStep(1)
    vBar:SetObeyStepOnDrag(true)
    vBar:SetScript("OnValueChanged", function(self, value)
        scroll:SetVerticalScroll(value)
    end)

    local hBar = CreateFrame("Slider", name and (name .. "HScroll") or nil, parent)
    hBar:SetOrientation("HORIZONTAL")
    hBar:SetHeight(16)
    hBar:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 16, -2)
    hBar:SetPoint("TOPRIGHT", scroll, "BOTTOMRIGHT", -16, -2)
    hBar:SetMinMaxValues(0, 0)
    hBar:SetValueStep(1)
    hBar:SetObeyStepOnDrag(true)

    -- Reuse scrollbar thumb art
    local thumb = hBar:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    thumb:SetSize(18, 16)
    hBar:SetThumbTexture(thumb)

    local hLeft = hBar:CreateTexture(nil, "BACKGROUND")
    hLeft:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")
    hLeft:SetSize(16, 16)
    hLeft:SetPoint("LEFT", -16, 0)

    local hRight = hBar:CreateTexture(nil, "BACKGROUND")
    hRight:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled")
    hRight:SetSize(16, 16)
    hRight:SetPoint("RIGHT", 16, 0)

    local hTrack = hBar:CreateTexture(nil, "BACKGROUND")
    hTrack:SetColorTexture(0.1, 0.1, 0.1, 0.6)
    hTrack:SetPoint("TOPLEFT", 0, 0)
    hTrack:SetPoint("BOTTOMRIGHT", 0, 0)

    hBar:SetScript("OnValueChanged", function(self, value)
        scroll:SetHorizontalScroll(value)
    end)

    local function UpdateBars()
        local viewW = scroll:GetWidth() or 0
        local viewH = scroll:GetHeight() or 0
        local contentW = child:GetWidth() or 0
        local contentH = child:GetHeight() or 0

        local maxV = math.max(0, contentH - viewH)
        local maxH = math.max(0, contentW - viewW)

        vBar:SetMinMaxValues(0, maxV)
        hBar:SetMinMaxValues(0, maxH)

        local curV = Clamp(scroll:GetVerticalScroll() or 0, 0, maxV)
        local curH = Clamp(scroll:GetHorizontalScroll() or 0, 0, maxH)
        scroll:SetVerticalScroll(curV)
        scroll:SetHorizontalScroll(curH)
        vBar:SetValue(curV)
        hBar:SetValue(curH)

        if maxV > 1 then
            vBar:Show()
        else
            vBar:Hide()
            scroll:SetVerticalScroll(0)
        end
        if maxH > 1 then
            hBar:Show()
        else
            hBar:Hide()
            scroll:SetHorizontalScroll(0)
        end
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown and IsShiftKeyDown() then
            local _, maxH = hBar:GetMinMaxValues()
            local step = 40
            local new = Clamp((self:GetHorizontalScroll() or 0) - delta * step, 0, maxH or 0)
            self:SetHorizontalScroll(new)
            hBar:SetValue(new)
        else
            local _, maxV = vBar:GetMinMaxValues()
            local step = 40
            local new = Clamp((self:GetVerticalScroll() or 0) - delta * step, 0, maxV or 0)
            self:SetVerticalScroll(new)
            vBar:SetValue(new)
        end
    end)

    scroll:SetScript("OnScrollRangeChanged", UpdateBars)
    scroll:SetScript("OnSizeChanged", UpdateBars)
    child:HookScript("OnSizeChanged", UpdateBars)

    scroll._aliUpdateBars = UpdateBars
    scroll._aliVBar = vBar
    scroll._aliHBar = hBar

    return scroll, child, UpdateBars
end

function UI.UpdateScroll(scroll)
    if scroll and scroll._aliUpdateBars then
        scroll._aliUpdateBars()
    end
end
