-- =================================================================================
-- Import base file
-- =================================================================================
local files = {
    "mappinmanager_cqui.lua",
    "mappinmanager.lua",
};
for _, file in ipairs(files) do
    include(file)
    if Initialize then
        print("DMT_MapPinManager Loading " .. file .. " as base file");
        break;
    end
end
include("PopupDialog");
include("dmt_mappinsubjectmanager");

local AUTO_DELETE_CONFIG_KEY = "DMT_AUTO_DELETE"; -- nil => NOT_SET, 0 => NO, 1 => YES.

local m_IsShiftDown = false;
local m_RememberChoice = true;

local m_AddMapTackId:number = Input.GetActionId("AddMapTack");
local m_DeleteMapTackId:number = Input.GetActionId("DeleteMapTack");
local m_ToggleMapTackVisibilityId:number = Input.GetActionId("ToggleMapTackVisibility");

local m_MapPinListBtn = nil;
local m_MapPinFlags = nil;

-- =================================================================================
-- Cache base functions
-- =================================================================================
BASE_MapPinFlag_Refresh = MapPinFlag.Refresh;
BASE_OnInputHandler = OnInputHandler;

-- =================================================================================
-- Overrides
-- =================================================================================
function MapPinFlag.Refresh(self)
    BASE_MapPinFlag_Refresh(self);
    UpdateYields(self);
    UpdateCanPlace(self);
end

function UpdateYields(pMapPinFlag)
    local pMapPin = pMapPinFlag:GetMapPin();

    if pMapPin ~= nil then
        local mapPinSubject = GetMapPinSubject(pMapPin:GetPlayerID(), pMapPin:GetHexX(), pMapPin:GetHexY());
        if mapPinSubject then
            local yieldString = mapPinSubject.YieldString;
            local yieldToolTip = mapPinSubject.YieldToolTip;
            if yieldString ~= nil and yieldString ~= "" then
                pMapPinFlag.m_Instance.YieldText:SetText(yieldString);
                if yieldToolTip ~= nil and yieldToolTip ~= "" then
                    pMapPinFlag.m_Instance.YieldText:SetToolTipString(yieldToolTip);
                else
                    pMapPinFlag.m_Instance.YieldText:SetToolTipString("");
                end
                pMapPinFlag.m_Instance.YieldContainer:SetHide(false);
                return;
            end
        end
    end

    pMapPinFlag.m_Instance.YieldText:SetText("");
    pMapPinFlag.m_Instance.YieldContainer:SetHide(true);
end

function UpdateCanPlace(pMapPinFlag)
    local pMapPin = pMapPinFlag:GetMapPin();

    if pMapPin ~= nil then
        local mapPinSubject = GetMapPinSubject(pMapPin:GetPlayerID(), pMapPin:GetHexX(), pMapPin:GetHexY());
        if mapPinSubject then
            local canPlace = mapPinSubject.CanPlace;
            local canPlaceToolTip = mapPinSubject.CanPlaceToolTip;
            pMapPinFlag.m_Instance.CanPlaceIcon:SetHide(canPlace);
            pMapPinFlag.m_Instance.CanPlaceIcon:SetToolTipString(canPlaceToolTip);
            return;
        end
    end

    pMapPinFlag.m_Instance.CanPlaceIcon:SetHide(true);
    pMapPinFlag.m_Instance.CanPlaceIcon:SetToolTipString("");
end

function OnMapPinFlagRightClick(playerID:number, pinID:number)
    if m_IsShiftDown and playerID == Game.GetLocalPlayer() then
        local playerCfg = PlayerConfigurations[playerID];
        -- Update map pin yields.
        LuaEvents.DMT_MapPinRemoved(playerCfg:GetMapPinID(pinID));
        -- Delete the pin.
        playerCfg:DeleteMapPin(pinID);
        Network.BroadcastPlayerInfo();
        UI.PlaySound("Map_Pin_Remove");
    end
end

function ToggleMapPinVisibility()
    if m_MapPinListBtn == nil then
        m_MapPinListBtn = ContextPtr:LookUpControl("/InGame/MinimapPanel/MapPinListButton");
    end
    if not m_MapPinListBtn:IsSelected() then
        if m_MapPinFlags == nil then
            m_MapPinFlags = ContextPtr:LookUpControl("/InGame/MapPinManager/MapPinFlags");
        end
        -- Only toggle the map pin visibility if MapPinListButton is not selected. i.e. not trying to add new pins.
        m_MapPinFlags:SetHide(not m_MapPinFlags:IsHidden());
    end
end

function ShowMapPins()
    if m_MapPinFlags == nil then
        m_MapPinFlags = ContextPtr:LookUpControl("/InGame/MapPinManager/MapPinFlags");
    end
    m_MapPinFlags:SetHide(false);
end

function AddMapPin()
    -- Make sure the map pins are shown before adding.
    ShowMapPins();
    local plotX, plotY = UI.GetCursorPlotCoord();
    LuaEvents.MapPinPopup_RequestMapPin(plotX, plotY);
end

function DeleteMapPin()
    if m_MapPinFlags == nil then
        m_MapPinFlags = ContextPtr:LookUpControl("/InGame/MapPinManager/MapPinFlags");
    end
    if not m_MapPinFlags:IsHidden() then
        -- Only delete if the map pins are not hidden.
        local plotX, plotY = UI.GetCursorPlotCoord();
        DeleteMapPinAtPlot(Game.GetLocalPlayer(), plotX, plotY);
    end
end

function DeleteMapPinAtPlot(playerID, plotX, plotY)
    local playerCfg = PlayerConfigurations[playerID];
    local mapPin = playerCfg and playerCfg:GetMapPin(plotX, plotY);
    if mapPin then
        -- Update map pin yields.
        LuaEvents.DMT_MapPinRemoved(mapPin);
        -- Delete the pin.
        playerCfg:DeleteMapPin(mapPin:GetID());
        Network.BroadcastPlayerInfo();
        UI.PlaySound("Map_Pin_Remove");
    end
end

function OnDeleteMapPinRequest(playerID, plotX, plotY)
    local playerCfg = PlayerConfigurations[playerID];
    local autoDeleteConfig = playerCfg and playerCfg:GetValue(AUTO_DELETE_CONFIG_KEY);
    if autoDeleteConfig == 0 then
        -- Don't auto delete.
    elseif autoDeleteConfig == 1 then
        -- Auto delete.
        DeleteMapPinAtPlot(playerID, plotX, plotY);
    else
        -- Not set, show popup.
        local popupDialog = PopupDialog:new("DMT_AutoDelete_PopupDialog");
        popupDialog:AddTitle("");
        popupDialog:AddText(Locale.Lookup("LOC_DMT_AUTO_DELETE_MAP_TACK_HINT"));
        popupDialog:AddCheckBox(Locale.Lookup("LOC_REMEMBER_MY_CHOICE"), m_RememberChoice, OnAutoDeleteRememberChoice);
        popupDialog:AddButton(Locale.Lookup("LOC_YES"), function() OnAutoDeleteChooseYes(playerID, plotX, plotY); end);
        popupDialog:AddButton(Locale.Lookup("LOC_NO"), function() OnAutoDeleteChooseNo(playerID, plotX, plotY); end);
        popupDialog:Open();
    end
end

function OnAutoDeleteRememberChoice(checked)
    m_RememberChoice = checked;
end

function OnAutoDeleteChooseYes(playerID, plotX, plotY)
    local playerCfg = PlayerConfigurations[playerID];
    if m_RememberChoice and playerCfg then
        playerCfg:SetValue(AUTO_DELETE_CONFIG_KEY, 1);
        Network.BroadcastPlayerInfo();
    end
    DeleteMapPinAtPlot(playerID, plotX, plotY);
end

function OnAutoDeleteChooseNo(playerID, plotX, plotY)
    local playerCfg = PlayerConfigurations[playerID];
    if m_RememberChoice and playerCfg then
        playerCfg:SetValue(AUTO_DELETE_CONFIG_KEY, 0);
        Network.BroadcastPlayerInfo();
    end
end

function OnInputHandler(pInputStruct:table)
    if BASE_OnInputHandler then
        BASE_OnInputHandler(pInputStruct);
    end
    -- **Inspired by CQUI. Credits to infixo.**
    if pInputStruct:GetKey() == Keys.VK_SHIFT then
        m_IsShiftDown = pInputStruct:GetMessageType() == KeyEvents.KeyDown;
    end
    return false;
end

function OnInterfaceModeChanged(eNewMode:number)
    if UI.GetInterfaceMode() == InterfaceModeTypes.PLACE_MAP_PIN then
        ShowMapPins();
    end
end

function OnInputActionTriggered(actionId:number)
    if actionId == m_AddMapTackId then
        AddMapPin();
    elseif actionId == m_DeleteMapTackId then
        DeleteMapPin();
    elseif actionId == m_ToggleMapTackVisibilityId then
        ToggleMapPinVisibility();
    end
end

function DMT_Initialize()
    ContextPtr:SetInputHandler(OnInputHandler, true);

    LuaEvents.DMT_DeleteMapPinRequest.Add(OnDeleteMapPinRequest);
    Events.InterfaceModeChanged.Add(OnInterfaceModeChanged);
    Events.InputActionTriggered.Add(OnInputActionTriggered);
end
DMT_Initialize()