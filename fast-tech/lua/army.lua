-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- The army gathers in front of the base. A wave leaves once its worth
-- passes the tier's mark, and goes for the nearest remembered enemy
-- building, a recent contact, or a start nobody has looked at. Units at
-- home turn on whoever hits the base. Fire goes to commanders first, then
-- the heaviest units, then the economy. Long-range guns are aimed at
-- remembered buildings they cannot see.

local builders = require("builders")
local catalog = require("catalog")
local factories = require("factories")
local util = require("util")
local world = require("world")

local army = {
    attacking = {}, -- unit id -> true
    target = nil,
    sent_at = 0,
}

-- Metal worth a wave needs before it leaves, by the seat's tier.
-- Tier-1 units mostly stay home: the bot spends on tech, not on trades.
local wave_worth = {[0] = 4000, 4000, 9000, 30000, 80000, 150000}

local function soldiers()
    return world.select(function(u, e) return e.combat and world.finished(u) end)
end

local function worth(list)
    local total = 0
    for _, unit in ipairs(list) do
        total = total + catalog.of(unit).cost
    end
    return total
end

-- The enemy to shoot: commanders first, then the heaviest, then the
-- economy (world.best_target).
local function nearest_enemy(from, reach)
    return world.best_target(from, reach)
end

local function rally_point()
    return world.front(380)
end

local function defend(home)
    local alarm = world.alarm
    if alarm == nil or me.tick - alarm.tick > 30 * 20 then
        return false
    end
    local target = nearest_enemy(alarm, 700)
    for _, unit in ipairs(home) do
        if target ~= nil then
            unit:attack(target)
        else
            unit:patrol(util.clamp(alarm, 64))
        end
    end
    return true
end

local function send_wave(home)
    local base = world.base or world.start
    local target = world.enemy_target(base)
    if target == nil then
        return false
    end
    army.target = target
    army.sent_at = me.tick
    for _, unit in ipairs(home) do
        unit:patrol(util.clamp(target, 64))
        army.attacking[unit.id] = true
    end
    print(string.format("wave of %d units (worth %.0f) to %.0f,%.0f", #home, worth(home), target.x, target.z))
    return true
end

-- Keeps the attackers moving: they fight what they see, and move on to the
-- next target once the current one is cleared.
local function push(attackers)
    if #attackers == 0 then
        army.target = nil
        return
    end
    local lead = util.pos(attackers[1])
    if lead == nil then
        return
    end
    local target = army.target
    if target == nil or (me:sees(target.x, target.z) and nearest_enemy(target, 500) == nil) then
        target = world.enemy_target(lead)
        army.target = target
    end
    for _, unit in ipairs(attackers) do
        local at = util.pos(unit)
        local enemy = at and nearest_enemy(at, 800)
        local contact = enemy == nil and at and world.nearest_contact(at, 1200)
        if enemy ~= nil then
            unit:attack(enemy)
        elseif contact then
            -- Seen only on radar or sonar: close in, fighting on the way.
            unit:patrol(util.clamp(contact, 64))
        elseif target ~= nil and util.free(unit) then
            unit:patrol(util.clamp(target, 64))
        end
    end
end

-- Heavy units (tier 3 and up) below 30 % health go home to be repaired,
-- and rejoin once mended.
army.mending = {} -- unit id -> true

local function send_to_mend(unit)
    local entry = catalog.of(unit)
    if entry == nil or not entry.combat or entry.tier < 3 or army.mending[unit.id] then
        return
    end
    if util.num(unit.health_percent) >= 30 then
        return
    end
    local home = world.base or world.start
    if home == nil then
        return
    end
    army.mending[unit.id] = true
    army.attacking[unit.id] = nil
    unit:move(util.clamp(util.around(home, brain.random(1000) / 1000, 250), 64))
    builders.mend_unit(unit)
end

-- Long-range guns rarely see their targets, so they are told what to hit:
-- a visible enemy in range, best first, else a remembered building in
-- range, factories and the heaviest first. Each gun gets a new order every
-- twenty seconds.
army.gun_orders = {} -- gun id -> tick

local function aim_guns()
    for _, gun in ipairs(world.select(function(u, e) return e.artillery and world.finished(u) end)) do
        local last = army.gun_orders[gun.id]
        if last == nil or me.tick - last >= 30 * 20 then
            local entry = catalog.of(gun)
            local at = util.pos(gun)
            if at ~= nil then
                local reach = entry.range * 0.95
                local target = world.best_target(at, reach)
                if target ~= nil and util.dist(at, util.pos(target)) <= reach then
                    gun:attack(target)
                    army.gun_orders[gun.id] = me.tick
                    print(string.format("%s fires at %s", entry.name, catalog.of(target).name))
                else
                    local best, best_key
                    for _, building in pairs(world.enemy_buildings) do
                        local d = util.dist(at, building)
                        if d <= reach then
                            local key = (building.factory and 6 or building.tier) * 100000 + building.cost - d
                            if best_key == nil or key > best_key then
                                best, best_key = building, key
                            end
                        end
                    end
                    -- Nothing remembered in range: a radar or sonar contact.
                    if best == nil then
                        best = world.nearest_contact(at, reach)
                    end
                    if best ~= nil then
                        gun:attack_ground({x = best.x, z = best.z})
                        army.gun_orders[gun.id] = me.tick
                        print(string.format("%s shells %.0f,%.0f", entry.name, best.x, best.z))
                    end
                end
            end
        end
    end
end

function army.step()
    util.guard("guns", aim_guns)
    local home, attackers = {}, {}
    for id in pairs(army.mending) do
        local unit = world.own[id]
        if unit == nil or util.num(unit.health_percent) >= 95 then
            army.mending[id] = nil
        end
    end
    for _, unit in ipairs(soldiers()) do
        if army.mending[unit.id] then
            -- Waiting at home for the builders.
        elseif army.attacking[unit.id] then
            attackers[#attackers + 1] = unit
        else
            home[#home + 1] = unit
        end
    end
    for id in pairs(army.attacking) do
        if world.own[id] == nil then
            army.attacking[id] = nil
        end
    end
    push(attackers)
    if defend(home) then
        return
    end
    local mark = wave_worth[math.min(5, world.tier)]
    -- Hard levels wait less; a single experimental may go with an escort.
    if me.difficulty ~= "hard" then
        mark = mark * 0.8
    end
    if worth(home) >= mark and #home >= 3 then
        if send_wave(home) then
            return
        end
    end
    local rally = rally_point()
    -- Enemies coming near the rally point are met there, commanders first.
    local near = world.best_target(rally, 700)
    if near ~= nil then
        for _, unit in ipairs(home) do
            unit:attack(near)
        end
        return
    end
    local contact = world.nearest_contact(rally, 900)
    if contact ~= nil then
        for _, unit in ipairs(home) do
            unit:patrol(util.clamp(contact, 64))
        end
        return
    end
    for _, unit in ipairs(home) do
        local at = util.pos(unit)
        if at ~= nil and util.free(unit) and util.dist(at, rally) > 250 then
            unit:move(util.clamp(util.around(rally, brain.random(1000) / 1000, 120), 64))
        end
    end
end

-- Something of the seat was hit: remember where, and let the factories
-- answer.
function army.on_damaged(unit, attacker)
    send_to_mend(unit)
    local at = util.pos(unit)
    if at == nil then
        return
    end
    local entry = catalog.of(unit)
    local base = world.base or world.start
    if entry ~= nil and (entry.structure or (base ~= nil and util.dist(at, base) < 1200)) then
        world.alarm = {x = at.x, z = at.z, tick = me.tick}
        factories.raise_alarm(60)
    end
    if attacker ~= nil and util.alive(attacker) then
        world.remember(attacker)
    end
end

return army
