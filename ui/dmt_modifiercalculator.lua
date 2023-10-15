-- =======================================================================
--  Copyright (c) 2021-03 wltk, DeepLogic. All rights reserved.
-- =======================================================================

print("Loading DMT_ModifierCalculator.lua");

include( "dmt_modifierrequirementchecker" );
-- =======================================================================
-- Defining ModifierSubject that would be used within this file:
-- The subject will contain these fields
--
-- ObjId: id of the modifier object. e.g. 666
-- OwnerId: id of the owner of this modifier. e.g. 666
-- ModifierId: id of the modifier. e.g. TRAIT_CAMPUS_RIVER_ADJACENCY
-- ModifierType: modifier type of the modifier. e.g. MODIFIER_PLAYER_CITIES_RIVER_ADJACENCY
-- CollectionType: collection type of the modifier. e.g. COLLECTION_PLAYER_CITIES
-- EffectType: effect type of the modifier. e.g. EFFECT_RIVER_ADJACENCY
-- Arguments: argument table that are specified for this modifier. 
--            e.g. {
--                DistrictType = "DISTRICT_CAMPUS",
--                Description = "LOC_DISTRICT_RIVER_SCIENCE",
--                Amount = "2",
--                YieldType = "YIELD_SCIENCE",
--            }
-- Subjects: subject table that the modifier applies to.
-- Requirements: a table of requirement ids that the modifier requires.
-- RequirementLogic: "ALL" or "ANY".
--
-- =======================================================================

-- =======================================================================
-- Constants
-- =======================================================================
local OBJ_TYPE_CITY = "LOC_MODIFIER_OBJECT_CITY";
local OBJ_TYPE_DISTRICT = "LOC_MODIFIER_OBJECT_DISTRICT";
local OBJ_TYPE_PLAYER = "LOC_MODIFIER_OBJECT_PLAYER";
local OBJ_TYPE_BELIEF = "LOC_MODIFIER_OBJECT_BELIEF";

local DEFAULT_MODIFIER_TOOLTIP_KEY = "LOC_DMT_YIELD_FROM_MODIFIER_DEFAULT";

local COLLECTION_TYPE_TO_CHECK = {
    COLLECTION_ALL_CITIES = true,
    COLLECTION_ALL_DISTRICTS = true,
    -- COLLECTION_CITY_PLOT_YIELDS = true,
    COLLECTION_OWNER = true,
    COLLECTION_PLAYER_CITIES = true,
    COLLECTION_PLAYER_DISTRICTS = true,
};

local EFFECT_TYPE_TO_CHECK = {
    EFFECT_ADJUST_DISTRICT_YIELD_BASED_ON_ADJACENCY_BONUS = true,
    EFFECT_ADJUST_PLAYER_FEAUTE_REQUIRED_FOR_SPECIALTY_DISTRICTS = true, -- for Vietnam.
    EFFECT_ADJUST_PLAYER_SPECIALTY_DISTRICT_CANNOT_BE_BUILT_ADJACENT_TO_CITY = true, -- for Gaul.
    EFFECT_ADJUST_VALID_FEATURES_DISTRICTS = true,
    -- EFFECT_ADJUST_PLOT_YIELD = true,
    -- EFFECT_ATTACH_MODIFIER = true,
    EFFECT_DISTRICT_ADJACENCY = true,
    EFFECT_FEATURE_ADJACENCY = true,
    EFFECT_IMPROVEMENT_ADJACENCY = true,
    EFFECT_TERRAIN_ADJACENCY = true,
    EFFECT_RIVER_ADJACENCY = true,
};

-- =======================================================================
-- Members
-- =======================================================================

-- DistrictType/ImprovementType => (ModifierId => ModifierSubject)
local m_GroupedModifiers = {}; -- Note: This assumes the same modifier will only apply once.
local m_ModifiersToSkip = {}; -- Modifier ids that are added under EFFECT_ATTACH_MODIFIER

local m_SpecialtyDistrictRequiredFeatures = {}; -- list of required features to put special districts on.
local m_ValidDistrictFeatures = {}; -- list of valid features to put districts on.

local m_NoSpecialtyDistrictNearCity = false; -- For Gaul.

function InitializeModifierCalculator()
    InitializeRequirementChecker();
end

-- Get the effective modifier subjects for the given player.
--
-- Params:
--     playerID: id of the player to check.
-- Return: a table of modifier subjects.
function CacheEffectiveModifiers(playerID:number)
    -- Only need to check for the local players.
    if playerID ~= Game.GetLocalPlayer() then return; end

    -- Clear caches.
    m_GroupedModifiers = {};
    m_SpecialtyDistrictRequiredFeatures = {};
    m_ValidDistrictFeatures = {};

    for _, modifierObjID in ipairs(GameEffects.GetModifiers()) do
        -- Check player ids.
        local isActive = GameEffects.GetModifierActive(modifierObjID);
        local ownerObjID = GameEffects.GetModifierOwner(modifierObjID);
        if isActive and IsOwnerRequirementSetMet(modifierObjID) then
            -- The modifier is active, belongs to the given player, and owner requirement set is met.
            local modifierDef = GameEffects.GetModifierDefinition(modifierObjID);
            local subjectObjs = GameEffects.GetModifierSubjects(modifierObjID) or {};

            local modifierSubject = GetModifierSubjectById(modifierDef.Id, playerID, ownerObjID);
            if modifierSubject then
                modifierSubject.ObjId = modifierObjID;
                modifierSubject.Arguments = modifierDef.Arguments;
                modifierSubject.Subjects = subjectObjs;
                GroupAndCacheModifier(modifierSubject);
            end
        end
    end
end

-- Check if the modifier's collection type should be checked later for the given player.
function FilterByCollectionType(ownerObjID:number, playerID:number, collectionType:string)
    if not COLLECTION_TYPE_TO_CHECK[collectionType] then return false; end
    if collectionType == "COLLECTION_ALL_CITIES"
        or collectionType == "COLLECTION_ALL_DISTRICTS" then
            -- "All" collection types all apply.
            return true;
    elseif ownerObjID == nil then
        return false; -- If owner obj id is nil, filter by default.
    else
        return GameEffects.GetObjectsPlayerId(ownerObjID) == playerID;
    end
end

-- Helper function to group modifiers by the types (district or improvement) that they apply to.
-- Currently only district related effect types were added.
function GroupAndCacheModifier(modifierSubject:table)
    -- Group modifiers by owner type.
    local ownerId = modifierSubject.OwnerId;
    local ownerObjName = GameEffects.GetObjectName(ownerId); -- e.g. LOC_DISTRICT_HOLY_SITE_NAME
    local ownerObjType = GameEffects.GetObjectType(ownerId);

    if ownerObjType == OBJ_TYPE_DISTRICT then
        local districtType = GetDistrictTypeByName(ownerObjName);
        if districtType then
            m_GroupedModifiers[districtType] = m_GroupedModifiers[districtType] or {};
            m_GroupedModifiers[districtType][modifierSubject.ModifierId] = modifierSubject;
        end
    end

    -- Group modifiers by effect type and requirement type.
    local effectType = modifierSubject.EffectType;
    if effectType == "EFFECT_DISTRICT_ADJACENCY"
        or effectType == "EFFECT_FEATURE_ADJACENCY"
        or effectType == "EFFECT_IMPROVEMENT_ADJACENCY"
        or effectType == "EFFECT_TERRAIN_ADJACENCY"
        or effectType == "EFFECT_RIVER_ADJACENCY" then
            -- They all have "DistrictType" as one of the arguments.
            local arguments = modifierSubject.Arguments;
            if arguments then
                local districtType = arguments.DistrictType;
                if districtType then
                    m_GroupedModifiers[districtType] = m_GroupedModifiers[districtType] or {};
                    m_GroupedModifiers[districtType][modifierSubject.ModifierId] = modifierSubject;
                end
            end
    elseif effectType == "EFFECT_ADJUST_DISTRICT_YIELD_BASED_ON_ADJACENCY_BONUS" then
        for _, requirementId in ipairs(modifierSubject.Requirements) do
            -- Check if district type is from requirements
            local districtType = GetModifierRequirementArgValue(requirementId, "DistrictType");
            if districtType then
                m_GroupedModifiers[districtType] = m_GroupedModifiers[districtType] or {};
                m_GroupedModifiers[districtType][modifierSubject.ModifierId] = modifierSubject;
            end
        end
    elseif effectType == "EFFECT_ADJUST_PLAYER_FEAUTE_REQUIRED_FOR_SPECIALTY_DISTRICTS" then
        local arguments = modifierSubject.Arguments;
        if arguments then
            table.insert(m_SpecialtyDistrictRequiredFeatures, arguments.FeatureType);
        end
    elseif effectType == "EFFECT_ADJUST_VALID_FEATURES_DISTRICTS" then
        local arguments = modifierSubject.Arguments;
        if arguments then
            local districtType = arguments.DistrictType;
            if districtType then
                m_ValidDistrictFeatures[districtType] = m_ValidDistrictFeatures[districtType] or {};
                m_ValidDistrictFeatures[districtType][arguments.FeatureType] = true;
            end
        end
    elseif effectType == "EFFECT_ADJUST_PLOT_YIELD" then
        for _, requirementId in ipairs(modifierSubject.Requirements) do
            -- Check if improvement type is from requirements
            local improvementType = GetModifierRequirementArgValue(requirementId, "ImprovementType");
            if improvementType then
                m_GroupedModifiers[improvementType] = m_GroupedModifiers[improvementType] or {};
                m_GroupedModifiers[improvementType][modifierSubject.ModifierId] = modifierSubject;
            end
        end
    elseif effectType == "EFFECT_ADJUST_PLAYER_SPECIALTY_DISTRICT_CANNOT_BE_BUILT_ADJACENT_TO_CITY" then
        m_NoSpecialtyDistrictNearCity = true;
    end
end

-- Check if the given district can be placed on the given feature type.
function CanDistrictPlaceOnFeatureByModifier(districtType:string, featureType:string)
    -- Check valid district features first.
    if m_ValidDistrictFeatures[districtType] and m_ValidDistrictFeatures[districtType][featureType] then
        return true;
    end
    -- Check required features.
    local requireFeature = DoesDistrictRequireFeatureByModifier(districtType);
    if requireFeature then
        -- Now it has to be a special district.
        for _, validFeatureType in ipairs(m_SpecialtyDistrictRequiredFeatures) do
            if validFeatureType == featureType then
                return true;
            end
        end
    end
    return false;
end

function CanPlaceSpecialtyDistrictNearCityByModifier()
    return not m_NoSpecialtyDistrictNearCity;
end

function DoesDistrictRequireFeatureByModifier(districtType:string)
    if districtType == nil then return false; end
    local districtRow = GameInfo.Districts[districtType];
    if districtRow == nil or districtRow.Coast or not IsSpecialtyDistrict(districtType) then
        -- Don't need to check if it is not land special districts.
        return false;
    end
    return #m_SpecialtyDistrictRequiredFeatures > 0;
end

function IsSpecialtyDistrict(districtType:string)
    if districtType == nil then return false; end
    local districtRow = GameInfo.Districts[districtType];
    return districtRow and districtRow.RequiresPopulation;
end

-- Calculate yields for the given district from the modifiers and the aggregated features surrounding plots have.
--
-- Params:
--     pinSubject: map pin subject to check.
--     adjFeatures: table of features for the adjacent plots.
--     adjYields: table of yields from the adjacent features.
-- Return: a table of yields with type, amount, and tooltip for the given district. And mirror type modifier if there's any.
-- Example:
-- {
--     0 = { Type = "YIELD_SCIENCE", Amount = 3, ToolTip = "LOC_DISTRICT_DISTRICT_1_SCIENCE" },
--     1 = { Type = "YIELD_FAITH", Amount = 2, ToolTip = "LOC_DISTRICT_DISTRICT_1_FAITH" },
-- },
-- {
--     0 = { YieldTypeToMirror = "YIELD_FAITH", YieldTypeToGrant = "YIELD_SCIENCE", ToolTip = "LOC_DMT_YIELD_FROM_MODIFIER_DEFAULT", ToolTipName = nil },
--     1 = { YieldTypeToMirror = "YIELD_FAITH", YieldTypeToGrant = "YIELD_PRODUCTION", ToolTip = "LOC_DMT_YIELD_FROM_MODIFIER_NAME", ToolTipName = "Work Ethic" }
-- }
function CalculateDistrictYieldFromModifiers(pinSubject:table, adjFeatures:table, adjYields:table, playerID:number)    
    local yieldTables = {};
    local yieldMirrorTable = {};

    local modifiers = m_GroupedModifiers[pinSubject.Key] or {};
    for modifierId, modifierSubject in pairs(modifiers) do
        if ShouldActivateModifier(playerID, modifierSubject, pinSubject) then
            -- Basic modifiers calculation.
            local yieldTable = CalculateDistrictYieldFromSingleModifier(modifierSubject, pinSubject, adjFeatures, adjYields, playerID);
            if yieldTable.Amount ~= 0 then
                table.insert(yieldTables, yieldTable);
            end

            -- "Mirror yield" type modifiers.
            local mirrorType = GetDistrictMirrorTypeFromModifier(modifierSubject);
            if mirrorType ~= nil then
                table.insert(yieldMirrorTable, mirrorType);
            end
        end
    end

    -- If the pin represents a replacement district, add the placement district's yields.
    if GameInfo.DistrictReplaces[pinSubject.Key] then
        local newPinSubject = CopyPinSubject(pinSubject); -- Quick copy original pin to a new one.
        newPinSubject.Key = GameInfo.DistrictReplaces[pinSubject.Key].ReplacesDistrictType;
        local replaceYieldTables, replaceMirrorTable = CalculateDistrictYieldFromModifiers(newPinSubject, adjFeatures, adjYields, playerID);
        for _, yieldTable in ipairs(replaceYieldTables) do
            table.insert(yieldTables, yieldTable);
        end
        for _, mirrorType in ipairs(replaceMirrorTable) do
            table.insert(yieldMirrorTable, mirrorType);
        end
    end

    return yieldTables, yieldMirrorTable;
end

-- Get yield for the given modifier by calculating the adjacent features and yields.
--
-- Return: a table containing yield type, amount, and tooltip for the given modifier.
function CalculateDistrictYieldFromSingleModifier(modifierSubject:table, pinSubject:table, adjFeatures:table, adjYields:table, playerID:number)
    local arguments = modifierSubject.Arguments;
    local result = {
        Type = arguments.YieldType,
        Amount = 0,
        ToolTip = arguments.Description or DEFAULT_MODIFIER_TOOLTIP_KEY
    };

    if adjFeatures == nil then return result; end

    local effectType = modifierSubject.EffectType;

    -- =================================
    -- District related effect type.
    -- =================================
    if effectType == "EFFECT_RIVER_ADJACENCY" then
        local plot = Map.GetPlot(pinSubject.X, pinSubject.Y);
        if plot:IsRiver() and PlayersVisibility[playerID]:IsRevealed(plot:GetIndex()) then
            result.Amount = arguments.Amount;
        end
        return result;
    end

    if effectType == "EFFECT_DISTRICT_ADJACENCY" then
        local adjList = adjFeatures[AdjacencyBonusTypes.ADJACENCY_DISTRICT];
        if adjList then
            -- Get total number of adjacency items to count.
            local totalCount = 0;
            for type, count in pairs(adjList) do
                totalCount = totalCount + count;
            end
            -- Check if any district is owned by others.
            local nonOwnerDistricts = adjFeatures["NON_OWNER_DISTRICT"];
            if nonOwnerDistricts then
                local nonOwnerCount = 0;
                for type, count in pairs(nonOwnerDistricts) do
                    nonOwnerCount = nonOwnerCount + count;
                end
                totalCount = totalCount - nonOwnerCount;
            end
            -- Get yield.
            result.Amount = arguments.Amount * totalCount;
        end
        return result;
    end

    -- Group similar calculation together.
    local adjType = nil;
    local adjTarget = nil;
    if effectType == "EFFECT_FEATURE_ADJACENCY" then
        adjType = AdjacencyBonusTypes.ADJACENCY_FEATURE;
        adjTarget = arguments.FeatureType;
    elseif effectType == "EFFECT_IMPROVEMENT_ADJACENCY" then
        adjType = AdjacencyBonusTypes.ADJACENCY_IMPROVEMENT;
        adjTarget = arguments.ImprovementType;
    elseif effectType == "EFFECT_TERRAIN_ADJACENCY" then
        adjType = AdjacencyBonusTypes.ADJACENCY_TERRAIN;
        adjTarget = arguments.TerrainType;
    end
    if adjType then
        local adjList = adjFeatures[adjType];
        if adjList then
            local count = adjList[adjTarget];
            if count then
                local tilesRequired = arguments.TilesRequired or 1;
                result.Amount = arguments.Amount * math.floor(count / tilesRequired);
            end
        end
        return result;
    end

    -- =================================
    -- Improvement related effect type.
    -- =================================
    -- if effectType == "EFFECT_ADJUST_PLOT_YIELD" then

    -- end

    return result;
end

-- Get yield for the modifier that has mirror type effect.
--
-- Return: yield type, amount, and tooltip for the given modifier.
-- Example:
-- { 
--    YieldTypeToMirror = "YIELD_FAITH",
--    YieldTypeToGrant = "YIELD_PRODUCTION",
--    ToolTip = "LOC_DMT_YIELD_FROM_MODIFIER_NAME",
--    ToolTipName = "LOC_BELIEF_WORK_ETHIC_NAME"
-- }
function GetDistrictMirrorTypeFromModifier(modifierSubject:table)
    if modifierSubject.EffectType == "EFFECT_ADJUST_DISTRICT_YIELD_BASED_ON_ADJACENCY_BONUS" then
        local arguments = modifierSubject.Arguments;
        local modifierOwnerName = GameEffects.GetObjectName(modifierSubject.OwnerId) or "";
        return {
            YieldTypeToMirror = arguments.YieldTypeToMirror,
            YieldTypeToGrant = arguments.YieldTypeToGrant,
            ToolTip = "LOC_DMT_YIELD_FROM_MODIFIER_NAME",
            ToolTipName = Locale.Lookup(modifierOwnerName)
        };
    end
    return nil;
end

-- Check if the given modifier should be activated for the player.
function ShouldActivateModifier(playerID:number, modifierSubject:table, pinSubject:table)
    if modifierSubject == nil then return false; end

    if modifierSubject.CollectionType == "COLLECTION_OWNER" then
        local ownerId = modifierSubject.OwnerId;
        local ownerObjType = GameEffects.GetObjectType(ownerId);

        if ownerObjType == OBJ_TYPE_DISTRICT then
            if not DoesPinMatchDistrictObj(playerID, ownerId, pinSubject) then
                -- Don't need to activate the modifier if the pin subject represented district
                -- doesn't match the modifier owner district.
                return false;
            end
        else
            -- By default don't activate modifier if collection type is "COLLECTION_OWNER".
            return false;
        end
    end

    return AreRequirementsMet(playerID, modifierSubject, pinSubject, modifierSubject.Requirements, modifierSubject.RequirementLogic);
end

-- Does the map pin match the given district object.
function DoesPinMatchDistrictObj(playerID:number, districtObjId:number, pinSubject:table)
    local player = Players[playerID];
    local districtObj = GetObjectByString(GameEffects.GetObjectString(districtObjId));
    local district = player:GetDistricts():FindID(districtObj.District);
    if district then
        local districtTypeId = district:GetType();
        if districtTypeId and districtTypeId ~= -1 then
            return district:GetX() == pinSubject.X
                and district:GetY() == pinSubject.Y
                and GameInfo.Districts[districtTypeId].DistrictType == pinSubject.Key;
        end
    end
    return false;
end

function GetDistrictTypeByName(districtName:string)
    -- return districtName:gsub("LOC_", ""):gsub("_NAME", ""); -- Probably won't work for mod introduced districts.
    for row in GameInfo.Districts() do
        if row.Name == districtName then
            return row.DistrictType;
        end
    end
    return nil;
end

-- Get the object table by the object string.
function GetObjectByString(objString:string)
    local obj = {};
    objString:gsub("[^,]+", function(itemStr)
        local key, value = itemStr:match("(%a+)[^%d]+(%d+)");
        if key then
            obj[key] = value; 
        end
    end);
    return obj;
end

-- Get a modifier subject by modifier id.
function GetModifierSubjectById(modifierId:string, playerID:number, ownerObjID:number)
    if modifierId == nil or GameInfo.Modifiers[modifierId] == nil then return nil; end
    -- Get modifier type's details.
    local modifierType = GameInfo.Modifiers[modifierId].ModifierType;
    local modifierTypeRow = GameInfo.DynamicModifiers[modifierType];
    -- We only care about the collection types and effect types that we need to handle.
    if FilterByCollectionType(ownerObjID, playerID, modifierTypeRow.CollectionType)
        and EFFECT_TYPE_TO_CHECK[modifierTypeRow.EffectType] then
            local requirementList, requirementLogic = GetModifierSubjectRequirements(modifierId);
            -- Construct a new modifier subject
            return {
                OwnerId = ownerObjID,
                ModifierId = modifierId,
                ModifierType = modifierType,
                CollectionType = modifierTypeRow.CollectionType,
                EffectType = modifierTypeRow.EffectType,
                Requirements = requirementList,
                RequirementLogic = requirementLogic,
            };
    end
    return nil;
end

-- Get given modifier's arguments by its id
function GetModifierArgsById(modifierId:string)
    if modifierId == nil then return nil; end
    local args = {};
    for row in GameInfo.ModifierArguments() do -- This is potentially slow since there are more than 8k rows.
        if row.ModifierId == modifierId then
            args[row.Name] = row.Value;
        end
    end
    return args;
end

function CopyPinSubject(pinSubject:table)
    local newPinSubject = {};
    for key, value in pairs(pinSubject) do
        newPinSubject[key] = value;
    end
    return newPinSubject;
end
