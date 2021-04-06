MapPinSubjectManager = {};
-- ======================================================================
-- Cache MapPinSubjects in the following format inside player properties:
-- {
--      "MapPinSubject" = {
--          "5_14" = mapPinSubject1:table,
--          "23_2" = mapPinSubject2:table,
--          ...
--      }
-- }
-- ======================================================================
local MAIN_CACHE_KEY = "MapPinSubject";

-- Clear the MapPinSubject at the given position.
MapPinSubjectManager.ClearPin = function(playerID, posX:number, posY:number)
    MapPinSubjectManager.UpdatePin(playerID, posX, posY, nil);
end

-- Get the MapPinSubject at the given position.
MapPinSubjectManager.GetPin = function(playerID, posX:number, posY:number)
    local player = Players[playerID];
    local mapPinSubjectProp = player:GetProperty(MAIN_CACHE_KEY) or {};
    return mapPinSubjectProp[GetCacheKey(posX, posY)];
end

-- Get adjacent pins for the given position.
MapPinSubjectManager.GetAdjacentPins = function(playerID, posX:number, posY:number)
    local player = Players[playerID];
    local mapPinSubjectProp = player:GetProperty(MAIN_CACHE_KEY) or {};
    local adjPins = {};
    local adjPlots = Map.GetAdjacentPlots(posX, posY);
    for i, plot in ipairs(adjPlots) do
        if plot ~= nil then
            local pinSubject = mapPinSubjectProp[GetCacheKey(plot:GetX(), plot:GetY())];
            if pinSubject then
                table.insert(adjPins, pinSubject);
            end
        end
    end
    return adjPins;
end

-- Get adjacent pins and the pin at the given location if there's any.
MapPinSubjectManager.GetSelfAndAdjacentPins = function(playerID, posX:number, posY:number)
    local pins = {};
    local currentPin = MapPinSubjectManager.GetPin(playerID, posX, posY);
    if currentPin == nil then
        return MapPinSubjectManager.GetAdjacentPins(playerID, posX, posY);
    end
    -- Has pin at the given location.
    table.insert(pins, currentPin);
    local adjPins = MapPinSubjectManager.GetAdjacentPins(playerID, posX, posYy);
    for _, adjPin in ipairs(adjPins) do
        table.insert(pins, adjPin);
    end
    return pins;
end

-- Get all pins on the given plots.
MapPinSubjectManager.GetAllPinsOnPlots = function(playerID, plots:table)
    local player = Players[playerID];
    local mapPinSubjectProp = player:GetProperty(MAIN_CACHE_KEY) or {};
    local allPins = {};
    for i, plot in ipairs(plots) do
        if plot ~= nil then
            local pinSubject = mapPinSubjectProp[GetCacheKey(plot:GetX(), plot:GetY())];
            if pinSubject then
                table.insert(allPins, pinSubject);
            end
        end
    end
    return allPins;
end

-- Get all pins available.
MapPinSubjectManager.GetAllPins = function(playerID)
    local allPins = {};
    local player = Players[playerID];
    local mapPinSubjectProp = player:GetProperty(MAIN_CACHE_KEY) or {};
    for key, pinSubject in pairs(mapPinSubjectProp) do
        table.insert(allPins, pinSubject);
    end
    return allPins;
end

-- Set/Update the MapPinSubject at the given position from the provided value.
MapPinSubjectManager.UpdatePin = function(playerID, posX:number, posY:number, pinSubject:table)
    local player = Players[playerID];
    local mapPinSubjectProp = player:GetProperty(MAIN_CACHE_KEY) or {};
    mapPinSubjectProp[GetCacheKey(posX, posY)] = pinSubject;
    player:SetProperty(MAIN_CACHE_KEY, mapPinSubjectProp);
end

-- Get the cache key to be used for storing MapPinSubjects.
function GetCacheKey(posX:number, posY:number)
    return posX .. "_" .. posY;
end

ExposedMembers.DMT = ExposedMembers.DMT or {};
ExposedMembers.DMT.MapPinSubjectManager = MapPinSubjectManager;
