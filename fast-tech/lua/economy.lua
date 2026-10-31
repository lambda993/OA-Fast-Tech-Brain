-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- The income each tier aims for, what is short now, and which economy
-- building a builder should put down. Targets are per second at the
-- seat's own rate, so a richer level reaches them sooner.

local catalog = require("catalog")
local util = require("util")
local world = require("world")

local economy = {}

local num = util.num

-- Income the seat wants before it reaches for the next tier. The next lab
-- starts sooner than this; these keep the economy growing beside it.
local metal_goal = {[0] = 6, 12, 35, 110, 220, 320}
local energy_goal = {[0] = 120, 300, 1400, 5500, 11000, 16000}

function economy.read()
    local e = {
        metal = num(me.metal),
        energy = num(me.energy),
        metal_cap = math.max(1, num(me.metal_storage)),
        energy_cap = math.max(1, num(me.energy_storage)),
        metal_income = num(me.metal_produced),
        energy_income = num(me.energy_produced),
        metal_demand = num(me.metal_requested),
        energy_demand = num(me.energy_requested),
    }
    e.metal_share = e.metal / e.metal_cap
    e.energy_share = e.energy / e.energy_cap
    economy.now = e
    return e
end

function economy.goals(tier)
    tier = math.max(0, math.min(5, tier))
    return metal_goal[tier], energy_goal[tier]
end

-- Energy income wanted for each unit of metal income, by tier. Escalation's
-- early buildings and units cost about ten energy per metal, extractors
-- and makers burn more, and the tier-3 and tier-4 units far more (a match
-- spent about 36 energy a metal at tier 3). A higher ratio at tier 2 took
-- builders off extractors and slowed the climb.
local energy_per_metal = {[0] = 15, 15, 15, 25, 30, 30}

-- "energy", "metal" or nil: what the seat should build more of, and 2
-- when it is running dry. Building drains the small energy store nearly
-- all the time, so the store alone does not decide; the balance of the
-- two incomes does.
function economy.need()
    local e = economy.now or economy.read()
    local metal_target, energy_target = economy.goals(world.tier)
    local energy_free = e.energy_income - economy.maker_upkeep()
    if e.energy_share < 0.05 and energy_free < e.energy_demand * 0.5 then
        return "energy", 2
    end
    -- Metal piling up while energy runs dry: energy is what holds things
    -- back, and metal to build power is at hand, so it comes first.
    if e.metal_share > 0.7 and e.energy_share < 0.3 and e.energy_income < e.energy_demand then
        return "energy", 2
    end
    local ratio = energy_per_metal[math.max(0, math.min(5, world.tier))]
    if energy_free < e.metal_income * ratio * 0.8 then
        return "energy", 1
    end
    if e.metal_share < 0.3 or e.metal_income < metal_target then
        return "metal", e.metal_share < 0.05 and 2 or 1
    end
    if e.energy_income < energy_target then
        return "energy", 1
    end
    return nil, 0
end

-- Whether `entry` fits the ground asked for: land buildings when `wet` is
-- nil or false, water-only ones (floating, underwater, tidal) when true.
local function on(entry, wet)
    return (entry.water_only == true) == (wet == true)
end

-- The power building with the best output for its cost that the seat can
-- pay for within about two minutes of income, on land or (`wet`) on the
-- water. Returns it and its value.
local function best_power(builder, wet)
    local e = economy.now
    local budget = math.max(400, e.metal_income * 120 + e.metal * 0.8)
    local options = catalog.buildable(builder, function(entry)
        return entry.power and not entry.geo and on(entry, wet) and entry.metal <= budget
            and entry.energy <= math.max(3000, e.energy_income * 150 + e.energy)
    end, wet)
    local best, best_value
    for _, entry in ipairs(options) do
        -- Output per cost, times the square root of the output: builders'
        -- time is short too, so one large plant beats many small ones.
        local value = entry.energy_yield / math.max(1, entry.cost) * math.sqrt(math.max(0, entry.energy_yield))
        if best_value == nil or value > best_value then
            best, best_value = entry, value
        end
    end
    return best, best_value or 0
end

-- The best extractor for land deposits, or (`wet`) for deposits under
-- the sea.
local function best_extractor(builder, wet)
    local options = catalog.buildable(builder, function(entry) return entry.extractor and on(entry, wet) end, wet)
    local best
    for _, entry in ipairs(options) do
        if best == nil or entry.extracts > best.extracts then
            best = entry
        end
    end
    return best
end

-- Whether the ground itself is worth extractors: metal maps (Core Prime,
-- Coremageddon: surface metal 255, no deposits). Maps with a little
-- surface metal and deposits (20 on Pincushion or Lava Mania) are not:
-- their deposits are many times richer.
function economy.metal_map()
    local surface = util.num(game.map.surface_metal)
    if surface >= 100 then
        return true
    end
    economy.free_spots(0)
    return surface >= 20 and #economy.spots < 4
end

-- The best metal maker the builder can pay for, fed or not, on land or
-- (`wet`) floating.
local function maker_type(builder, wet)
    local e = economy.now
    local options = catalog.buildable(builder, function(entry)
        return entry.metal_maker and on(entry, wet) and entry.metal <= math.max(300, e.metal_income * 120 + e.metal)
    end, wet)
    local best
    for _, entry in ipairs(options) do
        if best == nil or entry.metal_yield > best.metal_yield then
            best = entry
        end
    end
    return best
end

-- A metal maker the energy on hand can feed: the stores well filled and
-- the upkeep within most of what the income leaves over.
local function best_maker(builder, wet)
    local e = economy.now
    local maker = maker_type(builder, wet)
    if maker == nil or e.energy_share < 0.5 then
        return nil
    end
    local upkeep = -maker.energy_yield
    local spare = e.energy_income - economy.maker_upkeep()
    if upkeep > spare * 0.7 then
        return nil
    end
    return maker
end

-- Energy the seat's finished metal makers burn each second.
function economy.maker_upkeep()
    local total = 0
    for _, unit in ipairs(world.select(function(u, entry) return entry.metal_maker and world.finished(u) end)) do
        total = total - catalog.of(unit).energy_yield
    end
    return total
end

economy.maker_type = maker_type

-- Metal makers burn energy for metal. With the metal store nearly full
-- that energy is wasted, and with the energy store empty it starves the
-- builds: switch them off then, and back on when metal runs low.
function economy.toggle_makers()
    local e = economy.now or economy.read()
    local on = nil
    if e.metal_share > 0.85 or e.energy_share < 0.05 then
        on = false
    elseif e.metal_share < 0.5 and e.energy_share > 0.25 then
        on = true
    end
    if on == nil then
        return
    end
    for _, unit in ipairs(world.select(function(u, entry) return entry.metal_maker and world.finished(u) end)) do
        unit:on(on)
    end
end

economy.best_power = best_power

function economy.best_geo(builder)
    local options = catalog.buildable(builder, function(entry) return entry.geo end)
    local best
    for _, entry in ipairs(options) do
        if best == nil or entry.energy_yield > best.energy_yield then
            best = entry
        end
    end
    return best
end

-- Geothermal vents nobody of the seat covers yet, nearest the base first.
function economy.free_geo(reach)
    if economy.geo == nil then
        economy.geo = {}
        local list = game.map:geo_spots()
        if type(list) == "table" then
            for _, spot in ipairs(list) do
                economy.geo[#economy.geo + 1] = {x = util.whole(spot.cx) * 16 + 8, z = util.whole(spot.cz) * 16 + 8}
            end
        end
    end
    local base = world.base or world.start
    local plants = world.select(function(_, entry) return entry.geo end)
    local found = {}
    for _, spot in ipairs(economy.geo) do
        local d = util.dist(spot, base)
        local free = d <= reach
        for _, plant in ipairs(plants) do
            local at = util.pos(plant)
            if at ~= nil and util.dist2(at, spot) < 64 * 64 then
                free = false
            end
        end
        local claim = economy.claims[spot.x * 100000 + spot.z]
        if claim ~= nil and me.tick - claim < 30 * 60 then
            free = false
        end
        if free then
            found[#found + 1] = {x = spot.x, z = spot.z, d = d}
        end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    return found
end
economy.best_extractor = best_extractor
economy.best_maker = best_maker

-- Metal spots no extractor of the seat already covers, nearest the base
-- first, within `reach` world units. A spot claimed by the builder `by`
-- itself (it walked there to see it) stays free for it.
function economy.free_spots(reach, by)
    local spots = economy.spots
    if spots == nil then
        spots = {}
        local list = game.map:metal_spots()
        if type(list) == "table" then
            for _, spot in ipairs(list) do
                spots[#spots + 1] = {x = util.whole(spot.cx) * 16 + 8, z = util.whole(spot.cz) * 16 + 8}
            end
        end
        economy.spots = spots
    end
    local base = world.base or world.start
    local extractors = world.select(function(_, entry) return entry.extractor end)
    local taken = {}
    for _, unit in ipairs(extractors) do
        taken[#taken + 1] = util.pos(unit)
    end
    local found = {}
    for _, spot in ipairs(spots) do
        local d = util.dist(spot, base)
        if d <= reach then
            local free = true
            for _, at in ipairs(taken) do
                if at ~= nil and util.dist2(at, spot) < 48 * 48 then
                    free = false
                    break
                end
            end
            local claim = economy.claims[spot.x * 100000 + spot.z]
            local mine = by ~= nil and economy.claimed_by[spot.x * 100000 + spot.z] == by
            if claim ~= nil and me.tick - claim < 30 * 40 and not mine then
                free = false
            end
            for _, building in pairs(world.enemy_buildings) do
                if util.dist2(building, spot) < 64 * 64 then
                    free = false
                end
            end
            if free then
                found[#found + 1] = {x = spot.x, z = spot.z, d = d}
            end
        end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    return found
end

economy.claims = {}
economy.claimed_by = {}

-- Holds a spot back from other builders; `seconds` beyond the usual 40
-- keep it out longer, for spots a builder could not reach. `by` is the
-- builder that walks there.
function economy.claim(spot, seconds, by)
    local key = spot.x * 100000 + spot.z
    economy.claims[key] = me.tick + 30 * (seconds or 0)
    economy.claimed_by[key] = by
end

return economy
