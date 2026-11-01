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
    grounded = {},  -- aircraft id -> tick it pulled back from anti-air
    air_mending = {}, -- aircraft id -> tick it was sent to a repair pad
    rescue = nil,   -- {x, z, tick} an ally in trouble the army went to
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

-- The enemy `unit` should shoot: commanders first, then the heaviest,
-- anti-air, then the economy (world.best_target), among what its weapons
-- can hit: aircraft only for anti-air weapons.
local function nearest_enemy(from, reach, unit)
    return world.best_target(from, reach, unit and catalog.of(unit))
end

-- Each unit at `from` turns on the best target it can hit near `centre`;
-- returns whether any had one.
local function engage(units, centre, reach)
    local any = false
    for _, unit in ipairs(units) do
        local target = nearest_enemy(centre, reach, unit)
        if target ~= nil then
            unit:attack(target)
            any = true
        end
    end
    return any
end

local function rally_point()
    return world.front(380)
end

local function defend(home)
    local alarm = world.alarm
    if alarm == nil or me.tick - alarm.tick > 30 * 20 then
        return false
    end
    for _, unit in ipairs(home) do
        local target = nearest_enemy(alarm, 700, unit)
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
        local entry = catalog.of(unit)
        -- Bombers look further for anti-air to take out.
        local enemy = at and nearest_enemy(at, entry.bomber and 1400 or 800, unit)
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

-- Aircraft attacking a base pull back when the anti-air around them is
-- too strong for their number: they wait at home a minute and leave with
-- the next wave. Bombers stay (they go for the anti-air), and scouts are
-- not soldiers. Strength counts tiers: a tier-3 gun is worth three.
local function strength(entry)
    return math.max(1, entry.tier)
end

local function pull_back_aircraft(attackers)
    local enemies = world.visible_enemies()
    local keep = {}
    for _, unit in ipairs(attackers) do
        local entry = catalog.of(unit)
        local at = util.pos(unit)
        local retreat = false
        if entry.air and not entry.bomber and at ~= nil then
            local guns = 0
            for _, enemy in ipairs(enemies) do
                local kind = catalog.of(enemy)
                local where = util.pos(enemy)
                if world.anti_air(kind) and where ~= nil and util.dist(at, where) <= 1100 then
                    guns = guns + strength(kind)
                end
            end
            if guns > 0 then
                local own = 0
                for _, other in ipairs(attackers) do
                    local there = util.pos(other)
                    local kind = catalog.of(other)
                    if kind.air and there ~= nil and util.dist(at, there) <= 1100 then
                        own = own + strength(kind)
                    end
                end
                retreat = guns * 2 > own
            end
        end
        if retreat then
            army.attacking[unit.id] = nil
            army.grounded[unit.id] = me.tick
            unit:move(util.clamp(util.around(world.front(200), brain.random(1000) / 1000, 150), 64))
        else
            keep[#keep + 1] = unit
        end
    end
    if #keep < #attackers then
        print(string.format("aircraft pull back from anti-air: %d", #attackers - #keep))
    end
    return keep
end

-- Allies in grave danger: many armed enemies among an ally's units (the
-- `allies` and `threat` layers of a 32-cell grid, a cell and its
-- neighbours). The home army goes to help unless the seat's own base is
-- under heavy attack. At most one rescue every two minutes.
local rescue_threat = 8

local function heavy_attack_at_home()
    local base = world.base or world.start
    if base == nil or world.alarm == nil or me.tick - world.alarm.tick > 30 * 30 then
        return false
    end
    local armed = 0
    for _, enemy in ipairs(world.visible_enemies()) do
        local kind = catalog.of(enemy)
        local at = util.pos(enemy)
        if kind ~= nil and at ~= nil and (kind.combat or kind.commander) and util.dist(at, base) < 1500 then
            armed = armed + 1
        end
    end
    return armed >= 5
end

function army.ally_in_danger()
    local allies = me:allies()
    if type(allies) ~= "table" or #allies == 0 then
        return nil
    end
    local size = 32
    local grid = brain.grid({"allies", "threat"}, size)
    if grid == nil then
        return nil
    end
    local function at(layer, row, col)
        if row < 0 or col < 0 or row >= size or col >= size then
            return 0
        end
        return util.num(grid:get(layer * size * size + row * size + col + 1))
    end
    local width = util.whole(game.map.world_width)
    local height = util.whole(game.map.world_height)
    local base = world.base or world.start
    local best, best_threat
    for row = 0, size - 1 do
        for col = 0, size - 1 do
            if at(0, row, col) >= 1 then
                local threat = 0
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        threat = threat + at(1, row + dr, col + dc)
                    end
                end
                local point = {x = col * width // size + width // (2 * size), z = row * height // size + height // (2 * size)}
                -- Not the seat's own base: that is defended anyway.
                local own = base ~= nil and util.dist(point, base) < 900
                if threat >= rescue_threat and not own and (best_threat == nil or threat > best_threat) then
                    best, best_threat = point, threat
                end
            end
        end
    end
    return best, best_threat
end

local function rescue_ally(home)
    if #home < 3 or worth(home) < 1500 then
        return false
    end
    if army.rescue ~= nil and me.tick - army.rescue.tick < 30 * 120 then
        return false
    end
    if heavy_attack_at_home() then
        return false
    end
    local point, threat = army.ally_in_danger()
    if point == nil then
        return false
    end
    army.rescue = {x = point.x, z = point.z, tick = me.tick}
    army.target = point
    army.sent_at = me.tick
    for _, unit in ipairs(home) do
        unit:patrol(util.clamp(point, 64))
        army.attacking[unit.id] = true
    end
    print(string.format("ally in danger at %d,%d (%d armed enemies): %d units go to help", point.x, point.z, threat, #home))
    return true
end

-- Aircraft below half health fly to the nearest repair pad or carrier.
-- They are sent on a patrol to it: a patrolling aircraft under three
-- quarters health that reaches its waypoint lands on a pad within 3 840
-- units by itself (the engine's repair retreat), which attacks far from
-- home never trigger. Sent again after a minute and a half if still hurt.
local function send_aircraft_to_pads()
    local pads = world.select(function(u, e) return e.air_base and world.finished(u) end)
    for id, tick in pairs(army.air_mending) do
        local unit = world.own[id]
        if unit == nil or util.num(unit.health_percent) >= 95 or #pads == 0 then
            army.air_mending[id] = nil
        elseif me.tick - tick > 30 * 90 then
            army.air_mending[id] = nil
        end
    end
    if #pads == 0 then
        return
    end
    local sent = 0
    for _, unit in ipairs(world.select(function(u, e) return e.air and e.combat and not e.scout and world.finished(u) end)) do
        local at = util.pos(unit)
        if at ~= nil and army.air_mending[unit.id] == nil and util.num(unit.health_percent) < 50 then
            local best, best_d
            for _, pad in ipairs(pads) do
                local where = util.pos(pad)
                if where ~= nil then
                    local d = util.dist(at, where)
                    if best_d == nil or d < best_d then
                        best, best_d = where, d
                    end
                end
            end
            if best ~= nil then
                unit:patrol(util.clamp({x = best.x + 48, z = best.z + 48}, 64))
                army.air_mending[unit.id] = me.tick
                army.attacking[unit.id] = nil
                sent = sent + 1
            end
        end
    end
    if sent > 0 then
        print(string.format("aircraft to repair pads: %d", sent))
    end
end

-- Units worth 5 000 metal or more, of any tier (the same bar as for
-- buildings), go home below 30 % health to be repaired, and rejoin once
-- mended.
army.mending = {} -- unit id -> true
local mend_value = 5000

local function send_to_mend(unit)
    local entry = catalog.of(unit)
    if entry == nil or not entry.combat or entry.metal < mend_value or army.mending[unit.id] then
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

-- Whether the seat has aircraft that attack (scouts do not count): then
-- the guns take out the enemy's anti-air first.
local function has_strike_aircraft()
    return #world.select(function(_, e) return e.air and e.combat and e.hits_ground end) > 0
end

local function anti_air_in_reach(at, reach)
    local best, best_key
    for _, enemy in ipairs(world.visible_enemies()) do
        local kind = catalog.of(enemy)
        local where = util.pos(enemy)
        if world.anti_air(kind) and not kind.air and where ~= nil then
            local d = util.dist(at, where)
            if d <= reach and (best_key == nil or kind.tier * 100000 - d > best_key) then
                best, best_key = enemy, kind.tier * 100000 - d
            end
        end
    end
    if best ~= nil then
        return best, nil
    end
    for _, building in pairs(world.enemy_buildings) do
        if building.anti_air then
            local d = util.dist(at, building)
            if d <= reach and (best_key == nil or building.tier * 100000 - d > best_key) then
                best, best_key = building, building.tier * 100000 - d
            end
        end
    end
    return nil, best
end

local function aim_guns()
    local strike = has_strike_aircraft()
    for _, gun in ipairs(world.select(function(u, e) return e.artillery and world.finished(u) end)) do
        local last = army.gun_orders[gun.id]
        if last == nil or me.tick - last >= 30 * 20 then
            local entry = catalog.of(gun)
            local at = util.pos(gun)
            if at ~= nil then
                local reach = entry.range * 0.95
                local target = world.best_target(at, reach, entry)
                local remembered = nil
                if strike then
                    local guns, building = anti_air_in_reach(at, reach)
                    if guns ~= nil then
                        target = guns
                    elseif building ~= nil then
                        target, remembered = nil, building
                    end
                end
                if remembered ~= nil then
                    gun:attack_ground({x = remembered.x, z = remembered.z})
                    army.gun_orders[gun.id] = me.tick
                    print(string.format("%s shells anti-air at %.0f,%.0f", entry.name, remembered.x, remembered.z))
                elseif target ~= nil and util.dist(at, util.pos(target)) <= reach then
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
    util.guard("air repair", send_aircraft_to_pads)
    local home, attackers = {}, {}
    for id in pairs(army.mending) do
        local unit = world.own[id]
        if unit == nil or util.num(unit.health_percent) >= 95 then
            army.mending[id] = nil
        end
    end
    for _, unit in ipairs(soldiers()) do
        if army.mending[unit.id] or army.air_mending[unit.id] then
            -- Waiting at home for the builders, or on a repair pad.
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
    push(pull_back_aircraft(attackers))
    if defend(home) then
        return
    end
    -- Aircraft that pulled back from anti-air sit out the next minute.
    local ready = {}
    for _, unit in ipairs(home) do
        local grounded = army.grounded[unit.id]
        if grounded == nil or me.tick - grounded > 30 * 60 then
            army.grounded[unit.id] = nil
            ready[#ready + 1] = unit
        end
    end
    if rescue_ally(ready) then
        return
    end
    local mark = wave_worth[math.min(5, world.tier)]
    -- Hard levels wait less; a single experimental may go with an escort.
    if me.difficulty ~= "hard" then
        mark = mark * 0.8
    end
    if worth(ready) >= mark and #ready >= 3 then
        if send_wave(ready) then
            return
        end
    end
    local rally = rally_point()
    -- Enemies coming near the rally point are met there, commanders first,
    -- each unit taking what its weapons can hit.
    if engage(home, rally, 700) then
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
