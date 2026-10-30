-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- The race up the tiers. The goal is one factory of the next tier. A
-- builder that can put it down does so; when none can, the top factory
-- makes one. Old factories are reclaimed once they are two tiers behind,
-- or when a large lab finds no room.

local catalog = require("catalog")
local util = require("util")
local world = require("world")
local economy = require("economy")

local tech = {
    goal = nil,       -- catalog entry of the factory being raced for
    frame = nil,      -- its nanoframe once started
    started = nil,    -- tick the frame was ordered
    reclaiming = {},  -- factory id -> tick the reclaim was ordered
    scout_lab = nil,  -- factory kept for scouts
    no_room = 0,      -- placements of the goal that failed in a row
}

-- The highest factory tier the brain climbs to; LEV5 units come out of
-- LEV4 factories.
local top_factory_tier = 4

-- The distinct types among the seat's finished units that `test` accepts,
-- as a sequence.
local function own_types(test)
    local found, seen = {}, {}
    for _, unit in ipairs(world.select(function(u, e) return test(e) and world.finished(u) end)) do
        local entry = catalog.of(unit)
        if not seen[entry.index] then
            seen[entry.index] = true
            found[#found + 1] = entry
        end
    end
    return found
end

local function same_side(entry)
    local side = me.side_name
    return side == nil or entry.side == "" or entry.side == side
end

-- The highest factory tier a factory leads to: its own, or any factory a
-- builder it makes can put down, followed onward. Escalation's lines end
-- at different tiers, so the race follows the line that reaches highest.
local reach_memo = {}
local function reach(entry, visiting)
    local known = reach_memo[entry.index]
    if known ~= nil then
        return known
    end
    visiting = visiting or {}
    if visiting[entry.index] then
        return catalog.factory_tier(entry)
    end
    visiting[entry.index] = true
    local best = catalog.factory_tier(entry)
    for _, built in ipairs(entry.builds) do
        if built.mobile_builder and same_side(built) then
            for _, next_factory in ipairs(built.builds) do
                if next_factory.factory and next_factory ~= entry and same_side(next_factory)
                    and catalog.factory_tier(next_factory) >= catalog.factory_tier(entry) then
                    best = math.max(best, reach(next_factory, visiting))
                end
            end
        end
    end
    visiting[entry.index] = nil
    best = math.min(best, top_factory_tier)
    reach_memo[entry.index] = best
    return best
end

function tech.reset()
    reach_memo = {}
end

-- The next factory to race for: the one whose line reaches the highest
-- tier, preferring the next tier up and then the strongest line. A factory
-- of the current tier is a goal only when it opens a higher line than any
-- the seat has.
function tech.choose_goal()
    local tier = world.tier
    local builders = own_types(function(e) return e.mobile_builder end)
    local factories = own_types(function(e) return e.factory end)
    local owned, owned_reach = {}, tier
    for _, factory in ipairs(factories) do
        owned[factory.index] = true
        owned_reach = math.max(owned_reach, reach(factory))
    end
    local candidates, direct = {}, {}
    for _, builder in ipairs(builders) do
        for _, built in ipairs(builder.builds) do
            if built.factory then
                candidates[#candidates + 1] = built
                direct[built.index] = true
            end
        end
    end
    for _, factory in ipairs(factories) do
        for _, maker in ipairs(factory.builds) do
            if maker.mobile_builder then
                for _, built in ipairs(maker.builds) do
                    if built.factory then
                        candidates[#candidates + 1] = built
                    end
                end
            end
        end
    end
    local best, best_key
    for _, entry in ipairs(candidates) do
        local level = catalog.factory_tier(entry)
        local line = reach(entry)
        local useful = not owned[entry.index] and same_side(entry) and not entry.water_only
            and level <= top_factory_tier
            and (level > tier or line > owned_reach)
        if useful then
            local score = catalog.factory_score(entry) + (direct[entry.index] and 5 or 0)
            if entry.air then
                score = score - 5
            end
            if level == 1 then
                -- The first lab should also give the early scout.
                for _, built in ipairs(entry.builds) do
                    if built.scout and not built.air then
                        score = score + 6
                        break
                    end
                end
            end
            local key = line * 100000 + (level == tier + 1 and 50000 or 0) + level * 1000 + score
            if best_key == nil or key > best_key then
                best, best_key = entry, key
            end
        end
    end
    if best ~= tech.goal then
        tech.frame, tech.started, tech.no_room = nil, nil, 0
        if best then
            print(string.format("tech goal: %s (tier %d, line reaches %d)", best.name, best.tier, reach(best)))
        end
    end
    tech.goal = best
end

-- A builder type a factory of the seat can make that can build the goal.
function tech.builder_for_goal(factory_entry)
    if tech.goal == nil then
        return nil
    end
    for _, built in ipairs(factory_entry.builds) do
        if built.mobile_builder and catalog.can_build(built, tech.goal) then
            return built
        end
    end
    return nil
end

function tech.goal_builders()
    if tech.goal == nil then
        return {}
    end
    return world.select(function(u, e)
        return e.mobile_builder and world.finished(u) and catalog.can_build(e, tech.goal)
    end)
end

-- Whether the economy can carry the goal now. The bot starts the lab as
-- soon as the income would pay for it in about four minutes; starting it
-- sooner starves every other build until it is done.
function tech.affordable()
    if tech.goal == nil then
        return false
    end
    local e = economy.now or economy.read()
    local window = 240
    if me.difficulty ~= "hard" then
        window = 300
    end
    local metal_ok = e.metal_income * window + e.metal >= tech.goal.metal or e.metal_share > 0.9
    local energy_ok = e.energy_income * window + e.energy >= tech.goal.energy * 0.8 or e.energy_share > 0.9
    return metal_ok and energy_ok
end

function tech.note_created(unit)
    if tech.goal ~= nil and catalog.of(unit) == tech.goal and unit.finished ~= true then
        tech.frame = unit
    end
end

function tech.frame_alive()
    if tech.frame ~= nil and (not util.alive(tech.frame) or tech.frame.finished == true) then
        tech.frame = nil
    end
    return tech.frame ~= nil
end

-- Lab reclaiming --------------------------------------------------------------

-- Factories behind the times: two tiers below the top, or tier 1 once the
-- seat reached tier 3. The scout lab is kept.
function tech.obsolete()
    local found = {}
    local top = world.tier
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        local entry = catalog.of(unit)
        local tier = catalog.factory_tier(entry)
        if unit ~= tech.scout_lab and (tier <= top - 2 or (tier == 1 and top >= 3))
            and not tech.could_scout(unit, entry) then
            found[#found + 1] = unit
        end
    end
    return found
end

-- A tier-1 factory that makes scouts is kept while the seat has no scout
-- lab: it is about to become one.
function tech.could_scout(unit, entry)
    if tech.scout_lab ~= nil and util.alive(tech.scout_lab) then
        return false
    end
    if world.tier < 3 or catalog.factory_tier(entry) ~= 1 then
        return false
    end
    for _, built in ipairs(entry.builds) do
        if built.scout then
            return true
        end
    end
    return false
end

-- The lowest, nearest factory below the top tier: room for a large lab.
function tech.make_room()
    local base = world.base or world.start
    local best, best_key
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        local entry = catalog.of(unit)
        local tier = catalog.factory_tier(entry)
        if unit ~= tech.scout_lab and tier < world.tier and tech.reclaiming[unit.id] == nil then
            local at = util.pos(unit)
            local key = tier * 100000 + (at and util.dist(at, base) or 0)
            if best_key == nil or key < best_key then
                best, best_key = unit, key
            end
        end
    end
    return best
end

-- Factories to reclaim now, at most one new one per call.
function tech.reclaim_target()
    for id, tick in pairs(tech.reclaiming) do
        if me.tick - tick > 30 * 90 then
            tech.reclaiming[id] = nil
        end
    end
    for _, unit in ipairs(tech.obsolete()) do
        if tech.reclaiming[unit.id] == nil then
            return unit
        end
    end
    if tech.no_room >= 2 then
        local unit = tech.make_room()
        if unit ~= nil then
            tech.no_room = 0
            print("reclaiming " .. catalog.of(unit).name .. " to make room")
            return unit
        end
    end
    return nil
end

return tech
