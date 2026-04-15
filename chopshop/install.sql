-- ============================================================
--  ChopShop - SQL Install Script
--  Run this in your database before starting the resource.
-- ============================================================

-- ============================================================
--  1. ESX Job
--     Creates the 'chopshop' job with a single 'worker' grade.
--     Skip if you already have this job in your database.
-- ============================================================
INSERT IGNORE INTO `jobs` (`name`, `label`) VALUES ('chopshop', 'Chop Shop');

INSERT IGNORE INTO `job_grades` (`job_name`, `grade`, `name`, `label`, `salary`, `skin_male`, `skin_female`)
VALUES ('chopshop', 0, 'worker', 'Worker', 0, '{}', '{}');

-- ============================================================
--  2. ESX Items
--     Adds the tool items needed to strip vehicles.
--     These must exist in the `items` table for ESX to recognise them.
-- ============================================================
INSERT IGNORE INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`)
VALUES
    ('crowbar',     'Crowbar',     1, 0, 1),
    ('screwdriver', 'Screwdriver', 1, 0, 1),
    ('repair_kit',  'Repair Kit',  1, 0, 1);

-- ============================================================
--  3. ox_inventory stash (optional)
--     If you use ox_inventory the stash is created automatically
--     the first time it is opened. No SQL is required for that.
--     The stash id is defined in Config.ToolStashPed.stashId = 'chopshop_tools'
-- ============================================================
