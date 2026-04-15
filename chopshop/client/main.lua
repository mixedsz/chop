local ESX = exports['es_extended']:getSharedObject()
local isStripping = false

-- Only players with the chop job can strip (and within max job holders on server)
local function hasChopJob()
    local jobCfg = Config.Job
    if not jobCfg or not jobCfg.name then return true end
    local pd = ESX.GetPlayerData and ESX.GetPlayerData()
    if not pd or not pd.job then return false end
    return pd.job.name == jobCfg.name
end
local chopBlip, sellBlip
local chopPedEntity
local toolStashPedEntity
local myTruckNetId = nil
local vehicleStrippedCount = {}  -- [netId] = number of parts stripped (1-11), one part per click

-- Resolve vehicle from ox_target (may pass entity handle or network id)
local function resolveVehicleTarget(dataEntity)
    if dataEntity == nil then return nil end
    -- Try as entity handle first
    if type(dataEntity) == 'number' then
        if DoesEntityExist(dataEntity) and IsEntityAVehicle(dataEntity) then return dataEntity end
        -- Try as network id (ox_target sometimes passes net id for vehicles)
        local entity = NetworkGetEntityFromNetworkId(dataEntity)
        if entity and entity ~= 0 and DoesEntityExist(entity) and IsEntityAVehicle(entity) then return entity end
    end
    return nil
end

-- Get current vehicle model name (spawn name). Hash match first, then display name.
local function getVehicleModelName(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return nil end
    local hash = GetEntityModel(vehicle)
    -- Match by hash to whitelist first (most reliable for addon/variant names)
    for _, name in ipairs(Config.WhitelistedVehicles) do
        if GetHashKey(name) == hash then return string.lower(name) end
    end
    local display = GetDisplayNameFromVehicleModel(hash)
    if display and display ~= '' then
        display = string.lower(tostring(display):gsub('%s+', ''))
        if display ~= '' then return display end
    end
    return nil
end

-- Check if model is whitelisted (by name or by vehicle hash)
local function isWhitelistedModel(modelName)
    if not modelName or modelName == '' then return false end
    for _, v in ipairs(Config.WhitelistedVehicles) do
        if string.lower(v) == modelName then return true end
    end
    return false
end

local function isWhitelisted(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return false end
    local modelName = getVehicleModelName(vehicle)
    if modelName and isWhitelistedModel(modelName) then return true end
    local hash = GetEntityModel(vehicle)
    for _, name in ipairs(Config.WhitelistedVehicles) do
        if GetHashKey(name) == hash then return true end
    end
    return false
end

-- Get tier for model
local function getTierForModel(modelName)
    return Config.ModelToTier[modelName] or 'standard'
end

-- Normalize plate for server (uppercase, no spaces)
local function getVehiclePlate(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return '' end
    local plate = GetVehicleNumberPlateText(vehicle)
    return (plate and string.upper(tostring(plate):gsub('%s+', '')) or '')
end

-- Get street name for dispatch (general area)
local function getStreetName()
    local coords = GetEntityCoords(PlayerPedId())
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local street = GetStreetNameFromHashKey(streetHash)
    if street and street ~= '' then return street end
    return 'Unknown Area'
end

-- Progress / minigame: run for duration ms, return true if completed, false if cancelled
local function doProgress(duration, label)
    local cfg = Config.ProgressBar or {}
    label = label or cfg.label or 'Removing part...'

    if cfg.useExport and cfg.exportName and cfg.exportFunc then
        local export = exports[cfg.exportName]
        if export and export[cfg.exportFunc] then
            if cfg.exportName == 'ox_lib' and cfg.exportFunc == 'progressCircle' then
                local success = lib and lib.progressCircle and lib.progressCircle({
                    duration = duration,
                    label = label,
                    position = 'bottom',
                    useWhileDead = false,
                    canCancel = true,
                    disable = { move = true, car = true },
                })
                return success == true
            end
            -- Generic export progress (many use duration + label)
            local success = export[cfg.exportFunc](export, { duration = duration, label = label })
            return success == true
        end
    end

    -- Native progress (scaleform)
    if cfg.useNative ~= false then
        local endTime = GetGameTimer() + duration
        while GetGameTimer() < endTime do
            local elapsed = duration - (endTime - GetGameTimer())
            local pct = math.min(1.0, elapsed / duration)
            SetTextComponentFormat('STRING')
            AddTextComponentString(label)
            DisplayTextComponentSubstringTimed(0, 0, 0, 0, 0)
            DrawScaleformMovieFullScreen(0)  -- simplified: many servers use a scaleform; fallback is just wait
            Wait(100)
        end
        return true
    end

    -- Fallback: simple wait
    Wait(duration)
    return true
end

-- Strip action: play mechanic animation and wait. Must stay close to vehicle or strip cancels.
local function doStripMinigame(duration, vehicle)
    duration = math.max(1500, tonumber(duration) or 4000)
    local cfg = Config.Strip or {}
    local maxDist = (tonumber(cfg.maxDistance) or 2.5)
    local anim = cfg.animation or { dict = 'mini@repair', name = 'fixing_a_player', flag = 1 }
    local ped = PlayerPedId()
    local dict = anim.dict or 'mini@repair'
    local name = anim.name or 'fixing_a_player'
    local flag = tonumber(anim.flag) or 1

    RequestAnimDict(dict)
    local timeout = GetGameTimer() + 2000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeout do Wait(10) end
    if not HasAnimDictLoaded(dict) then
        Wait(duration)
        return true
    end

    TaskPlayAnim(ped, dict, name, 8.0, -8.0, -1, flag, 0, false, false, false)
    local endTime = GetGameTimer() + duration
    local success = true
    while GetGameTimer() < endTime do
        Wait(200)
        if not vehicle or not DoesEntityExist(vehicle) then break end
        local pedCoords = GetEntityCoords(ped)
        local vehCoords = GetEntityCoords(vehicle)
        if #(pedCoords - vehCoords) > maxDist then
            success = false
            break
        end
    end
    ClearPedTasks(ped)
    RemoveAnimDict(dict)
    return success
end

-- Parts to strip per car: 4 doors, 1 hood, 1 trunk, 1 engine, 4 tires
local PARTS_LIST = {
    { part = 'door',   label = 'Door' },
    { part = 'door',   label = 'Door' },
    { part = 'door',   label = 'Door' },
    { part = 'door',   label = 'Door' },
    { part = 'hood',   label = 'Hood' },
    { part = 'trunk',  label = 'Trunk' },
    { part = 'engine', label = 'Engine' },
    { part = 'tire',   label = 'Tire' },
    { part = 'tire',   label = 'Tire' },
    { part = 'tire',   label = 'Tire' },
    { part = 'tire',   label = 'Tire' },
}

-- Prop models for parts that fall to the ground
local PART_PROPS = {
    door = 'prop_rub_carpart_01',
    hood = 'prop_rub_carpart_01',
    trunk = 'prop_rub_carpart_01',
    engine = 'prop_car_engine_01',
    tire = 'prop_wheel_01',
}

local function spawnFallingPart(vehicle, partIndex)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    local coords = GetEntityCoords(vehicle)
    local heading = GetEntityHeading(vehicle)
    local rad = math.rad(heading)
    local cos, sin = math.cos(rad), math.sin(rad)
    local offX, offY, offZ = 0, 0, 0.5
    if partIndex <= 4 then
        local i = partIndex - 1
        offX = (i == 0 or i == 2) and -1.2 or 1.2
        offY = (i <= 1) and 1.5 or -1.5
    elseif partIndex == 5 then offY, offZ = 1.8, 0.8
    elseif partIndex == 6 then offY, offZ = -2.0, 0.6
    elseif partIndex == 7 then offZ = 0.3
    else offX, offY = 1.0, (partIndex == 8 or partIndex == 10) and 1.2 or -1.2
    end
    local wx = coords.x + offX * cos - offY * sin
    local wy = coords.y + offX * sin + offY * cos
    local wz = coords.z + offZ
    local model = (partIndex <= 4 and PART_PROPS.door) or ((partIndex == 5 or partIndex == 6) and PART_PROPS.hood) or (partIndex == 7 and PART_PROPS.engine) or PART_PROPS.tire
    local hash = GetHashKey(model)
    RequestModel(hash)
    if not HasModelLoaded(hash) then
        hash = GetHashKey('prop_rub_carpart_01')
        RequestModel(hash)
    end
    if not HasModelLoaded(hash) then return end
    local prop = CreateObject(hash, wx, wy, wz, true, true, true)
    SetEntityAsMissionEntity(prop, true, true)
    SetEntityVelocity(prop, 0.0, 0.0, -1.5)
    SetModelAsNoLongerNeeded(hash)
    CreateThread(function()
        Wait(30000)
        if DoesEntityExist(prop) then DeleteEntity(prop) end
    end)
end

-- Break part on vehicle and spawn falling prop
local function stripVehiclePartVisual(vehicle, partIndex)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    if partIndex >= 1 and partIndex <= 4 then
        SetVehicleDoorBroken(vehicle, partIndex - 1, true)
    elseif partIndex == 5 then SetVehicleDoorBroken(vehicle, 4, true)
    elseif partIndex == 6 then SetVehicleDoorBroken(vehicle, 5, true)
    elseif partIndex == 7 then
        SetVehicleEngineHealth(vehicle, -4000.0)
        SetVehicleBodyHealth(vehicle, math.max(0.0, GetVehicleBodyHealth(vehicle) - 500.0))
    elseif partIndex >= 8 and partIndex <= 11 then
        SetVehicleTyreBurst(vehicle, partIndex - 8, true, 1000.0)
    end
    spawnFallingPart(vehicle, partIndex)
end

-- Get chop zone center (supports vector4 or table with x,y,z)
local function getChopZoneCenter()
    local zone = Config.ChopZone
    if not zone then return nil end
    local c = zone[1] or zone.center
    if not c then return nil end
    local x = c.x or c[1]
    local y = c.y or c[2]
    local z = c.z or c[3]
    if x and y and z then return vector3(x, y, z) end
    return nil
end

-- Is vehicle inside the chop zone? (for parked cars)
local function isVehicleInChopZone(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return false end
    local center = getChopZoneCenter()
    if not center then return false end
    local r = (Config.ChopZone and Config.ChopZone.radius) or 25.0
    local coords = GetEntityCoords(vehicle)
    local dx = coords.x - center.x
    local dy = coords.y - center.y
    return (dx * dx + dy * dy) <= (r * r)
end

-- Is player in chop zone (and in vehicle)? Kept for optional E key.
local function isInChopZone()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return false end
    return isVehicleInChopZone(veh)
end

-- Is player in sell zone (in truck)?
local function isInSellZone()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return false end
    if myTruckNetId and NetworkGetNetworkIdFromEntity(veh) ~= myTruckNetId then return false end
    local coords = GetEntityCoords(veh)
    local c = Config.SellZone.center
    local r = Config.SellZone.radius or 15.0
    local dx = coords.x - c.x
    local dy = coords.y - c.y
    return (dx * dx + dy * dy) <= (r * r)
end

-- Create blips
local function createBlips()
    if not Config.Blip then return end
    local chop = Config.Blip.chop
    local center = getChopZoneCenter()
    if chop and center then
        chopBlip = AddBlipForCoord(center.x, center.y, center.z)
        SetBlipSprite(chopBlip, chop.sprite or 478)
        SetBlipColour(chopBlip, chop.color or 1)
        SetBlipScale(chopBlip, chop.scale or 0.9)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(chop.label or 'Chop Shop')
        EndTextCommandSetBlipName(chopBlip)
    end
    local sell = Config.Blip.sell
    if sell and Config.SellZone and Config.SellZone.center then
        local c = Config.SellZone.center
        sellBlip = AddBlipForCoord(c.x, c.y, c.z)
        SetBlipSprite(sellBlip, sell.sprite or 500)
        SetBlipColour(sellBlip, sell.color or 2)
        SetBlipScale(sellBlip, sell.scale or 0.8)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(sell.label or 'Parts Buyer')
        EndTextCommandSetBlipName(sellBlip)
    end
end

-- Spawn chop ped
local function spawnChopPed()
    if chopPedEntity and DoesEntityExist(chopPedEntity) then return chopPedEntity end
    local cfg = Config.ChopPed
    if not cfg or not cfg.model then return nil end
    RequestModel(cfg.model)
    while not HasModelLoaded(cfg.model) do Wait(10) end
    chopPedEntity = CreatePed(4, cfg.model, cfg.coords.x, cfg.coords.y, cfg.coords.z - 1.0, cfg.coords.w or 0.0, false, true)
    SetEntityInvincible(chopPedEntity, true)
    SetBlockingOfNonTemporaryEvents(chopPedEntity, true)
    if cfg.scenario then
        TaskStartScenarioInPlace(chopPedEntity, cfg.scenario, 0, true)
    end
    SetModelAsNoLongerNeeded(cfg.model)
    return chopPedEntity
end

-- Spawn tool stash ped (for storing/withdrawing strip tools)
local function spawnToolStashPed()
    if toolStashPedEntity and DoesEntityExist(toolStashPedEntity) then return toolStashPedEntity end
    local cfg = Config.ToolStashPed
    if not cfg or not cfg.model or not cfg.coords then return nil end
    RequestModel(cfg.model)
    while not HasModelLoaded(cfg.model) do Wait(10) end
    toolStashPedEntity = CreatePed(4, cfg.model, cfg.coords.x, cfg.coords.y, cfg.coords.z - 1.0, cfg.coords.w or 0.0, false, true)
    SetEntityInvincible(toolStashPedEntity, true)
    SetBlockingOfNonTemporaryEvents(toolStashPedEntity, true)
    TaskStartScenarioInPlace(toolStashPedEntity, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    SetModelAsNoLongerNeeded(cfg.model)
    return toolStashPedEntity
end

-- ox_target for tool stash ped (3rd eye inventory)
local function setupToolStashTarget()
    if GetResourceState('ox_target') ~= 'started' then return end
    local cfg = Config.ToolStashPed
    if not cfg or not cfg.coords or not cfg.stashId then return end
    if not toolStashPedEntity or not DoesEntityExist(toolStashPedEntity) then return end

    exports.ox_target:addLocalEntity(toolStashPedEntity, {
        {
            name = 'chopshop_tool_stash',
            icon = 'fas fa-toolbox',
            label = 'Access chop shop stash',
            distance = 2.0,
            canInteract = function(entity, distance, coords, name)
                return hasChopJob()
            end,
            onSelect = function(data)
                if GetResourceState('ox_inventory') ~= 'started' then
                    ESX.ShowNotification('Tool stash requires ox_inventory to be running.')
                    return
                end
                local stashId = cfg.stashId or 'chopshop_tools'
                local ok = exports.ox_inventory:openInventory('stash', stashId)
                if not ok then
                    exports.ox_inventory:openInventory('stash', { id = stashId })
                end
            end,
        },
        {
            name = 'chopshop_buy_crowbar',
            icon = 'fas fa-hammer',
            label = 'Buy Crowbar ($200)',
            distance = 2.0,
            canInteract = function(entity, distance, coords, name)
                return hasChopJob()
            end,
            onSelect = function(data)
                TriggerServerEvent('chopshop:server:buyTool', 'crowbar')
            end,
        },
        {
            name = 'chopshop_buy_screwdriver',
            icon = 'fas fa-screwdriver',
            label = 'Buy Screwdriver ($200)',
            distance = 2.0,
            canInteract = function(entity, distance, coords, name)
                return hasChopJob()
            end,
            onSelect = function(data)
                TriggerServerEvent('chopshop:server:buyTool', 'screwdriver')
            end,
        },
        {
            name = 'chopshop_buy_repair_kit',
            icon = 'fas fa-wrench',
            label = 'Buy Repair Kit ($300)',
            distance = 2.0,
            canInteract = function(entity, distance, coords, name)
                return hasChopJob()
            end,
            onSelect = function(data)
                TriggerServerEvent('chopshop:server:buyTool', 'repair_kit')
            end,
        },
    })
end

-- One part per click: minigame then strip one part (risk/reward)
local function stripOnePart(vehicle, modelName, tierName)
    if isStripping then return end
    if not vehicle or not DoesEntityExist(vehicle) then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local count = vehicleStrippedCount[netId] or 0
    if count >= 11 then
        ESX.ShowNotification('Vehicle is fully stripped.')
        return
    end

    local tier = Config.CarTiers[tierName] or Config.CarTiers.standard
    local stripTime = tier.stripTime or 8000

    -- First part: check tools/cooldown and start strip (dispatch)
    if count == 0 then
        isStripping = true
        ESX.TriggerServerCallback('chopshop:canStrip', function(can, reason, missing)
            if not can then
                isStripping = false
                if reason == 'not_whitelisted' then ESX.ShowNotification('This vehicle cannot be stripped here.')
                elseif reason == 'cooldown' then ESX.ShowNotification('You need to wait before stripping another car.')
                elseif reason == 'missing_tool' then ESX.ShowNotification(('You need a %s.'):format(missing or 'tool'))
                elseif reason == 'no_job' then ESX.ShowNotification('You do not have the job required to strip vehicles.')
                elseif reason == 'job_full' then ESX.ShowNotification('Maximum number of chop shop workers (3) are already active.')
                elseif reason == 'no_player' then ESX.ShowNotification('Session error. Try again.')
                else ESX.ShowNotification('You cannot strip this vehicle.') end
                return
            end
            local streetName = getStreetName()
            local plate = getVehiclePlate(vehicle)
            TriggerServerEvent('chopshop:server:startedStripping', streetName, tierName, plate)
            isStripping = false
            tryStripOnePart(vehicle, netId, modelName, tierName, count, stripTime)
        end, modelName, getStreetName())
        return
    end

    tryStripOnePart(vehicle, netId, modelName, tierName, count, stripTime)
end

-- Run minigame; on success strip one part and update count
function tryStripOnePart(vehicle, netId, modelName, tierName, count, stripTime)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    local partIndex = count + 1
    local p = PARTS_LIST[partIndex]

    isStripping = true
    ESX.ShowNotification(('Removing %s (%d/11)...'):format(p.label, partIndex))
    local success = doStripMinigame(stripTime, vehicle)
    isStripping = false

    if not success then
        ESX.ShowNotification('Stay close to the vehicle to strip parts.')
        return
    end
    if not DoesEntityExist(vehicle) then return end
    stripVehiclePartVisual(vehicle, partIndex)
    TriggerServerEvent('chopshop:server:addPart', modelName, p.part)
    vehicleStrippedCount[netId] = partIndex
    ESX.ShowNotification(('Removed %s (%d/11)'):format(p.label, partIndex))

    if partIndex == 11 then
        vehicleStrippedCount[netId] = nil
        if Config.RemoveStrippedVehicleEntity and DoesEntityExist(vehicle) then
            local ped = PlayerPedId()
            if GetVehiclePedIsIn(ped, false) == vehicle then
                TaskLeaveVehicle(ped, vehicle, 0)
                Wait(1500)
            end
            if DoesEntityExist(vehicle) then
                SetEntityAsMissionEntity(vehicle, true, true)
                DeleteEntity(vehicle)
            end
        end
        ESX.ShowNotification('Vehicle fully stripped. Talk to the contact for a truck.')
    end
end

-- ox_target: "Strip vehicle" on parked cars in chop zone
local function setupOxTarget()
    if GetResourceState('ox_target') ~= 'started' then return end
    local cfg = Config.OxTarget or {}
    if not cfg.enabled then return end
    local stripCfg = Config.Strip or {}
    local maxDist = tonumber(stripCfg.maxDistance) or tonumber(cfg.distance) or 2.5
    exports.ox_target:addGlobalVehicle({
        {
            name = 'chopshop_strip',
            icon = cfg.icon or 'fas fa-screwdriver-wrench',
            label = cfg.label or 'Strip part',
            distance = tonumber(cfg.distance) or maxDist,
            canInteract = function(entity)
                local veh = resolveVehicleTarget(entity)
                if not veh then return false end
                if not isVehicleInChopZone(veh) then return false end
                if not isWhitelisted(veh) then return false end
                local nid = NetworkGetNetworkIdFromEntity(veh)
                if (vehicleStrippedCount[nid] or 0) >= 11 then return false end
                local ped = PlayerPedId()
                if #(GetEntityCoords(ped) - GetEntityCoords(veh)) > maxDist then return false end
                return true
            end,
            onSelect = function(data)
                local rawEntity = data and data.entity
                local vehicle = resolveVehicleTarget(rawEntity)
                local debug = Config.Debug
                if not vehicle or not DoesEntityExist(vehicle) then
                    if debug then ESX.ShowNotification('Debug: No vehicle (raw=' .. tostring(rawEntity) .. ')') end
                    ESX.ShowNotification('Could not get vehicle. Try again.')
                    return
                end
                local vCoords = GetEntityCoords(vehicle)
                local center = getChopZoneCenter()
                local inZone = isVehicleInChopZone(vehicle)
                if not inZone then
                    if debug and center then
                        local dist = center and #(vCoords - center) or 0
                        ESX.ShowNotification(('Debug: Out of zone. Veh=%.1f,%.1f Zone=%.1f,%.1f Dist=%.1f R=%.0f'):format(vCoords.x, vCoords.y, center.x, center.y, dist, (Config.ChopZone and Config.ChopZone.radius) or 25))
                    end
                    ESX.ShowNotification('Move the vehicle into the chop zone.')
                    return
                end
                local hash = GetEntityModel(vehicle)
                local displayName = GetDisplayNameFromVehicleModel(hash) or ('hash_' .. tostring(hash))
                if not isWhitelisted(vehicle) then
                    if debug then ESX.ShowNotification('Debug: Not whitelisted. Model: ' .. tostring(displayName) .. ' (add to config)') end
                    ESX.ShowNotification('This vehicle cannot be stripped here. Model: ' .. tostring(displayName))
                    return
                end
                local modelName = getVehicleModelName(vehicle)
                if not modelName then
                    if debug then ESX.ShowNotification('Debug: No modelName for ' .. tostring(displayName)) end
                    ESX.ShowNotification('Unknown model: ' .. tostring(displayName) .. '. Add to Config.WhitelistedVehicles.')
                    return
                end
                stripOnePart(vehicle, modelName, getTierForModel(modelName))
            end,
        },
    })
end

-- Chop zone: blips, ped, ox_target; optional E key when sitting in driver seat
CreateThread(function()
    createBlips()
    spawnChopPed()
    spawnToolStashPed()
    setupOxTarget()
    setupToolStashTarget()

    while true do
        local sleep = 1500
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and isInChopZone() then
            local modelName = getVehicleModelName(veh)
            if modelName and isWhitelistedModel(modelName) then
                sleep = 0
                if not Config.OxTarget or not Config.OxTarget.enabled then
                    ESX.ShowHelpNotification('Press ~INPUT_CONTEXT~ to strip this vehicle (donor car).')
                    if IsControlJustPressed(0, 38) then
                        stripOnePart(veh, modelName, getTierForModel(modelName))
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

-- Listen for truck spawn from server (spawns at Config.TruckSpawn)
RegisterNetEvent('chopshop:client:spawnTruck', function()
    local model = Config.TruckModel or 'speedo'
    local spawn = Config.TruckSpawn
    local x, y, z, heading = spawn.x, spawn.y, spawn.z, spawn.w or spawn[4] or 0.0
    local hash = GetHashKey(model)
    RequestModel(hash)
    while not HasModelLoaded(hash) do Wait(10) end

    local veh = CreateVehicle(hash, x, y, z, heading, true, false)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    TriggerServerEvent('chopshop:server:setTruck', netId)
    myTruckNetId = netId
    SetModelAsNoLongerNeeded(hash)
    ESX.ShowNotification('Take the truck to the Parts Buyer to sell.')
end)

-- Sell zone: when in truck (my truck) in sell zone, sell
CreateThread(function()
    while true do
        local sleep = 1500
        if myTruckNetId and isInSellZone() then
            sleep = 0
            ESX.ShowHelpNotification('Press ~INPUT_CONTEXT~ to sell parts.')
            if IsControlJustPressed(0, 38) then
                TriggerServerEvent('chopshop:server:sellParts', myTruckNetId)
                myTruckNetId = nil
            end
        end
        Wait(sleep)
    end
end)

-- Ped interaction zone (talk to get truck)
CreateThread(function()
    local pedCfg = Config.ChopPed
    if not pedCfg or not pedCfg.coords then return end
    local r = 2.0
    while true do
        local sleep = 500
        local myCoords = GetEntityCoords(PlayerPedId())
        local dx = myCoords.x - pedCfg.coords.x
        local dy = myCoords.y - pedCfg.coords.y
        if (dx * dx + dy * dy) <= (r * r) then
            sleep = 0
            ESX.ShowHelpNotification('Press ~INPUT_CONTEXT~ to get a transport truck for your parts.')
            if IsControlJustPressed(0, 38) then
                TriggerServerEvent('chopshop:server:requestTruck')
            end
        end
        Wait(sleep)
    end
end)
