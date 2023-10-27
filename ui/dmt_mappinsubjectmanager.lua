-- =======================================================================
-- Cache MapPinSubjects in the following format inside player configuration:
-- {
--      "DMT_MapPinSubjects" = {
--          "5_14" = mapPinSubject1:table,
--          "23_2" = mapPinSubject2:table,
--          ...
--      }
-- }
-- =======================================================================

-- =======================================================================
-- Imports
-- =======================================================================
include("SupportFunctions"); -- DeepCompare
include("dmt_serialize"); -- Serialize and Deserialize

-- =======================================================================
-- Constants
-- =======================================================================
local MAIN_CACHE_KEY:string = "DMT_MapPinSubjects";

-- =======================================================================
-- Members
-- =======================================================================
local bUnbroadcastedChanges:boolean = false;

-- =======================================================================
-- Functions
-- =======================================================================
-- Clear the MapPinSubject at the given position.
function ClearMapPinSubject(playerID:number, posX:number, posY:number)
    UpdateMapPinSubject(playerID, posX, posY, nil);
end

-- Get the MapPinSubject at the given position.
function GetMapPinSubject(playerID:number, posX:number, posY:number)
    local mapPinSubjectTable = LoadMapPinSubjectTable(playerID, MAIN_CACHE_KEY) or {};
    return mapPinSubjectTable[GetMapPinSubjectCacheKey(posX, posY)];
end

-- Get adjacent pins for the given position.
function GetAdjacentMapPinSubjects(playerID:number, posX:number, posY:number)
    local mapPinSubjectTable = LoadMapPinSubjectTable(playerID, MAIN_CACHE_KEY) or {};
    local adjPins = {};
    local adjPlots = Map.GetAdjacentPlots(posX, posY);
    for i, plot in pairs(adjPlots) do
        if plot ~= nil then
            local pinSubject = mapPinSubjectTable[GetMapPinSubjectCacheKey(plot:GetX(), plot:GetY())];
            if pinSubject then
                table.insert(adjPins, pinSubject);
            end
        end
    end
    return adjPins;
end

-- Get adjacent pins and the pin at the given location if there's any.
function GetSelfAndAdjacentMapPinSubjects(playerID:number, posX:number, posY:number)
    local pins = {};
    local currentPin = GetMapPinSubject(playerID, posX, posY);
    if currentPin == nil then
        return GetAdjacentMapPinSubjects(playerID, posX, posY);
    end
    -- Has pin at the given location.
    table.insert(pins, currentPin);
    local adjPins = GetAdjacentMapPinSubjects(playerID, posX, posY);
    for _, adjPin in ipairs(adjPins) do
        table.insert(pins, adjPin);
    end
    return pins;
end

-- Get all pins on the given plots.
function GetAllMapPinSubjectsOnPlots(playerID:number, plots:table)
    local mapPinSubjectTable = LoadMapPinSubjectTable(playerID, MAIN_CACHE_KEY) or {};
    local allPins = {};
    for i, plot in pairs(plots) do
        if plot ~= nil then
            local pinSubject = mapPinSubjectTable[GetMapPinSubjectCacheKey(plot:GetX(), plot:GetY())];
            if pinSubject then
                table.insert(allPins, pinSubject);
            end
        end
    end
    return allPins;
end

-- Get all pins available.
function GetAllMapPinSubjects(playerID:number)
    local allPins = {};
    local mapPinSubjectTable = LoadMapPinSubjectTable(playerID, MAIN_CACHE_KEY) or {};
    for key, pinSubject in pairs(mapPinSubjectTable) do
        table.insert(allPins, pinSubject);
    end
    return allPins;
end

-- Set/Update the MapPinSubject at the given position from the provided value.
function UpdateMapPinSubject(playerID:number, posX:number, posY:number, pinSubject:table)
    -- Get the saved MapPinSubject data for the plot
    local mapPinSubjectTable = LoadMapPinSubjectTable(playerID, MAIN_CACHE_KEY) or {};
    local savedPinSubject = mapPinSubjectTable[GetMapPinSubjectCacheKey(posX, posY)];
    -- Skip if there is no difference between the saved data and the new data
    if DeepCompare(savedPinSubject, pinSubject) then
        return;
    end
    -- Save the new MapPinSubject data
    mapPinSubjectTable[GetMapPinSubjectCacheKey(posX, posY)] = pinSubject;
    SaveMapPinSubjectTable(playerID, MAIN_CACHE_KEY, mapPinSubjectTable);
end

-- Get the cache key to be used for storing MapPinSubjects.
function GetMapPinSubjectCacheKey(posX:number, posY:number)
    return posX .. "_" .. posY;
end

-- Load table from player config and deserialize.
function LoadMapPinSubjectTable(playerID:number, key:string)
    -- Get the player configuration
    local playerConfig = PlayerConfigurations[playerID];
    if not playerConfig then
        return nil;
    end
    -- Load the data from the player config and deserialize it if it exists
    local serializedTable = playerConfig:GetValue(key);
    if serializedTable then
        -- Return the deserialized table
        local deserializedTable = deserialize(serializedTable);
        return deserializedTable;
    end
    -- If this point is reached, just return nil
    return nil;
end

-- Serialize and save table to player config.
function SaveMapPinSubjectTable(playerID:number, key:string, value:table)
    -- Get the player configuration
    local playerConfig = PlayerConfigurations[playerID];
    if not playerConfig then
        return;
    end
    -- Serialize and save the data to the player config
    local serializedTable = serialize(value);
    playerConfig:SetValue(key, serializedTable);
    -- Mark as having unbroadcasted changes
    bUnbroadcastedChanges = true;
end

-- Broadcast the map pin subjects to the other clients.
function BroadcastMapPinSubjects()
    -- Stop if there are no changes since last broadcast
    if not bUnbroadcastedChanges then
        return;
    end
    -- Broadcast MapPinSubjects to all clients
    Network.BroadcastPlayerInfo();
    bUnbroadcastedChanges = false;
end
