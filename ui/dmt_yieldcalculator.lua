-- =======================================================================
--  Copyright (c) 2021-03 wltk, DeepLogic. All rights reserved.
-- =======================================================================

print("Loading DMT_YieldCalculator.lua");

include( "civ6common" );
include( "dmt_modifiercalculator" );

-- =======================================================================
-- Defining MapPinSubject that would be used within this file:
-- The subject will contain these fields
--
-- Id: id of the original MapPin object.
-- X: x coordinate of the original MapPin object.
-- Y: y coordinate of the original MapPin object.
-- Key: key of the MapPin represented subject e.g. DISTRICT_CAMPUS.
-- Type: type of the MapPin represented subject. e.g. MAP_PIN_TYPES.DISTRICT.
-- YieldString: the yield string to be shown for this MapPin.
-- YieldToolTip: the yield tooltip to be shown for this MapPin.
-- CanPlace: whether the MapPin can be placed at its position.
-- CanPlaceToolTip: the failure reason if the MapPin cannot be placed.
--
-- =======================================================================

local MapPinSubjectManager = ExposedMembers.DMT.MapPinSubjectManager;
-- =======================================================================
-- Constants
-- =======================================================================
-- Map pin types that we support checking.
-- Refer to MapTacks.lua's InitializeTypes function.
local MAP_PIN_TYPES = {
    UNKNOWN = "UNKNOWN",
    IMPROVEMENT = "IMPROVEMENT",
    DISTRICT = "DISTRICT",
    WONDER = "WONDER"
};
-- =======================================================================
-- Members
-- =======================================================================
local isXP2Active = false;

local BuildingRequiredFeature = {};
local BuildingValidFeature = {};
local BuildingValidTerrain = {};

local DistrictRequiredFeature = {};
local DistrictValidTerrain = {};

local ImprovementValidFeature = {};
local ImprovementValidResource = {};

-- Cache plot features to avoid double calculate within a single update call.
local m_CachedPlotFeatures = {};

local m_HiddenPlotsToCheck = {};

local m_CannotPlacedOnTextKey = "LOC_DMT_CANNOT_PLACE_ON_REASON";
-- =======================================================================
-- Core functions.
-- =======================================================================
-- Update given MapPins yields. Core function to be used to perform the update.
--
-- Params:
--     playerID:     owner of the MapPin subjects.
--     pinsToUpdate: a table of MapPin subjects to update.
function UpdatePinYields(playerID:number, pinsToUpdate:table)
    -- Clear cached plot features before each update, so that plots to update will get recalculated.
    m_CachedPlotFeatures = {};

    for _, pin in ipairs(pinsToUpdate) do
        -- Don't need to perform any action if it's an UNKNOWN map pin type, i.e. no adjacency impact.
        if pin.Type ~= MAP_PIN_TYPES.UNKNOWN then
            -- Get bonus yield for each pin.
            local bonusYields, yieldToolTip = GetBonusYields(playerID, pin);
            local yieldString = ConvertToYieldString(bonusYields);
            pin.YieldString = yieldString;
            pin.YieldToolTip = yieldToolTip;
            -- Check if the pin can be placed
            local canPlace, canPlaceToolTip = CanPlacePin(playerID, pin);
            pin.CanPlace = canPlace;
            pin.CanPlaceToolTip = canPlaceToolTip;
            -- Update the pin in MapPinSubjectManager.
            MapPinSubjectManager.UpdatePin(playerID, pin.X, pin.Y, pin);
        else
            MapPinSubjectManager.ClearPin(playerID, pin.X, pin.Y);
        end
        -- Update UI.
        LuaEvents.DMT_RefreshMapPinUI(playerID, pin.Id);
    end
end

-- Update adjacent pins and the pin at the given location if there's any.
function UpdateSelfAndAdjacentPins(playerID:number, posX:number, posY:number)
    if playerID ~= -1 and playerID == Game.GetLocalPlayer() then
        local pinsToUpdate = MapPinSubjectManager.GetSelfAndAdjacentPins(playerID, posX, posY);
        UpdatePinYields(playerID, pinsToUpdate);
    end
end

-- Convert yield table to yield string for display.
--
-- Params:
--     yields: Yield table.
-- Return: a combined yield string.
-- Example:
-- [ICON_Gold][COLOR:ResGoldLabelCS]+10[ENDCOLOR][ICON_Faith][COLOR:ResFaithLabelCS]+10[ENDCOLOR]
function ConvertToYieldString(yields:table)
    local yieldString = "";
    for yieldType, amount in pairs(yields) do
        yieldString = yieldString .. GetYieldString(yieldType, amount) .. " ";
    end
    return yieldString;
end

-- Create a MapPin subject that we defined given the original MapPin object.
--
-- Params:
--     mapPin: original MapPin object.
-- Return: a MapPin subject that we defined.
-- {
--     Id: 0,
--     X: 5,
--     Y: 14,
--     Key: "DISTRICT_HOLY_SITE",
--     Type: MAP_PIN_TYPES.DISTRICT
-- }
function CreateMapPinSubject(mapPin:table)
    local subject = {};
    subject.Id = mapPin:GetID();
    subject.X = mapPin:GetHexX();
    subject.Y = mapPin:GetHexY();

    local iconName = mapPin:GetIconName();
    local iconType = iconName:gsub("ICON_", "");
    subject.Key = iconType;
    subject.Type = MAP_PIN_TYPES.UNKNOWN;

    if iconType:match("^IMPROVEMENT_") then
        subject.Type = MAP_PIN_TYPES.IMPROVEMENT;
    elseif iconType:match("^DISTRICT_") then
        if iconType == "DISTRICT_WONDER" then
            subject.Type = MAP_PIN_TYPES.WONDER;
        else
            subject.Type = MAP_PIN_TYPES.DISTRICT;
        end
    elseif iconType:match("^BUILDING_") then -- Wonders
        subject.Type = MAP_PIN_TYPES.WONDER;
    elseif iconType == "MAP_PIN_DISTRICT" then
        subject.Type = MAP_PIN_TYPES.DISTRICT;
    elseif iconType == "NOTIFICATION_DISCOVER_GOODY_HUT" or iconType == "NOTIFICATION_BARBARIANS_SIGHTED" then
        -- Special for role playing players. :)
        local name = mapPin:GetName() or "";
        if string.upper(name):match("^CITY") then
            -- Consider this pin as a city center in our calculation.
            subject.Key = "DISTRICT_CITY_CENTER";
            subject.Type = MAP_PIN_TYPES.DISTRICT;
        end
    end

    return subject;
end

-- Check if the pin can be placed on the given plot.
--
-- Params:
--     playerID: owner player id of the MapPin.
--     pinSubject: the MapPin subject to check.
-- Return: can the pin be placed on the given plot, and the tooltip for reasons.
function CanPlacePin(playerID:number, pinSubject:table)
    local pinType = pinSubject.Type;
    local pinKey = pinSubject.Key;
    if pinType == MAP_PIN_TYPES.UNKNOWN then return true, {}; end

    local features = GetRealizedPlotFeatures(playerID, Map.GetPlot(pinSubject.X, pinSubject.Y), pinSubject);

    if features[AdjacencyBonusTypes.ADJACENCY_NATURAL_WONDER] ~= nil then
        -- Check if the plot has natural wonder. Don't need to do other checks if it has.
        return false, GetCannotPlaceReasonString(GameInfo.Features[features[AdjacencyBonusTypes.ADJACENCY_NATURAL_WONDER]].Name);
    end

    local canPlace = true;
    local reasons = {};
    -- Can place on feature?
    if not CanPlaceOnFeature(pinType, pinKey, features[AdjacencyBonusTypes.ADJACENCY_FEATURE]) then
        -- Check if the pin can be placed on the given feature.
        canPlace = false;
        if features[AdjacencyBonusTypes.ADJACENCY_FEATURE] == nil then
            table.insert(reasons, Locale.Lookup("LOC_DMT_MUST_PLACE_ON_CORRECT_FEATURES_REASON"));
        else
            table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Features[features[AdjacencyBonusTypes.ADJACENCY_FEATURE]].Name));
        end
    end
    -- Can place on terrain?
    if not CanPlaceOnTerrain(pinType, pinKey, features[AdjacencyBonusTypes.ADJACENCY_TERRAIN]) then
        -- Check if the pin can be placed on the given terrain.
        canPlace = false;
        table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Terrains[features[AdjacencyBonusTypes.ADJACENCY_TERRAIN]].Name));
    end

    -- Other checks.
    local subCanPlace = true;
    local subReasons = {};
    if pinType == MAP_PIN_TYPES.IMPROVEMENT then
        -- TODO
    elseif pinType == MAP_PIN_TYPES.DISTRICT then
        subCanPlace, subReasons = CanPlaceDistrictCheckHelper(playerID, pinSubject, features);
    elseif pinType == MAP_PIN_TYPES.WONDER then
        subCanPlace, subReasons = CanPlaceWonderCheckHelper(playerID, pinSubject, features);
    end

    canPlace = canPlace and subCanPlace;
    if subReasons then
        for _, reason in ipairs(subReasons) do
            table.insert(reasons, reason);
        end
    end

    return canPlace, ConvertReasonsToToolTip(reasons);
end

function ConvertReasonsToToolTip(reasons:table)
    if #reasons == 1 then
        return reasons[1]; -- Don't need to add bullets. Lua index starts from 1.
    elseif #reasons > 1 then
        local toolTipLines = {};
        for _, reason in ipairs(reasons) do
            table.insert(toolTipLines, "[ICON_Bullet] " .. reason);
        end
        return table.concat(toolTipLines, "[NEWLINE]");
    else
        return "";
    end
end

-- Can the resource be harvested.
function CanHarvestResource(resourceType:string)
    if resourceType == nil then return true; end
    for row in GameInfo.Resource_Harvests() do
        if row.ResourceType == resourceType then return true; end
    end
    return false;
end

-- Can the pin be placed on the feature.
function CanPlaceOnFeature(pinType:string, pinKey:string, featureType:string)
    if pinType == MAP_PIN_TYPES.IMPROVEMENT then
        -- TODO
    elseif pinType == MAP_PIN_TYPES.DISTRICT then
        local hasRequirement = false;
        for row in GameInfo.District_RequiredFeatures() do
            if row.DistrictType == pinKey then
                if row.FeatureType == featureType then return true; end
                hasRequirement = true;
            end
        end
        if hasRequirement then return false; end
        -- If the feature exists and the district is not compatible with it, return false.
        if featureType and not IsCityCenter(pinKey) and WillDistrictRemoveFeature(pinKey, featureType) then
            return false;
        end
        -- If district requires certain features, but the current feature is not one of them, return false.
        if DoesDistrictRequireFeatureByModifier(pinKey) and not CanDistrictPlaceOnFeatureByModifier(pinKey, featureType) then
            return false;
        end
    elseif pinType == MAP_PIN_TYPES.WONDER then
        -- Check for required feature.
        local hasRequirement = false;
        for row in GameInfo.Building_RequiredFeatures() do
            if row.BuildingType == pinKey then
                if row.FeatureType == featureType then return true; end
                hasRequirement = true;
            end
        end
        if hasRequirement then return false; end
        -- If the feature exists, but the wonder is not compatible with it, return false.
        if featureType and WillWonderRemoveFeature(pinKey, featureType) then
            return false;
        end
    end
    return true;
end

-- Can the pin be placed on the terrain.
function CanPlaceOnTerrain(pinType:string, pinKey:string, terrainType:string)
    if pinType == MAP_PIN_TYPES.IMPROVEMENT then
        -- For ski resort, mountain tunnel, and mountain road right now.
        for row in GameInfo.Improvement_ValidTerrains() do
            if row.ImprovementType == pinKey then
                if row.TerrainType == terrainType then return true; end
            end
        end
    elseif pinType == MAP_PIN_TYPES.DISTRICT then
        local hasRequirement = false;
        for row in GameInfo.District_ValidTerrains() do
            if row.DistrictType == pinKey then
                if row.TerrainType == terrainType then return true; end
                hasRequirement = true;
            end
        end
        if hasRequirement then return false; end
    elseif pinType == MAP_PIN_TYPES.WONDER then
        local hasRequirement = false;
        for row in GameInfo.Building_ValidTerrains() do
            if row.BuildingType == pinKey then
                if row.TerrainType == terrainType then return true; end
                hasRequirement = true;
            end
        end
        if hasRequirement then return false; end
    end

    -- By default pin cannot be placed on mountains.
    if terrainType and GameInfo.Terrains[terrainType] and GameInfo.Terrains[terrainType].Mountain then
        return false;
    end
    return true;
end

-- Can place check helper for districts.
function CanPlaceDistrictCheckHelper(playerID:number, pinSubject:table, features:table)
    local x = pinSubject.X;
    local y = pinSubject.Y;
    local canPlace = true;
    local reasons = {};
    -- Already has wonder?
    if features[AdjacencyBonusTypes.ADJACENCY_WONDER] ~= nil then
        -- Check if the plot has a wonder.
        canPlace = false;
        table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Buildings[features[AdjacencyBonusTypes.ADJACENCY_WONDER]].Name));
    end
    -- Already has district?
    if features[AdjacencyBonusTypes.ADJACENCY_DISTRICT] and features[AdjacencyBonusTypes.ADJACENCY_DISTRICT] ~= pinSubject.Key then
        -- Check if the plot has a district that is different from the pin.
        canPlace = false;
        table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Districts[features[AdjacencyBonusTypes.ADJACENCY_DISTRICT]].Name));
    end
    -- Cannot harvest resource?
    if not CanHarvestResource(features[AdjacencyBonusTypes.ADJACENCY_RESOURCE]) and not IsCityCenter(pinSubject.Key) then
        -- Check if the plot has a resource that cannot be harvested. City center can be placed on not harvestable resources.
        canPlace = false;
        table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Resources[features[AdjacencyBonusTypes.ADJACENCY_RESOURCE]].Name));
    end
    -- Database check for requirements.
    local districtRow = GameInfo.Districts[pinSubject.Key];
    if districtRow then
        -- Coast check.
        local terrain = features[AdjacencyBonusTypes.ADJACENCY_TERRAIN];
        if districtRow.Coast and not (terrain == "TERRAIN_COAST" and IsAdjacentToLandPlot(playerID, x, y)) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_UI_PEDIA_PLACEMENT_ADJ_TO_COAST"));
        elseif not districtRow.Coast and IsTerrainWater(terrain) then
            canPlace = false;
            table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Terrains[terrain].Name));
        end
        -- City center adjacent check.
        if districtRow.NoAdjacentCity and IsAdjacentToCityCenter(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_UI_PEDIA_PLACEMENT_NOT_ADJ_TO_CITY"));
        end
        -- City center check.
        if districtRow.CityCenter and not IsValidCityCenterPosition(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_HUD_UNIT_PANEL_TOOLTIP_TOO_CLOSE_TO_CITY"));
        end
        -- Aqueduct check.
        if districtRow.Aqueduct and not IsValidAqueductPosition(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_UI_PEDIA_PLACEMENT_ADJ_TO_CITY"));
        end
        -- Dam check.
        if districtRow.DistrictType == "DISTRICT_DAM" and not IsValidDamPosition(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_DMT_INVALID_DAM_PLACEMENT_REASON"));
        end
    end
    -- Specialty district check.
    if IsSpecialtyDistrict(pinSubject.Key) and not CanPlaceSpecialtyDistrict(playerID, x, y) then
        canPlace = false;
        table.insert(reasons, Locale.Lookup("LOC_UI_PEDIA_PLACEMENT_NOT_ADJ_TO_CITY"));
    end
    return canPlace, reasons;
end

-- Can place check helper for wonders.
function CanPlaceWonderCheckHelper(playerID:number, pinSubject:table, features:table)
    local x = pinSubject.X;
    local y = pinSubject.Y;
    local canPlace = true;
    local reasons = {};
    -- Already has district?
    if features[AdjacencyBonusTypes.ADJACENCY_DISTRICT] ~= nil then
        -- Check if the plot has a district.
        canPlace = false;
        table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Districts[features[AdjacencyBonusTypes.ADJACENCY_DISTRICT]].Name));
    end
    -- Already has wonder?
    if features[AdjacencyBonusTypes.ADJACENCY_WONDER] and features[AdjacencyBonusTypes.ADJACENCY_WONDER] ~= pinSubject.Key then
        -- Check if the plot has a wonder that is different from the pin.
        if features[AdjacencyBonusTypes.ADJACENCY_WONDER] ~= "DISTRICT_WONDER" and pinSubject.Key ~= "DISTRICT_WONDER" then
            canPlace = false;
            table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Buildings[features[AdjacencyBonusTypes.ADJACENCY_WONDER]].Name));
        end
    end
    -- Cannot harvest resource?
    if not CanHarvestResource(features[AdjacencyBonusTypes.ADJACENCY_RESOURCE]) and not IsCityCenter(pinSubject.Key) then
        -- Check if the plot has a resource that cannot be harvested.
        canPlace = false;
        table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Resources[features[AdjacencyBonusTypes.ADJACENCY_RESOURCE]].Name));
    end
    -- Database check for requirements.
    local wonderRow = GameInfo.Buildings[pinSubject.Key];
    if wonderRow then
        local terrain = features[AdjacencyBonusTypes.ADJACENCY_TERRAIN];
        -- Adjacent district check.
        if wonderRow.AdjacentDistrict and not IsAdjacentToDistrict(playerID, x, y, wonderRow.AdjacentDistrict) then
            canPlace = false;
            local districtName = Locale.Lookup(GameInfo.Districts[wonderRow.AdjacentDistrict].Name);
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_BUILDING_REQUIRES_ADJACENT_DISTRICT", districtName));
        end
        -- River requirement check.
        if wonderRow.RequiresRiver and not IsAdjacentToRiver(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_PLACEMENT_REQUIRES_ADJACENT_RIVER"));
        end
        -- Resource requirement check.
        if wonderRow.AdjacentResource and not IsAdjacentToResource(playerID, x, y, wonderRow.AdjacentResource) then
            canPlace = false;
            local resourceName = Locale.Lookup(GameInfo.Resources[wonderRow.AdjacentResource].Name);
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_BUILDING_REQUIRES_ADJACENT_RESOURCE", resourceName));
        end
        -- On land and adjacent to coast check.
        if wonderRow.Coast and (IsTerrainWater(terrain) or not IsAdjacentToCoast(playerID, x, y)) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_BUILDING_REQUIRES_ADJACENT_RESOURCE", Locale.Lookup("LOC_TOOLTIP_COAST")));
        end
        -- On coast and adjacent to land check.
        if wonderRow.MustBeAdjacentLand and not (terrain == "TERRAIN_COAST" and IsAdjacentToLandPlot(playerID, x, y)) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_UI_PEDIA_PLACEMENT_ADJ_TO_COAST"));
        end
        -- Lake check.
        if wonderRow.MustBeLake and not IsOnLake(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_PLACEMENT_REQUIRES_LAKE"));
        end
        -- Not lake check.
        if wonderRow.MustNotBeLake and IsOnLake(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_PLACEMENT_REQUIRES_NOT_LAKE"));
        end
        -- Adjacent to mountain check.
        if wonderRow.AdjacentToMountain and not IsAdjacentToMountain(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_PLACEMENT_REQUIRES_ADJACENT_MOUNTAIN"));
        end
        -- Adjacent to capital check.
        if wonderRow.AdjacentCapital and not IsAdjacentToCapital(playerID, x, y) then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_DMT_MUST_PLACE_ADJACENT_TO_CAPITAL_REASON"));
        end
        -- Adjacent to improvement check.
        if wonderRow.AdjacentImprovement and not IsAdjacentToImprovement(playerID, x, y, wonderRow.AdjacentImprovement) then
            canPlace = false;
            local improvementName = Locale.Lookup(GameInfo.Improvements[wonderRow.AdjacentImprovement].Name);
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_BUILDING_REQUIRES_ADJACENT_DISTRICT", improvementName));
        end
        -- Has religion check.
        if wonderRow.RequiresReligion and GetPlayerReligionType(playerID) == -1 then
            canPlace = false;
            table.insert(reasons, Locale.Lookup("LOC_TOOLTIP_PLACEMENT_REQUIRES_RELIGION"));
        end
        -- Special check for BUILDING_HALICARNASSUS_MAUSOLEUM's terrain type.
        if wonderRow.BuildingType == "BUILDING_HALICARNASSUS_MAUSOLEUM" and IsTerrainWater(terrain) then
            canPlace = false;
            table.insert(reasons, GetCannotPlaceReasonString(GameInfo.Terrains[terrain].Name));
        end
        -- Special check for BUILDING_GOLDEN_GATE_BRIDGE.
        if wonderRow.BuildingType == "BUILDING_GOLDEN_GATE_BRIDGE" or wonderRow.BuildingType == "BUILDING_TOWER_BRIDGE" then
            if not IsValidBridgePosition(playerID, x, y) then
                canPlace = false;
                table.insert(reasons, Locale.Lookup("LOC_DMT_GOLDEN_GATE_BRIDGE_REASON"));
            end
        end
    end
    return canPlace, reasons;
end

function GetCannotPlaceReasonString(nameKey:string)
    return Locale.Lookup(m_CannotPlacedOnTextKey, Locale.Lookup(nameKey));
end

-- Check if the position is adjacent to land.
function IsAdjacentToLandPlot(playerID, x, y)
    -- Cannot use plot:IsAdjacentToLand() since it'll include unrevealed plots.
    local adjPlots = Map.GetAdjacentPlots(x, y);
    for i, plot in ipairs(adjPlots) do
        if plot and IsPlotRevealedToPlayer(plot, playerID) and not plot:IsWater() then
            return true;
        end
    end
    return false;
end

-- Check if the position is adjacent to coast.
function IsAdjacentToCoast(playerID, x, y)
    -- Cannot use plot:IsCoastalLand() since it'll include unrevealed plots.
    local adjPlots = Map.GetAdjacentPlots(x, y);
    for i, plot in ipairs(adjPlots) do
        if plot and IsPlotRevealedToPlayer(plot, playerID) and plot:IsWater() and not plot:IsLake() then
            return true;
        end
    end
    return false;
end

-- Check if the position is adjacent to mountain.
function IsAdjacentToMountain(playerID, x, y)
    local adjPlots = Map.GetAdjacentPlots(x, y);
    for i, plot in ipairs(adjPlots) do
        if plot and IsPlotRevealedToPlayer(plot, playerID) and plot:IsMountain() then
            return true;
        end
    end
    return false;
end

-- Check if the position is adjacent to river.
function IsAdjacentToRiver(playerID, x, y)
    local plot = Map.GetPlot(x, y);
    return plot and plot:IsRiver() and IsPlotRevealedToPlayer(plot, playerID);
end

-- Check if the position is on lake.
function IsOnLake(playerID, x, y)
    local plot = Map.GetPlot(x, y);
    return plot and plot:IsLake() and IsPlotRevealedToPlayer(plot, playerID);
end

-- Check if the position is adjacent to a certain resource.
function IsAdjacentToResource(playerID, x, y, targetResource)
    local adjPlots = Map.GetAdjacentPlots(x, y);
    for i, plot in ipairs(adjPlots) do
        if plot then
            local adjPinSubject = MapPinSubjectManager.GetPin(playerID, plot:GetX(), plot:GetY());
            local features = GetRealizedPlotFeatures(playerID, plot, adjPinSubject);
            if features[AdjacencyBonusTypes.ADJACENCY_RESOURCE] == targetResource then
                return true;
            end
        end
    end
    return false;
end

-- Check if the position is adjacent to a certain improvement.
function IsAdjacentToImprovement(playerID, x, y, targetImprovement)
    local adjPlots = Map.GetAdjacentPlots(x, y);
    for i, plot in ipairs(adjPlots) do
        if plot then
            local adjPinSubject = MapPinSubjectManager.GetPin(playerID, plot:GetX(), plot:GetY());
            local features = GetRealizedPlotFeatures(playerID, plot, adjPinSubject);
            if features[AdjacencyBonusTypes.ADJACENCY_IMPROVEMENT] == targetImprovement then
                return true;
            end
        end
    end
    return false;
end

-- Check if the position is adjacent to player capital.
function IsAdjacentToCapital(playerID, x, y)
    local adjPlots = Map.GetAdjacentPlots(x, y);
    for i, plot in ipairs(adjPlots) do
        if plot then
            local city = Cities.GetCityInPlot(plot:GetX(), plot:GetY());
            if city and city:IsCapital() and city:GetOwner() == playerID then return true; end
        end
    end
    return false;
end

-- Check if the position is adjacent to a city center.
-- Return: if the position is adjacent to a city center and the direction for that city center.
function IsAdjacentToCityCenter(playerID, x, y)
    return IsAdjacentToDistrict(playerID, x, y, "DISTRICT_CITY_CENTER");
end

-- Check if the position is adjacent to a certain district.
-- Return: if the position is adjacent to a certain district and the direction for that district.
function IsAdjacentToDistrict(playerID, x, y, targetDistrict)
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1, 1 do
        local plot = Map.GetAdjacentPlot(x, y, direction);
        if plot then
            local adjPinSubject = MapPinSubjectManager.GetPin(playerID, plot:GetX(), plot:GetY());
            local features = GetRealizedPlotFeatures(playerID, plot, adjPinSubject);
            local districtType = features[AdjacencyBonusTypes.ADJACENCY_DISTRICT];
            -- Replace UDs with standard districts.
            if districtType and GameInfo.DistrictReplaces[districtType] then
                districtType = GameInfo.DistrictReplaces[districtType].ReplacesDistrictType;
            end
            -- Is plot owned by others?
            local isOwnedByOthers = plot:IsOwned() and plot:GetOwner() ~= playerID;
            if districtType == targetDistrict and not isOwnedByOthers then
                return true, direction;
            end
        end
    end
    return false;
end

-- Check if city center can be placed on the given position.
function IsValidCityCenterPosition(playerID, x, y)
    local isValid = true;
    local plotsWithin3Tiles = GetPlotsWithinXTiles(x, y, 3);
    for _, plot in ipairs(plotsWithin3Tiles) do
        if plot and not (plot:GetX() == x and plot:GetY() == y) then -- Don't need to do visibility check since player can see if there's a city center already.
            local pinSubject = MapPinSubjectManager.GetPin(playerID, plot:GetX(), plot:GetY());
            local features = GetRealizedPlotFeatures(playerID, plot, pinSubject);
            if IsCityCenter(features[AdjacencyBonusTypes.ADJACENCY_DISTRICT]) then
                isValid = false;
                -- Update the other city center map pin if there's any.
                if pinSubject and IsCityCenter(pinSubject.Key) then
                    pinSubject.CanPlace = false;
                    pinSubject.CanPlaceToolTip = Locale.Lookup("LOC_HUD_UNIT_PANEL_TOOLTIP_TOO_CLOSE_TO_CITY");
                    MapPinSubjectManager.UpdatePin(playerID, pinSubject.X, pinSubject.Y, pinSubject);
                    LuaEvents.DMT_RefreshMapPinUI(playerID, pinSubject.Id);
                end
            end
        end
    end
    return isValid;
end

-- Check if aqueduct can be placed on the given position.
function IsValidAqueductPosition(playerID, x, y)
    local adjCityCenter, cityCenterDirection = IsAdjacentToCityCenter(playerID, x, y);
    if adjCityCenter then
        local plotToCheck = Map.GetPlot(x, y);
        for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1, 1 do
            if direction ~= cityCenterDirection then
                local plot = Map.GetAdjacentPlot(x, y, direction);
                if plot and IsPlotRevealedToPlayer(plot, playerID) then
                    if plot:IsRiver() and plotToCheck:IsRiverCrossingToPlot(plot) then
                        -- If the plot has river adjacent, need to check if it shares with the current plot.
                        return true;
                    else
                        -- The plot doesn't have river, then check if it has lake, mountain, or oasis.
                        if plot:IsLake() or plot:IsMountain() or plot:GetFeatureType() == GameInfo.Features["FEATURE_OASIS"].Index then
                            return true;
                        end
                    end
                end
            end
        end
    end
    return false;
end

-- Check if dam can be placed on the given position.
function IsValidDamPosition(playerID, x, y)
    local plotToCheck = Map.GetPlot(x, y);
    -- Sanity check first.
    if plotToCheck:GetRiverCrossingCount() < 2 then
        return false;
    end
    local isValid = true;
    local riverCrossedEdgeCount = 0;
    local adjacentFloodplainCount = 0;
    local riverTypeId = RiverManager.GetRiverForFloodplain(x, y);
    if riverTypeId ~= -1 then
        -- Crossing edges check.
        local riverIndex = -1;
        for i = 0, RiverManager.GetNumRivers() - 1, 1 do
            local river = RiverManager.GetRiverByIndex(i);
            if river.TypeID == riverTypeId then
                riverIndex = i;
                break;
            end
        end
        if riverIndex ~= -1 then
            local river = RiverManager.GetRiverByIndex(riverIndex, "edges");
            for _, plotIndexPair in ipairs(river.Edges) do
                local floodplainCheckId = -1;
                if plotToCheck:GetIndex() == plotIndexPair[1] then
                    floodplainCheckId = plotIndexPair[2];
                elseif plotToCheck:GetIndex() == plotIndexPair[2] then
                    floodplainCheckId = plotIndexPair[1];
                end
                if floodplainCheckId ~= -1 then
                    riverCrossedEdgeCount = riverCrossedEdgeCount + 1;
                end
            end
        end
        -- Adjacent floodplain check.
        local adjPlots = Map.GetAdjacentPlots(x, y);
        for i, plot in ipairs(adjPlots) do
            if RiverManager.CanBeFlooded(plot) then
                adjacentFloodplainCount = adjacentFloodplainCount + 1;
            end
        end
        -- Single dam per river check.
        local riverName = RiverManager.GetRiverNameByType(riverTypeId);
        for _, plotIndex in ipairs(RiverManager.GetFloodplainPlots(riverTypeId)) do
            if plotToCheck:GetIndex() ~= plotIndex then
                local plot = Map.GetPlotByIndex(plotIndex);
                if plot and IsPlotRevealedToPlayer(plot, playerID) and riverName == RiverManager.GetRiverName(plot) then
                    local pinSubject = MapPinSubjectManager.GetPin(playerID, plot:GetX(), plot:GetY());
                    local features = GetRealizedPlotFeatures(playerID, plot, pinSubject);
                    if features[AdjacencyBonusTypes.ADJACENCY_DISTRICT] == "DISTRICT_DAM" then
                        isValid = false;
                        -- Update the other Dam map pin if there's any.
                        if pinSubject and pinSubject.Key == "DISTRICT_DAM" then
                            pinSubject.CanPlace = false;
                            pinSubject.CanPlaceToolTip = Locale.Lookup("LOC_DMT_INVALID_DAM_PLACEMENT_REASON");
                            MapPinSubjectManager.UpdatePin(playerID, pinSubject.X, pinSubject.Y, pinSubject);
                            LuaEvents.DMT_RefreshMapPinUI(playerID, pinSubject.Id);
                        end
                    end
                end
            end
        end
    end
    -- The plot needs to have 2 river crossing edges that touch floodplain plots that belong to the same area/river.
    if riverCrossedEdgeCount < 2 or adjacentFloodplainCount < 1 then
        return false;
    end
    return isValid;
end

-- Check if the district type is city center.
function IsCityCenter(districtType:string)
    return districtType and GameInfo.Districts[districtType] and GameInfo.Districts[districtType].CityCenter;
end

-- Check whether specialty district can be placed at the given position.
function CanPlaceSpecialtyDistrict(playerID, x, y)
    -- Gaul check.
    if not CanPlaceSpecialtyDistrictNearCityByModifier() and IsAdjacentToCityCenter(playerID, x, y) then
        return false;
    end
    return true;
end

-- Special check for golden gate bridge.
function IsValidBridgePosition(playerID, x, y)
    for direction = 0, 2, 1 do
        local refPlot = Map.GetAdjacentPlot(x, y, direction);
        local refPlot1 = Map.GetAdjacentPlot(x, y, direction + 1);
        local refPlot2 = Map.GetAdjacentPlot(x, y, direction + 2);
        local refPlot3 = Map.GetAdjacentPlot(x, y, direction + 3);
        local refPlot4 = Map.GetAdjacentPlot(x, y, (direction + 4) % 6); -- DirectionTypes.NUM_DIRECTION_TYPES = 6
        local refPlot5 = Map.GetAdjacentPlot(x, y, (direction + 5) % 6); -- DirectionTypes.NUM_DIRECTION_TYPES = 6
        local isRefPlotWater = refPlot and refPlot:IsWater() and IsPlotRevealedToPlayer(refPlot, playerID);
        local isRefPlot1Water = refPlot1 and refPlot1:IsWater() and IsPlotRevealedToPlayer(refPlot1, playerID);
        local isRefPlot2Water = refPlot2 and refPlot2:IsWater() and IsPlotRevealedToPlayer(refPlot2, playerID);
        local isRefPlot3Water = refPlot3 and refPlot3:IsWater() and IsPlotRevealedToPlayer(refPlot3, playerID);
        local isRefPlot4Water = refPlot4 and refPlot4:IsWater() and IsPlotRevealedToPlayer(refPlot4, playerID);
        local isRefPlot5Water = refPlot5 and refPlot5:IsWater() and IsPlotRevealedToPlayer(refPlot5, playerID);
        local areTwoEndLands = not isRefPlotWater and not isRefPlot3Water;
        local rightSideWater = isRefPlot1Water or isRefPlot2Water;
        local leftSideWater = isRefPlot4Water or isRefPlot5Water;
        if areTwoEndLands and rightSideWater and leftSideWater then return true; end
    end
    return false;
end

-- Get a table of adjacency bonus types for the given plot, with the assumption
-- that the MapPin specified district or improvement will be placed here.
-- Any feature or resource that will be cleared after placed will be considered as cleared.
--
-- Params:
--     playerID:   id of the player to check.
--     plot:       plot object to check.
--     pinSubject: MapPinSubject on this plot, if there's any. Nil if there isn't a MapPin.
-- Return: a table of adjacency bonus types
-- Example:
-- {
--     AdjacencyBonusTypes.ADJACENCY_FEATURE: "FEATURE_JUNGLE",
--     AdjacencyBonusTypes.ADJACENCY_IMPROVEMENT: "IMPROVEMENT_MINE",
--     AdjacencyBonusTypes.ADJACENCY_RESOURCE: "RESOURCE_COAL",
--     AdjacencyBonusTypes.ADJACENCY_TERRAIN: "TERRAIN_GRASS_HILLS"
-- }
-- or
-- {
--     AdjacencyBonusTypes.ADJACENCY_DISTRICT: "DISTRICT_CAMPUS",
--     AdjacencyBonusTypes.ADJACENCY_TERRAIN: "TERRAIN_PLAINS_HILLS"
-- }
-- or
-- {
--     AdjacencyBonusTypes.ADJACENCY_TERRAIN: "TERRAIN_DESERT_MOUNTAIN"
-- }
-- or
-- {
--     AdjacencyBonusTypes.ADJACENCY_NATURAL_WONDER: "FEATURE_LAKE_RETBA",
--     AdjacencyBonusTypes.ADJACENCY_TERRAIN: "TERRAIN_COAST"
-- }
-- or
-- {
--     AdjacencyBonusTypes.ADJACENCY_WONDER: "BUILDING_PYRAMIDS",
--     AdjacencyBonusTypes.ADJACENCY_FEATURE: "FEATURE_FLOODPLAINS",
--     AdjacencyBonusTypes.ADJACENCY_TERRAIN: "TERRAIN_DESERT"
-- }
function GetRealizedPlotFeatures(playerID:number, plot:table, pinSubject:table)
    -- Check cache first before doing calculation.
    local cacheKey = GetCacheKey(plot:GetX(), plot:GetY());
    local features = m_CachedPlotFeatures[cacheKey];
    if features then return features; end

    features = {};

    -- Get plot's features.
    local terrainType, featureType, improvementType, wonderType, districtType, resourceType = GetPlotFeatureTypes(plot, playerID);
    local bIsNaturalWonder = IsNaturalWonder(featureType);
    local bIsResourceVisible = IsResourceVisible(playerID, resourceType);

    -- Terrain will always be added.
    features[AdjacencyBonusTypes.ADJACENCY_TERRAIN] = terrainType;

    -- Add the resource if it is visible to the player.
    local canKeepResource = bIsResourceVisible and ((districtType ~= nil)
        or (pinSubject == nil)
        or (pinSubject.Type == MAP_PIN_TYPES.UNKNOWN)
        or (pinSubject.Type == MAP_PIN_TYPES.IMPROVEMENT and ImprovementValidResource[GetCacheKey(pinSubject.Key, resourceType)])
        or (pinSubject.Type == MAP_PIN_TYPES.DISTRICT and pinSubject.Key == "DISTRICT_CITY_CENTER"));
    if canKeepResource then
        features[AdjacencyBonusTypes.ADJACENCY_RESOURCE] = resourceType;
        features[AdjacencyBonusTypes.ADJACENCY_RESOURCE_CLASS] = GameInfo.Resources[resourceType].ResourceClassType;
        -- Check for sea resources.
        if GameInfo.Terrains[terrainType].Water then
            -- The resource is on a water terrain, so it is a sea resource.
            features[AdjacencyBonusTypes.ADJACENCY_SEA_RESOURCE] = resourceType;
        end
    end

    -- If the plot already has a district or wonder or natural wonder, the MapPin won't be able to place.
    -- Then simply add the plot's info. Same if we don't have a MapPin or it's an uncheckable pin.
    if districtType or wonderType or bIsNaturalWonder or (pinSubject == nil) or (pinSubject.Type == MAP_PIN_TYPES.UNKNOWN) then
        -- It's ok to add nil values, since they will be ignored.
        features[AdjacencyBonusTypes.ADJACENCY_FEATURE] = featureType;
        features[AdjacencyBonusTypes.ADJACENCY_IMPROVEMENT] = improvementType;
        -- District and Wonder.
        if districtType == "DISTRICT_WONDER" then
            features[AdjacencyBonusTypes.ADJACENCY_WONDER] = wonderType or districtType;
            -- Don't need to add DISTRICT_WONDER as district.
        else
            features[AdjacencyBonusTypes.ADJACENCY_WONDER] = wonderType;
            features[AdjacencyBonusTypes.ADJACENCY_DISTRICT] = districtType;
            -- Non owner district check.
            if districtType and plot:IsOwned() and plot:GetOwner() ~= playerID then
                features["NON_OWNER_DISTRICT"] = districtType;
            end
        end
        -- Natural wonder.
        if bIsNaturalWonder then
            features[AdjacencyBonusTypes.ADJACENCY_NATURAL_WONDER] = featureType;
        end
    else
        -- We have a MapPin and the MapPin can be placed.
        local pinType = pinSubject.Type;
        local pinKey = pinSubject.Key;

        if pinType == MAP_PIN_TYPES.IMPROVEMENT then
            -- Add the improvement itself.
            features[AdjacencyBonusTypes.ADJACENCY_IMPROVEMENT] = pinKey;
            -- Check if the improvement can be placed on this feature.
            -- If the improvement can be placed on the resource on top of this feature, this feature can be kept.
            local canKeepFeature = canKeepResource or ImprovementValidFeature[GetCacheKey(pinKey, featureType)];
            if canKeepFeature then
                features[AdjacencyBonusTypes.ADJACENCY_FEATURE] = featureType;
            end
        elseif pinType == MAP_PIN_TYPES.DISTRICT then
            -- Add the district itself.
            features[AdjacencyBonusTypes.ADJACENCY_DISTRICT] = pinKey;
            -- Only add feature if it won't be removed by after placing the district.
            if not WillDistrictRemoveFeature(pinKey, featureType) then
                features[AdjacencyBonusTypes.ADJACENCY_FEATURE] = featureType;
            end
        elseif pinType == MAP_PIN_TYPES.WONDER then
            -- Add the wonder itself.
            features[AdjacencyBonusTypes.ADJACENCY_WONDER] = pinKey;
            -- Only add feature if it won't be removed by after placing the wonder.
            if not WillWonderRemoveFeature(pinKey, featureType) then
                features[AdjacencyBonusTypes.ADJACENCY_FEATURE] = featureType;
            end
        end
    end

    -- Add the feature type if it is not removable.
    if featureType ~= nil and not GameInfo.Features[featureType].Removable then
        features[AdjacencyBonusTypes.ADJACENCY_FEATURE] = featureType;
    end

    -- Store calculated result to cache for speed up adjacent plot's calculation.
    m_CachedPlotFeatures[cacheKey] = features;

    return features;
end

-- Has the plot been revealed to the given player.
function IsPlotRevealedToPlayer(plot:table, playerID:number)
    local isPlotRevealed = PlayersVisibility[playerID]:IsRevealed(plot:GetIndex());
    m_HiddenPlotsToCheck[GetCacheKey(plot:GetX(), plot:GetY())] = not isPlotRevealed;
    return isPlotRevealed;
end

-- Get plot's feature types.
function GetPlotFeatureTypes(plot:table, playerID:number)
    -- If the plot is invisible to the player, hide the plot information
    if not IsPlotRevealedToPlayer(plot, playerID) then
        return nil, nil, nil, nil, nil, nil;
    end

    local terrainIndex = plot:GetTerrainType();
    local featureIndex = plot:GetFeatureType();
    local improvementIndex = plot:GetImprovementType();
    local resourceIndex = plot:GetResourceType();
    local wonderIndex = plot:GetWonderType();
    local districtIndex = plot:GetDistrictType();

    local terrainType = nil;
    if terrainIndex ~= -1 then terrainType = GameInfo.Terrains[terrainIndex].TerrainType; end

    local featureType = nil;
    if featureIndex ~= -1 then featureType = GameInfo.Features[featureIndex].FeatureType; end

    local improvementType = nil;
    if improvementIndex ~= -1 then improvementType = GameInfo.Improvements[improvementIndex].ImprovementType; end

    local wonderType = nil;
    -- This won't be 100% accurate. When the wonder is just built, the wonderIndex will still be -1 until next turn.
    if wonderIndex ~= -1 then wonderType = GameInfo.Buildings[wonderIndex].BuildingType; end

    local districtType = nil;
    if districtIndex ~= -1 then districtType = GameInfo.Districts[districtIndex].DistrictType; end

    local resourceType = nil;
    if resourceIndex ~= -1 then resourceType = GameInfo.Resources[resourceIndex].ResourceType; end

    -- TODO: Add pillage check.
    return terrainType, featureType, improvementType, wonderType, districtType, resourceType;
end

-- Check if the given feature type is a natural wonder feature.
function IsNaturalWonder(featureType:string)
    if featureType == nil then
        return false;
    end
    local feature = GameInfo.Features[featureType];
    return feature ~= nil and feature.NaturalWonder;
end

-- Check if the resource is visible to this player.
function IsResourceVisible(playerID:number, resourceType:string)
    if resourceType == nil then
        return false;
    end
    local player = Players[playerID];
    local resourceHash = GameInfo.Resources[resourceType].Hash;
    return player:GetResources():IsResourceVisible(resourceHash);
end

-- Check if placing the given wonder will remove the plot feature.
function WillWonderRemoveFeature(wonderType:string, featureType:string)
    if wonderType == nil or featureType == nil then return false; end
    if IsFeatureValidForPlacement(featureType, true) then return false; end
    local key = GetCacheKey(wonderType, featureType);
    return not BuildingRequiredFeature[key] and not BuildingValidFeature[key];
end

-- Check if placing the given district will remove the plot feature.
function WillDistrictRemoveFeature(districtType:string, featureType:string)
    if districtType == nil or featureType == nil then return false; end
    if IsFeatureValidForPlacement(featureType, false) then return false; end
    if CanDistrictPlaceOnFeatureByModifier(districtType, featureType) then return false; end
    local key = GetCacheKey(districtType, featureType);
    return not DistrictRequiredFeature[key];
end

-- Check if the feature is valid for district or wonder placements.
-- (Mainly used for floodplains and volcanic soil check)
function IsFeatureValidForPlacement(featureType:string, isWonder:boolean)
    if isXP2Active then
        local featureRow = GameInfo.Features_XP2[featureType];
        if featureRow then
            if isWonder then
                return featureRow.ValidWonderPlacement;
            else
                return featureRow.ValidDistrictPlacement;
            end
        end
    end
    return false;
end

-- Get bonus yield of the given MapPin on the given plot.
--
-- Params:
--     playerID:   id of the player to check.
--     pinSubject: MapPin subject on this plot, this shouldn't be nil.
-- Return: the summarized total bonus yield per type and the yield tooltip.
-- Example:
-- {
--     "YIELD_GOLD": 10,
--     "YIELD_FAITH": 2
-- },
-- +2 [ICON_Gold] Gold from the adjacent City Center district.
function GetBonusYields(playerID:number, pinSubject:table)
    local currentPlot = Map.GetPlot(pinSubject.X, pinSubject.Y);

    local allFeatures = {};
    local adjPlots = Map.GetAdjacentPlots(pinSubject.X, pinSubject.Y);
    for i, plot in ipairs(adjPlots) do
        if plot ~= nil then
            local adjPinSubject = MapPinSubjectManager.GetPin(playerID, plot:GetX(), plot:GetY());

            local features = GetRealizedPlotFeatures(playerID, plot, adjPinSubject);
            for adjType, adjTarget in pairs(features) do
                allFeatures[adjType] = allFeatures[adjType] or {};
                allFeatures[adjType][adjTarget] = allFeatures[adjType][adjTarget] or 0;
                allFeatures[adjType][adjTarget] = allFeatures[adjType][adjTarget] + 1;
            end
        end
    end

    local bonusYields = {};
    local bonusYieldToolTipsRaw = {};
    -- Get the list of yield changes that could contribute to this MapPin represented subject.
    local yieldChanges = {};
    if pinSubject.Type == MAP_PIN_TYPES.DISTRICT then
        yieldChanges = GetYieldChangesForDistrict(playerID, pinSubject.Key);
    elseif pinSubject.Type == MAP_PIN_TYPES.IMPROVEMENT then
        yieldChanges = GetYieldChangesForImprovement(playerID, pinSubject.Key);
    end

    -- Calculate yield changes by checking the features that could contribute.
    for _, adjID in ipairs(yieldChanges) do
        local yieldType, yieldAmount, yieldToolTip = CalculateYieldFromAdjacency(adjID, allFeatures, playerID, currentPlot);
        if yieldAmount ~= 0 then
            bonusYields[yieldType] = bonusYields[yieldType] or 0;
            bonusYields[yieldType] = bonusYields[yieldType] + yieldAmount;

            -- Add tooltip if not a placeholder.
            if yieldToolTip ~= "Placeholder" then
                table.insert(bonusYieldToolTipsRaw, {
                    Type = yieldType,
                    Amount = yieldAmount,
                    ToolTip = yieldToolTip
                });
            end
        end
    end

    -- Calculate yield from modifiers. Need to do this after adjacency calculation since some modifiers require the adjacency value.
    -- e.g. WORK_ETHIC_ADJACENCY_PRODUCTION_2 (BELIEF), GREATPERSON_HOLY_SITE_ADJACENCY_AS_SCIENCE (HILDEGARD_OF_BINGEN)
    -- BonusYields here all came from adjacency.
    if pinSubject.Type == MAP_PIN_TYPES.DISTRICT then
        -- For common type modifiers.
        local yieldTables, yieldMirrorTable = CalculateDistrictYieldFromModifiers(pinSubject, allFeatures, bonusYields, playerID);
        for _, yieldTable in ipairs(yieldTables) do
            if yieldTable.Amount ~= 0 then
                bonusYields[yieldTable.Type] = bonusYields[yieldTable.Type] or 0;
                bonusYields[yieldTable.Type] = bonusYields[yieldTable.Type] + yieldTable.Amount;
                table.insert(bonusYieldToolTipsRaw, yieldTable);
            end
        end
        -- For mirror type modifiers.
        for _, yieldMirror in ipairs(yieldMirrorTable) do
            local yieldAmount = bonusYields[yieldMirror.YieldTypeToMirror] or 0;
            if yieldAmount ~= 0 then
                local yieldType = yieldMirror.YieldTypeToGrant;
                bonusYields[yieldType] = bonusYields[yieldType] or 0;
                bonusYields[yieldType] = bonusYields[yieldType] + yieldAmount;
                -- This mirror yield will be unique, so store the final yield string directly.
                local yieldRow = GameInfo.Yields[yieldType];
                local yieldTypeStr = yieldRow.IconString .. " " .. Locale.Lookup(yieldRow.Name);
                local tooltip = Locale.Lookup(yieldMirror.ToolTip, yieldAmount, yieldTypeStr, yieldMirror.ToolTipName);
                table.insert(bonusYieldToolTipsRaw, {
                    Type = yieldType,
                    Amount = yieldAmount,
                    ToolTip = tooltip
                });
            end
        end
    elseif pinSubject.Type == MAP_PIN_TYPES.IMPROVEMENT then
        -- TODO: Add yield from improvement modifiers.
        -- Add base yields for improvements.
        local yields = GetYieldForImprovement(playerID, pinSubject.Key);
        for yieldType, yieldAmount in pairs(yields) do
            if yieldAmount ~= 0 then
                bonusYields[yieldType] = bonusYields[yieldType] or 0;
                bonusYields[yieldType] = bonusYields[yieldType] + yieldAmount;
            end
        end
    end

    local bonusYieldToolTips = GroupSameToolTips(bonusYieldToolTipsRaw);
    return bonusYields, table.concat(bonusYieldToolTips, "[NEWLINE]");
end

-- Helper function to group yield items by the same ToolTip.
function GroupSameToolTips(bonusYieldToolTipsRaw:table)
    local tooltipMap = {};
    for _, item in ipairs(bonusYieldToolTipsRaw) do
        local key = item.Type .. "@" .. Locale.Lookup(item.ToolTip, 1); -- ignore the amount.
        if tooltipMap[key] then
            tooltipMap[key].Amount = tooltipMap[key].Amount + item.Amount;
        else
            tooltipMap[key] = item;
        end
    end
    -- Sort the map so same yield type are grouped together.
    local tooltipKeys = {};
    for tooltipKey in pairs(tooltipMap) do
        table.insert(tooltipKeys, tooltipKey);
    end
    table.sort(tooltipKeys);

    local bonusYieldToolTips = {};
    for _, key in pairs(tooltipKeys) do
        local item = tooltipMap[key];
        table.insert(bonusYieldToolTips, Locale.Lookup(item.ToolTip, item.Amount));
    end
    return bonusYieldToolTips;
end

-- Calculate yields for the given Adjacency_YieldChanges ID and aggregated features the surrounding plots have.
--
-- Params:
--     adjID:   Adjacency_YieldChanges ID.
--     adjFeatures: table of features in the below format.
--                  {
--                       AdjacencyBonusTypes.ADJACENCY_FEATURE: {
--                           "FEATURE_JUNGLE": 2,
--                           "FEATURE_FOREST": 1,
--                       }
--                       ...
--                  }
-- Return: the yield type, amount, and tooltip key for the given Adjacency_YieldChanges ID.
-- Example: "YIELD_GOLD", 10, "LOC_DISTRICT_CITY_CENTER_GOLD"
function CalculateYieldFromAdjacency(adjID:string, adjFeatures:table, playerID:number, plot:table)
    local row = GameInfo.Adjacency_YieldChanges[adjID];
    local yieldType = row.YieldType;
    local yieldAmount = 0;
    local yieldToolTipKey = row.Description;

    -- Check if this adjacency doesn't apply to the player due to tech or civic.
    local player = Players[playerID];
    if (row.PrereqTech and not player:GetTechs():HasTech(GameInfo.Technologies[row.PrereqTech].Index))
        or (row.ObsoleteTech and player:GetTechs():HasTech(GameInfo.Technologies[row.ObsoleteTech].Index))
        or (row.PrereqCivic and not player:GetCulture():HasCivic(GameInfo.Civics[row.PrereqCivic].Index))
        or (row.ObsoleteCivic and player:GetCulture():HasCivic(GameInfo.Civics[row.ObsoleteCivic].Index)) then
            -- If the player doesn't have prereq or has obsolete, simply return 0 as the amount and skip the check.
            return yieldType, yieldAmount, yieldToolTipKey;
    end

    -- Check if this adjacency doesn't apply to the player due to GameInfo.ExcludedAdjacencies.
    for excludeRow in GameInfo.ExcludedAdjacencies() do
        if excludeRow.YieldChangeId == adjID then
            local playerConfig = PlayerConfigurations[playerID];
            local civName = playerConfig:GetCivilizationTypeName();
            local leaderName = playerConfig:GetLeaderTypeName();
            local traitName = excludeRow.TraitType;
            if CivilizationHasTrait(civName, traitName) or LeaderHasTrait(leaderName, traitName) then
                -- If the player doesn't apply to this adj yield due to trait, simply return 0 as the amount and skip the check.
                return yieldType, yieldAmount, yieldToolTipKey;
            end
        end
    end

    -- Check any yield from itself. Like DISTRICT_SEOWON.
    if row.Self then
        return yieldType, row.YieldChange, yieldToolTipKey;
    end

    -- Check yield from river if needed.
    if row.AdjacentRiver and IsAdjacentToRiver(playerID, plot:GetX(), plot:GetY()) then
        return yieldType, row.YieldChange, yieldToolTipKey;
    end

    -- Check yield from adjacent features.
    local adjType = nil;
    -- Group similar calculation together.
    if row.OtherDistrictAdjacent then
        adjType = AdjacencyBonusTypes.ADJACENCY_DISTRICT;
    elseif row.AdjacentResource then
        adjType = AdjacencyBonusTypes.ADJACENCY_RESOURCE;
    elseif row.AdjacentSeaResource then
        adjType = AdjacencyBonusTypes.ADJACENCY_SEA_RESOURCE;
    elseif row.AdjacentWonder then
        adjType = AdjacencyBonusTypes.ADJACENCY_WONDER;
    elseif row.AdjacentNaturalWonder then
        adjType = AdjacencyBonusTypes.ADJACENCY_NATURAL_WONDER;
    end
    if adjType then
        local adjList = adjFeatures[adjType];
        if adjList then
            -- Get total number of adjacency items to count.
            local totalCount = 0;
            for type, count in pairs(adjList) do
                totalCount = totalCount + count;
            end
            -- Check if any district is owned by others.
            if adjType == AdjacencyBonusTypes.ADJACENCY_DISTRICT then
                local nonOwnerDistricts = adjFeatures["NON_OWNER_DISTRICT"];
                if nonOwnerDistricts then
                    local nonOwnerCount = 0;
                    for type, count in pairs(nonOwnerDistricts) do
                        nonOwnerCount = nonOwnerCount + count;
                    end
                    totalCount = totalCount - nonOwnerCount;
                end
            end
            -- Get yield.
            yieldAmount = row.YieldChange * math.floor(totalCount / row.TilesRequired);
        end
        return yieldType, yieldAmount, yieldToolTipKey;
    end

    -- Not the above types, check another group.
    local adjTarget = nil;
    if row.AdjacentTerrain then
        adjType = AdjacencyBonusTypes.ADJACENCY_TERRAIN;
        adjTarget = row.AdjacentTerrain;
    elseif row.AdjacentFeature then
        adjType = AdjacencyBonusTypes.ADJACENCY_FEATURE;
        adjTarget = row.AdjacentFeature;
    elseif row.AdjacentImprovement then
        adjType = AdjacencyBonusTypes.ADJACENCY_IMPROVEMENT;
        adjTarget = row.AdjacentImprovement;
    elseif row.AdjacentDistrict then
        adjType = AdjacencyBonusTypes.ADJACENCY_DISTRICT;
        adjTarget = row.AdjacentDistrict;
    elseif row.AdjacentResourceClass ~= "NO_RESOURCECLASS" then
        adjType = AdjacencyBonusTypes.ADJACENCY_RESOURCE_CLASS;
        adjTarget = row.AdjacentResourceClass;
    end
    if adjType then
        local adjList = adjFeatures[adjType];
        if adjList then
            local count = adjList[adjTarget];
            if count then
                yieldAmount = row.YieldChange * math.floor(count / row.TilesRequired);
            end
        end
        return yieldType, yieldAmount, yieldToolTipKey;
    end

    return yieldType, yieldAmount, yieldToolTipKey;
end

-- Get list of adjacency YieldChanges that apply for the given district.
--
-- Params:
--     playerID:     id of the player to check.
--     districtType: district type to check.
-- Return: a table of Adjacency_YieldChanges IDs that apply for the given district.
function GetYieldChangesForDistrict(playerID:number, districtType:string)
    local yieldChanges = {};
    for adjRow in GameInfo.District_Adjacencies() do
        if adjRow.DistrictType == districtType then
            table.insert(yieldChanges, adjRow.YieldChangeId);
        end
    end
    return yieldChanges;
end

-- Get list of adjacency YieldChanges that apply for the given improvement.
--
-- Params:
--     playerID:        id of the player to check.
--     improvementType: improvement type to check.
-- Return: a table of Adjacency_YieldChanges IDs that apply for the given improvement.
function GetYieldChangesForImprovement(playerID:number, improvementType:string)
    local yieldChanges = {};
    for adjRow in GameInfo.Improvement_Adjacencies() do
        if adjRow.ImprovementType == improvementType then
            table.insert(yieldChanges, adjRow.YieldChangeId);
        end
    end
    return yieldChanges;
end

-- Get given improvement's yields for the given player
--
-- Params:
--     playerID:        id of the player to check.
--     improvementType: improvement type to check.
-- Return: the yield type and amount for the given improvement.
-- {
--     "YIELD_GOLD": 10,
--     "YIELD_FAITH": 2
-- }
function GetYieldForImprovement(playerID:number, improvementType:string)
    local player = Players[playerID];
    local yields = {};
    -- Get the base yields.
    for row in GameInfo.Improvement_YieldChanges() do
        if row.ImprovementType == improvementType then
            yields[row.YieldType] = row.YieldChange;
        end
    end
    -- Get the bonus yields.
    for row in GameInfo.Improvement_BonusYieldChanges() do
        if row.ImprovementType == improvementType then
            if (row.PrereqTech and player:GetTechs():HasTech(GameInfo.Technologies[row.PrereqTech].Index))
                or (row.PrereqCivic and player:GetCulture():HasCivic(GameInfo.Civics[row.PrereqCivic].Index)) then
                    yields[row.YieldType] = yields[row.YieldType] or 0;
                    yields[row.YieldType] = yields[row.YieldType] + row.BonusYieldChange;
            end
        end
    end
    return yields;
end

function GetCacheKey(first, second)
    -- Parameters are nilable. Surround with tostring().
    return tostring(first) .. "_" .. tostring(second);
end

function InitializeCache()
    -- Buildings.
    BuildingRequiredFeature = {};
    for row in GameInfo.Building_RequiredFeatures() do
        BuildingRequiredFeature[GetCacheKey(row.BuildingType, row.FeatureType)] = true;
    end
    BuildingValidFeature = {};
    for row in GameInfo.Building_ValidFeatures() do
        BuildingValidFeature[GetCacheKey(row.BuildingType, row.FeatureType)] = true;
    end
    BuildingValidTerrain = {};
    for row in GameInfo.Building_ValidTerrains() do
        BuildingValidTerrain[GetCacheKey(row.BuildingType, row.TerrainType)] = true;
    end

    -- Districts.
    DistrictRequiredFeature = {};
    for row in GameInfo.District_RequiredFeatures() do
        DistrictRequiredFeature[GetCacheKey(row.DistrictType, row.FeatureType)] = true;
    end
    DistrictValidTerrain = {};
    for row in GameInfo.District_ValidTerrains() do
        DistrictValidTerrain[GetCacheKey(row.DistrictType, row.TerrainType)] = true;
    end

    -- Improvements.
    ImprovementValidFeature = {};
    for row in GameInfo.Improvement_ValidFeatures() do
        ImprovementValidFeature[GetCacheKey(row.ImprovementType, row.FeatureType)] = true;
    end
    ImprovementValidResource = {};
    for row in GameInfo.Improvement_ValidResources() do
        ImprovementValidResource[GetCacheKey(row.ImprovementType, row.ResourceType)] = true;
    end
end

-- Helper Functions
----CivilizationandLeaderHasTrait
function CivilizationHasTrait(sCiv, sTrait)
    for tRow in GameInfo.CivilizationTraits() do
        if (tRow.CivilizationType == sCiv and tRow.TraitType == sTrait) then
            return true;
        end
    end
    return false;
end

function LeaderHasTrait(sLeader, sTrait)
    for tRow in GameInfo.LeaderTraits() do
        if (tRow.LeaderType == sLeader and tRow.TraitType == sTrait) then
            return true;
        end
    end
    return false;
end

function GetPlayerReligionType(playerID)
    local player = Players[playerID];
    return player:GetReligion():GetReligionTypeCreated();
end

-- Get all plots that are within X tiles of the given position.
function GetPlotsWithinXTiles(x, y, numOfTiles)
    local plots = {};
    for dx = -numOfTiles, numOfTiles do
        for dy = -numOfTiles, numOfTiles do
            local otherPlot = Map.GetPlotXYWithRangeCheck(x, y, dx, dy, numOfTiles);
            if otherPlot then
                table.insert(plots, otherPlot);
            end
        end
    end
    return plots;
end

-- Check if the terrainType is water type.
function IsTerrainWater(terrainType)
    return terrainType and GameInfo.Terrains[terrainType] and GameInfo.Terrains[terrainType].Water;
end
-- =======================================================================
-- Listeners
-- =======================================================================
function OnMapPinAdded(mapPinCfg:table)
    if mapPinCfg == nil then
        return;
    end
    local playerID = mapPinCfg:GetPlayerID();
    local pin = CreateMapPinSubject(mapPinCfg);

    local pinsToUpdate = {};
    -- Need to add the newly added pin first, so that it can be processed first.
    -- In this way, the surrounding pins will include the newly added pin when they are updating.
    table.insert(pinsToUpdate, pin);
    -- Add adjacent pins to update as well.
    local adjPins = MapPinSubjectManager.GetAdjacentPins(playerID, pin.X, pin.Y);
    for _, adjPin in ipairs(adjPins) do
        table.insert(pinsToUpdate, adjPin);
    end
    -- Update.
    UpdatePinYields(playerID, pinsToUpdate);
end

function OnMapPinRemoved(mapPinCfg:table)
    if mapPinCfg == nil then
        return;
    end
    local playerID = mapPinCfg:GetPlayerID();
    local pin = CreateMapPinSubject(mapPinCfg);
    -- Don't need to perform any action if it's an UNKNOWN map pin type, i.e. no adjacency impact.
    if pin.Type == MAP_PIN_TYPES.UNKNOWN then
        return;
    end
    -- Clear the removed pin in our cache before updating adjacent pins.
    MapPinSubjectManager.ClearPin(playerID, pin.X, pin.Y);

    local pinsToUpdate = {};
    -- If a city center pin is removed, update all pins within 3 tiles
    if IsCityCenter(pin.Key) then
        local cityPlots = GetPlotsWithinXTiles(pin.X, pin.Y, 3);
        pinsToUpdate = MapPinSubjectManager.GetAllPinsOnPlots(playerID, cityPlots);
    else
        -- Otherwise update adjacent pins only.
        pinsToUpdate = MapPinSubjectManager.GetAdjacentPins(playerID, pin.X, pin.Y);
    end
    UpdatePinYields(playerID, pinsToUpdate);
end

function OnLoadGameViewStateDone()
    InitializeModifierCalculator();

    OnLocalPlayerTurnBegin(true);
end

function OnLocalPlayerTurnBegin(isFirstLoad)
    local playerID = Game.GetLocalPlayer();
    CacheEffectiveModifiers(playerID);

    m_HiddenPlotsToCheck = {};
    -- Update all pins.
    local allPins = MapPinSubjectManager.GetAllPins(playerID);
    if isFirstLoad and #allPins == 0 then
        -- If there's no pin for the first load, check if there's existing map pins
        -- (for compatible with games started before including this mod).
        local playerConfig = PlayerConfigurations[playerID];
        local playerPins = playerConfig:GetMapPins();
        for _, mapPinCfg in pairs(playerPins) do
            local pin = CreateMapPinSubject(mapPinCfg);
            if pin.Type ~= MAP_PIN_TYPES.UNKNOWN then
                MapPinSubjectManager.UpdatePin(playerID, pin.X, pin.Y, pin); -- Create the pin.
                table.insert(allPins, pin); -- Add to update candidate.
            end
        end
    end
    UpdatePinYields(playerID, allPins);
end

function OnBuildingAdded(plotX, plotY, buildingIndex, playerID)
    -- Remove the wonder pin if the added wonder matches the pin.
    if playerID ~= -1 and playerID == Game.GetLocalPlayer() then
        local pin = MapPinSubjectManager.GetPin(playerID, plotX, plotY);
        if pin ~= nil and pin.Key == GameInfo.Buildings[buildingIndex].BuildingType then
            LuaEvents.DMT_DeleteMapPinRequest(playerID, plotX, plotY);
        end
    end
end

function OnDistrictAdded(playerID, districtID, cityID, districtX, districtY, districtIndex)
    OnDistrictChanged(playerID, districtID, cityID, districtX, districtY, districtIndex);
    -- Remove the district pin if the added district matches the pin.
    if playerID ~= -1 and playerID == Game.GetLocalPlayer() then
        local pin = MapPinSubjectManager.GetPin(playerID, districtX, districtY);
        if pin ~= nil and pin.Key == GameInfo.Districts[districtIndex].DistrictType then
            LuaEvents.DMT_DeleteMapPinRequest(playerID, districtX, districtY);
        end
    end
end

function OnDistrictChanged(playerID, districtID, cityID, districtX, districtY, districtIndex)
    if playerID ~= -1 and playerID == Game.GetLocalPlayer() then
        local pinsToUpdate = {};
        -- If a city center is changed, update all pins within 3 tiles.
        if districtIndex ~= -1 and GameInfo.Districts[districtIndex].CityCenter then
            local cityPlots = GetPlotsWithinXTiles(districtX, districtY, 3);
            pinsToUpdate = MapPinSubjectManager.GetAllPinsOnPlots(playerID, cityPlots);
        else
            pinsToUpdate = MapPinSubjectManager.GetSelfAndAdjacentPins(playerID, districtX, districtY);
        end
        UpdatePinYields(playerID, pinsToUpdate);
    end
end

function OnFeatureRemovedFromMap(posX, posY)
    UpdateSelfAndAdjacentPins(Game.GetLocalPlayer(), posX, posY);
end

function OnImprovementAdded(posX, posY, improvementIndex, playerID)
    OnImprovementChanged(posX, posY, improvementIndex, playerID);
    -- Remove the improvement pin if the added improvement matches the pin.
    if playerID ~= -1 and playerID == Game.GetLocalPlayer() then
        local pin = MapPinSubjectManager.GetPin(playerID, posX, posY);
        if pin ~= nil and pin.Key == GameInfo.Improvements[improvementIndex].ImprovementType then
            LuaEvents.DMT_DeleteMapPinRequest(playerID, posX, posY);
        end
    end
end

function OnImprovementChanged(posX, posY, improvementIndex, playerID)
    UpdateSelfAndAdjacentPins(playerID, posX, posY);
end

function OnImprovementRemoved(posX, posY, playerID)
    UpdateSelfAndAdjacentPins(playerID, posX, posY);
end

function OnPlotVisibilityChanged(posX, posY, visibilityType)
    if m_HiddenPlotsToCheck[GetCacheKey(posX, posY)] then
        UpdateSelfAndAdjacentPins(Game.GetLocalPlayer(), posX, posY);
    end
end

function DMT_Initialize()
    isXP2Active = IsExpansion2Active();

    InitializeCache();

    -- Listeners for events.
    LuaEvents.DMT_UpdatePinYields.Add(UpdatePinYields);
    LuaEvents.DMT_MapPinAdded.Add(OnMapPinAdded);
    LuaEvents.DMT_MapPinRemoved.Add(OnMapPinRemoved);

    -- Listeners for Events in the Game
    Events.BuildingAddedToMap.Add(OnBuildingAdded);
    Events.DistrictAddedToMap.Add(OnDistrictAdded);
    Events.DistrictPillaged.Add(OnDistrictChanged);
    Events.DistrictRemovedFromMap.Add(OnDistrictChanged);
    Events.FeatureRemovedFromMap.Add(OnFeatureRemovedFromMap);
    Events.ImprovementChanged.Add(OnImprovementChanged);
    Events.ImprovementAddedToMap.Add(OnImprovementAdded);
    Events.ImprovementRemovedFromMap.Add(OnImprovementRemoved);
    Events.PlotVisibilityChanged.Add(OnPlotVisibilityChanged);
    Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone); -- LocalPlayerTurnBegin won't trigger when the game is first loaded.
    Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBegin);
end

DMT_Initialize();
