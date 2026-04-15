Config = {}

-- Job: only players with this job can strip vehicles. Max 3 players can have/work this job at a time.
Config.Job = {
    name = 'chopshop',   -- ESX job name (create this job in your database / es_extended jobs table)
    maxHolders = 3,      -- max number of players who can have this job at once (no more than 3 can work stripping)
}

-- Only these vehicles can be chopped (donor cars). Use GTA model names (spawn codes).
-- Add your whitelisted donor cars here. Model name = spawn name / display name.
Config.WhitelistedVehicles = {
    -- Hellcat tier (premium)
    '12charger',
    '16charger',
    '24chargered',
    '23LastCallCharger',
    '24hellecharger',
    '23LastCallChallenger',
    '23LastcallChargered',
    'ghoulcharg24',
    'ghoulchall24',
    'ghouldur24',
    'GwopMoreQuanHellcat',
    'playatigercat2',
    'playaquanhawk',
    'srt392',
    'dreysotrackjail',
    'srt2018',  -- add more as needed
    -- Benz & BMW tier (luxury)
    'm340i',
    'm5f10',
    'm5f90c',
    'm2g87',
    'e60',
    'e92',
    '16m3f80',
    '18m3f80cs',
    '05m3e46',
    'e63amg',
    'cls63s',
    'infinitig35',
    'cla250',
    'sjbenzml',
    'lynx2',
    'massacro',
    'massacro2',
    'rapidgt',
    'rapidgt2',
    -- Standard tier (example)
    '08magnumsrt',
    'BurnG8',
    'taho2',
    -- Add any other donor car spawn names
}

-- Car tiers: maps vehicle model (lowercase) to tier key. Tier key is used for payout/difficulty.
Config.CarTiers = {
    premium = {  -- Hellcat-style payouts
        models = { 'hellcat', 'demon', 'redeye', 'durango18' },
        parts = {
            door   = 1300,
            hood   = 1500,
            trunk  = 1400,
            engine = 3500,
            tire   = 1000,
        },
        stripTime = 12000,  -- ms per part (difficulty)
    },
    luxury = {   -- Benz & BMW
        models = { 'schafter2', 'schafter3', 'schafter5', 'schafter6', 'superd', 'tailgater', 'oracle', 'oracle2', 'sentinel', 'sentinel2', 'windsor', 'windsor2', 'seven70', 'bestiagts', 'lynx2', 'massacro', 'massacro2', 'rapidgt', 'rapidgt2' },
        parts = {
            door   = 1000,
            hood   = 1200,
            trunk  = 1100,
            engine = 2700,
            tire   = 750,
        },
        stripTime = 10000,
    },
    standard = { -- fallback for any other whitelisted car not in above
        models = { 'blista', 'futo', 'sultan' },  -- example fallbacks; add more
        parts = {
            door   = 600,
            hood   = 700,
            trunk  = 650,
            engine = 1800,
            tire   = 400,
        },
        stripTime = 8000,
    },
}

-- Required tools (ESX item names). One of each required to START a strip.
-- Single use: when you start stripping a car, one of each tool is consumed for that full car (all 11 parts).
Config.RequiredTools = {
    'crowbar',
    'screwdriver',
    -- 'wrench',  -- optional, add if you have item
}

-- Chop zone: where the vehicle must be to strip it (center + radius)
Config.ChopZone = {
    vector4(-115.6831, 6365.7446, 31.9271, 222.9174),  -- x, y, z, heading (example: scrap yard)
    radius = 35.0,
}

-- Set to true to see why stripping fails (notifications with coords, model, zone check)
Config.Debug = true

-- Ped that gives the truck (where you get the worker's truck)
Config.ChopPed = {
    coords = vector4(-161.5475, 6307.1377, 31.3082, 133.7655),
    model  = 's_m_m_lsmetro_01',  -- or 'a_m_m_hillbilly_01'
    scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
}

-- Ped with stash inventory for tools needed to strip cars
-- Uses ox_inventory stash: openInventory('stash', stashId)
-- buyableTools: item name -> price (unlimited stock for workers)
Config.ToolStashPed = {
    coords = vector4(-118.7234, 6357.0679, 31.8600, 349.5829),
    model  = 's_m_m_autoshop_02',
    stashId = 'chopshop_tools',   -- stash name in ox_inventory
    buyableTools = {
        crowbar     = 200,
        screwdriver = 200,
        repair_kit  = 300,
    },
}

-- Sell zone: drop-off spot to deliver the truck and sell parts (center + radius)
Config.SellZone = {
    center = vector3(1733.3961, 3708.8352, 34.1542),
    radius = 15.0,
}

-- Truck model given by the ped (worker van style)
Config.TruckModel = 'speedo'

-- Where the truck spawns when you get it from the ped (x, y, z, heading)
Config.TruckSpawn = vector4(-154.8051, 6305.3022, 31.4162, 313.7075)

-- Cooldown (minutes) before same player can strip again. Applied when they START stripping.
Config.CooldownMinutes = 45

-- Remove only the in-world vehicle entity after stripping (cleans up the chop zone).
-- This does NOT delete the vehicle from the owner's garage/saved cars. The owner can still
-- retrieve their vehicle from garage after the next server restart (or whenever garage allows).
Config.RemoveStrippedVehicleEntity = true

-- Dispatch (PD alert) when stripping STARTS. General area only for RP.
Config.Dispatch = {
    enabled = true,
    -- Event name for cd_dispatch. Many use 'cd_dispatch:AddNotification' (TriggerEvent on server).
    -- If your dispatch uses a different event or export, change server/main.lua sendDispatch().
    eventName = 'cd_dispatch:AddNotification',
    generalArea = true,  -- if true, send approximate coords + street name (no exact location)
    alertCode = '10-66',
    alertMessage = 'Suspicious activity - possible vehicle stripping in the area.',
}

-- Strip minigame: wheel (press key once when in green zone) or progress bar only.
-- Set useWheel = false to use progress bar only (no key press, no spamming).
Config.SkillCheck = {
    useWheel = true,             -- true = wheel "press E once in green zone", false = progress bar only
    areaSize = 75,              -- success zone size in degrees (bigger = easier)
    speedMultiplier = 0.12,      -- wheel speed (lower = slower, easier to time; 0.1–0.2 recommended)
}

-- Progress bar / minigame. Use your server's progress bar export.
-- Examples: ox_lib = exports.ox_lib:progressCircle({ duration = 5000, ... })
--           progressBars = exports['progressBars']:Progress({ duration = 5000, ... })
Config.ProgressBar = {
    useExport = false,           -- set true and set exportName to use an export
    exportName = 'ox_lib',       -- e.g. 'ox_lib', 'progressBars', 'ac_progressbar'
    exportFunc = 'progressCircle', -- e.g. 'progressCircle', 'Progress'
    label = 'Removing part...',
    useNative = true,            -- if no export, use simple native progress (scaleform)
}

-- Build model -> tier lookup (do not edit)
Config.ModelToTier = {}
for tierName, data in pairs(Config.CarTiers) do
    for _, model in ipairs(data.models) do
        Config.ModelToTier[string.lower(model)] = tierName
    end
end

-- ox_target: 3rd eye option (one part per click). Must be close to vehicle.
Config.OxTarget = {
    enabled = true,
    distance = 2.5,               -- max interaction distance (stay close to strip)
    label = 'Strip part',
    icon = 'fas fa-screwdriver-wrench',
}

-- Mechanic animation while removing parts (realism). Stay within this distance or strip cancels.
Config.Strip = {
    maxDistance = 2.5,            -- meters; walk away = strip cancelled
    animation = {
        dict = 'mini@repair',     -- mechanic working on car
        name = 'fixing_a_player',
        flag = 1,                 -- loop
    },
}

-- Blips (optional)
Config.Blip = {
    chop = { sprite = 478, color = 1, scale = 0.9, label = 'Chop Shop' },
    sell = { sprite = 500, color = 2, scale = 0.8, label = 'Parts Buyer' },
}
