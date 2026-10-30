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
local util = require("util")
local world = require("world")

local hooks = {}
local armed = false
local refreshed = false

local function status()
    local e = require("economy").read()
    local counts = {builders = 0, factories = 0, combat = 0, scouts = 0, extractors = 0, power = 0, radar = 0, defense = 0}
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
    end
    print(string.format(
        "status tier %d goal %s frame %s | metal %.0f/%.0f +%.1f -%.1f | energy %.0f/%.0f +%.0f -%.0f | bld %d fac %d army %d scout %d mex %d (%d/%d/%d) pow %d radar %d def %d | foes known %d",
        world.tier, tech.goal and tech.goal.name or "-", tech.frame_alive() and "up" or "-",
        e.metal, e.metal_cap, e.metal_income, e.metal_demand, e.energy, e.energy_cap, e.energy_income, e.energy_demand,
        counts.builders, counts.factories, counts.combat, counts.scouts, counts.extractors,
        by_tier[1], by_tier[2], by_tier[3], counts.power,
        counts.radar, counts.defense, util.count(world.enemy_buildings)))
end

local function think()
    if not refreshed then
        catalog.refresh_builds()
        tech.reset()
        refreshed = true
    end
    util.guard("world", function()
        world.update_tier()
        world.update_base()
        tech.choose_goal()
    end)
    local second = me.tick // 30
    util.guard("builders", builders.step)
    if second % 2 == 0 then
        util.guard("factories", factories.step)
        util.guard("makers", require("economy").toggle_makers)
    end
    if second % 3 == 0 then
        util.guard("army", army.step)
    end
    if second % 60 == 0 then
        util.guard("status", status)
    end
    if second % 5 == 0 then
        util.guard("scouts", scouts.step)
        util.guard("prune", world.prune)
    end
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

function hooks.onUnitDamaged(unit, attacker, _, kind)
    if kind ~= "weapon" then
        return
    end
    local entry = catalog.of(unit)
    if entry == nil then
        return
    end
    util.guard("damaged", function()
        builders.on_damaged(unit, entry)
        army.on_damaged(unit, attacker)
    end)
end

function hooks.onUnitDestroyed(unit)
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
