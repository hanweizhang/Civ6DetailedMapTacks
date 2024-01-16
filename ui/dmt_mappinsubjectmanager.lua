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

-- DeepCompare copied from SupportFunctions.lua
-- Some other mods unintentionally remove this function from that file, so it is copied here instead
-- ===========================================================================
--  Recursively compare two tables (ignoring metatable)
--  Original from: https://stackoverflow.com/questions/25922437/how-can-i-deep-compare-2-lua-tables-which-may-or-may-not-have-tables-as-keys
--  ARGS:    table1        table one
--           table2        table two
--  RETURNS:    true if tables have the same content, false otherwise
-- ===========================================================================
function DeepCompare( table1, table2 )
    local avoid_loops = {}

    local function recurse(t1, t2)      
        -- Compare value types
        if type(t1) ~= type(t2) then return false; end

        -- Compare simple values
        if type(t1) ~= "table" then return (t1 == t2); end
      
        -- First, let's avoid looping forever.
        if avoid_loops[t1] then return avoid_loops[t1] == t2; end
        avoid_loops[t1] = t2;

            -- Copy keys from t2
        local t2keys = {}
        local t2tablekeys = {}
        for k, _ in pairs(t2) do
            if type(k) == "table" then table.insert(t2tablekeys, k); end
            t2keys[k] = true;
        end

        -- Iterate keys from t1
        for k1, v1 in pairs(t1) do
            local v2 = t2[k1]
            if type(k1) == "table" then
                -- if key is a table, we need to find an equivalent one.
                local ok = false
                for i, tk in ipairs(t2tablekeys) do
                    if DeepCompare(k1, tk) and recurse(v1, t2[tk]) then
                        table.remove(t2tablekeys, i)
                        t2keys[tk] = nil
                        ok = true
                        break;
                    end
                end
                if not ok then return false; end
            else
                -- t1 has a key which t2 doesn't have, fail.
                if v2 == nil then return false; end
                t2keys[k1] = nil
                if not recurse(v1, v2) then return false; end
            end
        end
        -- if t2 has a key which t1 doesn't have, fail.
        if next(t2keys) then return false; end
        return true;
    end

    return recurse(table1, table2);
end