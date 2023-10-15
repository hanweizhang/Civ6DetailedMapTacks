-- =======================================================================
--  Copyright (c) 2021-03 wltk, DeepLogic. All rights reserved.
-- =======================================================================

print("Loading DMT_ModifierRequirementChecker.lua");

-- =======================================================================
-- Members
-- =======================================================================
local m_CachedRequirementMap = {}; -- RequirementSetId => Requirement id list
local m_CachedRequirementArgsMap = {}; -- RequirementId_Name => value

function InitializeRequirementChecker()
    CacheRequirements();
    CacheRequirementArgs();
end

-- Cache requirements to get list of requirements by requirementSet faster in the game.
function CacheRequirements()
    for row in GameInfo.RequirementSetRequirements() do
        m_CachedRequirementMap[row.RequirementSetId] = m_CachedRequirementMap[row.RequirementSetId] or {};
        table.insert(m_CachedRequirementMap[row.RequirementSetId], row.RequirementId);
    end
end

-- Cache requirement arguments to get value by requirement arguments + name faster in the game.
function CacheRequirementArgs()
    for row in GameInfo.RequirementArguments() do
        m_CachedRequirementArgsMap[GetCacheKey(row.RequirementId, row.Name)] = row.Value;
    end
end

-- Get list of requirement types for the given modifier id.
function GetModifierSubjectRequirements(modifierId:string)
    local subjectRequirementSetId = GameInfo.Modifiers[modifierId].SubjectRequirementSetId;
    if subjectRequirementSetId then
        local requirementSetRow = GameInfo.RequirementSets[subjectRequirementSetId];
        local requirementList = m_CachedRequirementMap[requirementSetRow.RequirementSetId] or {};
        local requirementLogic = requirementSetRow.RequirementSetType:gsub("REQUIREMENTSET_TEST_", "") or "ALL";
        return requirementList, requirementLogic;
    end
    return {}, "ALL";
end

-- Get modifier's requirement argument's value by given requirement id and name.
function GetModifierRequirementArgValue(requirementId:string, name:string)
    return m_CachedRequirementArgsMap[GetCacheKey(requirementId, name)];
end

-- Check if the modifier's owner requirement set is met.
function IsOwnerRequirementSetMet(modifierObjId:number)
    -- Check if owner requirements are met.
    if modifierObjId ~= nil and modifierObjId ~= 0 then
        local ownerRequirementSetId = GameEffects.GetModifierOwnerRequirementSet(modifierObjId);
        if ownerRequirementSetId then
            return GameEffects.GetRequirementSetState(ownerRequirementSetId) == "Met";
        end
    end
    return true;
end

-- Check if the player has "Pantheon modifier"'s corresponding Pantheon.
function DoesPlayerHasModifierPantheon(playerID:number, ownerObjID:number)
    -- The modifier owner name will be the Pantheon's name. e.g. LOC_BELIEF_DANCE_OF_THE_AURORA_NAME.
    local modifierOwnerName = GameEffects.GetObjectName(ownerObjID);

    local player = Players[playerID];
    local belief = player:GetReligion():GetPantheon();
    if belief ~= nil and belief ~= -1 then
        return GameInfo.Beliefs[belief].Name == modifierOwnerName;
    end
    return false;
end

-- Check if the pin's city has "religion belief modifier"'s corresponding belief.
function DoesPinHasModifierReligionBelief(pinSubject:table, ownerObjID:number)
    -- Check if the pin is within a city. Return false if it is not.
    local city = Cities.GetPlotPurchaseCity(pinSubject.X, pinSubject.Y);
    if city == nil then return false; end

    -- The modifier owner name will be the Religion belief's name. e.g. LOC_BELIEF_WORK_ETHIC_NAME.
    local modifierOwnerName = GameEffects.GetObjectName(ownerObjID);

    local religionId = city:GetReligion():GetMajorityReligion();
    if religionId ~= nil and religion ~= -1 then
        local allRegions = Game.GetReligion():GetReligions();
        for _, religion in ipairs(allRegions) do
            if religion.Religion == religionId then
                for _, beliefIndex in ipairs(religion.Beliefs) do
                    if GameInfo.Beliefs[beliefIndex].Name == modifierOwnerName then
                        return true;
                    end
                end
            end
        end
    end
    return false;
end

function GetCacheKey(first, second)
    -- Parameters are nilable. Surround with tostring().
    return tostring(first) .. "_" .. tostring(second);
end

-- ========================================================================================
-- Define requirement check logic for each supported requirement below.
-- ========================================================================================
local ReqCheck = {};

ReqCheck["REQUIREMENT_DISTRICT_TYPE_MATCHES"] = function(requirementId:string, playerID:number, modifierSubject:table, pinSubject:table)
    return GetModifierRequirementArgValue(requirementId, "DistrictType") == pinSubject.Key;
end

ReqCheck["REQUIREMENT_PLOT_DISTRICT_TYPE_MATCHES"] = function(requirementId:string, playerID:number, modifierSubject:table, pinSubject:table)
    return GetModifierRequirementArgValue(requirementId, "DistrictType") == pinSubject.Key;
end

ReqCheck["REQUIREMENT_PLOT_IMPROVEMENT_TYPE_MATCHES"] = function(requirementId:string, playerID:number, modifierSubject:table, pinSubject:table)
    return GetModifierRequirementArgValue(requirementId, "ImprovementType") == pinSubject.Key;
end

ReqCheck["REQUIREMENT_CITY_FOLLOWS_PANTHEON"] = function(requirementId:string, playerID:number, modifierSubject:table, pinSubject:table)
    return DoesPlayerHasModifierPantheon(playerID, modifierSubject.OwnerId);
end

ReqCheck["REQUIREMENT_CITY_FOLLOWS_RELIGION"] = function(requirementId:string, playerID:number, modifierSubject:table, pinSubject:table)
    return DoesPinHasModifierReligionBelief(pinSubject, modifierSubject.OwnerId);
end

-- Check if the modifier's subject requirements are met.
function AreRequirementsMet(playerID:number, modifierSubject:table, pinSubject:table, requirementIds:table, requirementLogic:string)
    local result = true; -- If no requirements exist, default to "met".

    for _, requirementId in ipairs(requirementIds) do
        local isMet = false;

        local requirementType = GameInfo.Requirements[requirementId].RequirementType;

        local checkFunc = ReqCheck[requirementType];
        if checkFunc ~= nil then
            isMet = checkFunc(requirementId, playerID, modifierSubject, pinSubject);
        end

        -- Combine and check the result.
        if requirementLogic == "ANY" and isMet then
            return true;
        elseif requirementLogic == "ALL" and not isMet then
            return false;
        else
            result = result and isMet;
        end
    end

    return result;
end
