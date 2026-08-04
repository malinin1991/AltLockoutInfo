local addonName, ns = ...

--- Debug UI lives in Options → Debug tab. This module keeps slash/API compatibility.
ns.UI_Debug = ns.UI_Debug or {}
local UI = ns.UI_Debug

function UI.Show()
    if ns.UI_Options and ns.UI_Options.ShowDebugTab then
        ns.UI_Options.ShowDebugTab()
    end
end

function UI.Hide()
    if ns.UI_Options and ns.UI_Options.Hide then
        ns.UI_Options.Hide()
    end
end

function UI.Toggle()
    if ns.UI_Options and ns.UI_Options.IsShown and ns.UI_Options.IsShown() then
        local ui = ns.DB and ns.DB.GetUI and ns.DB.GetUI()
        if ui and ui.optionsTab == "debug" then
            ns.UI_Options.Hide()
            return
        end
    end
    UI.Show()
end

function UI.IsShown()
    if not (ns.UI_Options and ns.UI_Options.IsShown and ns.UI_Options.IsShown()) then
        return false
    end
    local ui = ns.DB and ns.DB.GetUI and ns.DB.GetUI()
    return ui and ui.optionsTab == "debug"
end

function UI.Refresh()
    if ns.UI_Options and ns.UI_Options.RefreshDebugIfShown then
        ns.UI_Options.RefreshDebugIfShown()
    end
end
