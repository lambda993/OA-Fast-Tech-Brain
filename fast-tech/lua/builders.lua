-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What each free builder does next. Half the builders lean on the tech
-- race, half on the economy; both fall back on the other. The commander
-- keeps to the base: it builds there, helps what goes up there or the
-- factories, and only when far away walks back toward the middle.

local catalog = require("catalog")
local city = require("city")
local economy = require("economy")
local tech = require("tech")
local terrain = require("terrain")
local util = require("util")
local world = require("world")

local builders = {
    upgrading = {}, -- extractor id -> tick a builder was sent to replace it
    walking = {},  -- builder id -> {tick, x, z} while it walks to unexplored ground
    role = {},     -- builder id -> "tech" or "economy"
    parked = {},   -- builder id -> tick it was sent to patrol or assist
    wide_search = {},  -- factory index -> tick of the last search around the base
    wide_failed = {},  -- factory index -> searches in a row that found nothing
    pending = {},  -- what was ordered recently, so two builders do not start the same thing
    retreat = {},  -- commander id -> tick it was sent home
}

local commander_reach = 1000
-- Surface metal from which the bare ground is worth an extractor.
local metal_ground = 20
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
    -- The commander keeps to the base: it walks out only a little way.
    if unit.type ~= nil and unit.type.commander == true then
        local home = world.base or world.start
        if home == nil or util.dist(home, spot) > 900 then
            return false
        end
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

local function base()
    return world.base or world.start
end

-- A factory that fits nowhere near the base: every explored spot in rings
-- out to about 1 500 world units is searched (brain.place itself stops
-- near 500). Done at most once a minute per type, it costs about 30
-- placements. brain.place only takes explored ground: after a search that
-- found nothing the builder walks to the nearest unexplored ring point.
-- Returns true when ordered, and false plus true when three searches a
-- minute apart found nothing.
local wide_rings = {{0, 1}, {480, 8}, {960, 12}, {1440, 16}}

local function place_wide(unit, entry, centre)
    local last = builders.wide_search[entry.index]
    if last ~= nil and me.tick - last < 30 * 60 then
        return false, false
    end
    builders.wide_search[entry.index] = me.tick
    local unseen = nil
    for _, ring in ipairs(wide_rings) do
        local distance, count = ring[1], ring[2]
        for step = 0, count - 1 do
            local near = util.clamp(util.around(centre, step / count, distance), 96)
            if util.explored(near) then
                local _, _, x, z = brain.place(entry.record, near, 480, 0)
                if x ~= nil then
                    x, z = util.whole(x), util.whole(z)
                    if not city.on_street(entry, x, z) and unit:build(entry.record, {x = x, z = z}, 0) then
                        builders.wide_failed[entry.index] = nil
                        return true
                    end
                end
            elseif unseen == nil then
                unseen = near
            end
        end
    end
    local failed = (builders.wide_failed[entry.index] or 0) + 1
    builders.wide_failed[entry.index] = failed
    if failed >= 3 then
        return false, true
    end
    if unseen ~= nil and scout_site(unit, unseen) then
        return true
    end
    return false, false
end

-- Puts a building in the city grid; toward `toward` when given (the front).
-- Water-only buildings go by the open water nearest the base. With no room
-- on explored ground a builder other than the commander walks out to the
-- nearest unexplored block.
local function build_in_city(unit, entry, toward)
    if entry.water_only then
        local water = terrain.water_point
        if water == nil then
            return false
        end
        if place(unit, entry, water, 400, true) then
            return true
        end
        if entry.factory then
            return place_wide(unit, entry, water)
        end
        return false
    end
    if city.place(unit, entry, toward) then
        return true
    end
    local unseen = city.unexplored_block(toward or base())
    if unseen ~= nil and scout_site(unit, unseen) then
        return true
    end
    -- Ground too rough or cramped for the grid: anywhere near the base,
    -- but never on a street. A factory found nowhere returns false plus true.
    local centre = toward or base()
    for _, distance in ipairs({160, 320, 520, 800}) do
        local near = util.clamp(util.around(centre, brain.random(1000) / 1000, distance), 96)
        if util.explored(near) then
            local facing = brain.random(4) - 1
            local _, _, x, z = brain.place(entry.record, near, 320, facing)
            if x ~= nil and not city.on_street(entry, util.whole(x), util.whole(z))
                and unit:build(entry.record, {x = util.whole(x), z = util.whole(z)}, facing) then
                return true
            end
        end
    end
    if entry.factory then
        return place_wide(unit, entry, centre)
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
    local placed, nowhere = build_in_city(unit, goal)
    if placed then
        mark("goal")
        tech.started = me.tick
        tech.no_room = 0
        print("building " .. goal.name)
        return true
    end
    tech.no_room = tech.no_room + 1
    if nowhere then
        tech.no_site(goal)
    end
    return false
end

-- The site for an extractor at a deposit that covers the most metal: every
-- footprint position a few cells around the deposit is checked, and the
-- one with the most metal under it wins, the nearest on a tie. Returns the
-- footprint's centre in world units, or nil when no site is clear.
local function extractor_site(extractor, spot)
    local map = game.map
    local record = extractor.record
    local width = math.max(1, util.whole(record.footprintx))
    local depth = math.max(1, util.whole(record.footprintz))
    local spot_x = (spot.x - 8) // 16
    local spot_z = (spot.z - 8) // 16
    local best, best_metal, best_d
    for dz = -3, 3 do
        for dx = -3, 3 do
            local cx = spot_x - width // 2 + dx
            local cz = spot_z - depth // 2 + dz
            if brain.site(record, cx, cz, 0) == true then
                local metal = 0
                for z = 0, depth - 1 do
                    for x = 0, width - 1 do
                        metal = metal + util.num(map:metal(cx + x, cz + z))
                    end
                end
                local d = dx * dx + dz * dz
                if best == nil or metal > best_metal or (metal == best_metal and d < best_d) then
                    best, best_metal, best_d = {x = cx * 16 + width * 8, z = cz * 16 + depth * 8}, metal, d
                end
            end
        end
    end
    return best
end

local function try_extractor(unit, entry, reach)
    local extractor = economy.best_extractor(entry)
    if extractor == nil then
        return false
    end
    local spots = economy.free_spots(reach)
    -- On maps whose deposits lie far apart, builders other than the
    -- commander go further out rather than build none.
    if #spots == 0 and not entry.commander and reach >= 1600 then
        spots = economy.free_spots(4500)
    end
    -- On a metal map the ground itself holds metal and there are few or no
    -- deposits: extractors go in the city like any other building.
    if #spots == 0 and util.num(game.map.surface_metal) >= metal_ground then
        return build_in_city(unit, extractor)
    end
    local tried = 0
    for index = 1, #spots do
        if tried >= 3 then
            break
        end
        local spot = spots[index]
        tried = tried + 1
        local site = extractor_site(extractor, spot)
        if site ~= nil and unit:build(extractor.record, site, 0) then
            economy.claim(spot)
            return true
        end
        -- The commander keeps to the base and does not walk out to explore.
        if site == nil and not entry.commander and scout_site(unit, spot) then
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
    -- On a metal map any ground will do: build new extractors, keep the old.
    if util.num(game.map.surface_metal) >= metal_ground then
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
    return build_in_city(unit, power)
end

local function try_maker(unit, entry, centre, spread)
    local maker = economy.best_maker(entry)
    if maker == nil then
        return false
    end
    return build_in_city(unit, maker)
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

-- Radar, and sonar where there is water, as many of each as the tier
-- calls for.
local function try_radar(unit, entry)
    local wanted = radar_wanted[math.min(5, world.tier)]
    if recently("radar", 30) then
        return false
    end
    local best
    local have = count_of(function(_, e) return e.radar_tower end)
    if have < wanted then
        for _, option in ipairs(catalog.buildable(entry, function(e) return e.radar_tower end)) do
            if best == nil or option.radar > best.radar then
                best = option
            end
        end
    end
    if best == nil and terrain.water_share >= 0.05 then
        local sonars = count_of(function(_, e) return e.sonar_tower end)
        if sonars < wanted then
            for _, option in ipairs(catalog.buildable(entry, function(e) return e.sonar_tower end, true)) do
                if best == nil or util.num(option.record.sonardistance) > util.num(best.record.sonardistance) then
                    best = option
                end
            end
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
    if build_in_city(unit, best, near) then
        mark("radar")
        return true
    end
    return false
end

-- Jammers to hide the base from enemy radar and sonar: as many as the
-- seat has radar and sonar towers, near the middle of the base.
local function try_jammer(unit, entry)
    if recently("jammer", 40) then
        return false
    end
    local towers = count_of(function(_, e) return e.radar_tower or e.sonar_tower end)
    local have = count_of(function(_, e) return e.jammer end)
    if have >= towers then
        return false
    end
    local best, best_reach
    for _, option in ipairs(catalog.buildable(entry, function(e) return e.jammer end, terrain.water_share >= 0.05)) do
        local reach = util.num(option.record.radardistancejam) + util.num(option.record.sonardistancejam)
        if best_reach == nil or reach > best_reach then
            best, best_reach = option, reach
        end
    end
    if best == nil then
        return false
    end
    if build_in_city(unit, best, base()) then
        mark("jammer")
        print("jammer: " .. best.name)
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
    if build_in_city(unit, best, world.front(300)) then
        mark("defence")
        return true
    end
    return false
end

-- More factories once the economy can feed them. A factory line the seat
-- lacks comes first, so the army mixes kbots, vehicles, aircraft and
-- hovercraft; then more of what it has. The top tier first, else the one
-- below. Water-only factories are left out.
local function try_more_factories(unit, entry)
    local tier = world.tier
    if tier < 1 or recently("factory", 60) then
        return false
    end
    local e = economy.now
    local metal_goal = economy.goals(tier)
    if e.metal_share < 0.4 or e.metal_income < metal_goal * 0.6 or e.energy_share < 0.4 then
        return false
    end
    -- While the next lab goes up, every builder is better spent on it.
    if tech.frame_alive() then
        return false
    end
    local owned, count = {}, {}
    for _, factory in ipairs(world.select(function(_, f) return f.factory end)) do
        local kind = catalog.of(factory)
        owned[kind.index] = true
        local level = catalog.factory_tier(kind)
        count[level] = (count[level] or 0) + 1
    end
    local limit = me.difficulty == "hard" and 3 or 4
    local best, best_score
    for _, option in ipairs(catalog.buildable(entry, function(f) return f.factory end, terrain.ship_ok)) do
        local level = catalog.factory_tier(option)
        local rank = terrain.rank(option.line)
        if rank ~= nil and (level == tier or level == tier - 1) and (count[level] or 0) < limit
            and option ~= tech.goal then
            local fights = 0
            for _, built in ipairs(option.builds) do
                if built.combat then
                    fights = fights + 1
                end
            end
            if fights > 0 then
                local score = (level == tier and 1000 or 0) + (owned[option.index] and 0 or 500)
                    - rank * 300 + fights
                if best_score == nil or score > best_score then
                    best, best_score = option, score
                end
            end
        end
    end
    if best == nil then
        return false
    end
    if build_in_city(unit, best) then
        mark("factory")
        print("another factory: " .. best.name)
        return true
    end
    return false
end

-- The energy store the seat's long-range guns need: one shot of the
-- hungriest, built or going up, and a tenth more. A B.F.G. shot takes a
-- million, an Armageddon's or a Dictator's 120 000.
local function shot_store_needed()
    local needed = 0
    for _, unit in ipairs(world.select(function(_, e) return e.artillery end)) do
        needed = math.max(needed, catalog.of(unit).shot_energy)
    end
    return needed * 1.1
end

-- Energy storage until the guns can fire: before anything else but the
-- emergencies, at a quicker pace than ordinary storage.
local function try_shot_storage(unit, entry)
    local needed = shot_store_needed()
    if needed <= 0 or economy.now.energy_cap >= needed or recently("shot-storage", 12) then
        return false
    end
    local best, best_value
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.energy_storage end)) do
        local value = option.energy_capacity / math.max(1, option.cost)
        if best_value == nil or value > best_value then
            best, best_value = option, value
        end
    end
    if best == nil then
        return false
    end
    if build_in_city(unit, best) then
        mark("shot-storage")
        return true
    end
    return false
end

-- Storage once a store sits full while the income would fill it again
-- within a minute or so: the surplus is kept instead of wasted.
local function try_storage(unit, entry)
    if recently("storage", 45) then
        return false
    end
    local e = economy.now
    -- Enough room for two minutes of income is enough.
    local metal_full = e.metal_share > 0.9 and e.metal_income * 45 > e.metal_cap
        and e.metal_cap < e.metal_income * 120
    local energy_full = e.energy_share > 0.9 and e.energy_income * 20 > e.energy_cap
        and e.energy_cap < e.energy_income * 120
    -- Metal is the scarcer store: it goes first when both are full.
    local want = metal_full and "metal_storage" or (energy_full and "energy_storage" or nil)
    if want == nil then
        return false
    end
    local best, best_value
    for _, option in ipairs(catalog.buildable(entry, function(o) return o[want] end)) do
        local capacity = want == "metal_storage" and option.metal_capacity or option.energy_capacity
        local value = capacity / math.max(1, option.cost)
        if best_value == nil or value > best_value then
            best, best_value = option, value
        end
    end
    if best == nil then
        return false
    end
    if build_in_city(unit, best) then
        mark("storage")
        print("storage: " .. best.name)
        return true
    end
    return false
end

-- Helps put up the nearest unfinished building of the seat.
local function try_help(unit, reach)
    local at = util.pos(unit)
    if at == nil then
        return false
    end
    local best, best_d
    for _, frame in ipairs(world.select(function(u, e) return e.structure and u.finished ~= true end)) do
        local where = util.pos(frame)
        if where ~= nil then
            local d = util.dist(at, where)
            if d <= reach and (best_d == nil or d < best_d) then
                best, best_d = frame, d
            end
        end
    end
    if best ~= nil and unit:help(best) then
        builders.parked[unit.id] = me.tick
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
    if build_in_city(unit, best) then
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

-- Static anti-air from tier 1 to 3, more when enemy aircraft were seen.
local anti_air_wanted = {[0] = 0, 2, 5, 9, 12, 12}

local function try_anti_air(unit, entry)
    if recently("anti-air", 25) then
        return false
    end
    local wanted = anti_air_wanted[math.min(5, world.tier)]
    if world.enemy_air then
        wanted = wanted + 3
    end
    local have = count_of(function(_, e) return e.defense and e.anti_air end)
    if have >= wanted then
        return false
    end
    local e = economy.now
    local budget = math.max(250, e.metal_income * 60 + e.metal * 0.3)
    local best
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.defense and o.anti_air end)) do
        if option.metal <= budget and option.tier <= 3 and (best == nil or option.tier > best.tier
            or (option.tier == best.tier and option.range > best.range)) then
            best = option
        end
    end
    if best == nil then
        return false
    end
    -- Spread round the base rather than all on one side.
    local around = util.clamp(util.around(base(), brain.random(1000) / 1000, 400 + world.tier * 150), 96)
    if build_in_city(unit, best, around) then
        mark("anti-air")
        return true
    end
    return false
end

-- Long-range artillery from tier 2: one more each tier, toward the enemy.
local artillery_wanted = {[0] = 0, 0, 1, 2, 4, 4}

local function try_artillery(unit, entry)
    local wanted = artillery_wanted[math.min(5, world.tier)]
    if wanted == 0 or recently("artillery", 60) then
        return false
    end
    if count_of(function(_, e) return e.artillery end) >= wanted then
        return false
    end
    local e = economy.now
    -- The largest guns (Armageddon, Dictator, B.F.G.) take long to pay for.
    local budget = e.metal_income * (world.tier >= 4 and 600 or 240) + e.metal
    local best
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.artillery end)) do
        if option.metal <= budget and (best == nil or option.range > best.range) then
            best = option
        end
    end
    if best == nil then
        return false
    end
    if build_in_city(unit, best, world.front(500)) then
        mark("artillery")
        print("artillery: " .. best.name)
        return true
    end
    return false
end

-- Clears large wrecks left in the base once the fighting there is over.
local function try_clear_wreck(unit, entry)
    if entry.record.canreclamate ~= true or #world.wrecks == 0 then
        return false
    end
    if world.alarm ~= nil and me.tick - world.alarm.tick < 30 * 30 then
        return false
    end
    local at = util.pos(unit)
    local best, best_index, best_d
    for index, wreck in ipairs(world.wrecks) do
        local d = at and util.dist(at, wreck) or 0
        if best_d == nil or d < best_d then
            best, best_index, best_d = wreck, index, d
        end
    end
    table.remove(world.wrecks, best_index)
    if unit:reclaim({x = best.x, z = best.z}) then
        builders.parked[unit.id] = me.tick
        return true
    end
    return false
end

-- A block with free ground where nothing fits may hold rocks, trees or
-- wrecks: a builder patrols through it, and patrolling builders reclaim
-- what they pass.
local function try_sweep(unit)
    local block = table.remove(city.crowded, 1)
    if block == nil or me.tick - block.tick > 30 * 300 then
        return false
    end
    if unit:patrol(util.clamp(block, 64)) then
        builders.parked[unit.id] = me.tick
        return true
    end
    return false
end

-- Emergencies: builders drop what they do to repair buildings worth 7500
-- metal or more that are below half health while the base is under fire,
-- and heavy units sent home to be mended.
builders.mend = {}      -- unit id -> tick it was sent home for repair
builders.repairing = {} -- builder id -> id of what it repairs
local repair_value = 7500
local repairers_each = 3

local function repair_targets()
    local targets = {}
    local attacked = world.alarm ~= nil and me.tick - world.alarm.tick < 30 * 60
    if attacked then
        for _, unit in ipairs(world.select(function(u, e)
            return e.structure and e.metal >= repair_value and world.finished(u)
        end)) do
            if util.num(unit.health_percent) < 50 then
                targets[#targets + 1] = unit
            end
        end
    end
    local home = base()
    for id in pairs(builders.mend) do
        local unit = world.own[id]
        local at = unit and util.pos(unit)
        if unit == nil or util.num(unit.health_percent) >= 95 then
            builders.mend[id] = nil
        elseif at ~= nil and home ~= nil and util.dist(at, home) < 900 then
            targets[#targets + 1] = unit
        end
    end
    return targets
end

local function send_repairs()
    local targets = repair_targets()
    if #targets == 0 then
        builders.repairing = {}
        return
    end
    local crews = {}
    for builder_id, target_id in pairs(builders.repairing) do
        local target = world.own[target_id]
        if target ~= nil and util.num(target.health_percent) < 95 then
            crews[target_id] = (crews[target_id] or 0) + 1
        else
            builders.repairing[builder_id] = nil
        end
    end
    local free = world.select(function(u, e)
        return e.mobile_builder and world.finished(u) and builders.repairing[u.id] == nil
    end)
    for _, target in ipairs(targets) do
        local where = util.pos(target)
        while where ~= nil and (crews[target.id] or 0) < repairers_each and #free > 0 do
            local best, best_index, best_d
            for index, unit in ipairs(free) do
                local at = util.pos(unit)
                local d = at and util.dist(at, where) or 1e9
                if best_d == nil or d < best_d then
                    best, best_index, best_d = unit, index, d
                end
            end
            table.remove(free, best_index)
            if best_d > 2500 then
                break
            end
            if best:repair(target) then
                builders.repairing[best.id] = target.id
                builders.parked[best.id] = me.tick
                crews[target.id] = (crews[target.id] or 0) + 1
            end
        end
    end
end

-- Commander -------------------------------------------------------------------

-- The danger round the commander: more than eight tier-1 enemies, more
-- than five tier-2, any tier-3 or heavier, or aircraft it cannot shoot
-- at. Returns the middle of the threat, or nil.
local danger_radius = 900
local air_radius = 700

local function danger(unit, entry)
    local at = util.pos(unit)
    if at == nil then
        return nil
    end
    local t1, t2, heavy, air = 0, 0, 0, 0
    local sum_x, sum_z, count = 0, 0, 0
    for _, enemy in ipairs(world.visible_enemies()) do
        local where = util.pos(enemy)
        local kind = catalog.of(enemy)
        if where ~= nil and kind ~= nil and (kind.combat or kind.commander or kind.decoy) then
            local d = util.dist(at, where)
            local counted = false
            -- Aircraft it cannot shoot count only once they hit it.
            local hit = builders.commander_hit ~= nil and me.tick - builders.commander_hit < 30 * 5
            if kind.air and not entry.anti_air and hit and d <= air_radius then
                air = air + 1
                counted = true
            elseif not kind.air and d <= danger_radius then
                if kind.tier >= 3 then
                    heavy = heavy + 1
                elseif kind.tier == 2 then
                    t2 = t2 + 1
                else
                    t1 = t1 + 1
                end
                counted = true
            end
            if counted then
                sum_x, sum_z, count = sum_x + where.x, sum_z + where.z, count + 1
            end
        end
    end
    if t1 > 8 or t2 > 5 or heavy > 0 or air > 0 then
        return {x = sum_x / count, z = sum_z / count}
    end
    return nil
end

-- Runs as far from the threat as it can: straight away from it, a long
-- way, bending toward the back of the base when the map edge is close.
local function flee(unit, threat)
    local at = util.pos(unit)
    local away = util.toward(at, threat, -1800)
    local spot = util.clamp(away, 96)
    if util.dist(spot, at) < 900 then
        -- Cornered against the edge: slide along it, toward the base's back.
        local home = base()
        local back = util.toward(home, world.front(400), -1200)
        spot = util.clamp(back, 96)
    end
    unit:move(spot)
    if builders.fleeing == nil then
        print(string.format("commander flees from %.0f,%.0f", threat.x, threat.z))
    end
    builders.fleeing = me.tick
end

builders.dgun_at = 0

-- Cloaked and out of danger, the commander may fire its D-gun at a lone
-- tier-3 or heavier enemy inside its own base.
local function try_dgun(unit, entry)
    if builders.cloaked ~= true or entry.record.candgun ~= true or me.tick - builders.dgun_at < 30 * 5 then
        return false
    end
    local home = base()
    local at = util.pos(unit)
    if home == nil or at == nil then
        return false
    end
    local enemies = world.visible_enemies()
    for _, enemy in ipairs(enemies) do
        local kind = catalog.of(enemy)
        local where = util.pos(enemy)
        if kind ~= nil and where ~= nil and kind.tier >= 3 and not kind.air
            and util.dist(where, home) < 1200 and util.dist(where, at) < 900 then
            local alone = true
            for _, other in ipairs(enemies) do
                local there = util.pos(other)
                if other ~= enemy and there ~= nil and util.dist(there, where) < 600 then
                    alone = false
                    break
                end
            end
            if alone and unit:dgun(enemy) then
                builders.dgun_at = me.tick
                print("commander d-guns " .. kind.name)
                return true
            end
        end
    end
    return false
end

-- The commander's own safety comes before its work.
local function guard_commander(unit, entry)
    local threat = danger(unit, entry)
    if threat ~= nil then
        if builders.fleeing == nil or me.tick - builders.fleeing > 30 * 4 then
            flee(unit, threat)
        end
        return true
    end
    if builders.fleeing ~= nil and me.tick - builders.fleeing < 30 * 6 then
        return true
    end
    builders.fleeing = nil
    return try_dgun(unit, entry)
end

-- Decoys fight without fear: anything worth shooting near them is shot.
local function decoy_fights(unit)
    local at = util.pos(unit)
    local target = at and world.best_target(at, 700)
    if target ~= nil then
        unit:attack(target)
        builders.parked[unit.id] = me.tick - 30 * 10
        return true
    end
    return false
end

-- Cloaks the commander while energy is plentiful, and drops the cloak when
-- the stores run low.
local function cloak_commander(unit, entry)
    local moving = util.num(entry.record.cloakcostmoving)
    if util.num(entry.record.cloakcost) <= 0 then
        return
    end
    local e = economy.now
    local spare = e.energy_income - e.energy_demand
    if e.energy_share > 0.6 and spare > moving then
        if builders.cloaked ~= true then
            unit:cloak(true)
            builders.cloaked = true
        end
    elseif e.energy_share < 0.2 and builders.cloaked == true then
        unit:cloak(false)
        builders.cloaked = false
    end
end


-- Sends the commander back toward the middle of the base when it is far
-- away. The middle may sit under a building, so it stops on open ground
-- short of it, and is not sent again while it walks there.
local function send_home(unit)
    local centre = base()
    local at = util.pos(unit)
    if at == nil or centre == nil then
        return
    end
    local last = builders.retreat[unit.id]
    if last ~= nil and me.tick - last < 30 * 20 then
        return
    end
    if util.dist(at, centre) > 350 then
        local spot = util.clamp(util.toward(centre, at, 200), 64)
        unit:move(spot)
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
    if try_storage(unit, entry) then
        return true
    end
    -- Nothing of its own to build: help what goes up at the base, then
    -- the factories.
    if try_help(unit, 900) then
        return true
    end
    return try_assist(unit)
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
    -- The race comes first for whoever can build the next lab once the
    -- seat can pay for it, whatever that builder's role.
    local racing = tech.goal ~= nil and catalog.can_build(entry, tech.goal)
        and (tech.frame_alive() or tech.affordable())
    if racing or (builders.role[unit.id] == "tech" and not critical) then
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
    -- Anti-air and long-range artillery come early, at their own pace, and
    -- the energy store the guns need to fire before either.
    table.insert(order, 3, "artillery")
    table.insert(order, 3, "anti-air")
    table.insert(order, 2, "shot-storage")
    local tasks = {
        ["shot-storage"] = try_shot_storage,
        ["anti-air"] = try_anti_air,
        artillery = try_artillery,
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
        {"defence", try_defence}, {"jammer", try_jammer},
        {"factory", try_more_factories}, {"upgrade", try_upgrade_extractor},
        {"storage", try_storage}, {"scout lab", try_scout_lab}, {"wreck", try_clear_wreck},
        {"help", function(u) return try_help(u, 1500) end}, {"sweep", function(u) return try_sweep(u) end},
        {"assist", function(u) return try_assist(u) end},
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
    send_repairs()
    local list = world.select(function(u, e) return e.mobile_builder and world.finished(u) end)
    for _, unit in ipairs(list) do
        local entry = catalog.of(unit)
        local busy = false
        if entry.commander then
            cloak_commander(unit, entry)
            busy = guard_commander(unit, entry)
        elseif entry.decoy then
            busy = decoy_fights(unit)
        end
        if not busy and ready(unit) and builders.repairing[unit.id] == nil then
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

-- A heavy unit sent home for repair.
function builders.mend_unit(unit)
    builders.mend[unit.id] = me.tick
end

-- The commander walks home as soon as it is idle, and when badly hurt.
function builders.on_idle(unit, entry)
    if entry.commander and world.located() and builders.fleeing == nil then
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
    if entry.commander then
        builders.commander_hit = me.tick
    end
    if entry.commander and util.num(unit.health_percent) < 50 then
        local last = builders.retreat[unit.id]
        if last == nil or me.tick - last > 30 * 10 then
            send_home(unit)
        end
    end
end

return builders
