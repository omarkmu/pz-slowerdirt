---Handles correction of dirt accrual based on multipliers.

local pairs = pairs
local ipairs = ipairs
local floor = math.floor
local instanceof = instanceof
local SandboxVars = SandboxVars
local getCoveredParts = BloodClothingType.getCoveredParts
local calcTotalDirtLevel = BloodClothingType.calcTotalDirtLevel

local mode = 3
local bodyMultiplier = 0.1
local bodyApplyMin, bodyApplyMax = 0, 1
local clothingMultiplier = 0.1
local clothingApplyMin, clothingApplyMax = 0, 1

local playerDirtCache = {}


-- collect body parts to use later
local allBodyParts = ArrayList.new(BloodBodyPartType.MAX:index())
for i = 0, BloodBodyPartType.MAX:index() - 1 do
    allBodyParts:add(BloodBodyPartType.FromIndex(i))
end


---Saves an item's dirt values in the cache.
---@param item Clothing A clothing item.
---@param dest table A table in which results will be stored.
---@param visual ItemVisual The item's visual.
---@param bodyParts table A table of body parts that the item covers.
local function cacheItemDirt(item, dest, visual, bodyParts)
    local dirt = {}
    for i = 0, bodyParts:size() - 1 do
        dirt[i] = visual:getDirt(bodyParts:get(i))
    end

    dest[item:getID()] = dirt
end

---Initializes the cache for the given player.
---@param playerNum integer
---@param player IsoPlayer
---@param visual HumanVisual
local function initPlayerCache(playerNum, player, visual)
    local bodyDirt = {}
    local clothingDirt = {}

    if mode ~= 2 then -- 2: Clothing Only
        for i = 0, allBodyParts:size() - 1 do
            bodyDirt[i] = visual:getDirt(allBodyParts:get(i))
        end
    end

    if mode ~= 1 then -- 1: Body Only
        local wornItems = player:getWornItems()
        for i = 0, wornItems:size() - 1 do
            local item = wornItems:getItemByIndex(i) ---@cast item Clothing
            if item and instanceof(item, 'Clothing') then
                local itemVisual = item:getVisual()

                if itemVisual then
                    local parts = getCoveredParts(item:getBloodClothingType())
                    cacheItemDirt(item, clothingDirt, itemVisual, parts)
                end
            end
        end
    end

    playerDirtCache[playerNum] = {
        body = bodyDirt,
        clothing = clothingDirt,
    }
end

---Updates dirt on a visual and in the cache.
---@param visual HumanVisual | ItemVisual
---@param bodyParts ArrayList List of body parts to update.
---@param cache table
---@param multiplier number
---@param diffMin number
---@param diffMax number
---@return boolean #Whether the visual's dirt was updated.
local function updateDirt(visual, bodyParts, cache, multiplier, diffMin, diffMax)
    local updated = false

    for i = 0, bodyParts:size() - 1 do
        local bodyPart = bodyParts:get(i)
        local current = visual:getDirt(bodyPart)
        local last = cache[i] or current
        local diff = current - last

        -- comparing with epsilon value to avoid floating point inaccuracies
        if diff > 0.00001 and diff >= diffMin and diff <= diffMax then
            local new = last
            if multiplier > 0 then
                new = last + diff * multiplier
                local byteValue = floor(new * 255)

                -- setDirt performs lossy conversion to byte
                -- if the modified increase is too small to register, use next byte value instead
                if byteValue == floor(last * 255) then
                    new = (byteValue + 1) / 255
                end
            end

            current = new
            visual:setDirt(bodyPart, current)
            updated = true
        end

        cache[i] = current
    end

    return updated
end

---Updates dirt for a given list of items.
---@param itemList WornItems
---@param cacheTable table<number, table> A map of inventory item IDs to cache tables.
---@param multiplier number
---@param diffMin number
---@param diffMax number
---@return boolean #True if any items were updated.
local function updateItemsDirt(itemList, cacheTable, multiplier, diffMin, diffMax)
    local updated = false

    for i = 0, itemList:size() - 1 do
        local item = itemList:getItemByIndex(i) ---@cast item Clothing
        if item and instanceof(item, 'Clothing') then
            local visual = item:getVisual()

            if visual then
                local cache = cacheTable[item:getID()]
                local parts = getCoveredParts(item:getBloodClothingType())

                if not cache then
                    cacheItemDirt(item, cacheTable, visual, parts)
                elseif updateDirt(visual, parts, cache, multiplier, diffMin, diffMax) then
                    updated = true
                    calcTotalDirtLevel(item)
                end
            end
        end
    end

    return updated
end

---Updates the dirt cache, correcting dirt values where appropriate.
---@param player IsoPlayer
local function onPlayerUpdate(player)
    local playerNum = player:getPlayerNum()
    local visual = player:getVisual() ---@cast visual HumanVisual
    if not playerDirtCache[playerNum] then
        initPlayerCache(playerNum, player, visual)
        return
    end

    local updatedBody = false
    local updatedClothing = false
    local cache = playerDirtCache[playerNum]

    if mode ~= 2 then -- 2: Clothing Only
        updatedBody = updateDirt(visual, allBodyParts, cache.body, bodyMultiplier, bodyApplyMin, bodyApplyMax)
    end

    if mode ~= 1 then -- 1: Body Only
        updatedClothing = updateItemsDirt(player:getWornItems(), cache.clothing, clothingMultiplier, clothingApplyMin, clothingApplyMax)
    end

    -- mark the player as updated
    if updatedBody or updatedClothing then
        player:resetModel()
    end

    if updatedBody then
        sendVisual(player)
    end

    if updatedClothing then
        -- intentionally not triggering OnClothingUpdated; this is modified accrual, not washing
        sendClothing(player)
    end
end

---Sets up initial cache information for newly spawned players.
---@param playerNum integer
---@param player IsoPlayer
local function onCreatePlayer(playerNum, player)
    mode = SandboxVars.SlowerDirt.Mode or mode
    bodyMultiplier = SandboxVars.SlowerDirt.BodyDirtIncreaseMultiplier or bodyMultiplier
    bodyApplyMax = SandboxVars.SlowerDirt.BodyMultiplierApplyMaximum or bodyApplyMax
    bodyApplyMin = SandboxVars.SlowerDirt.BodyMultiplierApplyMinimum or bodyApplyMin
    clothingMultiplier = SandboxVars.SlowerDirt.ClothingDirtIncreaseMultiplier or clothingMultiplier
    clothingApplyMax = SandboxVars.SlowerDirt.ClothingMultiplierApplyMaximum or clothingApplyMax
    clothingApplyMin = SandboxVars.SlowerDirt.ClothingMultiplierApplyMinimum or clothingApplyMin

    local visual = player:getVisual() ---@cast visual HumanVisual
    if visual then
        initPlayerCache(playerNum, player, visual)
    end
end

---Removes outdated information from the cache.
local function cleanupCache()
    for i, cache in ipairs(playerDirtCache) do
        local player = getSpecificPlayer(i)
        if player then
            if mode ~= 1 and cache.clothing then -- 1: Body Only
                local wornSet = {}
                local wornItems = player:getWornItems()
                for j = 0, wornItems:size() - 1 do
                    local item = wornItems:getItemByIndex(j)
                    if item and instanceof(item, 'Clothing') then
                        wornSet[item:getID()] = true
                    end
                end

                for id in pairs(cache.clothing) do
                    if not wornSet[id] then
                        cache.clothing[id] = nil
                    end
                end
            end
        else
            playerDirtCache[i] = nil
        end
    end
end


Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.EveryDays.Add(cleanupCache)
