local ESX = exports['es_extended']:getSharedObject()

-- ============================================================
--  State
-- ============================================================
local playerCooldowns  = {}   -- [playerId] = timestamp (os.time) when their cooldown expires
local playerParts      = {}   -- [playerId] = { door=N, hood=N, trunk=N, engine=N, tire=N }
local playerTrucks     = {}   -- [playerId] = netId of their assigned truck
local activeWorkers    = {}   -- [playerId] = true  (currently stripping / has started a job)

-- ============================================================
--  Helpers
-- ============================================================

local function getPlayerParts(playerId)
    if not playerParts[playerId] then
        playerParts[playerId] = { door = 0, hood = 0, trunk = 0, engine = 0, tire = 0 }
    end
    return playerParts[playerId]
end

local function countActiveWorkers()
    local count = 0
    for _, _ in pairs(activeWorkers) do count = count + 1 end
    return count
end

-- Send a dispatch alert (cd_dispatch compatible). Falls back silently if not running.
local function sendDispatch(streetName, tierName, coords)
    local cfg = Config.Dispatch
    if not cfg or not cfg.enabled then return end

    local alertCoords = coords
    if cfg.generalArea then
        -- Slightly randomise coords so PD gets general area only
        alertCoords = { x = coords.x + math.random(-80, 80), y = coords.y + math.random(-80, 80), z = coords.z }
    end

    -- cd_dispatch style
    TriggerEvent(cfg.eventName, {
        job_table = { 'police', 'sheriff' },
        coords    = alertCoords,
        title     = cfg.alertCode .. ' - ' .. (cfg.alertMessage or 'Possible vehicle stripping'),
        message   = ('Suspicious activity near %s. Tier: %s'):format(streetName or 'Unknown', tierName or 'unknown'),
        flash     = 1,
        unique_id = tostring(math.random(0x10000, 0xFFFFF)),
        blip = {
            sprite   = 473,
            scale    = 1.2,
            colour   = 1,
            flashes  = true,
            text     = cfg.alertCode,
            time     = 5,
        },
    })
end

-- Calculate total payout for a player's accumulated parts
local function calcPayout(playerId, tierName)
    local parts  = getPlayerParts(playerId)
    local tier   = Config.CarTiers[tierName] or Config.CarTiers.standard
    local prices = tier.parts

    local total = 0
    total = total + (parts.door   * (prices.door   or 600))
    total = total + (parts.hood   * (prices.hood   or 700))
    total = total + (parts.trunk  * (prices.trunk  or 650))
    total = total + (parts.engine * (prices.engine or 1800))
    total = total + (parts.tire   * (prices.tire   or 400))
    return total
end

-- ============================================================
--  Server Callback: chopshop:canStrip
--  Client passes: modelName, streetName
--  Returns: can (bool), reason (string), missingTool (string|nil)
-- ============================================================
ESX.RegisterServerCallback('chopshop:canStrip', function(source, cb, modelName, streetName)
    local playerId = source
    local xPlayer  = ESX.GetPlayerFromId(playerId)

    if not xPlayer then
        cb(false, 'no_player')
        return
    end

    -- Job check
    local jobCfg = Config.Job
    if jobCfg and jobCfg.name then
        if xPlayer.getJob().name ~= jobCfg.name then
            cb(false, 'no_job')
            return
        end
    end

    -- Max concurrent workers check
    local maxHolders = (jobCfg and jobCfg.maxHolders) or 3
    if not activeWorkers[playerId] and countActiveWorkers() >= maxHolders then
        cb(false, 'job_full')
        return
    end

    -- Cooldown check
    local now = os.time()
    if playerCooldowns[playerId] and now < playerCooldowns[playerId] then
        cb(false, 'cooldown')
        return
    end

    -- Whitelist check (server-side sanity)
    local whitelisted = false
    if modelName then
        local lower = string.lower(modelName)
        for _, v in ipairs(Config.WhitelistedVehicles) do
            if string.lower(v) == lower then
                whitelisted = true
                break
            end
        end
    end
    if not whitelisted then
        cb(false, 'not_whitelisted')
        return
    end

    -- Required tools check
    if Config.RequiredTools and #Config.RequiredTools > 0 then
        for _, toolItem in ipairs(Config.RequiredTools) do
            local item = xPlayer.getInventoryItem(toolItem)
            if not item or item.count < 1 then
                cb(false, 'missing_tool', toolItem)
                return
            end
        end

        -- Consume tools (one of each per full strip job)
        for _, toolItem in ipairs(Config.RequiredTools) do
            xPlayer.removeInventoryItem(toolItem, 1)
        end
    end

    -- All checks passed – mark worker active and set cooldown
    activeWorkers[playerId] = true
    local cooldownSecs = (Config.CooldownMinutes or 45) * 60
    playerCooldowns[playerId] = now + cooldownSecs

    cb(true)
end)

-- ============================================================
--  chopshop:server:startedStripping
--  Fires dispatch alert when a player begins stripping
-- ============================================================
RegisterNetEvent('chopshop:server:startedStripping')
AddEventHandler('chopshop:server:startedStripping', function(streetName, tierName, plate)
    local playerId = source
    local xPlayer  = ESX.GetPlayerFromId(playerId)
    if not xPlayer then return end

    -- Use chop zone coords for the dispatch alert
    local zone   = Config.ChopZone
    local center = zone and (zone[1] or zone.center)
    local coords = { x = 0, y = 0, z = 0 }
    if center then
        coords = { x = center.x or 0, y = center.y or 0, z = center.z or 0 }
    end

    sendDispatch(streetName, tierName, coords)

    if Config.Debug then
        print(('[ChopShop] Player %s (%d) started stripping a %s vehicle (plate: %s) near %s'):format(
            xPlayer.getName(), playerId, tierName, tostring(plate), tostring(streetName)
        ))
    end
end)

-- ============================================================
--  chopshop:server:addPart
--  Called each time one part is stripped. Accumulates in session.
-- ============================================================
RegisterNetEvent('chopshop:server:addPart')
AddEventHandler('chopshop:server:addPart', function(modelName, partType)
    local playerId = source
    local xPlayer  = ESX.GetPlayerFromId(playerId)
    if not xPlayer then return end

    -- Validate part type
    local validParts = { door = true, hood = true, trunk = true, engine = true, tire = true }
    if not validParts[partType] then
        if Config.Debug then
            print(('[ChopShop] Invalid part type "%s" from player %d'):format(tostring(partType), playerId))
        end
        return
    end

    local parts = getPlayerParts(playerId)
    parts[partType] = (parts[partType] or 0) + 1

    -- Store the tier for this player so sell can use it
    if modelName then
        local tier = Config.ModelToTier and Config.ModelToTier[string.lower(modelName)] or 'standard'
        playerParts[playerId]._tier = tier
    end

    if Config.Debug then
        print(('[ChopShop] Player %d added part: %s (model: %s). Totals: door=%d hood=%d trunk=%d engine=%d tire=%d'):format(
            playerId, partType, tostring(modelName),
            parts.door, parts.hood, parts.trunk, parts.engine, parts.tire
        ))
    end
end)

-- ============================================================
--  chopshop:server:requestTruck
--  Player talks to ped → spawn a delivery truck client-side
-- ============================================================
RegisterNetEvent('chopshop:server:requestTruck')
AddEventHandler('chopshop:server:requestTruck', function()
    local playerId = source
    local xPlayer  = ESX.GetPlayerFromId(playerId)
    if not xPlayer then return end

    -- Must be an active worker with parts
    local parts = getPlayerParts(playerId)
    local totalParts = parts.door + parts.hood + parts.trunk + parts.engine + parts.tire
    if totalParts < 1 then
        TriggerClientEvent('esx:showNotification', playerId, 'You have no parts to deliver.')
        return
    end

    -- Already has a truck
    if playerTrucks[playerId] then
        TriggerClientEvent('esx:showNotification', playerId, 'You already have a truck assigned.')
        return
    end

    -- Tell client to spawn the truck
    TriggerClientEvent('chopshop:client:spawnTruck', playerId)

    if Config.Debug then
        print(('[ChopShop] Truck requested by player %d'):format(playerId))
    end
end)

-- ============================================================
--  chopshop:server:setTruck
--  Client reports back the netId of the spawned truck
-- ============================================================
RegisterNetEvent('chopshop:server:setTruck')
AddEventHandler('chopshop:server:setTruck', function(netId)
    local playerId = source
    playerTrucks[playerId] = netId

    if Config.Debug then
        print(('[ChopShop] Player %d truck netId set to %d'):format(playerId, netId))
    end
end)

-- ============================================================
--  chopshop:server:sellParts
--  Player arrives at sell zone in their truck → pay out
-- ============================================================
RegisterNetEvent('chopshop:server:sellParts')
AddEventHandler('chopshop:server:sellParts', function(truckNetId)
    local playerId = source
    local xPlayer  = ESX.GetPlayerFromId(playerId)
    if not xPlayer then return end

    -- Verify truck ownership
    if playerTrucks[playerId] ~= truckNetId then
        TriggerClientEvent('esx:showNotification', playerId, 'That is not your truck.')
        return
    end

    local parts = getPlayerParts(playerId)
    local totalParts = parts.door + parts.hood + parts.trunk + parts.engine + parts.tire
    if totalParts < 1 then
        TriggerClientEvent('esx:showNotification', playerId, 'No parts to sell.')
        return
    end

    -- Work out payout using stored tier (or standard as fallback)
    local tierName = parts._tier or 'standard'
    local payout   = calcPayout(playerId, tierName)

    if payout <= 0 then
        TriggerClientEvent('esx:showNotification', playerId, 'No parts to sell.')
        return
    end

    -- Pay the player
    xPlayer.addMoney(payout)

    local msg = ('Parts sold for $%d. Thanks for the delivery!'):format(payout)
    TriggerClientEvent('esx:showNotification', playerId, msg)

    if Config.Debug then
        print(('[ChopShop] Player %d sold parts for $%d (tier: %s). Parts: door=%d hood=%d trunk=%d engine=%d tire=%d'):format(
            playerId, payout, tierName,
            parts.door, parts.hood, parts.trunk, parts.engine, parts.tire
        ))
    end

    -- Clean up player state
    playerParts[playerId]  = nil
    playerTrucks[playerId] = nil
    activeWorkers[playerId] = nil
end)

-- ============================================================
--  chopshop:server:buyTool
--  Player buys a tool from the stash ped
-- ============================================================
RegisterNetEvent('chopshop:server:buyTool')
AddEventHandler('chopshop:server:buyTool', function(toolName)
    local playerId = source
    local xPlayer  = ESX.GetPlayerFromId(playerId)
    if not xPlayer then return end

    -- Job check
    local jobCfg = Config.Job
    if jobCfg and jobCfg.name then
        if xPlayer.getJob().name ~= jobCfg.name then
            TriggerClientEvent('esx:showNotification', playerId, 'You do not have the required job.')
            return
        end
    end

    local cfg = Config.ToolStashPed
    if not cfg or not cfg.buyableTools then
        TriggerClientEvent('esx:showNotification', playerId, 'Tool shop not configured.')
        return
    end

    local price = cfg.buyableTools[toolName]
    if not price then
        TriggerClientEvent('esx:showNotification', playerId, 'Unknown tool.')
        return
    end

    -- Check item exists in ESX items
    local item = ESX.GetItem(toolName)
    if not item then
        TriggerClientEvent('esx:showNotification', playerId, ('Item "%s" does not exist. Add it to your items table.'):format(toolName))
        return
    end

    -- Check funds
    if xPlayer.getMoney() < price then
        TriggerClientEvent('esx:showNotification', playerId, ('You need $%d to buy a %s.'):format(price, toolName))
        return
    end

    xPlayer.removeMoney(price)
    xPlayer.addInventoryItem(toolName, 1)
    TriggerClientEvent('esx:showNotification', playerId, ('Bought 1x %s for $%d.'):format(toolName, price))

    if Config.Debug then
        print(('[ChopShop] Player %d bought %s for $%d'):format(playerId, toolName, price))
    end
end)

-- ============================================================
--  Cleanup on player drop
-- ============================================================
AddEventHandler('playerDropped', function(reason)
    local playerId = source
    playerCooldowns[playerId]  = nil
    playerParts[playerId]      = nil
    playerTrucks[playerId]     = nil
    activeWorkers[playerId]    = nil
end)
