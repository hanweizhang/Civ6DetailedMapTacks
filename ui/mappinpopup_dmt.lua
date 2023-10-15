-- =================================================================================
-- Import base file
-- =================================================================================
local files = {
    "mappinpopup.lua",
}

for _, file in ipairs(files) do
    include(file)
    if Initialize then
        print("DMT_MapPinPopup Loading " .. file .. " as base file");
        break
    end
end

local previousTime = 0;
local previousControl = nil;

-- =================================================================================
-- Cache base functions
-- =================================================================================
BASE_OnDelete = OnDelete;
BASE_OnOk = OnOk;
BASE_UpdateIconOptionColors = UpdateIconOptionColors;

function OnDelete()
    LuaEvents.DMT_MapPinRemoved(GetEditPinConfig());
    BASE_OnDelete();
end

function OnOk()
    BASE_OnOk();
    LuaEvents.DMT_MapPinAdded(GetEditPinConfig());
end

function UpdateIconOptionColors()
    BASE_UpdateIconOptionColors();

    -- This function will be called whenever the popup is going to show or when an icon is clicked.
    -- Use this trick to handle double click instead registering IconOptionButton's eLDblClick because I don't
    -- want to copy over entire PopulateIconOptions method and they made g_iconOptionEntries local variable. :(
    if not ContextPtr:IsHidden() then
        -- Only handle if an icon is clicked. i.e. ignore the call before showing the popup.
        local currentTime = Automation.GetTime();
        local currentControl = UIManager:GetControlUnderMouse(ContextPtr);
        if currentTime - previousTime < 0.5 and previousControl == currentControl then -- default windows double click elapsed time.
            -- Consider this as a double click, and confirm on the placement.
            OnOk();
        end
        previousTime = currentTime;
        previousControl = currentControl;
    end
end

-- ===========================================================================
function DMT_Initialize()
    Controls.DeleteButton:RegisterCallback(Mouse.eLClick, OnDelete);
    Controls.OkButton:RegisterCallback(Mouse.eLClick, OnOk);
end
DMT_Initialize()
