-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What each free builder does next. Half the builders lean on the tech
-- race, half on the economy; both fall back on the other. The commander
-- keeps to the base: it builds there, and with nothing to do it walks back
-- to the middle of the base.

local catalog = require("catalog")
local economy = require("economy")
local tech = require("tech")
local util = require("util")
local world = require("world")

local builders = {
    upgrading = {}, -- extractor id -> tick a builder was sent to replace it
    walking = {},  -- builder id -> {tick, x, z} while it walks to unexplored ground
    role = {},     -- builder id -> "tech" or "economy"
    parked = {},   -- builder id -> tick it was sent to patrol or assist
    pending = {},  -- what was ordered recently, so two builders do not start the same thing
    retreat = {},  -- commander id -> tick it was sent home
}

local commander_reach = 1000
local radar_wanted = {[0] = 0, 1, 2, 3, 3, 3}
local defence_wanted = {[0] = 0, 1, 2, 3, 4, 4}

local function count_of(test)
    return #world.select(test)
end

local function recently(key, seconds)
    local tick = builders.pending[key]
    return tick ~= nil and me.tick - tick < 30 * seconds
end

local function mark(key)
    builders.pending[key] = me.tick
end

-- Ground the seat has never seen takes no building, so a builder sent
-- there walks over first and tries again once it is idle.
local function scout_site(unit, spot)
    if util.explored(spot) then
        return false
    end
    if unit:move(spot) then
        builders.walking[unit.id] = {tick = me.tick, x = spot.x, z = spot.z}
        return true
    end
    return false
end

-- Puts `entry` down near `near`, searching `radius` world units. When
-- `walk` is set and the ground is unexplored, the builder walks there.
local function place(unit, entry, near, radius, walk)
    local facing = brain.random(4) - 1
    local spot = util.clamp(near, 64)
    local _, _, x, z = brain.place(entry.record, spot, radius, facing)
    if x == nil then
        return walk == true and scout_site(unit, spot)
    end
    return unit:build(entry.record, {x = util.whole(x), z = util.whole(z)}, facing) == true
end

-- Tries a few points around `centre` at `distance`, widening each time.
-- Explored points come first; the builder walks out only when none fit.
local function place_around(unit, entry, centre, distance, radius)
    local offset = brain.random(1000) / 1000
    local unseen = nil
    for attempt = 0, 5 do
        local near = util.clamp(util.around(centre, offset + attempt * 0.17, distance + attempt * 100), 64)
        if util.explored(near) then
            if place(unit, entry, near, radius + attempt * 60) then
                return true
            end
        elseif unseen == nil then
            unseen = near
        end
    end
    if unseen ~= nil then
        return scout_site(unit, unseen)
    end
    return false
end

local function base()
    return world.base or world.start
end

-- Large labs need flat open ground, which the base's corner may lack:
-- try points further and further out in every direction, explored ones
-- only, before giving up.
local function place_large(unit, entry)
    local centre = base()
    local offset = brain.random(1000) / 1000
    local unseen = nil
    for ring = 0, 5 do
        local distance = ring == 0 and 120 or 120 + entry.footprint * 8 + (ring - 1) * 450
        for step = 0, 3 do
            local turn = offset + step * 0.25 + ring * 0.125
            local near = util.clamp(util.around(centre, turn, distance), 96)
            if util.explored(near) then
                if place(unit, entry, near, 320) then
                    return true
                end
            elseif unseen == nil then
                unseen = near
            end
        end
    end
    if unseen ~= nil then
        return scout_site(unit, unseen)
    end
    return false
end

-- Tasks ---------------------------------------------------------------------

local function try_reclaim(unit, entry)
    if entry.record.canreclamate ~= true or recently("reclaim", 20) then
        return false
    end
    local target = tech.reclaim_target()
    if target == nil then
        return false
    end
    target:stop()
    if unit:reclaim(target) then
        tech.reclaiming[target.id] = me.tick
        mark("reclaim")
        print("reclaim " .. catalog.of(target).name)
        return true
    end
    return false
end

local function try_goal(unit, entry)
    local goal = tech.goal
    if goal == nil or not catalog.can_build(entry, goal) then
        return false
    end
    if tech.frame_alive() then
        return unit:help(tech.frame) == true
    end
    if recently("goal", 45) or not tech.affordable() then
        return false
    end
    if place_large(unit, goal) then
        mark("goal")
        tech.started = me.tick
        tech.no_room = 0
        print("building " .. goal.name)
        return true
    end
    tech.no_room = tech.no_room + 1
    return false
end

local function try_extractor(unit, entry, reach)
    local extractor = economy.best_extractor(entry)
    if extractor == nil then
        return false
    end
    local spots = economy.free_spots(reach)
    local tried = 0
    for index = 1, #spots do
        if tried >= 3 then
            break
        end
        local spot = spots[index]
        tried = tried + 1
        local _, _, x, z = brain.place(extractor.record, spot, 40, 0)
        if x ~= nil and unit:build(extractor.record, {x = util.whole(x), z = util.whole(z)}, 0) then
            economy.claim(spot)
            return true
        end
        if x == nil and scout_site(unit, spot) then
            economy.claim(spot)
            return true
        end
        economy.claim(spot)
    end
    return false
end

-- Replaces a lower-tier extractor with the best one this builder can make:
-- reclaim the old one, then build the new one on the same spot. The
-- nearest to the base go first, one builder per extractor.
local function try_upgrade_extractor(unit, entry)
    local extractor = economy.best_extractor(entry)
    if extractor == nil then
        return false
    end
    local centre = base()
    local best, best_d
    for _, old in ipairs(world.select(function(u, e) return e.extractor and world.finished(u) end)) do
        local old_entry = catalog.of(old)
        local at = util.pos(old)
        local taken = builders.upgrading[old.id]
        if old_entry.extracts < extractor.extracts and at ~= nil
            and (taken == nil or me.tick - taken > 30 * 90) then
            local d = util.dist(at, centre)
            if best_d == nil or d < best_d then
                best, best_d = old, d
            end
        end
    end
    if best == nil then
        return false
    end
    local at = util.pos(best)
    if unit:reclaim(best) then
        unit:build(extractor.record, at, 0, true)
        builders.upgrading[best.id] = me.tick
        print(string.format("upgrade %s -> %s at %d,%d", catalog.of(best).name, extractor.name, at.x, at.z))
        return true
    end
    return false
end

local function try_geo(unit, entry, reach)
    local plant = economy.best_geo(entry)
    if plant == nil then
        return false
    end
    for _, spot in ipairs(economy.free_geo(reach)) do
        local _, _, x, z = brain.place(plant.record, spot, 48, 0)
        economy.claim(spot)
        if x ~= nil and unit:build(plant.record, {x = util.whole(x), z = util.whole(z)}, 0) then
            return true
        end
        if x == nil and scout_site(unit, spot) then
            return true
        end
    end
    return false
end

local function try_power(unit, entry, centre, spread)
    if try_geo(unit, entry, 1500 + world.tier * 800) then
        return true
    end
    local power = economy.best_power(entry)
    if power == nil then
        return false
    end
    return place_around(unit, power, centre, spread, 300)
end

local function try_maker(unit, entry, centre, spread)
    local maker = economy.best_maker(entry)
    if maker == nil then
        return false
    end
    return place_around(unit, maker, centre, spread, 300)
end

local function try_economy(unit, entry, near_base)
    local need, urgency = economy.need()
    -- Extractors are cheap and pay back fast: take free spots first unless
    -- energy is running out.
    local metal_goal = economy.goals(world.tier)
    if need ~= "energy" then
        if economy.now.metal_income < metal_goal * 2 then
            local reach = near_base and commander_reach or 1600 + world.tier * 800
            if try_extractor(unit, entry, math.min(reach, 1200)) then
                return true
            end
            if not near_base and try_upgrade_extractor(unit, entry) then
                return true
            end
            if try_extractor(unit, entry, reach) then
                return true
            end
        end
    end
    if need == nil then
        return false
    end
    local centre = base()
    local spread = near_base and 200 or 250 + world.tier * 60
    if need == "metal" then
        local reach = near_base and commander_reach or 1600 + world.tier * 800
        -- Near spots first, then better extractors on old spots, and only
        -- then the long walk to far spots.
        if try_extractor(unit, entry, math.min(reach, 1200)) then
            return true
        end
        if try_upgrade_extractor(unit, entry) then
            return true
        end
        if try_extractor(unit, entry, reach) then
            return true
        end
        if try_maker(unit, entry, centre, spread) then
            return true
        end
        -- No spot left and no energy for a maker: build the power the
        -- next maker will burn.
        if economy.maker_type(entry) ~= nil then
            return try_power(unit, entry, centre, spread)
        end
        return false
    end
    return try_power(unit, entry, centre, spread)
end

local function try_radar(unit, entry)
    local wanted = radar_wanted[math.min(5, world.tier)]
    local have = count_of(function(_, e) return e.radar_tower end)
    if have >= wanted or recently("radar", 30) then
        return false
    end
    local best
    for _, option in ipairs(catalog.buildable(entry, function(e) return e.radar_tower end)) do
        if best == nil or option.radar > best.radar then
            best = option
        end
    end
    if best == nil then
        return false
    end
    -- The first radar faces the enemy, later ones spread round the base.
    local near
    if have == 0 then
        near = world.front(450)
    else
        near = util.clamp(util.around(base(), brain.random(1000) / 1000, 550), 96)
    end
    if place(unit, best, near, 250, true) then
        mark("radar")
        return true
    end
    return false
end

local function try_defence(unit, entry)
    local wanted = defence_wanted[math.min(5, world.tier)]
    if wanted == 0 or recently("defence", 40) then
        return false
    end
    local have = count_of(function(_, e) return e.defense end)
    if have >= wanted then
        return false
    end
    local e = economy.now
    local budget = math.max(300, e.metal_income * 60 + e.metal * 0.3)
    local best
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.defense and not o.air end)) do
        if option.metal <= budget and (best == nil or option.tier > best.tier
            or (option.tier == best.tier and option.cost > best.cost)) then
            best = option
        end
    end
    if best == nil then
        return false
    end
    if place(unit, best, world.front(300), 220, true) then
        mark("defence")
        return true
    end
    return false
end

-- A second factory of the top tier once the economy can feed it.
local function try_more_factories(unit, entry)
    local tier = world.tier
    if tier < 1 or recently("factory", 60) then
        return false
    end
    local e = economy.now
    local metal_goal = economy.goals(tier)
    if e.metal_share < 0.5 or e.metal_income < metal_goal * 0.7 or e.energy_share < 0.5 then
        return false
    end
    -- While the next lab goes up, or could, every builder and every bit of
    -- room is better spent on it.
    if tech.frame_alive() or (tech.goal ~= nil and tech.affordable()) then
        return false
    end
    local top = world.select(function(u, f) return f.factory and catalog.factory_tier(f) == tier end)
    local limit = me.difficulty == "hard" and 2 or 3
    if #top >= limit or #top == 0 then
        return false
    end
    local kind = catalog.of(top[1])
    if not catalog.can_build(entry, kind) then
        return false
    end
    if place_large(unit, kind) then
        mark("factory")
        print("another " .. kind.name)
        return true
    end
    return false
end

-- Keeps one cheap factory for scouts once the seat has reached tier 3:
-- aircraft if the builder can make them, otherwise vehicles.
local function try_scout_lab(unit, entry)
    if world.tier < 3 or recently("scout-lab", 90) then
        return false
    end
    if tech.scout_lab ~= nil and util.alive(tech.scout_lab) then
        return false
    end
    local best, best_score
    for _, option in ipairs(catalog.buildable(entry, function(e) return e.factory end)) do
        local scout = false
        for _, built in ipairs(option.builds) do
            if built.scout then
                scout = true
            end
        end
        if scout then
            local score = (option.air and 100 or 50) - option.metal / 100
            if best_score == nil or score > best_score then
                best, best_score = option, score
            end
        end
    end
    if best == nil then
        return false
    end
    if place_around(unit, best, base(), 300, 300) then
        mark("scout-lab")
        print("building scout lab " .. best.name)
        return true
    end
    return false
end

-- Helps the top factory with what it is making.
local function try_assist(unit)
    local tier = world.tier
    local top = world.select(function(u, f)
        return f.factory and world.finished(u) and catalog.factory_tier(f) == tier and not util.free(u)
    end)
    if #top == 0 then
        return false
    end
    local factory = top[brain.random(#top)]
    if unit:guard(factory) then
        builders.parked[unit.id] = me.tick
        return true
    end
    return false
end

local function park(unit)
    local centre = base()
    local spot = util.clamp(util.around(centre, brain.random(1000) / 1000, 220), 96)
    if unit:patrol(spot) then
        builders.parked[unit.id] = me.tick
    end
end

-- Commander -------------------------------------------------------------------

local function send_home(unit)
    local centre = base()
    local at = util.pos(unit)
    if at == nil or centre == nil then
        return
    end
    if util.dist(at, centre) > 120 then
        unit:move(util.clamp(centre, 64))
        builders.retreat[unit.id] = me.tick
    end
end

builders.send_home = send_home

local function commander_turn(unit, entry)
    if world.tier == 0 then
        -- Opening: two extractors and some power, then the first lab.
        local extractors = count_of(function(_, e) return e.extractor end)
        local power = count_of(function(_, e) return e.power end)
        if extractors < 2 and try_extractor(unit, entry, commander_reach) then
            return true
        end
        if power < 2 and try_power(unit, entry, base(), 160) then
            return true
        end
        if try_goal(unit, entry) then
            return true
        end
    end
    if try_economy(unit, entry, true) then
        return true
    end
    if try_radar(unit, entry) then
        return true
    end
    if try_goal(unit, entry) then
        return true
    end
    if try_scout_lab(unit, entry) then
        return true
    end
    return false
end

-- Dispatch ------------------------------------------------------------------

local function builder_turn(unit, entry)
    if builders.role[unit.id] == nil then
        local tech_count = 0
        for _, role in pairs(builders.role) do
            if role == "tech" then
                tech_count = tech_count + 1
            end
        end
        local total = util.count(builders.role)
        builders.role[unit.id] = tech_count <= total - tech_count and "tech" or "economy"
    end
    local critical = select(2, economy.need()) >= 2
    local order
    if builders.role[unit.id] == "tech" and not critical then
        order = {"reclaim", "radar", "goal", "economy"}
    else
        order = {"reclaim", "radar", "economy", "goal"}
    end
    -- Under attack, or with too few defences, the economy builders fortify first.
    local attacked = world.alarm ~= nil and me.tick - world.alarm.tick < 30 * 60
    local defences = count_of(function(_, e) return e.defense end)
    if builders.role[unit.id] == "economy" and (attacked or defences * 2 < defence_wanted[math.min(5, world.tier)]) then
        table.insert(order, 2, "defence")
    end
    local tasks = {
        reclaim = try_reclaim,
        radar = try_radar,
        goal = try_goal,
        defence = try_defence,
        economy = function(u, e) return try_economy(u, e, false) end,
    }
    for _, name in ipairs(order) do
        if tasks[name](unit, entry) then
            return true
        end
    end
    local rest = {
        {"defence", try_defence}, {"upgrade", try_upgrade_extractor}, {"factory", try_more_factories},
        {"scout lab", try_scout_lab}, {"assist", function(u) return try_assist(u) end},
    }
    for _, task in ipairs(rest) do
        if task[2](unit, entry) then
            return true
        end
    end
    return false
end

-- Whether a builder should get a new order now. A walk that takes more
-- than 40 seconds is given up, and its spot set aside for a while.
local function ready(unit)
    local walk = builders.walking[unit.id]
    if walk ~= nil then
        local kind = unit:head_order()
        if kind ~= "Move_Ground" and kind ~= "Move" then
            builders.walking[unit.id] = nil
        elseif me.tick - walk.tick > 30 * 40 then
            builders.walking[unit.id] = nil
            economy.claim({x = walk.x, z = walk.z}, 300)
            unit:stop()
            return true
        else
            return false
        end
    end
    local parked = builders.parked[unit.id]
    if parked ~= nil then
        if me.tick - parked >= 30 * 15 then
            builders.parked[unit.id] = nil
            return true
        end
        return false
    end
    return util.free(unit)
end

function builders.step()
    economy.read()
    local list = world.select(function(u, e) return e.mobile_builder and world.finished(u) end)
    for _, unit in ipairs(list) do
        if ready(unit) then
            local entry = catalog.of(unit)
            if entry.commander then
                if not commander_turn(unit, entry) then
                    send_home(unit)
                end
            elseif not builder_turn(unit, entry) then
                park(unit)
            end
        end
    end
end

-- The commander walks home as soon as it is idle, and when badly hurt.
function builders.on_idle(unit, entry)
    if entry.commander then
        economy.read()
        if not commander_turn(unit, entry) then
            send_home(unit)
        end
    end
end

-- A builder that cannot find a path gives up its walk; the spot is set
-- aside for ten minutes.
function builders.on_path_failed(unit)
    local walk = builders.walking[unit.id]
    if walk ~= nil then
        builders.walking[unit.id] = nil
        economy.claim({x = walk.x, z = walk.z}, 600)
    end
end

function builders.on_damaged(unit, entry)
    if entry.commander and util.num(unit.health_percent) < 50 then
        local last = builders.retreat[unit.id]
        if last == nil or me.tick - last > 30 * 10 then
            send_home(unit)
        end
    end
end

return builders
