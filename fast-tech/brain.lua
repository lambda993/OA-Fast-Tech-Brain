-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- Fast Tech, a computer player for Escalation that races up the tiers.
-- Every second the seat reads its tier and its next goal; builders,
-- factories, the army and the scouts then take turns, each on its own
-- interval. Events steer idle units, damage and what the seat sees.

local army = require("army")
local builders = require("builders")
local catalog = require("catalog")
local factories = require("factories")
local scouts = require("scouts")
local tech = require("tech")
local terrain = require("terrain")
local util = require("util")
local world = require("world")

local hooks = {}
hooks.dump_city = true
local armed = false
local refreshed = false

local function status()
    local e = require("economy").read()
    local counts = {builders = 0, factories = 0, combat = 0, scouts = 0, extractors = 0, power = 0, radar = 0, defense = 0, water = 0}
    local by_tier = {0, 0, 0, 0, 0}
    for _, unit in ipairs(world.select(function() return true end)) do
        local entry = catalog.of(unit)
        if entry.mobile_builder then counts.builders = counts.builders + 1 end
        if entry.factory then counts.factories = counts.factories + 1 end
        if entry.combat then counts.combat = counts.combat + 1 end
        if entry.scout then counts.scouts = counts.scouts + 1 end
        if entry.extractor then
            counts.extractors = counts.extractors + 1
            local level = math.max(1, math.min(5, entry.tier))
            by_tier[level] = by_tier[level] + 1
        end
        if entry.power then counts.power = counts.power + 1 end
        if entry.radar_tower then counts.radar = counts.radar + 1 end
        if entry.defense then counts.defense = counts.defense + 1 end
        if entry.structure and entry.water_only then counts.water = counts.water + 1 end
    end
    local kinds = {}
    for _, unit in ipairs(world.select(function(_, e) return e.mobile_builder end)) do
        local name = catalog.of(unit).name
        kinds[#kinds + 1] = name
    end
    table.sort(kinds)
    print("builders: " .. table.concat(kinds, ", "))
    local shot = 0
    for _, unit in ipairs(world.select(function(_, e) return e.artillery end)) do
        shot = math.max(shot, catalog.of(unit).shot_energy)
    end
    print(string.format("artillery shot needs %.0f energy, store holds %.0f", shot, e.energy_cap))
    print(string.format("defence: decoys %d, anti-air %d, artillery %d, commander cloaked %s",
        #world.select(function(_, e) return e.decoy end),
        #world.select(function(_, e) return e.defense and e.anti_air end),
        #world.select(function(_, e) return e.artillery end),
        tostring(builders.cloaked == true)))
    print(string.format(
        "status tier %d goal %s (builders %d, affordable %s) frame %s | metal %.0f/%.0f +%.1f -%.1f | energy %.0f/%.0f +%.0f -%.0f | bld %d fac %d army %d scout %d mex %d (%d/%d/%d) pow %d radar %d def %d water %d | foes known %d",
        world.tier, tech.goal and tech.goal.name or "-", #tech.goal_builders(), tostring(tech.affordable()),
        tech.frame_alive() and "up" or "-",
        e.metal, e.metal_cap, e.metal_income, e.metal_demand, e.energy, e.energy_cap, e.energy_income, e.energy_demand,
        counts.builders, counts.factories, counts.combat, counts.scouts, counts.extractors,
        by_tier[1], by_tier[2], by_tier[3], counts.power,
        counts.radar, counts.defense, counts.water, util.count(world.enemy_buildings)))
end

local function think()
    -- The first turn only reads the build lists again: with everything
    -- else on top of it a first turn passed 250 ms and stopped the seat.
    if not refreshed then
        catalog.refresh_builds()
        tech.reset()
        refreshed = true
        return
    end
    util.guard("world", function()
        world.update_tier()
        world.update_base()
        tech.choose_goal()
    end)
    -- Nothing can be placed or sent before the seat knows where it stands.
    if not world.located() then
        return
    end
    local second = me.tick // 30
    util.guard("builders", builders.step)
    if second % 2 == 0 then
        util.guard("factories", factories.step)
        util.guard("makers", require("economy").toggle_makers)
        util.guard("boosters", require("economy").toggle_boosters)
    end
    if second % 3 == 0 then
        util.guard("army", army.step)
    end
    if second % 60 == 0 then
        util.guard("status", status)
    end
    if hooks.dump_city and second % 600 == 0 then
        util.guard("city dump", require("city").dump)
    end
    if second % 5 == 0 then
        util.guard("scouts", scouts.step)
        util.guard("prune", world.prune)
    end
end

-- The map survey asks one route at a time, every tenth of a second, so
-- its answer (which lines reach the enemy) comes before the first lab.
-- One route every six ticks, and never on the tick another seat asks
-- one: four seats asking on the same ticks every tenth of a second made
-- the start of a game on a large map stutter (Two Continents).
local function survey()
    if terrain.ready or not world.located() then
        return
    end
    if (me.tick // 3) % 2 ~= (me.player or 0) % 2 then
        return
    end
    util.guard("survey", terrain.survey)
end

function hooks.fits(game_now)
    local mod = game_now.mod
    if mod == nil or mod.id ~= "escalation" then
        return "Fast Tech plays Escalation only"
    end
    return true
end

function hooks.start()
    catalog.load()
    world.reset()
    refreshed = false
    if not armed then
        brain.every(30, think)
        brain.every(3, survey)
        armed = true
    end
    print(string.format("fast-tech %s on %s, side %s, level %s",
        "0.1", tostring(game.map.name), tostring(me.side_name), tostring(me.level)))
end

function hooks.onUnitCreated(unit)
    world.own[unit.id] = unit
    util.guard("created", tech.note_created, unit)
end

function hooks.onUnitFinished(unit)
    world.own[unit.id] = unit
    local entry = catalog.of(unit)
    -- Units take the stance of the factory that made them: armed
    -- factories hold fire (their weapon3 only turns the exit), and their
    -- ships stood under fire without answering (user's game). Every armed
    -- mobile unit but the careful ones fires at will.
    if entry ~= nil and entry.mobile and entry.armed and not entry.careful then
        util.guard("stance", function() unit:stance({fire = "at_will"}) end)
    end
    if entry ~= nil and entry.extractor then
        util.guard("extractor check", builders.check_extractor, unit, entry)
    end
end

function hooks.onUnitIdle(unit)
    world.own[unit.id] = unit
    local entry = catalog.of(unit)
    if entry == nil or unit.finished ~= true then
        return
    end
    if entry.factory then
        util.guard("factory idle", factories.on_idle, unit)
    elseif entry.scout then
        util.guard("scout idle", scouts.on_idle, unit)
    elseif entry.mobile_builder then
        util.guard("builder idle", builders.on_idle, unit, entry)
    end
end

-- A unit under fire is hit many times a second; once every ten ticks per
-- unit is enough for the alarm, the repairs and fleeing builders (in big
-- fights hundreds of hits a second each read positions and entries).
local last_hit = {}

function hooks.onUnitDamaged(unit, attacker, _, kind)
    if kind ~= "weapon" then
        return
    end
    local id = unit.id
    local last = last_hit[id]
    if last ~= nil and me.tick - last < 10 then
        return
    end
    last_hit[id] = me.tick
    local entry = catalog.of(unit)
    if entry == nil then
        return
    end
    util.guard("damaged", function()
        builders.on_damaged(unit, entry, attacker)
        army.on_damaged(unit, attacker)
    end)
end

function hooks.onUnitDestroyed(unit, _, wreck)
    last_hit[unit.id] = nil
    util.guard("wreck", world.note_wreck, catalog.of(unit), wreck)
    world.own[unit.id] = nil
    world.forget(unit)
end

function hooks.onUnitGiven(unit, _, _, to)
    if to == me.player then
        world.own[unit.id] = unit
    else
        world.own[unit.id] = nil
    end
end

function hooks.onPathFailed(unit)
    util.guard("path", builders.on_path_failed, unit)
end

function hooks.onUnitSeen(unit)
    util.guard("seen", world.remember, unit)
end

function hooks.onRadarContact(contact)
    if contact ~= nil and contact.x ~= nil then
        world.note_contact({x = util.whole(contact.x), z = util.whole(contact.z)})
    end
end

function hooks.report()
    local lines = {
        "Fast Tech 0.1",
        "tier: " .. tostring(world.tier),
        "goal: " .. (tech.goal and tech.goal.name or "none"),
        "known enemy buildings: " .. util.count(world.enemy_buildings),
    }
    return table.concat(lines, "\n") .. "\n"
end

return hooks
