-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What each idle factory makes. The top tier builds freely; each tier
-- below builds less, and tier 1 the least. Within a list the higher
-- tiers weigh far more, tier 2 well above tier 1. Builders come first
-- while the race needs them, and the scout lab only makes scouts.

local catalog = require("catalog")
local economy = require("economy")
local tech = require("tech")
local terrain = require("terrain")
local util = require("util")
local world = require("world")

local factories = {
    alarm_until = 0,
}

-- How strongly a combat unit of each tier is preferred.
local tier_weight = {[0] = 0, 1, 8, 14, 22, 34}

-- Builders the seat keeps for each factory tier.
local builders_wanted = {[0] = 0, 7, 6, 5, 4, 4}

local scout_cap = 12
local decoys_wanted = 15

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

-- Finished factories of the seat's top tier that make combat units.
local function top_factories()
    local count = 0
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        local entry = catalog.of(unit)
        if catalog.factory_tier(entry) >= world.tier then
            for _, built in ipairs(entry.builds) do
                if built.combat then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count
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
    -- Factories below the top tier stop making combat units once the
    -- production has moved up (the user's rule): two working combat
    -- factories of the top tier. Before that they go on, or a seat that
    -- reached tier 2 with a single lab (busy with its unit upgrade and
    -- the race) made almost no army for 25 minutes (user's game).
    if top_factories() >= 2 then
        return 0
    end
    return behind == 1 and 0.6 or 0.3
end

local function level_share()
    if me.level == "fair" then
        return 0.85
    end
    return 1
end

local function count_builders(tier)
    return #world.select(function(_, e)
        return e.mobile_builder and not e.commander and not e.decoy and math.max(1, e.tier) == tier
    end)
end

local function scouts()
    return world.select(function(_, e) return e.scout end)
end

local function scouts_wanted()
    local tier = world.tier
    if tier <= 0 then
        return 1
    end
    return ({3, 6, 10, 10, 10})[math.min(5, tier)]
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
    -- Torpedo-only units (torpedo bombers too) are no use unless ships
    -- reach the enemy: water by the base alone is not enough.
    local wet = terrain.ship_reaches == true
    -- Nor are units that cannot reach the enemy on this map.
    local options = catalog.buildable(entry, function(e)
        return e.combat and (wet or not e.torpedo_only) and terrain.useful(e)
    end, true)
    -- Only what this factory's share of the income (shared among the
    -- factories at work) pays for in about two minutes; with nothing that
    -- cheap, the cheapest units it offers.
    local working = #world.select(function(u, e) return e.factory and world.finished(u) and not util.free(u) end)
    local share = 1 / math.max(1, working)
    local fitting = {}
    for _, option in ipairs(options) do
        if economy.affords(option, 120, share) then
            fitting[#fitting + 1] = option
        end
    end
    if #fitting == 0 and #options > 0 then
        local cheapest = nil
        for _, option in ipairs(options) do
            if cheapest == nil or option.cost < cheapest then
                cheapest = option.cost
            end
        end
        for _, option in ipairs(options) do
            if option.cost <= cheapest * 1.5 then
                fitting[#fitting + 1] = option
            end
        end
    end
    options = fitting
    -- Every group that leaves takes anti-air along: at least three mobile
    -- anti-air units, one more for every ten other ground units.
    local ground, anti_air = 0, 0
    for _, unit in ipairs(world.select(function(u, e) return e.combat and not e.air end)) do
        if catalog.of(unit).mobile_anti_air then
            anti_air = anti_air + 1
        else
            ground = ground + 1
        end
    end
    if anti_air < 3 + ground // 10 then
        local guns = {}
        for _, option in ipairs(options) do
            if option.mobile_anti_air then
                guns[#guns + 1] = option
            end
        end
        if #guns > 0 then
            options = guns
        end
    end
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
        if built.mobile_builder and not built.decoy then
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
    -- Metal piling up while energy is fine: the seat is short of build
    -- power (no room for more factories), so up to twice as many builders,
    -- who then help the factories.
    local wanted = builders_wanted[math.min(5, tier)] or 2
    local e = economy.now or economy.read()
    if e.metal_share > 0.8 and e.energy_share > 0.5 then
        wanted = wanted * 2
    end
    if count_builders(tier) >= wanted then
        return nil
    end
    return best
end

-- Escalation's unit upgrades: a factory that can build one (Level 2 in
-- the advanced labs, Level 3 in the tier-3 ones) builds it before
-- anything else, once: a second would only hold up production. Not in a
-- factory that is being wound down, and only when the stores can pay.
factories.unit_upgraded = {} -- factory id -> tick the upgrade was queued

local function unit_upgrade(unit, entry, tier)
    if factories.unit_upgraded[unit.id] ~= nil or #entry.unit_upgrades == 0 or tier < world.tier - 1 then
        return false
    end
    local e = economy.now or economy.read()
    for _, upgrade in ipairs(entry.unit_upgrades) do
        if e.metal_share > 0.3 and upgrade.metal <= e.metal_income * 120 + e.metal
            and unit:queue(upgrade.record, 1) then
            factories.unit_upgraded[unit.id] = me.tick
            print("unit upgrade " .. entry.name .. ": " .. upgrade.name)
            return true
        end
    end
    return false
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
    if unit_upgrade(unit, entry, tier) then
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
    -- Decoy commanders, a few at a time from tier 2 on, until fifteen
    -- stand: they draw fire meant for the commander and build like it.
    if top >= 2 and util.chance(0.25) and #world.select(function(_, e) return e.decoy end) < decoys_wanted then
        local e = economy.now or economy.read()
        for _, built in ipairs(entry.builds) do
            if built.decoy and e.metal_share > 0.3 then
                unit:queue(built.record, 1)
                return
            end
        end
    end
    -- Scouts from any factory that makes them, up to the tier's number
    -- (the user wants many, watching the enemy starts): 3 at tier 1, 6 at
    -- tier 2, 10 from tier 3. Lower-tier factories make them too.
    if #scouts() < scouts_wanted() then
        local scout = pick_scout(entry)
        if scout ~= nil and util.chance(0.5) then
            unit:queue(scout.record, 1)
            return
        end
    end
    -- Carriers once the seat flies many aircraft: a mobile repair base for
    -- every sixteen, counted with the pads.
    local fleet = #world.select(function(_, e) return e.air and e.combat and not e.scout end)
    if fleet >= 12 and util.chance(0.2) then
        local bases = #world.select(function(_, e) return e.air_base end)
        if bases < 1 + fleet // 16 then
            for _, built in ipairs(entry.builds) do
                if built.air_base and built.mobile and terrain.useful(built) then
                    unit:queue(built.record, 1)
                    print("carrier: " .. built.name)
                    return
                end
            end
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

-- Buildings that upgrade themselves (Escalation's reactor and geothermal
-- armour) take the upgrade once the stores can spare it, one at a time.
factories.upgraded = {} -- building id -> tick the upgrade was queued

local function upgrade_buildings()
    -- Upgrades waited for both stores to be 40 % full, which a seat
    -- spending all it makes seldom is: a geothermal plant went half an
    -- hour without its armour (user's game). Now an upgrade the income
    -- pays for in about two minutes goes in whenever energy is not dry.
    local e = economy.now or economy.read()
    if e.energy_share < 0.15 then
        return
    end
    for id, tick in pairs(factories.upgraded) do
        if world.own[id] == nil or me.tick - tick > 30 * 600 then
            factories.upgraded[id] = nil
        end
    end
    for _, unit in ipairs(world.select(function(u, e2)
        return (e2.power or e2.geo) and e2.builder and world.finished(u)
    end)) do
        if factories.upgraded[unit.id] == nil and util.free(unit) then
            for _, built in ipairs(catalog.of(unit).builds) do
                if built.upgrade and economy.affords(built, 120, 0.5) then
                    if unit:queue(built.record, 1) then
                        factories.upgraded[unit.id] = me.tick
                        print("upgrade " .. catalog.of(unit).name .. ": " .. built.name)
                        return
                    end
                end
            end
        end
    end
end

-- Some of Escalation's factories carry a special weapon (weapon3) that
-- does no damage and only turns the way their units come out; left at
-- fire at will they turned it on enemies. Each armed factory is set to
-- hold fire once.
factories.held = {} -- factory id -> true

local function hold_fire()
    for id in pairs(factories.held) do
        if world.own[id] == nil then
            factories.held[id] = nil
        end
    end
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        if not factories.held[unit.id] then
            local record = catalog.of(unit).record
            local armed = false
            for slot = 1, 3 do
                local weapon = record["weapon" .. slot]
                if type(weapon) == "string" and weapon ~= "" then
                    armed = true
                end
            end
            if not armed or unit:stance({fire = "hold"}) ~= false then
                factories.held[unit.id] = true
            end
        end
    end
end

function factories.step()
    util.guard("hold fire", hold_fire)
    choose_scout_lab()
    util.guard("upgrades", upgrade_buildings)
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
