-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What the map allows: how much of it is water, and whether the enemy can
-- be reached on land, by hovercraft or by ship. From that, the order in
-- which factory lines are preferred:
--
--   land map          kbots, vehicles > aircraft > ships > hovercraft
--   water map         kbots, vehicles, ships > aircraft > hovercraft
--   enemy over water  hovercraft and ships first, then aircraft
--   enemy cut off     aircraft first (nothing on the ground reaches it)
--
-- Ships count only when there is water near the base.

local catalog = require("catalog")
local util = require("util")
local world = require("world")

local terrain = {
    ready = false,
    water_share = 0,
    land_ok = true,
    hover_ok = true,
    ship_ok = false,
    water_point = nil, -- the open water nearest the base, for shipyards
}

local grid_size = 32
local water_map = 0.5    -- share of water that makes a water map
local some_water = 0.05  -- share below which ships are not worth it
local water_reach = 1500 -- how far from the base a shipyard may stand

-- Where the enemies stand: their own starts when the match tells them
-- (fixed starts), otherwise every start that is not the seat's.
local function enemy_starts()
    local found = {}
    for _, row in ipairs(me:players()) do
        if row.player ~= me.player and not me:allied(row.player) and row.start_x ~= nil then
            found[#found + 1] = {x = util.whole(row.start_x), z = util.whole(row.start_z)}
        end
    end
    if #found > 0 then
        return found
    end
    local starts = game.map:starts()
    if type(starts) == "table" then
        for _, start in ipairs(starts) do
            local at = {x = util.whole(start.x), z = util.whole(start.z)}
            if world.start == nil or util.dist(at, world.start) > 600 then
                found[#found + 1] = at
            end
        end
    end
    return found
end

-- Whether `class` gets from `a` to `b`. Without full awareness
-- map:reachable counts ground the seat has never seen as open, so it is
-- only trusted when it says no; a yes is checked with map:route, which
-- reads the real movement map. A route is costly (tens of milliseconds on
-- a large map), so the survey asks one a turn. Maps past the route's cap
-- of 1 048 576 cells keep reachable's answer.
local route_cap = 1048576

-- map:reachable is no cheap first test: on a large map it cost more than
-- the route itself (Icy Bergs: about 2 s of the first 15 seconds per
-- seat, a lag every player saw), so only maps past the route's cap use it.
local function meets(a, b, class)
    local cells = (util.whole(game.map.world_width) // 16) * (util.whole(game.map.world_height) // 16)
    if cells > route_cap then
        local ok, near = pcall(function() return game.map:reachable(a, b, class) end)
        return ok and near == true, false
    end
    local found, route = pcall(function() return game.map:route(a, b, class) end)
    return found and route ~= nil, true
end

-- Whether a movement class gets from the base to the enemy: to every
-- enemy start, or to most of them when the starts are only guesses.
-- The survey fills this in, a class at a time.
-- A class that keeps to the water. Core's amphibious tier-3 ships
-- (Monitor, Inferno, Rancor: BOATA classes) also cross land, so they are
-- judged like ground units, by a route from base to base.
local function is_boat(class)
    local upper = string.upper(class)
    return string.find(upper, "BOAT", 1, true) ~= nil and string.find(upper, "BOATA", 1, true) == nil
end

local class_reach = {}
local class_hits = {}  -- class -> {asked, reached}
-- Boat class -> enemy number -> how close to that enemy's start the
-- class gets on the water (the nearest water point a route reached).
local ship_approach = {}
-- A ship whose weapons reach this far past the water's edge still
-- shells the base: buildings stand round the start.
local base_margin = 300

local function verdict(class)
    local hits = class_hits[class]
    if hits == nil then
        return nil
    end
    if terrain.targets_known then
        return hits.reached == #terrain.targets
    end
    return hits.reached * 2 > #terrain.targets
end

-- Whether the checks asked so far already settle a class: every target
-- must be reached when the starts are known, most of them when guessed.
local function settled(hits, total)
    local failed = hits.asked - hits.reached
    if terrain.targets_known then
        return failed > 0 or hits.reached == total
    end
    return hits.reached * 2 > total or failed * 2 >= total
end

function terrain.class_reaches(class)
    if class == nil or class == "" then
        return true
    end
    local known = class_reach[class]
    if known ~= nil then
        return known
    end
    local targets = terrain.targets or {}
    if #targets == 0 or world.start == nil then
        return true
    end
    if not terrain.ready then
        -- Not surveyed yet: assume it does, as the map line will tell.
        return true
    end
    -- A class the survey did not list: asked now, all at once.
    local from = {x = world.start.x, z = world.start.z}
    local reached = 0
    for _, target in ipairs(targets) do
        if meets(from, target, class) then
            reached = reached + 1
        end
    end
    class_hits[class] = {asked = #targets, reached = reached}
    class_reach[class] = verdict(class)
    return class_reach[class]
end

-- Whether a ship's weapons reach the enemy bases from the nearest water
-- its class sails to: at every enemy start when the starts are known,
-- at most of them when guessed. Not whether its hull gets there: a ship
-- that shells a base from the sea is worth building (user's rule).
function terrain.ship_hits_base(entry)
    if not terrain.ship_ok then
        return false
    end
    local class = entry.record.movementclass
    if not terrain.ready or type(class) ~= "string" then
        return true
    end
    local approach = ship_approach[class]
    local targets = terrain.targets or {}
    if approach == nil or #targets == 0 then
        return false
    end
    local hit = 0
    for number = 1, #targets do
        local d = approach[number]
        if d ~= nil and d <= entry.range + base_margin then
            hit = hit + 1
        end
    end
    if terrain.targets_known then
        return hit == #targets
    end
    return hit * 2 > #targets
end

-- Whether a unit type can reach the enemy on this map. Aircraft always
-- can; ships when the water near the base leads to water near the enemy.
function terrain.useful(entry)
    if entry.air then
        return true
    end
    local class = entry.record.movementclass
    if entry.water_only or (type(class) == "string" and is_boat(class)) then
        return terrain.ship_hits_base(entry)
    end
    if type(class) ~= "string" or class == "" then
        return true
    end
    return terrain.class_reaches(class)
end


-- The boat classes of the combat ships the seat's side can make, each
-- once, in type order.
local function boat_classes()
    local side = me.side_name
    local found, seen = {}, {}
    for index = 1, #units do
        local entry = catalog.types[index]
        local class = entry ~= nil and entry.record.movementclass
        if entry ~= nil and entry.combat and not entry.air and entry.water_only
            and type(class) == "string" and class ~= "" and is_boat(class)
            and (side == nil or entry.side == "" or entry.side == side) and not seen[class] then
            seen[class] = true
            found[#found + 1] = class
        end
    end
    return found
end

-- The ground movement classes of the combat units the seat's side can
-- make, each once, in type order.
local function ground_classes()
    local side = me.side_name
    local found, seen = {}, {}
    for index = 1, #units do
        local entry = catalog.types[index]
        local class = entry ~= nil and entry.record.movementclass
        if entry ~= nil and entry.combat and not entry.air and not entry.water_only
            and type(class) == "string" and class ~= "" and not is_boat(class)
            and (side == nil or entry.side == "" or entry.side == side) and not seen[class] then
            seen[class] = true
            found[#found + 1] = class
        end
    end
    return found
end

-- Whether most of a line's combat units reach the enemy, over every
-- factory of that line on the seat's side.
local function line_reaches(line)
    local side = me.side_name
    local total, good = 0, 0
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and entry.factory and entry.line == line
            and (side == nil or entry.side == "" or entry.side == side) then
            for _, built in ipairs(entry.builds) do
                if built.combat then
                    total = total + 1
                    if terrain.useful(built) then
                        good = good + 1
                    end
                end
            end
        end
    end
    return total > 0 and good * 2 >= total
end

-- The survey's questions: each ground class to each enemy start, then
-- each boat class from the water by the base to the three open-water
-- points nearest each enemy start (within a long reach; the nearest may
-- be a pond or shallows). Answered a route at a time.
local checks = nil
local next_check = 1
local ship_hits = {}  -- boat class -> {asked, reached}

local function plan_checks(waters)
    checks = {}
    next_check = 1
    local from = {x = world.start.x, z = world.start.z}
    -- First the water the seat builds on: the nearest open water that a
    -- hovercraft gets to from the base (the nearest may be a crater lake
    -- behind cliffs, or the sea beyond a rim no builder crosses).
    local hover
    for _, class in ipairs(ground_classes()) do
        if string.find(string.upper(class), "HOVER", 1, true) then
            hover = class
            break
        end
    end
    if hover ~= nil then
        local near = {}
        for _, water in ipairs(waters) do
            local d = util.dist(water, world.start)
            if d <= water_reach then
                near[#near + 1] = {x = water.x, z = water.z, d = d}
            end
        end
        table.sort(near, function(a, b) return a.d < b.d end)
        for index = 1, math.min(5, #near) do
            checks[#checks + 1] = {class = hover, from = from, to = {x = near[index].x, z = near[index].z}, water = true}
        end
    end
    for _, class in ipairs(ground_classes()) do
        class_hits[class] = {asked = 0, reached = 0}
        for _, target in ipairs(terrain.targets) do
            checks[#checks + 1] = {class = class, from = from, to = target}
        end
    end
    if not terrain.ship_ok then
        return
    end
    -- Only water deep and clear enough for that class counts: a cell that
    -- is mostly water may still be shallows a ship cannot enter.
    -- Answers are kept: on a sea map nearly every grid point is water, and
    -- asking each of them for every class and enemy took a first turn past
    -- 250 ms (Flooded Glaciers).
    local sail_memo = {}
    local function sails(boat, point)
        local key = boat .. ":" .. point.x .. "," .. point.z
        local known = sail_memo[key]
        if known == nil then
            local ok, pass = pcall(function() return game.map:passable(boat, point.x // 16, point.z // 16) end)
            known = ok and util.num(pass) >= 3
            sail_memo[key] = known
        end
        return known
    end
    -- Water points are looked for as far from each enemy start as the
    -- longest-ranged ship can shoot.
    local longest = 0
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and entry.combat and entry.water_only and not entry.torpedo_only then
            longest = math.max(longest, entry.range)
        end
    end
    local radius = math.max(2500, math.min(6000, longest + base_margin))
    for _, boat in ipairs(boat_classes()) do
        ship_hits[boat] = {asked = #terrain.targets, reached = 0, failed = 0}
        ship_approach[boat] = {}
        local from, from_d
        for _, water in ipairs(waters) do
            local d = util.dist(water, world.start)
            if d <= water_reach and (from_d == nil or d < from_d) and sails(boat, water) then
                from, from_d = water, d
            end
        end
        if from ~= nil then
            for number, target in ipairs(terrain.targets) do
                -- The water points nearest the enemy first; only the first
                -- five a ship of this class sails on are asked.
                local by_distance = {}
                for _, water in ipairs(waters) do
                    local d = util.dist(water, target)
                    if d <= radius then
                        by_distance[#by_distance + 1] = {x = water.x, z = water.z, d = d}
                    end
                end
                table.sort(by_distance, function(a, b) return a.d < b.d end)
                local near = {}
                for _, water in ipairs(by_distance) do
                    if #near >= 5 then
                        break
                    end
                    if sails(boat, water) then
                        near[#near + 1] = water
                    end
                end
                local last = #near
                for index = 1, last do
                    checks[#checks + 1] = {class = boat, from = from,
                        to = {x = near[index].x, z = near[index].z}, ship = number, last = index == last,
                        d = near[index].d}
                end
                if last == 0 then
                    ship_hits[boat].failed = ship_hits[boat].failed + 1
                end
            end
        end
    end
end

-- Answers survey questions until one has needed a route. A ship check
-- is skipped once another water point by the same enemy was reached.
local ship_done = {}  -- boat class .. enemy number -> reached

local function skip(check)
    if check.water then
        return terrain.water_found == true
    end
    if check.ship then
        local hits = ship_hits[check.class]
        local total = #terrain.targets
        return ship_done[check.class .. "#" .. check.ship]
    end
    return settled(class_hits[check.class], #terrain.targets)
end

local function run_checks()
    while next_check <= #checks do
        local check = checks[next_check]
        next_check = next_check + 1
        local key = check.ship and (check.class .. "#" .. check.ship)
        if not skip(check) then
            local ok, routed = meets(check.from, check.to, check.class)
            if check.water then
                if ok then
                    terrain.water_found = true
                    terrain.water_point = check.to
                    terrain.shore = terrain.shore_toward(check.to)
                end
            elseif check.ship then
                if ok then
                    ship_done[key] = true
                    ship_hits[check.class].reached = ship_hits[check.class].reached + 1
                    ship_approach[check.class][check.ship] = check.d
                elseif check.last then
                    ship_hits[check.class].failed = ship_hits[check.class].failed + 1
                end
            else
                local hits = class_hits[check.class]
                hits.asked = hits.asked + 1
                if ok then
                    hits.reached = hits.reached + 1
                end
            end
            if routed then
                return false
            end
        end
    end
    return true
end

-- Reads the map once the seat knows where it stands; the reach questions
-- take a turn per route, so the map line comes some seconds in.
function terrain.survey()
    if terrain.ready or world.start == nil then
        return
    end
    if checks == nil then
        local grid = brain.grid({"water"}, grid_size)
        if grid == nil then
            return
        end
        local width = util.whole(game.map.world_width)
        local height = util.whole(game.map.world_height)
        local total, nearest, nearest_d = 0, nil, nil
        local waters = {}
        for index = 0, grid_size * grid_size - 1 do
            local share = util.num(grid:get(index + 1))
            total = total + share
            if share > 0.6 then
                local point = {
                    x = (index % grid_size) * width // grid_size + width // (2 * grid_size),
                    z = (index // grid_size) * height // grid_size + height // (2 * grid_size),
                }
                waters[#waters + 1] = point
                local d = util.dist(point, world.start)
                if d <= water_reach and (nearest_d == nil or d < nearest_d) then
                    nearest, nearest_d = point, d
                end
            end
        end
        terrain.water_share = total / (grid_size * grid_size)
        terrain.water_point = nearest
        terrain.shore = nearest and terrain.shore_toward(nearest)
        terrain.targets = enemy_starts()
        terrain.targets_known = false
        for _, row in ipairs(me:players()) do
            if row.player ~= me.player and row.start_x ~= nil then
                terrain.targets_known = true
            end
        end
        terrain.ship_ok = nearest ~= nil and terrain.water_share >= some_water
        plan_checks(waters)
    end
    if not run_checks() then
        return
    end
    for class, _ in pairs(class_hits) do
        class_reach[class] = verdict(class)
    end
    terrain.ready = true
    terrain.land_ok = line_reaches("kbot") or line_reaches("vehicle")
    terrain.hover_ok = line_reaches("hover")
    -- Ships count when some ship of the side shells the enemy bases from
    -- the water its class reaches (not torpedo boats: they hit nothing
    -- on land).
    local ships_through, seen_boat = {}, {}
    local side = me.side_name
    for index = 1, #units do
        local entry = catalog.types[index]
        local class = entry ~= nil and entry.record.movementclass
        if entry ~= nil and entry.combat and entry.water_only and not entry.torpedo_only
            and type(class) == "string" and is_boat(class)
            and (side == nil or entry.side == "" or entry.side == side)
            and terrain.ship_hits_base(entry) and not seen_boat[class] then
            seen_boat[class] = true
            ships_through[#ships_through + 1] = class
        end
    end
    terrain.ship_reaches = terrain.ship_ok and #ships_through > 0
    local through = {}
    for _, class in ipairs(ground_classes()) do
        if class_reach[class] then
            through[#through + 1] = class
        end
    end
    for _, boat in ipairs(ships_through) do
        through[#through + 1] = boat
    end
    print(string.format("map: water %.0f%%, enemy by land %s, by hover %s, ships %s (reach %s), %d enemy starts%s; classes through: %s",
        terrain.water_share * 100, tostring(terrain.land_ok), tostring(terrain.hover_ok),
        tostring(terrain.ship_ok), tostring(terrain.ship_reaches), #terrain.targets,
        terrain.targets_known and "" or " guessed", #through > 0 and table.concat(through, " ") or "none"))
end

-- The edge of the water at `water` nearest the base: from the water point
-- toward the base, the last point still under the sea. Water buildings go
-- there, close to the land, where builders that cannot sail reach them;
-- walking from the water side keeps to that body of water, not a lake
-- the straight line crosses first.
function terrain.shore_toward(water)
    local home = world.base or world.start
    if home == nil then
        return water
    end
    local sea = util.num(game.map.sea_level)
    local d = util.dist(home, water)
    local last = water
    local step = 0
    while step <= d do
        local at = util.toward(water, home, step)
        local ok, ground = pcall(function() return game.map:ground(util.whole(at.x), util.whole(at.z)) end)
        if not ok or ground == nil or util.num(ground) < 0 or util.num(ground) >= sea - 4 then
            break
        end
        last = {x = util.whole(at.x), z = util.whole(at.z)}
        step = step + 32
    end
    return last
end

-- Whether a point lies under the sea (an underwater deposit).
function terrain.under_water(point)
    local ok, ground = pcall(function() return game.map:ground(util.whole(point.x), util.whole(point.z)) end)
    return ok and ground ~= nil and util.num(ground) >= 0 and util.num(ground) < util.num(game.map.sea_level)
end

-- Whether a line's units reach the enemy on this map.
function terrain.line_ok(line)
    if line == "kbot" or line == "vehicle" then
        return terrain.land_ok
    end
    if line == "hover" then
        return terrain.hover_ok
    end
    if line == "ship" then
        return terrain.ship_reaches == true
    end
    return true
end

-- How much a line is wanted on this map: 0 is the most, higher is less,
-- nil means not at all.
function terrain.rank(line)
    if line == "ship" and not terrain.ship_ok then
        return nil
    end
    if not terrain.land_ok and not terrain.hover_ok then
        local order = {air = 0, ship = 1, hover = 2, kbot = 3, vehicle = 3}
        return order[line]
    end
    if not terrain.land_ok then
        -- Across water: hovercraft, and ships when they reach, then aircraft.
        -- Ships that shell the enemy from the sea come first, then
        -- hovercraft (on a sea map the hover line used to win the tie).
        local order = {hover = terrain.ship_reaches and 1 or 0, ship = terrain.ship_reaches and 0 or 2,
            air = terrain.ship_reaches and 2 or 1, kbot = 3, vehicle = 3}
        return order[line]
    end
    if terrain.water_share > water_map then
        local order = {kbot = 0, vehicle = 0, ship = 0, air = 1, hover = 3}
        return order[line]
    end
    local order = {kbot = 0, vehicle = 0, air = 1, ship = 2, hover = 3}
    return order[line]
end

return terrain
