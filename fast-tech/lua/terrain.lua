-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What the map allows: how much of it is water, and whether the enemy can
-- be reached on land, by hovercraft or by ship. From that, the order in
-- which factory lines are preferred:
--
--   land map          kbots, vehicles > aircraft > ships > hovercraft
--   water map         kbots, vehicles, ships > aircraft > hovercraft
--   enemy over water  hovercraft first (land does not reach it)
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

-- Movement classes of the seat's side for each line, taken from its
-- factories' combat units.
local function line_classes()
    local found = {}
    local side = me.side_name
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and entry.factory and entry.line ~= nil and found[entry.line] == nil
            and (side == nil or entry.side == "" or entry.side == side) then
            found[entry.line] = catalog.line_class(entry)
        end
    end
    return found
end

-- Enemy start positions: the starts that are not the seat's own.
local function enemy_starts()
    local found = {}
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

local function reaches(class, from, targets)
    if class == nil then
        return false
    end
    for _, target in ipairs(targets) do
        local ok, result = pcall(function() return game.map:reachable(from, target, class) end)
        if ok and result == true then
            return true
        end
    end
    return false
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
    for index = 0, grid_size * grid_size - 1 do
        local share = util.num(grid:get(index + 1))
        total = total + share
        if share > 0.6 then
            local point = {
                x = (index % grid_size) * width // grid_size + width // (2 * grid_size),
                z = (index // grid_size) * height // grid_size + height // (2 * grid_size),
            }
            local d = util.dist(point, world.start)
            if d <= water_reach and (nearest_d == nil or d < nearest_d) then
                nearest, nearest_d = point, d
            end
        end
    end
    terrain.water_share = total / (grid_size * grid_size)
    terrain.water_point = nearest
    local classes = line_classes()
    local targets = enemy_starts()
    if #targets > 0 then
        local from = {x = world.start.x, z = world.start.z}
        terrain.land_ok = reaches(classes.vehicle, from, targets) or reaches(classes.kbot, from, targets)
        terrain.hover_ok = reaches(classes.hover, from, targets)
    end
    terrain.ship_ok = nearest ~= nil and terrain.water_share >= some_water
    terrain.ready = true
    print(string.format("map: water %.0f%%, enemy by land %s, by hover %s, ships %s",
        terrain.water_share * 100, tostring(terrain.land_ok), tostring(terrain.hover_ok),
        tostring(terrain.ship_ok)))
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
        local order = {hover = 0, air = 1, ship = 2, kbot = 3, vehicle = 3}
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
