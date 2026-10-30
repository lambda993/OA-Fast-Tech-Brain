-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What each idle factory makes. The top tier builds freely; each tier
-- below builds less, and tier 1 the least. Within a list the higher
-- tiers weigh far more, tier 2 well above tier 1. Builders come first
-- while the race needs them, and the scout lab only makes scouts.

local catalog = require("catalog")
local economy = require("economy")
local tech = require("tech")
local util = require("util")
local world = require("world")

local factories = {
    alarm_until = 0,
}

-- How strongly a combat unit of each tier is preferred.
local tier_weight = {[0] = 0, 1, 8, 14, 22, 34}

-- Builders the seat keeps for each factory tier.
local builders_wanted = {[0] = 0, 7, 6, 5, 4, 4}

local scout_cap = 8

-- Worth of the army the seat keeps at home, by tier, before racing on.
local guard_worth = {[0] = 0, 1200, 5000, 15000, 40000, 60000}

local function army_worth()
    local total = 0
    for _, unit in ipairs(world.select(function(u, e) return e.combat and world.finished(u) end)) do
        total = total + catalog.of(unit).cost
    end
    return total
end

-- True while the home army is below the guard the tier calls for.
function factories.guard_short()
    local wanted = guard_worth[math.min(5, world.tier)] or 0
    if me.level == "fair" then
        wanted = wanted * 0.7
    end
    return army_worth() < wanted
end

-- Share of idle turns a factory `behind` tiers under the top spends
-- making combat units.
local function production_share(tier, top)
    local behind = top - tier
    if behind <= 0 then
        -- Racing for the next tier: the top factory only keeps a guard.
        if tech.goal ~= nil then
            return top <= 1 and 0.3 or 0.6
        end
        return 1
    end
    if tier == 1 then
        if behind == 1 then
            return 0.15
        end
        return 0
    end
    if behind == 1 then
        return 0.4
    end
    if behind == 2 then
        return 0.1
    end
    return 0
end

local function level_share()
    if me.level == "fair" then
        return 0.85
    end
    return 1
end

local function count_builders(tier)
    return #world.select(function(_, e)
        return e.mobile_builder and not e.commander and math.max(1, e.tier) == tier
    end)
end

local function scouts()
    return world.select(function(_, e) return e.scout end)
end

local function pick_scout(entry)
    local best
    for _, built in ipairs(entry.builds) do
        if built.scout and (best == nil or (built.air and not best.air)
            or (built.air == best.air and built.cost < best.cost)) then
            best = built
        end
    end
    return best
end

local function pick_combat(entry)
    local options = catalog.buildable(entry, function(e) return e.combat end)
    return util.weighted(options, function(e)
        local weight = tier_weight[math.min(5, e.tier)] or 1
        -- Air keeps a smaller part of the army: it cannot hold ground.
        if e.air then
            weight = weight * 0.5
        end
        return weight
    end)
end

-- What the seat's builders, finished or not, can already do.
local function owned_abilities()
    local found = {}
    for _, unit in ipairs(world.select(function(_, e) return e.mobile_builder end)) do
        for word in pairs(catalog.abilities(catalog.of(unit))) do
            found[word] = true
        end
        if tech.goal ~= nil and catalog.can_build(catalog.of(unit), tech.goal) then
            found.goal = true
        end
    end
    return found
end

local ability_weight = {extractor = 6, goal = 6, radar = 2, maker = 2, power = 1, geo = 1, defense = 1}
local ability_order = {"extractor", "goal", "radar", "maker", "power", "geo", "defense"}

-- The builder this factory should make, if any: first one that brings an
-- ability the seat lacks (extractors and the next lab weigh most), then
-- more of the best kind until the tier's count is met.
local function pick_builder(entry, tier)
    local owned = owned_abilities()
    local best, best_score
    for _, built in ipairs(entry.builds) do
        if built.mobile_builder then
            local abilities = catalog.abilities(built)
            if tech.goal ~= nil and catalog.can_build(built, tech.goal) then
                abilities.goal = true
            end
            local missing, total = 0, 0
            for _, word in ipairs(ability_order) do
                if abilities[word] then
                    total = total + ability_weight[word]
                    if not owned[word] then
                        missing = missing + ability_weight[word]
                    end
                end
            end
            local score = missing * 100 + total * 5 + built.tier - (built.air and 3 or 0)
            if best_score == nil or score > best_score then
                best, best_score = built, score
            end
        end
    end
    if best == nil then
        return nil
    end
    local brings_missing = best_score >= 100
    if brings_missing and (best_score >= 600 or tier >= world.tier) then
        return best
    end
    if tier < world.tier then
        return nil
    end
    if count_builders(tier) >= (builders_wanted[math.min(5, tier)] or 2) then
        return nil
    end
    return best
end

local function one_factory(unit)
    if not util.free(unit) or tech.reclaiming[unit.id] ~= nil then
        return
    end
    local entry = catalog.of(unit)
    local tier = catalog.factory_tier(entry)
    local top = world.tier
    if unit == tech.scout_lab then
        if #scouts() < scout_cap then
            local scout = pick_scout(entry)
            if scout ~= nil then
                unit:queue(scout.record, 1)
            end
        end
        return
    end
    local short = factories.guard_short() and tier >= top - 1
    local builder = pick_builder(entry, tier)
    -- A short guard comes before more builders once there are four, except
    -- the one the next lab needs.
    local builder_count = #world.select(function(_, e) return e.mobile_builder and not e.commander end)
    if builder ~= nil and short and builder_count >= 4
        and not (tech.goal ~= nil and catalog.can_build(builder, tech.goal) and #tech.goal_builders() == 0) then
        builder = nil
    end
    if builder ~= nil then
        unit:queue(builder.record, 1)
        return
    end
    -- One early scout from the first factory that can make one.
    if top <= 2 and #scouts() < 1 then
        local scout = pick_scout(entry)
        if scout ~= nil then
            unit:queue(scout.record, 1)
            return
        end
    end
    local share = production_share(tier, top) * level_share()
    -- Metal piling up is metal wasted: spend it.
    local e = economy.now or economy.read()
    if e.metal_share > 0.8 and e.energy_share > 0.3 then
        share = math.max(share, tier >= top - 1 and 1 or 0.3)
    end
    if me.tick < factories.alarm_until then
        share = math.max(share, 0.7)
    end
    if short then
        share = 1
    end
    -- While the next lab is going up, the lower factories hold back more.
    if tier < top and tech.frame_alive() and not short then
        share = share * 0.5
    end
    if not util.chance(share) then
        return
    end
    local combat = pick_combat(entry)
    if combat ~= nil then
        unit:queue(combat.record, 1)
    end
end

-- Picks the scout lab: a finished tier-1 factory that makes scouts,
-- aircraft first.
local function choose_scout_lab()
    if world.tier < 3 then
        return
    end
    if tech.scout_lab ~= nil and util.alive(tech.scout_lab) then
        return
    end
    tech.scout_lab = nil
    local best, best_score
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        local entry = catalog.of(unit)
        local scout = pick_scout(entry)
        if scout ~= nil and tech.reclaiming[unit.id] == nil then
            local score = (scout.air and 100 or 50) - catalog.factory_tier(entry) * 10
            if best_score == nil or score > best_score then
                best, best_score = unit, score
            end
        end
    end
    if best ~= nil then
        tech.scout_lab = best
        print("scout lab: " .. catalog.of(best).name)
    end
end

function factories.step()
    choose_scout_lab()
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        one_factory(unit)
    end
end

function factories.on_idle(unit)
    if world.finished(unit) then
        one_factory(unit)
    end
end

function factories.raise_alarm(seconds)
    factories.alarm_until = math.max(factories.alarm_until, me.tick + 30 * seconds)
end

return factories
