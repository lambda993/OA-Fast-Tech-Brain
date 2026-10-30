-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What the seat knows: its own units by role, the base, the tier it has
-- reached, and a memory of enemy buildings and contacts, since a seat
-- without full awareness forgets what leaves its sight.

local catalog = require("catalog")
local util = require("util")

local world = {
    tier = 0,
    own = {},           -- id -> unit, every live unit of the seat
    enemy_buildings = {}, -- id -> {x, z, tier, cost, tick}
    contacts = {},      -- recent radar or sight positions of enemies
    alarm = nil,        -- {x, z, tick} where the base was last hit
    start = nil,
    base = nil,
}

function world.reset()
    world.tier = 0
    world.own = {}
    world.enemy_buildings = {}
    world.contacts = {}
    world.alarm = nil
    world.find_start()
    me:each_unit(function(unit)
        world.own[unit.id] = unit
    end)
end

function world.find_start()
    world.start = nil
    local players = me:players()
    for _, row in ipairs(players) do
        if row.player == me.player and row.start_x ~= nil then
            world.start = {x = util.whole(row.start_x), z = util.whole(row.start_z)}
        end
    end
    if world.start == nil then
        me:each_unit(function(unit)
            local entry = catalog.of(unit)
            if world.start == nil and entry and entry.commander then
                world.start = util.pos(unit)
            end
        end)
    end
    world.base = world.start
end

-- Whether the seat knows where it stands. A seat opened before the
-- players are placed has no start and no commander yet, so the start is
-- looked for again each turn until it is known.
function world.located()
    if world.start == nil then
        world.find_start()
        if world.start ~= nil then
            print(string.format("start found at %d,%d", world.start.x, world.start.z))
        end
    end
    return world.start ~= nil
end

-- Units of the seat that `test(unit, entry)` accepts.
function world.select(test)
    local found = {}
    for id, unit in pairs(world.own) do
        if not util.alive(unit) then
            world.own[id] = nil
        else
            local entry = catalog.of(unit)
            if entry ~= nil and test(unit, entry) then
                found[#found + 1] = unit
            end
        end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    return found
end

function world.finished(unit)
    return unit.finished == true
end

-- The base is the middle of the seat's buildings, or its start.
function world.update_base()
    if not world.located() then
        return
    end
    local sum_x, sum_z, count = 0, 0, 0
    for _, unit in ipairs(world.select(function(u, e) return e.structure and world.finished(u) end)) do
        local at = util.pos(unit)
        if at then
            sum_x, sum_z, count = sum_x + at.x, sum_z + at.z, count + 1
        end
    end
    if count >= 3 then
        world.base = {x = sum_x // count, z = sum_z // count}
    else
        world.base = world.start
    end
end

-- The highest factory tier the seat has finished.
function world.update_tier()
    local tier = 0
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        local entry = catalog.of(unit)
        tier = math.max(tier, catalog.factory_tier(entry))
    end
    if tier > world.tier then
        print("tier " .. world.tier .. " -> " .. tier)
    end
    world.tier = tier
end

-- Enemy memory --------------------------------------------------------------

function world.remember(unit)
    if not util.enemy(unit) then
        return
    end
    local at = util.pos(unit)
    if at == nil then
        return
    end
    local entry = catalog.of(unit)
    if entry ~= nil and entry.structure then
        world.enemy_buildings[unit.id] = {
            x = at.x, z = at.z, tier = entry.tier, cost = entry.cost, tick = me.tick,
            unit = unit, factory = entry.factory, commander = false,
        }
    end
    world.note_contact(at)
end

function world.note_contact(at)
    world.contacts[#world.contacts + 1] = {x = at.x, z = at.z, tick = me.tick}
    if #world.contacts > 64 then
        table.remove(world.contacts, 1)
    end
end

function world.forget(unit)
    world.enemy_buildings[unit.id] = nil
end

-- Drops remembered buildings whose place the seat sees again empty.
function world.prune()
    for id, building in pairs(world.enemy_buildings) do
        local gone = building.unit ~= nil and building.unit.alive == false
        if not gone and me:sees(building.x, building.z) then
            gone = not me:sees_unit(building.unit)
        end
        if gone then
            world.enemy_buildings[id] = nil
        end
    end
    local keep = {}
    for _, contact in ipairs(world.contacts) do
        if me.tick - contact.tick < 30 * 120 then
            keep[#keep + 1] = contact
        end
    end
    world.contacts = keep
end

-- Live enemies the seat sees now.
function world.visible_enemies()
    local found = {}
    local seen = me.seen
    if type(seen) ~= "table" then
        return found
    end
    for index = 1, #seen do
        local unit = seen[index]
        if util.alive(unit) and util.enemy(unit) then
            found[#found + 1] = unit
        end
    end
    return found
end

-- Start positions that may hold an enemy and are not yet explored.
function world.unexplored_starts()
    local found = {}
    local starts = game.map:starts()
    if type(starts) ~= "table" then
        return found
    end
    for _, start in ipairs(starts) do
        local at = {x = util.whole(start.x), z = util.whole(start.z)}
        local own = world.start ~= nil and util.dist(at, world.start) < 600
        if not own then
            local explored = me.explored
            local known = false
            if explored ~= nil then
                local cx, cz = explored:cell_of(at.x, at.z)
                if cx ~= nil then
                    known = explored:at(cx, cz) == true
                end
            end
            if not known then
                found[#found + 1] = at
            end
        end
    end
    return found
end

-- Where the enemy most likely is: the closest remembered building, a
-- recent contact, or an unexplored start.
function world.enemy_target(from)
    local best, best_d
    for _, building in pairs(world.enemy_buildings) do
        local d = util.dist2(from, building)
        if building.factory then
            d = d * 0.5
        end
        if best_d == nil or d < best_d then
            best, best_d = {x = building.x, z = building.z}, d
        end
    end
    if best ~= nil then
        return best
    end
    for index = #world.contacts, 1, -1 do
        local contact = world.contacts[index]
        if me.tick - contact.tick < 30 * 60 then
            return {x = contact.x, z = contact.z}
        end
    end
    local starts = world.unexplored_starts()
    for _, at in ipairs(starts) do
        local d = util.dist2(from, at)
        if best_d == nil or d < best_d then
            best, best_d = at, d
        end
    end
    return best
end

-- The side of the base that faces the enemy, for radar, defences and rally.
function world.front(distance)
    local base = world.base or world.start
    local target = world.enemy_target(base)
    if target == nil then
        target = {x = util.whole(game.map.world_width) // 2, z = util.whole(game.map.world_height) // 2}
    end
    return util.clamp(util.toward(base, target, distance), 96)
end

return world
