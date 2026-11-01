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
    released = {},     -- builder id -> tick it was last called back from helping
    upgrade_tried = {}, -- deposit and extractor type -> tick an upgrade was tried there
    pending = {},  -- what was ordered recently, so two builders do not start the same thing
    retreat = {},  -- commander id -> tick it was sent home
    running = {},  -- builder or decoy id -> tick it last ran from danger
    hit = {},      -- builder or decoy id -> {tick, x, z} of the last weapon hit
    salvaging = {}, -- builder id -> tick it was sent to reclaim a wreck
}

local commander_reach = 1000
-- How far from the base the commander walks to see a deposit.
local commander_walk = 800
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

-- Who works on which frame, counted once a turn (builders.step): a
-- builder alone on a frame is never sent to other work until it is up.
-- Only running is left to it, and only once it is under fire and down to
-- three quarters of its health. (The commander keeps its own safety
-- rules: losing it loses the game.)
builders.on_frame = {} -- builder id -> id of the frame it builds or helps
builders.crew = {}     -- frame id -> builders on it

local function count_crews()
    builders.on_frame, builders.crew = {}, {}
    local frames = world.select(function(u, e) return e.structure and u.finished ~= true end)
    if #frames == 0 then
        return
    end
    for _, worker in ipairs(world.select(function(u, e) return e.mobile_builder and world.finished(u) end)) do
        local orders = worker:orders()
        local head = type(orders) == "table" and orders[1] or nil
        if head ~= nil and (head.kind == "HelpBuild" or head.kind == "MobileBuild") then
            local target = head.target
            local found = nil
            if (type(target) == "userdata" or type(target) == "table") and target.id ~= nil then
                for _, frame in ipairs(frames) do
                    if frame.id == target.id then
                        found = frame
                    end
                end
            end
            local x, z = util.num(head.x), util.num(head.z)
            if found == nil and (x > 0 or z > 0) then
                for _, frame in ipairs(frames) do
                    local where = util.pos(frame)
                    if where ~= nil and util.dist(where, {x = x, z = z}) < 48 then
                        found = frame
                    end
                end
            end
            if found ~= nil then
                builders.on_frame[worker.id] = found.id
                builders.crew[found.id] = (builders.crew[found.id] or 0) + 1
            end
        end
    end
end

-- The frame `unit` is the only builder on, or nil.
local function alone_on_frame(unit)
    local frame = builders.on_frame[unit.id]
    if frame ~= nil and builders.crew[frame] == 1 then
        return frame
    end
    return nil
end

-- Whether a builder alone on a frame may leave it to run: hit in the last
-- ten seconds and down to 75 % health.
local function may_leave_frame(unit)
    if alone_on_frame(unit) == nil then
        return true
    end
    local hit = builders.hit[unit.id]
    return hit ~= nil and me.tick - hit.tick <= 30 * 10 and util.num(unit.health_percent) <= 75
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
        -- A walk may last 40 seconds plus a second for every 20 world
        -- units: far deposits (3 000 units and more on some maps) are
        -- beyond a slow builder's first minute.
        local at = util.pos(unit)
        local far = at ~= nil and util.dist(at, spot) or 0
        builders.walking[unit.id] = {tick = me.tick, x = spot.x, z = spot.z, limit = 30 * (40 + far // 20)}
        return true
    end
    return false
end

-- Outside the city grid nothing may hem a factory in: a building is kept
-- a few cells off every factory, and a factory off every building and
-- deposit (an extractor goes there later). A hovercraft platform with an
-- extractor at its door and a solar collector at its back kept its
-- builders on the pad for a whole match.
local factory_margin = 64

local function half_size(entry)
    return math.max(util.num(entry.record.footprintx), util.num(entry.record.footprintz)) * 8
end

-- A factory's units leave by its door, on the axis it faces (facing 0 and
-- 2, heading 0 and 32768: the z axis). Its door and back must stay clear
-- along that axis; its sides may touch other buildings.
local function axis_of_heading(heading)
    local quarter = ((util.num(heading) % 65536) + 8192) // 16384 % 4
    return quarter % 2 == 0 and "z" or "x"
end

local function hems(axis, fx, fz, fhalf, ox, oz, ohalf)
    local dx, dz = math.abs(ox - fx), math.abs(oz - fz)
    local along, across = dz, dx
    if axis == "x" then
        along, across = dx, dz
    end
    return across < fhalf + ohalf and along < fhalf + ohalf + factory_margin
end

local function crowds_factory(entry, x, z, facing)
    local half = half_size(entry)
    local axis = (facing or 0) % 2 == 0 and "z" or "x"
    for _, other in ipairs(world.select(function(u, e) return e.structure end)) do
        local kind = catalog.of(other)
        local at = util.pos(other)
        if at ~= nil then
            if kind.factory and hems(axis_of_heading(other.heading), at.x, at.z, half_size(kind), x, z, half) then
                return true
            end
            if entry.factory and hems(axis, x, z, half, at.x, at.z, half_size(kind)) then
                return true
            end
        end
    end
    if entry.factory then
        economy.free_spots(0)
        for _, spot in ipairs(economy.spots or {}) do
            if hems(axis, x, z, half, spot.x, spot.z, 24) then
                return true
            end
        end
    end
    return false
end

builders.crowds_factory = crowds_factory

-- Puts `entry` down near `near`, searching `radius` world units. When
-- `walk` is set and the ground is unexplored, the builder walks there.
local function place(unit, entry, near, radius, walk)
    local spot = util.clamp(near, 64)
    for attempt = 1, 3 do
        local facing = brain.random(4) - 1
        local from = attempt == 1 and spot or util.clamp(util.around(spot, brain.random(1000) / 1000, 160), 64)
        local _, _, x, z = brain.place(entry.record, from, radius, facing)
        if x == nil then
            return attempt == 1 and walk == true and scout_site(unit, spot)
        end
        x, z = util.whole(x), util.whole(z)
        if not crowds_factory(entry, x, z, facing) and util.reachable(unit, {x = x, z = z}, entry.factory) then
            return unit:build(entry.record, {x = x, z = z}, facing) == true
        end
    end
    return false
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
    -- The first lab cannot wait three minutes to learn it fits nowhere.
    local pause = world.tier == 0 and 30 * 30 or 30 * 60
    if last ~= nil and me.tick - last < pause then
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
                    if not city.on_street(entry, x, z) and not crowds_factory(entry, x, z, 0)
                        and util.reachable(unit, {x = x, z = z}, true)
                        and unit:build(entry.record, {x = x, z = z}, 0) then
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
-- Water-only buildings go into the sea nearest the base, by the shore, where
-- builders that cannot sail still reach them. With no room on explored
-- ground a builder other than the commander walks out to the nearest
-- unexplored block.
local function build_in_city(unit, entry, toward)
    if entry.water_only then
        local water = terrain.shore or terrain.water_point
        if water == nil then
            return false
        end
        if place(unit, entry, water, 480, true) then
            return true
        end
        if entry.factory then
            return place_wide(unit, entry, terrain.water_point or water)
        end
        return false
    end
    if city.place(unit, entry, toward) then
        return true
    end
    -- Ground too rough or cramped for the grid (a narrow ring of land, a
    -- small island): anywhere near the base, but never on a street. The
    -- commander tries this before walking out to unexplored blocks.
    local centre = toward or base()
    local function anywhere()
        for _, distance in ipairs({160, 320, 520, 800}) do
            local near = util.clamp(util.around(centre, brain.random(1000) / 1000, distance), 96)
            if util.explored(near) then
                local facing = brain.random(4) - 1
                local _, _, x, z = brain.place(entry.record, near, 320, facing)
                if x ~= nil and not city.on_street(entry, util.whole(x), util.whole(z))
                    and not crowds_factory(entry, util.whole(x), util.whole(z), facing)
                    and util.reachable(unit, {x = util.whole(x), z = util.whole(z)}, entry.factory)
                    and unit:build(entry.record, {x = util.whole(x), z = util.whole(z)}, facing) then
                    return true
                end
            end
        end
        return false
    end
    local kind = catalog.of(unit)
    if kind ~= nil and kind.commander and anywhere() then
        return true
    end
    -- Unexplored blocks are worth a walk only close to the base: on a map
    -- of islands or a thin ring of land there is always another one, and
    -- the builders would walk all game.
    local unseen = city.unexplored_block(toward or base())
    if unseen ~= nil and util.dist(unseen, base()) <= 600 and scout_site(unit, unseen) then
        return true
    end
    -- A factory found nowhere returns false plus true.
    if anywhere() then
        return true
    end
    if entry.factory then
        return place_wide(unit, entry, centre)
    end
    return false
end

-- Puts `land` down in the city, or `wet` (its water kind) on the sea by the
-- base. On a map with much water some go on the water by choice, as the
-- islands are small; otherwise the water is used when the land has no room.
local function build_land_or_water(unit, land, wet, toward)
    if wet ~= nil and (land == nil or (terrain.water_share >= 0.3 and brain.random(3) == 1)) then
        land, wet = wet, land
    end
    return (land ~= nil and build_in_city(unit, land, toward)) or (wet ~= nil and build_in_city(unit, wet, toward))
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
        -- A builder sent to see unexplored ground first is not building yet.
        local walk = builders.walking[unit.id]
        if walk == nil or walk.tick ~= me.tick then
            print("building " .. goal.name)
        end
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
-- one with the most metal under it wins, the nearest on a tie. A clear
-- site must cover at least 60 % of what the best position over the
-- deposit would: when the deposit is taken (an enemy extractor, a
-- building, rocks) the bare ground beside it is not worth an extractor.
-- With `ignore_site` the site test is skipped (an extractor to be
-- replaced still stands there). Returns the footprint's centre in world
-- units, or nil.
local deposit_share = 0.8

local function extractor_site(extractor, spot, ignore_site)
    local map = game.map
    local record = extractor.record
    local width = math.max(1, util.whole(record.footprintx))
    local depth = math.max(1, util.whole(record.footprintz))
    local spot_x = (spot.x - 8) // 16
    local spot_z = (spot.z - 8) // 16
    local best, best_metal, best_d
    local richest = 0
    for dz = -3, 3 do
        for dx = -3, 3 do
            local cx = spot_x - width // 2 + dx
            local cz = spot_z - depth // 2 + dz
            local metal = 0
            for z = 0, depth - 1 do
                for x = 0, width - 1 do
                    metal = metal + util.num(map:metal(cx + x, cz + z))
                end
            end
            richest = math.max(richest, metal)
            if ignore_site or brain.site(record, cx, cz, 0) == true then
                local d = dx * dx + dz * dz
                if best == nil or metal > best_metal or (metal == best_metal and d < best_d) then
                    best, best_metal, best_d = {x = cx * 16 + width * 8, z = cz * 16 + depth * 8}, metal, d
                end
            end
        end
    end
    if best == nil or best_metal <= 0 or best_metal < richest * deposit_share then
        return nil
    end
    return best
end

-- Deposits under the sea take an underwater extractor; a builder without
-- one tries its land extractor there (shallows may take it).
local function try_extractor(unit, entry, reach)
    local land = economy.best_extractor(entry)
    local wet = terrain.water_share > 0 and economy.best_extractor(entry, true) or nil
    if land == nil and wet == nil then
        return false
    end
    local spots = economy.free_spots(reach, unit.id)
    -- On maps whose deposits lie far apart, builders other than the
    -- commander go further out rather than build none.
    if #spots == 0 and not entry.commander and reach >= 1600 then
        spots = economy.free_spots(4500, unit.id)
    end
    -- On a metal map the ground itself holds metal and there are few or no
    -- deposits: extractors go in the city like any other building.
    if #spots == 0 and land ~= nil and economy.metal_map() then
        return build_in_city(unit, land)
    end
    -- A deposit the seat can see and build on comes first, nearest the
    -- base; only when there is none does the builder walk to one it has
    -- not seen (at the start even near ones are unexplored).
    local unseen = {}
    for index = 1, math.min(6, #spots) do
        local spot = spots[index]
        local extractor = land
        if terrain.under_water(spot) then
            extractor = wet or land
        end
        if extractor ~= nil then
            if util.explored(spot) then
                local site = extractor_site(extractor, spot)
                -- Out of this builder's reach (a plateau, an island) is
                -- not out of every builder's: the deposit stays free.
                if site ~= nil and not util.reachable(unit, site) then
                    site = false
                end
                if site and unit:build(extractor.record, site, 0) then
                    economy.claim(spot)
                    return true
                end
                -- Taken, or no room: left alone for a while.
                if site ~= false then
                    economy.claim(spot)
                end
            else
                unseen[#unseen + 1] = spot
            end
        end
    end
    for index = 1, math.min(3, #unseen) do
        local spot = unseen[index]
        -- The commander walks out only to deposits close to the base.
        if (not entry.commander or spot.d <= commander_walk) and scout_site(unit, spot) then
            economy.claim(spot, 0, unit.id)
            return true
        end
    end
    return false
end

-- Replaces a lower-tier extractor with the best one this builder can make:
-- reclaim the old one, then build the new one on the same spot. The
-- nearest to the base go first, one builder per extractor.
local function upgrade_key(at, extractor)
    return string.format("%d,%d:%d", at.x // 32, at.z // 32, extractor.index)
end

local function try_upgrade_extractor(unit, entry)
    local land = economy.best_extractor(entry)
    local wet = terrain.water_share > 0 and economy.best_extractor(entry, true) or nil
    if land == nil and wet == nil then
        return false
    end
    -- On a metal map any ground will do: build new extractors, keep the old.
    if economy.metal_map() then
        return false
    end
    local centre = base()
    local best, best_d, best_new
    for _, old in ipairs(world.select(function(u, e) return e.extractor and world.finished(u) end)) do
        local old_entry = catalog.of(old)
        local at = util.pos(old)
        local taken = builders.upgrading[old.id]
        local extractor = old_entry.water_only and wet or (not old_entry.water_only and land) or nil
        -- A deposit where the same upgrade was tried in the last ten
        -- minutes is left alone: the new extractor did not go up there
        -- (no room, or the builder could not get there).
        local tried = extractor ~= nil and at ~= nil and builders.upgrade_tried[upgrade_key(at, extractor)]
        if extractor ~= nil and old_entry.extracts < extractor.extracts and at ~= nil
            and (taken == nil or me.tick - taken > 30 * 90)
            and (not tried or me.tick - tried > 30 * 600)
            and util.reachable(unit, at) then
            local d = util.dist(at, centre)
            if best_d == nil or d < best_d then
                best, best_d, best_new = old, d, extractor
            end
        end
    end
    if best == nil then
        return false
    end
    local at = util.pos(best)
    -- The new extractor may be larger: it goes where it covers the most of
    -- the deposit, not simply centred on the old one.
    local site = extractor_site(best_new, at, true) or at
    if unit:reclaim(best) then
        unit:build(best_new.record, site, 0, true)
        builders.upgrading[best.id] = me.tick
        builders.upgrade_tried[upgrade_key(at, best_new)] = me.tick
        print(string.format("upgrade %s -> %s at %d,%d", catalog.of(best).name, best_new.name, at.x, at.z))
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
        if x ~= nil and util.reachable(unit, {x = util.whole(x), z = util.whole(z)})
            and unit:build(plant.record, {x = util.whole(x), z = util.whole(z)}, 0) then
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
    -- Tidal and floating plants when they give more for their cost, or
    -- when the land has no room.
    local land, land_value = economy.best_power(entry)
    local wet, wet_value = nil, 0
    if terrain.ship_ok then
        wet, wet_value = economy.best_power(entry, true)
    end
    if wet ~= nil and (land == nil or wet_value > land_value) then
        land, wet = wet, land
    end
    return (land ~= nil and build_in_city(unit, land)) or (wet ~= nil and build_in_city(unit, wet))
end

local function try_maker(unit, entry, centre, spread)
    local maker = economy.best_maker(entry)
    if maker ~= nil and build_in_city(unit, maker) then
        return true
    end
    -- Floating makers when the land has none or no room.
    local wet = terrain.ship_ok and economy.best_maker(entry, true) or nil
    return wet ~= nil and build_in_city(unit, wet)
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
        if economy.maker_type(entry) ~= nil or (terrain.ship_ok and economy.maker_type(entry, true) ~= nil) then
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
    local function pick(wet)
        local best
        for _, option in ipairs(catalog.buildable(entry, function(o)
            return o.defense and not o.air and o.water_only == wet
        end, wet)) do
            if option.metal <= budget and (best == nil or option.tier > best.tier
                or (option.tier == best.tier and option.cost > best.cost)) then
                best = option
            end
        end
        return best
    end
    local land = pick(false)
    local wet = terrain.ship_ok and pick(true) or nil
    if land == nil and wet == nil then
        return false
    end
    if build_land_or_water(unit, land, wet, world.front(300)) then
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
    -- More factories only burn more energy when it is already short.
    if economy.need() == "energy" then
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
    -- All tiers together: old factories wait to be reclaimed, and the
    -- builders and energy go to the new ones.
    local total = 0
    for _, n in pairs(count) do
        total = total + n
    end
    if total >= limit * 3 then
        return false
    end
    local best, best_score
    for _, option in ipairs(catalog.buildable(entry, function(f) return f.factory end, terrain.ship_ok)) do
        local level = catalog.factory_tier(option)
        local rank = terrain.rank(option.line)
        if rank ~= nil and terrain.line_ok(option.line) and (level == tier or level == tier - 1)
            and (count[level] or 0) < limit and option ~= tech.goal then
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
    -- Below tier 2 a full store means the builders are too few to spend
    -- the income, not that it needs keeping: they help the factories.
    if world.tier < 2 or recently("storage", 45) then
        return false
    end
    local e = economy.now
    -- Enough room for two minutes of income is enough, and for metal less
    -- once the income is large: a big store late in the game only holds
    -- metal the factories should be spending (about 11 000 at 450 a second).
    local metal_full = e.metal_share > 0.9 and e.metal_income * 45 > e.metal_cap
        and e.metal_cap < math.min(e.metal_income * 120, 2000 + e.metal_income * 20)
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

-- Helps the frame of the next lab, which any builder can help even when it
-- could not have started it.
local function try_help_frame(unit)
    if not tech.frame_alive() then
        return false
    end
    local at = util.pos(unit)
    local where = util.pos(tech.frame)
    if at == nil or where == nil or util.dist(at, where) > 2500 then
        return false
    end
    if unit:help(tech.frame) then
        builders.parked[unit.id] = me.tick
        return true
    end
    return false
end

-- Large frames left with nobody on them (their builders ran, were called
-- to an emergency or went on to other work) are taken up again before
-- anything new is started: the half-built Armageddons and reactors
-- stood for minutes. Helpers are not held on a frame (that starved the
-- economy in the test matches); a frame nobody works on is what counts.
local big_frame = 5000
builders.resumed = {} -- builder id -> id of the frame it last took up

local function frame_worked(frame, workers)
    local where = util.pos(frame)
    for _, worker in ipairs(workers) do
        local orders = worker:orders()
        local head = type(orders) == "table" and orders[1] or nil
        if head ~= nil and (head.kind == "HelpBuild" or head.kind == "MobileBuild") then
            local target = head.target
            if (type(target) == "userdata" or type(target) == "table") and target.id == frame.id then
                return true
            end
            local x, z = util.num(head.x), util.num(head.z)
            if where ~= nil and (x > 0 or z > 0) and util.dist(where, {x = x, z = z}) < 48 then
                return true
            end
        end
    end
    return false
end

local function try_resume(unit)
    local need, urgency = economy.need()
    if need == "metal" and urgency >= 2 then
        return false
    end
    local at = util.pos(unit)
    if at == nil then
        return false
    end
    local frames = world.select(function(u, e) return e.structure and e.metal >= big_frame and u.finished ~= true end)
    if #frames == 0 then
        return false
    end
    local workers = world.select(function(u, e) return e.mobile_builder and u.id ~= unit.id end)
    local best, best_left
    for _, frame in ipairs(frames) do
        local where = util.pos(frame)
        if where ~= nil and util.dist(at, where) <= 1500 and util.reachable(unit, where)
            and not frame_worked(frame, workers) then
            local left = util.num(frame.build_remaining)
            if best_left == nil or left < best_left then
                best, best_left = frame, left
            end
        end
    end
    if best ~= nil and unit:help(best) then
        builders.parked[unit.id] = me.tick
        -- Logged once per builder and frame: a lone helper is looked at
        -- again every fifteen seconds and comes straight back.
        if builders.resumed[unit.id] ~= best.id then
            builders.resumed[unit.id] = best.id
            print("resume " .. catalog.of(best).name)
        end
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
    local function pick(wet)
        local best
        for _, option in ipairs(catalog.buildable(entry, function(o)
            return o.defense and o.anti_air and o.water_only == wet
        end, wet)) do
            if option.metal <= budget and option.tier <= 3 and (best == nil or option.tier > best.tier
                or (option.tier == best.tier and option.range > best.range)) then
                best = option
            end
        end
        return best
    end
    local land = pick(false)
    local wet = terrain.ship_ok and pick(true) or nil
    if land == nil and wet == nil then
        return false
    end
    -- Spread round the base rather than all on one side.
    local around = util.clamp(util.around(base(), brain.random(1000) / 1000, 400 + world.tier * 150), 96)
    if build_land_or_water(unit, land, wet, around) then
        mark("anti-air")
        return true
    end
    return false
end

-- Long-range artillery from tier 2, toward the enemy: one at tier 2,
-- three at tier 3, five at tier 4, six above.
local artillery_wanted = {[0] = 0, 0, 1, 3, 5, 6}

local function try_artillery(unit, entry)
    local wanted = artillery_wanted[math.min(5, world.tier)]
    if wanted == 0 or recently("artillery", 60) then
        return false
    end
    local guns = world.select(function(_, e) return e.artillery end)
    if #guns >= wanted then
        return false
    end
    local owned = {}
    for _, gun in ipairs(guns) do
        local index = catalog.of(gun).index
        owned[index] = (owned[index] or 0) + 1
    end
    local e = economy.now
    -- The largest guns (Armageddon, Dictator, B.F.G.) take long to pay for.
    local budget = e.metal_income * (world.tier >= 4 and 600 or 240) + e.metal
    -- Every kind gets built: the kind the seat has fewest of first, the
    -- cheapest among those. Taking the longest range went straight to
    -- the Armageddon and Dictator and never built a Big Bertha, an
    -- Intimidator, a Vulcan or a Buzzsaw.
    local best, best_owned
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.artillery end)) do
        local have = owned[option.index] or 0
        if option.metal <= budget and (best == nil or have < best_owned
            or (have == best_owned and option.metal < best.metal)) then
            best, best_owned = option, have
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

-- Repair pads once the seat flies enough aircraft: one for every four
-- attacking aircraft, up to ten, carriers counted (a pad mends one
-- aircraft at a time). The army sends aircraft below half health to them.
local function air_fleet()
    return #world.select(function(_, e) return e.air and e.combat and not e.scout end)
end

function builders.air_bases_wanted()
    return math.min(10, air_fleet() // 4)
end

local function try_air_base(unit, entry)
    if recently("air-base", 30) then
        return false
    end
    local have = count_of(function(_, e) return e.air_base end)
    if have >= builders.air_bases_wanted() then
        return false
    end
    local best
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.air_base and o.structure end)) do
        if best == nil or option.cost < best.cost then
            best = option
        end
    end
    if best == nil then
        return false
    end
    if build_in_city(unit, best) then
        mark("air-base")
        print("air base: " .. best.name)
        return true
    end
    return false
end

-- From tier 3, one commander upgrade building (Arm's Research Facility):
-- it makes the commander tougher.
local function try_commander_upgrade(unit, entry)
    if world.tier < 3 or recently("commander-upgrade", 120) then
        return false
    end
    if count_of(function(_, e) return e.commander_upgrade end) > 0 then
        return false
    end
    for _, option in ipairs(catalog.buildable(entry, function(o) return o.commander_upgrade end)) do
        if build_in_city(unit, option) then
            mark("commander-upgrade")
            print("commander upgrade: " .. option.name)
            return true
        end
    end
    return false
end

-- Lean times: a store below a fifth of its size (where the engine's own
-- patrolling builders start reclaiming) makes wrecks near the builder
-- worth more than a new extractor or power plant. The nearest known
-- wreck is reclaimed; with none known, a crowded block near the builder
-- (rocks and trees, whose positions the API does not give) is patrolled,
-- and the patrol reclaims what it passes while the store is low.
local salvage_reach = 1200
local salvagers_max = 3

local function scarce()
    local e = economy.now or economy.read()
    return e.metal_share < 0.2 or e.energy_share < 0.2
end

local function try_salvage(unit, entry)
    if entry.record.canreclamate ~= true or not scarce() then
        return false
    end
    local working = 0
    for id, tick in pairs(builders.salvaging) do
        if me.tick - tick > 30 * 30 or world.own[id] == nil then
            builders.salvaging[id] = nil
        elseif id ~= unit.id then
            working = working + 1
        end
    end
    if working >= salvagers_max then
        return false
    end
    local at = util.pos(unit)
    local home = base()
    if at == nil or home == nil then
        return false
    end
    local enemies = world.visible_enemies()
    local function safe(spot)
        for _, enemy in ipairs(enemies) do
            local where = util.pos(enemy)
            local kind = catalog.of(enemy)
            if where ~= nil and kind ~= nil and kind.combat and util.dist2(where, spot) < 700 * 700 then
                return false
            end
        end
        return true
    end
    local best, best_index, best_d
    for index = #world.salvage, 1, -1 do
        local wreck = world.salvage[index]
        if me.tick - wreck.tick > 30 * 1200 then
            table.remove(world.salvage, index)
        else
            local d = util.dist(at, wreck)
            if d <= salvage_reach and util.dist(home, wreck) <= 3000 and safe(wreck)
                and (best_d == nil or d < best_d) then
                best, best_index, best_d = wreck, index, d
            end
        end
    end
    if best ~= nil then
        table.remove(world.salvage, best_index)
        if unit:reclaim({x = best.x, z = best.z}) then
            builders.parked[unit.id] = me.tick
            builders.salvaging[unit.id] = me.tick
            print(string.format("salvage wreck at %d,%d (about %d metal)", best.x, best.z, util.whole(best.metal)))
            return true
        end
        return false
    end
    if recently("salvage-sweep", 30) then
        return false
    end
    for index, block in ipairs(city.crowded) do
        if me.tick - block.tick <= 30 * 300 and util.dist(at, block) <= salvage_reach and safe(block) then
            table.remove(city.crowded, index)
            if unit:patrol(util.clamp(block, 64)) then
                mark("salvage-sweep")
                builders.parked[unit.id] = me.tick
                builders.salvaging[unit.id] = me.tick
                print(string.format("salvage sweep at %d,%d", block.x, block.z))
                return true
            end
            return false
        end
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

-- Emergencies: builders drop what they do to repair buildings worth 5000
-- metal or more that are below half health while the base is under fire,
-- and heavy units sent home to be mended.
builders.mend = {}      -- unit id -> tick it was sent home for repair
builders.repairing = {} -- builder id -> id of what it repairs
local repair_value = 5000
local repairers_each = 3
-- The commander is mended from below 75 % health, by more builders: it
-- walks back to the base and waits there until mended
-- (builders.commander_mending).
local commander_mend_below = 75
local commander_repairers = 4

local function repair_targets()
    local targets = {}
    for _, commander in ipairs(world.select(function(_, e) return e.commander end)) do
        local health = util.num(commander.health_percent)
        if health < commander_mend_below then
            builders.commander_mending = true
        elseif health >= 95 then
            builders.commander_mending = nil
        end
        if builders.commander_mending then
            targets[#targets + 1] = commander
        end
    end
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
        return e.mobile_builder and not e.commander and world.finished(u) and builders.repairing[u.id] == nil
            and (e.decoy or builders.running[u.id] == nil) and alone_on_frame(u) == nil
    end)
    for _, target in ipairs(targets) do
        local where = util.pos(target)
        local wanted = catalog.of(target).commander and commander_repairers or repairers_each
        while where ~= nil and (crews[target.id] or 0) < wanted and #free > 0 do
            local best, best_index, best_d
            for index, unit in ipairs(free) do
                local at = util.pos(unit)
                local d = at and util.dist(at, where) or 1e9
                -- Decoys go first: they never leave an emergency repair.
                if catalog.of(unit).decoy then
                    d = d * 0.5
                end
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
-- than five tier-2, any tier-3 or heavier, any enemy commander or decoy
-- (two commanders D-gunning each other both die), or aircraft it cannot
-- shoot at. Returns the middle of the threat, or nil.
local danger_radius = 900
local air_radius = 700
local commander_radius = 1100

local function danger(unit, entry, ignore_air)
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
            -- Aircraft it cannot shoot count only once they hit it; decoys
            -- ignore them.
            local last = builders.hit[unit.id]
            local hit = last ~= nil and me.tick - last.tick < 30 * 5
            if kind.air and not entry.anti_air and hit and not ignore_air and d <= air_radius then
                air = air + 1
                counted = true
            elseif (kind.commander or kind.decoy) and d <= commander_radius then
                heavy = heavy + 1
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
local function run_from(unit, threat, distance)
    local at = util.pos(unit)
    local away = util.toward(at, threat, -distance)
    local spot = util.clamp(away, 96)
    if util.dist(spot, at) < distance / 2 then
        -- Cornered against the edge: slide along it, toward the base's back.
        local home = base()
        local back = util.toward(home, world.front(400), -1200)
        spot = util.clamp(back, 96)
    end
    unit:move(spot)
end

local function flee(unit, threat)
    run_from(unit, threat, 1800)
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

-- Decoys keep out of fights as the commander does: they run from the
-- same dangers and from enemy commanders and decoys, but aircraft do not
-- move them. A decoy on an emergency repair never runs.
local function guard_decoy(unit, entry)
    if builders.repairing[unit.id] ~= nil then
        builders.running[unit.id] = nil
        return false
    end
    local threat = danger(unit, entry, true)
    if threat ~= nil and not may_leave_frame(unit) then
        threat = nil
    end
    local last = builders.running[unit.id]
    if threat ~= nil then
        if last == nil or me.tick - last > 30 * 4 then
            if last == nil then
                print(string.format("decoy flees from %.0f,%.0f", threat.x, threat.z))
            end
            run_from(unit, threat, 1200)
            builders.walking[unit.id] = nil
            builders.running[unit.id] = me.tick
        end
        return true
    end
    if last ~= nil and me.tick - last < 30 * 6 then
        return true
    end
    builders.running[unit.id] = nil
    return false
end

-- Builders run from danger too, and from anything that hits them: back
-- toward the base when it lies away from the threat, else straight away
-- from it. A walk they were on is given up and its spot set aside.
local base_radius = 800

local function builder_threat(unit, entry)
    local threat = danger(unit, entry)
    if threat ~= nil then
        return threat
    end
    local last = builders.hit[unit.id]
    -- Inside the base, where the defences stand, a hit alone sends a
    -- builder away only once it is below half health: raids on the base
    -- otherwise stopped all building (81 flights in one game).
    local at, home = util.pos(unit), base()
    local in_base = at ~= nil and home ~= nil and util.dist(at, home) <= base_radius
    if in_base and util.num(unit.health_percent) >= 50 then
        last = nil
    end
    if last ~= nil and me.tick - last.tick < 30 * 4 then
        if last.x ~= nil then
            return {x = last.x, z = last.z}
        end
        -- Hit by something unseen: the nearest armed enemy in sight.
        local best, best_d
        for _, enemy in ipairs(world.visible_enemies()) do
            local kind = catalog.of(enemy)
            local where = util.pos(enemy)
            if at ~= nil and kind ~= nil and where ~= nil and kind.combat then
                local d = util.dist(at, where)
                if d < 1000 and (best_d == nil or d < best_d) then
                    best, best_d = where, d
                end
            end
        end
        if best == nil then
            -- Nothing in sight to run from: back to the base.
            return {home = true}
        end
        return best
    end
    return nil
end

local function guard_builder(unit, entry)
    local threat = builder_threat(unit, entry)
    if threat ~= nil and not may_leave_frame(unit) then
        threat = nil
    end
    local last = builders.running[unit.id]
    if threat ~= nil then
        if last == nil or me.tick - last > 30 * 4 then
            local at = util.pos(unit)
            local home = base()
            if at ~= nil and home ~= nil and threat.home then
                if util.dist(at, home) > 300 then
                    unit:move(util.clamp(util.toward(home, at, 200), 64))
                end
            elseif at ~= nil and home ~= nil and util.dist(at, home) > 600
                and util.dist(threat, home) > util.dist(at, home) then
                unit:move(util.clamp(util.toward(home, at, 200), 64))
            elseif at ~= nil and threat.x ~= nil then
                run_from(unit, threat, 700)
            end
            local walk = builders.walking[unit.id]
            if walk ~= nil then
                builders.walking[unit.id] = nil
                economy.claim({x = walk.x, z = walk.z}, 120)
            end
            builders.repairing[unit.id] = nil
            builders.running[unit.id] = me.tick
            if last == nil then
                builders.new_runners = (builders.new_runners or 0) + 1
            end
        end
        return true
    end
    if last ~= nil and me.tick - last < 30 * 8 then
        return true
    end
    builders.running[unit.id] = nil
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

-- The commander's leash: nothing it is told to build, help or guard may
-- lie more than this far from the base. Placements that fall back to
-- open ground, wide searches for a lab and help for far frames and
-- factories took it 1 300 to 2 100 units out (test matches).
local commander_leash = 900
builders.leashed = {} -- task name -> tick a far order of it was dropped

-- Where the head order of `unit` leads: the build site or the unit it
-- helps or guards.
local function order_point(unit)
    local orders = unit:orders()
    local head = type(orders) == "table" and orders[1] or nil
    if head == nil then
        return nil
    end
    local target = head.target
    if (type(target) == "userdata" or type(target) == "table") and util.pos(target) ~= nil then
        return util.pos(target)
    end
    local x, z = util.num(head.x), util.num(head.z)
    if string.find(tostring(head.kind), "Build", 1, true) ~= nil and (x > 0 or z > 0) then
        return {x = x, z = z}
    end
    return nil
end

-- Runs a commander task; an order it gave beyond the leash is dropped,
-- what the task marked is put back, and the task rests twenty seconds.
local function leashed(name, unit, task, ...)
    local last = builders.leashed[name]
    if last ~= nil and me.tick - last < 30 * 20 then
        return false
    end
    local pending = {}
    for key, tick in pairs(builders.pending) do
        pending[key] = tick
    end
    local started, no_room = tech.started, tech.no_room
    if not task(unit, ...) then
        return false
    end
    local at = order_point(unit)
    local home = base()
    if at == nil or home == nil or util.dist(at, home) <= commander_leash then
        return true
    end
    unit:stop()
    builders.pending = pending
    tech.started, tech.no_room = started, no_room
    builders.walking[unit.id] = nil
    builders.leashed[name] = me.tick
    return false
end

local function commander_turn(unit, entry)
    if world.tier == 0 then
        -- Opening: an extractor, the first lab, then more extractors and
        -- power. The lab brings builders, which do the rest far faster.
        local extractors = count_of(function(_, e) return e.extractor end)
        local power = count_of(function(_, e) return e.power end)
        if extractors < 1 and leashed("extractor", unit, try_extractor, entry, commander_reach) then
            return true
        end
        if leashed("goal", unit, try_goal, entry) then
            return true
        end
        if extractors < 2 and leashed("extractor", unit, try_extractor, entry, commander_reach) then
            return true
        end
        if power < 2 and leashed("power", unit, try_power, entry, base(), 160) then
            return true
        end
    end
    -- Metal piling up: the factories and frames are short of build power,
    -- so the commander lends its own before anything else.
    local e = economy.now
    if world.tier >= 1 and e.metal_share > 0.7 and e.energy_share > 0.3 then
        if leashed("goal", unit, try_goal, entry) or leashed("help frame", unit, try_help_frame) or leashed("assist", unit, try_assist) or leashed("help", unit, try_help, 900) then
            return true
        end
    end
    if leashed("salvage", unit, try_salvage, entry) or leashed("economy", unit, try_economy, entry, true) then
        return true
    end
    if leashed("radar", unit, try_radar, entry) then
        return true
    end
    if leashed("goal", unit, try_goal, entry) then
        return true
    end
    if leashed("scout lab", unit, try_scout_lab, entry) then
        return true
    end
    if leashed("storage", unit, try_storage, entry) then
        return true
    end
    -- Nothing of its own to build: help what goes up at the base, then
    -- the factories.
    if leashed("help", unit, try_help, 900) then
        return true
    end
    return leashed("assist", unit, try_assist)
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
    local need, urgency = economy.need()
    local critical = urgency >= 2
    local attacked = world.alarm ~= nil and me.tick - world.alarm.tick < 30 * 60
    -- No metal at all: anything but the economy only adds frames that
    -- cannot rise (a map whose deposits lie far off starts like this).
    local starving = need == "metal" and critical and not attacked
    local order
    -- The race comes first for whoever can build the next lab once the
    -- seat can pay for it, whatever that builder's role; but with the
    -- economy running dry (no metal on a map whose deposits lie far off)
    -- the economy builders see to it first, or the lab never gets the
    -- metal to go up.
    local racing = tech.goal ~= nil and catalog.can_build(entry, tech.goal)
        and (tech.frame_alive() or tech.affordable())
        and not (critical and builders.role[unit.id] == "economy")
    if racing or (builders.role[unit.id] == "tech" and not critical) then
        order = {"reclaim", "radar", "goal", "resume", "salvage", "economy"}
    else
        order = {"reclaim", "radar", "resume", "salvage", "economy", "goal"}
    end
    -- Under attack, or with too few defences, the economy builders fortify first.
    local defences = count_of(function(_, e) return e.defense end)
    if builders.role[unit.id] == "economy" and not starving
        and (attacked or defences * 2 < defence_wanted[math.min(5, world.tier)]) then
        table.insert(order, 2, "defence")
    end
    -- Anti-air and long-range artillery come early, at their own pace, and
    -- the energy store the guns need to fire before either.
    if not starving then
        -- A builder racing for the next lab puts it before anti-air and
        -- artillery: the first tier-1 builders used to raise towers first.
        local at = racing and (#order) or 3
        table.insert(order, at, "artillery")
        table.insert(order, at, "anti-air")
        table.insert(order, 2, "shot-storage")
    end
    -- From tier 3 the commander upgrade building comes right after the lab.
    if not starving then
        for index, name in ipairs(order) do
            if name == "goal" then
                table.insert(order, index + 1, "commander-upgrade")
                break
            end
        end
    end
    local tasks = {
        ["commander-upgrade"] = try_commander_upgrade,
        ["shot-storage"] = try_shot_storage,
        ["anti-air"] = try_anti_air,
        artillery = try_artillery,
        reclaim = try_reclaim,
        salvage = try_salvage,
        radar = try_radar,
        goal = try_goal,
        resume = function(u) return try_resume(u) end,
        defence = try_defence,
        economy = function(u, e) return try_economy(u, e, false) end,
    }
    for _, name in ipairs(order) do
        if tasks[name](unit, entry) then
            return true
        end
    end
    local rest = {
        {"air base", try_air_base},
        {"defence", try_defence}, {"jammer", try_jammer},
        {"factory", try_more_factories}, {"upgrade", try_upgrade_extractor},
        {"storage", try_storage}, {"scout lab", try_scout_lab}, {"wreck", try_clear_wreck},
        {"help", function(u) return try_help(u, 1500) end}, {"sweep", function(u) return try_sweep(u) end},
        {"assist", function(u) return try_assist(u) end},
    }
    -- Metal piling up: the factories are short of build power, so more
    -- factories and then helping them come before the rest.
    local e = economy.now
    if e.metal_share > 0.7 and e.energy_share > 0.3 then
        local first = {}
        local others = {}
        first[1] = {"frame", function(u) return try_help_frame(u) end}
        for _, task in ipairs(rest) do
            if task[1] == "factory" then
                table.insert(first, 2, task)
            elseif task[1] == "assist" then
                first[#first + 1] = task
            else
                others[#others + 1] = task
            end
        end
        for _, task in ipairs(others) do
            first[#first + 1] = task
        end
        rest = first
    end
    local spare = {wreck = true, help = true, sweep = true, assist = true}
    for _, task in ipairs(rest) do
        if (not starving or spare[task[1]]) and task[2](unit, entry) then
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
        elseif me.tick - walk.tick > (walk.limit or 30 * 40) then
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
        -- Alone on a frame (helping it, after the builder that started it
        -- left): it stays until the frame is up.
        if alone_on_frame(unit) ~= nil then
            return false
        end
        if me.tick - parked >= 30 * 15 then
            builders.parked[unit.id] = nil
            return true
        end
        return false
    end
    -- A guard the brain did not park the unit on (the engine turns help
    -- on a finished factory into one) would last for ever, and so would a
    -- move that is no walk the brain is timing (a path that failed).
    local kind = unit:head_order()
    if type(kind) == "string" and (string.find(kind, "Follow", 1, true) or string.find(kind, "Guard", 1, true)) then
        return true
    end
    if (kind == "Move_Ground" or kind == "Move") and not catalog.of(unit).commander then
        return true
    end
    return util.free(unit)
end

-- An economy builder helping a frame while metal has run out is called
-- back, at most every 30 seconds, to see to the economy: otherwise it
-- helps a lab that cannot rise for want of metal for minutes on end.
local function released(unit, entry)
    if entry.commander or builders.role[unit.id] ~= "economy" or alone_on_frame(unit) ~= nil then
        return false
    end
    local need, urgency = economy.need()
    if need ~= "metal" or urgency < 2 or unit:head_order() ~= "HelpBuild" then
        return false
    end
    local last = builders.released[unit.id]
    if last ~= nil and me.tick - last < 30 * 30 then
        return false
    end
    builders.released[unit.id] = me.tick
    return true
end

function builders.step()
    economy.read()
    count_crews()
    send_repairs()
    builders.new_runners = 0
    local list = world.select(function(u, e) return e.mobile_builder and world.finished(u) end)
    for _, unit in ipairs(list) do
        local entry = catalog.of(unit)
        local busy = false
        if entry.commander then
            cloak_commander(unit, entry)
            busy = guard_commander(unit, entry)
            -- Hurt: it walks back to the base (where the attack is not) and
            -- waits there for the builders until mended; danger still sends
            -- it running. With no builder left to mend it, it works on.
            if not busy and builders.commander_mending and builders.can_mend() then
                busy = true
                local at, home = util.pos(unit), base()
                if at ~= nil and home ~= nil and util.dist(at, home) > 350 then
                    local kind = unit:head_order()
                    if kind ~= "Move_Ground" and kind ~= "Move" then
                        builders.retreat[unit.id] = nil
                        send_home(unit)
                        if not builders.mend_walk then
                            print(string.format("commander walks home for repair (health %d%%)",
                                util.whole(util.num(unit.health_percent))))
                            builders.mend_walk = true
                        end
                    end
                elseif not util.free(unit) and unit:head_order() ~= "Move_Ground" and unit:head_order() ~= "Move" then
                    unit:stop()
                end
            elseif not builders.commander_mending then
                builders.mend_walk = nil
            end
        elseif entry.decoy then
            busy = guard_decoy(unit, entry)
        else
            busy = guard_builder(unit, entry)
        end
        if not busy and (ready(unit) or released(unit, entry)) and builders.repairing[unit.id] == nil then
            if entry.commander then
                if not commander_turn(unit, entry) then
                    send_home(unit)
                    -- Whatever it is doing now (a guard, a walk home), it
                    -- looks for work again in fifteen seconds.
                    builders.parked[unit.id] = me.tick
                end
            elseif not builder_turn(unit, entry) then
                park(unit)
            end
        end
    end
    if builders.new_runners > 0 then
        print("builders flee: " .. builders.new_runners)
    end
    for id in pairs(builders.running) do
        if world.own[id] == nil then
            builders.running[id] = nil
        end
    end
    for id, last in pairs(builders.hit) do
        if world.own[id] == nil or me.tick - last.tick > 30 * 60 then
            builders.hit[id] = nil
        end
    end
end

-- A finished extractor that covers less than 90 % of the metal it could
-- cover a few cells away is logged ("extractor off deposit"): placement
-- should never do that, so the line points at a fault.
function builders.check_extractor(unit, entry)
    local at = util.pos(unit)
    if at == nil or economy.metal_map() then
        return
    end
    local map = game.map
    local width = math.max(1, util.whole(entry.record.footprintx))
    local depth = math.max(1, util.whole(entry.record.footprintz))
    local left = (at.x - width * 8) // 16
    local top = (at.z - depth * 8) // 16
    local here, richest = 0, 0
    for dz = -3, 3 do
        for dx = -3, 3 do
            local metal = 0
            for z = 0, depth - 1 do
                for x = 0, width - 1 do
                    metal = metal + util.num(map:metal(left + dx + x, top + dz + z))
                end
            end
            if dx == 0 and dz == 0 then
                here = metal
            end
            richest = math.max(richest, metal)
        end
    end
    if here < richest * 0.9 then
        print(string.format("extractor off deposit: %s at %d,%d covers %d of %d", entry.name, at.x, at.z, here, richest))
    end
end

-- Whether any builder besides the commander could come to mend it.
function builders.can_mend()
    return #world.select(function(u, e)
        return e.mobile_builder and not e.commander and world.finished(u)
    end) > 0
end

-- How many builders are repairing `unit`.
function builders.crew_for(unit)
    local count = 0
    for _, target_id in pairs(builders.repairing) do
        if target_id == unit.id then
            count = count + 1
        end
    end
    return count
end

-- A heavy unit sent home for repair.
function builders.mend_unit(unit)
    builders.mend[unit.id] = me.tick
end

-- The commander walks home as soon as it is idle, and when badly hurt.
function builders.on_idle(unit, entry)
    if entry.commander and world.located() and builders.fleeing == nil
        and not (builders.commander_mending and builders.can_mend()) then
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
    -- The failed move would otherwise stay at the head of the queue and
    -- the builder would never be free again.
    unit:stop()
end

function builders.on_damaged(unit, entry, attacker)
    if not entry.mobile_builder then
        return
    end
    local from = attacker ~= nil and util.pos(attacker) or nil
    builders.hit[unit.id] = {tick = me.tick, x = from and from.x, z = from and from.z}
    if entry.commander and util.num(unit.health_percent) < 50 then
        local last = builders.retreat[unit.id]
        if last == nil or me.tick - last > 30 * 10 then
            send_home(unit)
        end
    end
end

return builders
