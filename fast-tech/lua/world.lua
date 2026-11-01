-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What the seat knows: its own units by role, the base, the tier it has
-- reached, and a memory of enemy buildings and contacts, since a seat
-- without full awareness forgets what leaves its sight.

local catalog = require("catalog")
local util = require("util")

local world = {
    wrecks = {},        -- wrecks left in the base: {x, z, size, tick}
    salvage = {},       -- wrecks near the base worth reclaiming: {x, z, metal, tick}
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
    -- The middle of the buildings round the start. Extractors on far
    -- deposits and buildings put far out for want of room pulled it 1 100
    -- units away (A tale of two cities), and the commander, sent home,
    -- went there.
    local sum_x, sum_z, count = 0, 0, 0
    for _, unit in ipairs(world.select(function(u, e) return e.structure and not e.extractor and world.finished(u) end)) do
        local at = util.pos(unit)
        if at and util.dist(at, world.start) <= 1500 then
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
    if entry ~= nil and entry.air and entry.combat then
        world.enemy_air = true
    end
    if entry ~= nil and entry.structure then
        world.enemy_buildings[unit.id] = {
            x = at.x, z = at.z, tier = entry.tier, cost = entry.cost, tick = me.tick,
            unit = unit, factory = entry.factory, commander = false,
            anti_air = world.anti_air(entry),
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

-- Remembers a large wreck left near the base, to clear it later.
function world.note_wreck(entry, wreck)
    if wreck == nil or wreck.x == nil or world.base == nil then
        return
    end
    local at = {x = util.whole(wreck.x), z = util.whole(wreck.z)}
    -- Any wreck within reach of the base is salvage for lean times; its
    -- metal is taken as half the unit's cost.
    local worth = entry ~= nil and entry.metal * 0.5 or 0
    if worth >= 25 and util.dist(at, world.base) <= 3000 then
        world.salvage[#world.salvage + 1] = {x = at.x, z = at.z, metal = worth, tick = me.tick}
        if #world.salvage > 80 then
            table.remove(world.salvage, 1)
        end
    end
    if util.dist(at, world.base) > 2500 then
        return
    end
    if entry ~= nil and (entry.metal >= 500 or entry.footprint >= 4) then
        world.wrecks[#world.wrecks + 1] = {x = at.x, z = at.z, size = entry.footprint, tick = me.tick}
        if #world.wrecks > 40 then
            table.remove(world.wrecks, 1)
        end
    end
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

-- How much an enemy is worth shooting first: commanders and decoys (they
-- look alike, so both count as commanders), then tier 4 and 5, tier 3,
-- anti-air (it keeps the seat's aircraft away), the economy, and the rest.
world.commander_priority = 6

function world.anti_air(entry)
    return entry ~= nil and entry.anti_air and (entry.defense or entry.combat)
end

function world.priority(entry)
    if entry == nil then
        return 1
    end
    if entry.commander or entry.decoy then
        return 6
    end
    if entry.tier >= 4 then
        return 5
    end
    if entry.tier == 3 then
        return 4
    end
    if world.anti_air(entry) then
        return 3
    end
    -- The economy, the factories and the builders.
    if entry.extractor or entry.power or entry.metal_maker or entry.factory
        or entry.metal_storage or entry.energy_storage or entry.mobile_builder then
        return 2
    end
    return 1
end

-- Whether `shooter` (a catalog entry, or nil for any) can fire at `target`:
-- only anti-air weapons hit aircraft, and only other weapons hit the rest.
function world.can_hit(shooter, target)
    if shooter == nil or target == nil then
        return true
    end
    if target.air then
        return shooter.anti_air == true
    end
    return shooter.hits_ground == true
end

-- The visible enemy to shoot from `from` within `reach`: the highest
-- priority, the nearest among equals. A commander is chased twice as far,
-- so everything near one turns on it. With `shooter` (the catalog entry of
-- the unit that fires) only what it can hit counts, and a bomber goes for
-- anti-air first.
function world.best_target(from, reach, shooter)
    local best, best_key
    for _, enemy in ipairs(world.visible_enemies()) do
        local at = util.pos(enemy)
        local entry = catalog.of(enemy)
        if at ~= nil and world.can_hit(shooter, entry) then
            local priority = world.priority(entry)
            if shooter ~= nil and shooter.bomber and world.anti_air(entry) then
                priority = 7
            end
            local limit = priority == world.commander_priority and reach * 2 or reach
            local d = util.dist(from, at)
            if d <= limit then
                local key = priority * 100000 - d
                if best_key == nil or key > best_key then
                    best, best_key = enemy, key
                end
            end
        end
    end
    return best
end

-- The radar or sonar contact nearest `from` within `reach`, as a point,
-- for when nothing in sight is worth shooting.
function world.nearest_contact(from, reach)
    local contacts = me.radar
    if type(contacts) ~= "table" then
        return nil
    end
    local best, best_d
    for index = 1, #contacts do
        local contact = contacts[index]
        if contact ~= nil and contact.x ~= nil and contact.current ~= false then
            local at = {x = util.whole(contact.x), z = util.whole(contact.z)}
            local d = util.dist(from, at)
            if d <= reach and (best_d == nil or d < best_d) then
                best, best_d = at, d
            end
        end
    end
    return best
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
