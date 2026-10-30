-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- Small helpers shared by every module: numbers out of f32 and fixed
-- values, positions in whole world units, distances and free units.

local util = {}

-- A Lua number from a number, an f32 or a fixed value. Anything else is 0.
function util.num(value)
    local kind = type(value)
    if kind == "number" then
        return value
    end
    if kind == "userdata" or kind == "table" then
        local ok, result = pcall(function() return value:tonumber() end)
        if ok and type(result) == "number" then
            return result
        end
        ok, result = pcall(function() return value:floor() end)
        if ok and type(result) == "number" then
            return result
        end
    end
    return 0
end

-- A whole number of world units.
function util.whole(value)
    return math.floor(util.num(value))
end

-- A unit's position as {x, z} in whole world units, or nil when unknown.
function util.pos(unit)
    if unit == nil or unit.x == nil or unit.z == nil then
        return nil
    end
    return {x = util.whole(unit.x), z = util.whole(unit.z)}
end

function util.dist2(a, b)
    local dx = a.x - b.x
    local dz = a.z - b.z
    return dx * dx + dz * dz
end

function util.dist(a, b)
    return math.sqrt(util.dist2(a, b))
end

-- A point clamped inside the map, with a margin.
function util.clamp(point, margin)
    margin = margin or 64
    local width = util.whole(game.map.world_width)
    local height = util.whole(game.map.world_height)
    local x = math.max(margin, math.min(width - margin, math.floor(point.x)))
    local z = math.max(margin, math.min(height - margin, math.floor(point.z)))
    return {x = x, z = z}
end

-- The point `distance` units from `from` toward `to`.
function util.toward(from, to, distance)
    local length = util.dist(from, to)
    if length < 1 then
        return {x = from.x, z = from.z}
    end
    local share = distance / length
    return {x = from.x + (to.x - from.x) * share, z = from.z + (to.z - from.z) * share}
end

-- A point at an angle (0..1 of a full turn) and a distance from `centre`.
function util.around(centre, turn, distance)
    local angle = turn * 2 * math.pi
    return {x = centre.x + math.cos(angle) * distance, z = centre.z + math.sin(angle) * distance}
end

-- Whether the seat has ever seen the ground at `point`.
function util.explored(point)
    local grid = me.explored
    if grid == nil then
        return true
    end
    local cx, cz = grid:cell_of(math.floor(point.x), math.floor(point.z))
    if cx == nil then
        return false
    end
    return grid:at(cx, cz) == true
end

-- Whether `unit` can travel to `point`. Aircraft and units without a
-- movement class go anywhere.
function util.reachable(unit, point)
    local record = unit.type
    if record == nil or record.canfly == true then
        return true
    end
    local class = record.movementclass
    if type(class) ~= "string" or class == "" then
        return true
    end
    local ok, result = pcall(function()
        return game.map:reachable(unit, {x = math.floor(point.x), z = math.floor(point.z)}, class)
    end)
    return not ok or result ~= false
end

-- A unit with no order at the head of its queue, or a finished one.
function util.free(unit)
    local kind, _, idle = unit:head_order()
    return kind == nil or idle == true or kind == "Standby"
end

function util.alive(unit)
    return unit ~= nil and unit.alive == true
end

function util.enemy(unit)
    local owner = unit.owner
    return owner ~= nil and owner ~= me.player and me:allied(owner) ~= true
end

-- Picks one entry of `list` with probability proportional to weight(entry).
function util.weighted(list, weight)
    local total = 0
    for index = 1, #list do
        total = total + math.max(0, weight(list[index]))
    end
    if total <= 0 then
        return nil
    end
    local roll = (brain.random(1000000) - 1) / 1000000 * total
    for index = 1, #list do
        roll = roll - math.max(0, weight(list[index]))
        if roll < 0 then
            return list[index]
        end
    end
    return list[#list]
end

-- True with the given probability (0..1).
function util.chance(probability)
    if probability >= 1 then
        return true
    end
    if probability <= 0 then
        return false
    end
    return brain.random(1000) <= math.floor(probability * 1000)
end

function util.count(map)
    local count = 0
    for _ in pairs(map) do
        count = count + 1
    end
    return count
end

-- Runs fn and logs the first error of each label instead of stopping the seat.
local reported = {}
function util.guard(label, fn, ...)
    local ok, problem = pcall(fn, ...)
    if not ok and not reported[label] then
        reported[label] = true
        print("error in " .. label .. ": " .. tostring(problem))
    end
    return ok
end

return util
