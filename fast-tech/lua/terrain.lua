-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What the map allows: how much of it is water, and whether the enemy can
-- be reached on land, by hovercraft or by ship. From that, the order in
-- which factory lines are preferred:
--
--   land map          kbots, vehicles > aircraft > ships > hovercraft
--   water map         kbots, vehicles, ships > aircraft > hovercraft
--   enemy over water  hovercraft and ships first, then aircraft
--   enemy cut off     aircraft first (nothing on the ground reaches it)
--
-- Ships count only when there is water near the base.

local catalog = require("catalog")
local util = require("util")
local world = require("world")

local terrain = {
    ready = false,
    water_share = 0,
    land_ok = true,
    hover_ok = true,
    ship_ok = false,
    water_point = nil, -- the open water nearest the base, for shipyards
}

local grid_size = 32
local water_map = 0.5    -- share of water that makes a water map
local some_water = 0.05  -- share below which ships are not worth it
local water_reach = 1500 -- how far from the base a shipyard may stand

-- Where the enemies stand: their own starts when the match tells them
-- (fixed starts), otherwise every start that is not the seat's.
local function enemy_starts()
    local found = {}
    for _, row in ipairs(me:players()) do
        if row.player ~= me.player and not me:allied(row.player) and row.start_x ~= nil then
            found[#found + 1] = {x = util.whole(row.start_x), z = util.whole(row.start_z)}
        end
    end
    if #found > 0 then
        return found
    end
    local starts = game.map:starts()
    if type(starts) == "table" then
        for _, start in ipairs(starts) do
            local at = {x = util.whole(start.x), z = util.whole(start.z)}
            if world.start == nil or util.dist(at, world.start) > 600 then
                found[#found + 1] = at
            end
        end
    end
    return found
end

-- Whether a movement class gets from the base to the enemy: to every
-- enemy start, or to most of them when the starts are only guesses.
-- Read once per class.
local class_reach = {}

function terrain.class_reaches(class)
    if class == nil or class == "" then
        return true
    end
    local known = class_reach[class]
    if known ~= nil then
        return known
    end
    local targets = terrain.targets or {}
    if #targets == 0 or world.start == nil then
        return true
    end
    local from = {x = world.start.x, z = world.start.z}
    local reached = 0
    for _, target in ipairs(targets) do
        local ok, result = pcall(function() return game.map:reachable(from, target, class) end)
        if ok and result == true then
            reached = reached + 1
        end
    end
    local result = reached * 2 > #targets
    if terrain.targets_known then
        result = reached == #targets
    end
    class_reach[class] = result
    return result
end

-- Whether a unit type can reach the enemy on this map. Aircraft always
-- can; ships when the water near the base leads to water near the enemy.
function terrain.useful(entry)
    if entry.air then
        return true
    end
    local class = entry.record.movementclass
    if entry.water_only or (type(class) == "string" and string.find(string.upper(class), "BOAT", 1, true)) then
        return terrain.ship_reaches == true
    end
    if type(class) ~= "string" or class == "" then
        return true
    end
    return terrain.class_reaches(class)
end

-- Whether ships get from the water by the base to water by the enemy:
-- the nearest open water to each enemy start, within a long reach.
local function ships_reach(waters, class)
    if terrain.water_point == nil or class == nil then
        return false
    end
    local reached, total = 0, 0
    for _, target in ipairs(terrain.targets) do
        local best, best_d
        for _, water in ipairs(waters) do
            local d = util.dist(water, target)
            if d <= 2500 and (best_d == nil or d < best_d) then
                best, best_d = water, d
            end
        end
        total = total + 1
        if best ~= nil then
            local ok, result = pcall(function() return game.map:reachable(terrain.water_point, best, class) end)
            if ok and result == true then
                reached = reached + 1
            end
        end
    end
    return total > 0 and reached * 2 >= total
end

-- A ship's movement class on the seat's side.
local function ship_class()
    local side = me.side_name
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and entry.combat and entry.water_only and not entry.air
            and type(entry.record.movementclass) == "string" and entry.record.movementclass ~= ""
            and (side == nil or entry.side == "" or entry.side == side) then
            return entry.record.movementclass
        end
    end
    return nil
end

-- Whether most of a line's combat units reach the enemy, over every
-- factory of that line on the seat's side.
local function line_reaches(line)
    local side = me.side_name
    local total, good = 0, 0
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and entry.factory and entry.line == line
            and (side == nil or entry.side == "" or entry.side == side) then
            for _, built in ipairs(entry.builds) do
                if built.combat then
                    total = total + 1
                    if terrain.useful(built) then
                        good = good + 1
                    end
                end
            end
        end
    end
    return total > 0 and good * 2 >= total
end

-- Reads the map once the seat knows where it stands.
function terrain.survey()
    if terrain.ready or world.start == nil then
        return
    end
    local grid = brain.grid({"water"}, grid_size)
    if grid == nil then
        return
    end
    local width = util.whole(game.map.world_width)
    local height = util.whole(game.map.world_height)
    local total, nearest, nearest_d = 0, nil, nil
    local waters = {}
    for index = 0, grid_size * grid_size - 1 do
        local share = util.num(grid:get(index + 1))
        total = total + share
        if share > 0.6 then
            local point = {
                x = (index % grid_size) * width // grid_size + width // (2 * grid_size),
                z = (index // grid_size) * height // grid_size + height // (2 * grid_size),
            }
            waters[#waters + 1] = point
            local d = util.dist(point, world.start)
            if d <= water_reach and (nearest_d == nil or d < nearest_d) then
                nearest, nearest_d = point, d
            end
        end
    end
    terrain.water_share = total / (grid_size * grid_size)
    terrain.water_point = nearest
    terrain.targets = enemy_starts()
    terrain.targets_known = false
    for _, row in ipairs(me:players()) do
        if row.player ~= me.player and row.start_x ~= nil then
            terrain.targets_known = true
        end
    end
    terrain.land_ok = line_reaches("kbot") or line_reaches("vehicle")
    terrain.hover_ok = line_reaches("hover")
    terrain.ship_ok = nearest ~= nil and terrain.water_share >= some_water
    terrain.ship_reaches = terrain.ship_ok and ships_reach(waters, ship_class())
    terrain.ready = true
    print(string.format("map: water %.0f%%, enemy by land %s, by hover %s, ships %s (reach %s), %d enemy starts%s",
        terrain.water_share * 100, tostring(terrain.land_ok), tostring(terrain.hover_ok),
        tostring(terrain.ship_ok), tostring(terrain.ship_reaches), #terrain.targets,
        terrain.targets_known and "" or " guessed"))
end

-- How much a line is wanted on this map: 0 is the most, higher is less,
-- nil means not at all.
function terrain.rank(line)
    if line == "ship" and not terrain.ship_ok then
        return nil
    end
    if not terrain.land_ok and not terrain.hover_ok then
        local order = {air = 0, ship = 1, hover = 2, kbot = 3, vehicle = 3}
        return order[line]
    end
    if not terrain.land_ok then
        -- Across water: hovercraft, and ships when they reach, then aircraft.
        local order = {hover = 0, ship = terrain.ship_reaches and 0 or 2, air = 1, kbot = 3, vehicle = 3}
        return order[line]
    end
    if terrain.water_share > water_map then
        local order = {kbot = 0, vehicle = 0, ship = 0, air = 1, hover = 3}
        return order[line]
    end
    local order = {kbot = 0, vehicle = 0, air = 1, ship = 2, hover = 3}
    return order[line]
end

return terrain
