-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- Scouts go where the seat sees nothing. The map is cut into a 16 by 16
-- grid; a scout takes a cell out of sight, never explored ones first, the
-- unexplored start positions before anything, and not a cell another scout
-- already heads for. Ground scouts only take cells they can reach.

local util = require("util")
local world = require("world")
local catalog = require("catalog")

local scouts = {
    heading = {}, -- scout id -> {x, z, tick}
}

local size = 16

local function cell_centre(index)
    local width = util.whole(game.map.world_width)
    local height = util.whole(game.map.world_height)
    local row = index // size
    local column = index % size
    return {
        x = (column * width) // size + width // (2 * size),
        z = (row * height) // size + height // (2 * size),
    }
end

local function taken(point)
    for _, heading in pairs(scouts.heading) do
        if util.dist2(heading, point) < 400 * 400 then
            return true
        end
    end
    return false
end

local function reachable(unit, entry, point)
    if entry.air then
        return true
    end
    local class = entry.record.movementclass
    if type(class) ~= "string" or class == "" then
        return true
    end
    local ok, result = pcall(function() return game.map:reachable(unit, point, class) end)
    return ok and result == true
end

-- The place to send `unit` next, or nil.
local function choose(unit, entry)
    local at = util.pos(unit)
    if at == nil then
        return nil
    end
    for _, start in ipairs(world.unexplored_starts()) do
        if not taken(start) then
            return start
        end
    end
    local grid = brain.grid({"sight", "explored"}, size)
    if grid == nil then
        return nil
    end
    local cells = size * size
    local candidates = {}
    for index = 0, cells - 1 do
        local sight = util.num(grid:get(index + 1))
        if sight <= 0.05 then
            local explored = util.num(grid:get(cells + index + 1))
            local point = cell_centre(index)
            if not taken(point) then
                local d = util.dist(at, point)
                -- Unexplored ground first, nearer cells a little before far ones.
                local score = (1.5 - explored) * 1000 / (1 + d / 2000) * (0.5 + brain.random(100) / 100)
                candidates[#candidates + 1] = {point = point, score = score}
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    for index = 1, math.min(6, #candidates) do
        local point = candidates[index].point
        if reachable(unit, entry, point) then
            return point
        end
    end
    -- The reach test can say no from a blocked cell; go anyway.
    if #candidates > 0 then
        return candidates[1].point
    end
    return nil
end

local function send(unit)
    local entry = catalog.of(unit)
    if entry == nil then
        return
    end
    local point = choose(unit, entry)
    if point == nil then
        return
    end
    point = util.clamp(point, 64)
    if unit:move(point) then
        scouts.heading[unit.id] = {x = point.x, z = point.z, tick = me.tick}
    end
end

function scouts.step()
    for id in pairs(scouts.heading) do
        if world.own[id] == nil then
            scouts.heading[id] = nil
        end
    end
    for _, unit in ipairs(world.select(function(u, e) return e.scout and world.finished(u) end)) do
        local heading = scouts.heading[unit.id]
        local stale = heading == nil or me.tick - heading.tick > 30 * 60
            or me:sees(heading.x, heading.z) or util.free(unit)
        if stale then
            send(unit)
        end
    end
end

function scouts.on_idle(unit)
    scouts.heading[unit.id] = nil
    send(unit)
end

return scouts
