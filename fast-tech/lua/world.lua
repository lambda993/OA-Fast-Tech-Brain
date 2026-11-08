-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- What the seat knows: its own units by role, the base, the tier it has
-- reached, and a memory of enemy buildings and contacts, since a seat
-- without full awareness forgets what leaves its sight.

local catalog = require("catalog")
local util = require("util")

local world = {
    wrecks = {},        -- wrecks left in the base: {x, z, size, tick}
    salvage = {},       -- wrecks near the base worth reclaiming: {x, z, metal, tick}
    tier = 0,
    own = {},           -- id -> unit, every live unit of the seat
    enemy_buildings = {}, -- id -> {x, z, tier, cost, tick}
    contacts = {},      -- recent radar or sight positions of enemies
    alarm = nil,        -- {x, z, tick} where the base was last hit
    start = nil,
    base = nil,
}

function world.reset()
    world.tier = 0
    world.own = {}
    world.enemy_buildings = {}
    world.contacts = {}
    world.alarm = nil
    world.find_start()
    me:each_unit(function(unit)
        world.own[unit.id] = unit
    end)
end

function world.find_start()
    world.start = nil
    local players = me:players()
    for _, row in ipairs(players) do
        if row.player == me.player and row.start_x ~= nil then
            world.start = {x = util.whole(row.start_x), z = util.whole(row.start_z)}
        end
    end
    if world.start == nil then
        me:each_unit(function(unit)
            local entry = catalog.of(unit)
            if world.start == nil and entry and entry.commander then
                world.start = util.pos(unit)
            end
        end)
    end
    world.base = world.start
end

-- Whether the seat knows where it stands. A seat opened before the
-- players are placed has no start and no commander yet, so the start is
-- looked for again each turn until it is known.
function world.located()
    if world.start == nil then
        world.find_start()
        if world.start ~= nil then
            print(string.format("start found at %d,%d", world.start.x, world.start.z))
        end
    end
    return world.start ~= nil
end

-- The seat's live units with their entries, sorted by id, built once a
-- tick: world.select is called dozens of times a turn (placement checks
-- run it per candidate site) and used to walk and sort every unit each
-- time.
local own_tick, own_list = -1, {}

local function own_units()
    if own_tick == me.tick then
        return own_list
    end
    local found = {}
    for id, unit in pairs(world.own) do
        if not util.alive(unit) then
            world.own[id] = nil
        else
            local entry = catalog.of(unit)
            if entry ~= nil then
                found[#found + 1] = {unit = unit, entry = entry}
            end
        end
    end
    table.sort(found, function(a, b) return a.unit.id < b.unit.id end)
    own_tick, own_list = me.tick, found
    return found
end

-- Units of the seat that `test(unit, entry)` accepts.
function world.select(test)
    local found = {}
    for _, row in ipairs(own_units()) do
        local unit = row.unit
        if unit.alive == true and test(unit, row.entry) then
            found[#found + 1] = unit
        end
    end
    return found
end

function world.finished(unit)
    return unit.finished == true
end

-- The base is the middle of the seat's buildings, or its start.
function world.update_base()
    if not world.located() then
        return
    end
    -- The middle of the buildings round the start. Extractors on far
    -- deposits and buildings put far out for want of room pulled it 1 100
    -- units away (A tale of two cities), and the commander, sent home,
    -- went there.
    local sum_x, sum_z, count = 0, 0, 0
    for _, unit in ipairs(world.select(function(u, e) return e.structure and not e.extractor and world.finished(u) end)) do
        local at = util.pos(unit)
        if at and util.dist(at, world.start) <= 1500 then
            sum_x, sum_z, count = sum_x + at.x, sum_z + at.z, count + 1
        end
    end
    if count >= 3 then
        world.base = {x = sum_x // count, z = sum_z // count}
    else
        world.base = world.start
    end
end

-- The highest factory tier the seat has finished.
function world.update_tier()
    local tier = 0
    for _, unit in ipairs(world.select(function(u, e) return e.factory and world.finished(u) end)) do
        local entry = catalog.of(unit)
        tier = math.max(tier, catalog.factory_tier(entry))
    end
    if tier > world.tier then
        print("tier " .. world.tier .. " -> " .. tier)
    end
    world.tier = tier
end

-- Enemy memory --------------------------------------------------------------

function world.remember(unit)
    if not util.enemy(unit) then
        return
    end
    local at = util.pos(unit)
    if at == nil then
        return
    end
    local entry = catalog.of(unit)
    if entry ~= nil and entry.air and entry.combat then
        world.enemy_air = true
    end
    if entry ~= nil and entry.structure then
        world.enemy_buildings[unit.id] = {
            x = at.x, z = at.z, tier = entry.tier, cost = entry.cost, tick = me.tick,
            unit = unit, factory = entry.factory, commander = false, entry = entry,
            anti_air = world.anti_air(entry),
        }
    end
    -- Where the enemy stands, for the waves: not aircraft passing by, nor
    -- what lies under the sea.
    if entry == nil or not (entry.air or entry.tags.underwater) then
        world.note_contact(at)
    end
end

function world.note_contact(at)
    world.contacts[#world.contacts + 1] = {x = at.x, z = at.z, tick = me.tick}
    if #world.contacts > 64 then
        table.remove(world.contacts, 1)
    end
end

function world.forget(unit)
    world.enemy_buildings[unit.id] = nil
    world.sightings[unit.id] = nil
end

-- Remembers a large wreck left near the base, to clear it later.
function world.note_wreck(entry, wreck)
    if wreck == nil or wreck.x == nil or world.base == nil then
        return
    end
    local at = {x = util.whole(wreck.x), z = util.whole(wreck.z)}
    -- Any wreck within reach of the base is salvage for lean times; its
    -- metal is taken as half the unit's cost.
    local worth = entry ~= nil and entry.metal * 0.5 or 0
    if worth >= 25 and util.dist(at, world.base) <= 3000 then
        world.salvage[#world.salvage + 1] = {x = at.x, z = at.z, metal = worth, tick = me.tick}
        if #world.salvage > 80 then
            table.remove(world.salvage, 1)
        end
    end
    if util.dist(at, world.base) > 2500 then
        return
    end
    if entry ~= nil and (entry.metal >= 500 or entry.footprint >= 4) then
        world.wrecks[#world.wrecks + 1] = {x = at.x, z = at.z, size = entry.footprint, tick = me.tick}
        if #world.wrecks > 40 then
            table.remove(world.wrecks, 1)
        end
    end
end

-- Drops remembered buildings whose place the seat sees again empty.
function world.prune()
    for id, seen in pairs(world.sightings) do
        if me.tick - seen.tick > 30 * 120 then
            world.sightings[id] = nil
        end
    end
    for id, building in pairs(world.enemy_buildings) do
        local gone = building.unit ~= nil and building.unit.alive == false
        if not gone and me:sees(building.x, building.z) then
            gone = not me:sees_unit(building.unit)
        end
        if gone then
            world.enemy_buildings[id] = nil
        end
    end
    local keep = {}
    for _, contact in ipairs(world.contacts) do
        if me.tick - contact.tick < 30 * 120 then
            keep[#keep + 1] = contact
        end
    end
    world.contacts = keep
end

-- Live enemies the seat sees now.
-- Built once a tick: every unit of the army asks for it.
local visible_tick, visible_list = -1, {}

function world.visible_enemies()
    if visible_tick == me.tick then
        return visible_list
    end
    local found = {}
    local seen = me.seen
    if type(seen) ~= "table" then
        return found
    end
    for index = 1, #seen do
        local unit = seen[index]
        if util.alive(unit) and util.enemy(unit) then
            found[#found + 1] = unit
        end
    end
    visible_tick, visible_list = me.tick, found
    return found
end

-- How much an enemy is worth shooting first, whoever shoots: commanders and
-- decoys (they look alike, so both count as commanders), then threat level
-- 4 and 5, threat level 3, anti-air (it keeps the seat's aircraft away), the
-- economy, and the rest. A shooter's own list comes first (world.rank).
world.commander_priority = 6

function world.anti_air(entry)
    return entry ~= nil and entry.anti_air and (entry.defense or entry.combat)
end

function world.priority(entry)
    if entry == nil then
        return 1
    end
    if entry.commander or entry.decoy then
        return 6
    end
    if entry.threat >= 4 then
        return 5
    end
    if entry.threat == 3 then
        return 4
    end
    if world.anti_air(entry) then
        return 3
    end
    -- The economy, the factories and the builders.
    if entry.extractor or entry.power or entry.metal_maker or entry.factory
        or entry.metal_storage or entry.energy_storage or entry.mobile_builder then
        return 2
    end
    return 1
end

-- Where `target` stands in the shooter's own list of priority targets: the
-- index of the first of its tags on the list, or false.
local function list_place(shooter, target)
    local places = shooter.list_places
    if places == nil then
        places = {}
        shooter.list_places = places
    end
    local place = places[target.unit_name]
    if place == nil then
        place = false
        for index, token in ipairs(shooter.first_targets) do
            if target.tags[token] then
                place = index
                break
            end
        end
        places[target.unit_name] = place
    end
    return place
end

local tier_tokens = {t1 = true, t2 = true, t3 = true, t4 = true, t5 = true}

-- The table's rules for one pair of types. `attack_only` is a closed list.
-- `underwater` among the ignored always wins; otherwise being on the
-- priority list wins over being ignored (a tier on the list does not: it
-- orders targets and picks none out).
local function table_allows(shooter, target)
    local tags = target.tags
    for _, token in ipairs(shooter.ignored) do
        if token == "underwater" and tags.underwater then
            return false
        end
    end
    if #shooter.only > 0 then
        local listed = false
        for _, token in ipairs(shooter.only) do
            listed = listed or tags[token] == true
        end
        if not listed then
            return false
        end
    end
    for _, token in ipairs(shooter.first_targets) do
        if tags[token] and not tier_tokens[token] then
            return true
        end
    end
    for _, token in ipairs(shooter.ignored) do
        if tags[token] then
            return false
        end
    end
    return true
end

local function allowed(shooter, target)
    local answers = shooter.allowed_targets
    if answers == nil then
        answers = {}
        shooter.allowed_targets = answers
    end
    local answer = answers[target.unit_name]
    if answer == nil then
        answer = table_allows(shooter, target)
        answers[target.unit_name] = answer
    end
    return answer
end

-- What `target` is worth to this shooter: a bomber takes anti-air first
-- (the user's rule, above the table), then the shooter's own list in order,
-- then world.priority.
function world.rank(shooter, target)
    if target == nil then
        return 1
    end
    if shooter ~= nil then
        if shooter.bomber and world.anti_air(target) then
            return 40
        end
        local place = list_place(shooter, target)
        if place then
            return 30 - place
        end
    end
    return world.priority(target)
end

-- Whether `shooter` (a catalog entry, or nil for any) can fire at `target`:
-- only anti-air weapons hit aircraft, and only other weapons hit the rest,
-- within what the user's table lets it shoot.
function world.can_hit(shooter, target)
    if shooter == nil or target == nil then
        return true
    end
    -- (Aircraft only for paralyzers without anti-air: none in Escalation
    -- has any, Mirage and Scorpion included.)
    if shooter.paralyzer and (target.immune or (target.air and not shooter.anti_air)) then
        return false
    end
    if not allowed(shooter, target) then
        return false
    end
    if target.air then
        return shooter.anti_air == true
    end
    return shooter.hits_ground == true
end

-- Amphibious units under water count as `underwater`: a shooter that ignores
-- those cannot hit them there (a non-water weapon never hits a submerged
-- unit).
local function out_of_reach_below(shooter, row)
    if shooter == nil or row.entry == nil or not row.entry.tags.amphibious or row.entry.air then
        return false
    end
    local below = false
    for _, token in ipairs(shooter.ignored) do
        below = below or token == "underwater"
    end
    if not below then
        return false
    end
    local ok, ground = pcall(function() return game.map:ground(util.whole(row.x), util.whole(row.z)) end)
    return ok and ground ~= nil and util.num(ground) >= 0 and util.num(ground) < util.num(game.map.sea_level)
end

local function under_sea(point)
    local ok, ground = pcall(function() return game.map:ground(util.whole(point.x), util.whole(point.z)) end)
    return ok and ground ~= nil and util.num(ground) < util.num(game.map.sea_level)
end

-- An amphibious unit with no water weapon cannot fire from under the sea:
-- sent at a target out on the water it walked the sea floor beneath it,
-- unable to shoot (user's game). Such a target is only worth it when there
-- is dry ground within the shooter's reach of it, on the side it comes
-- from.
local function fires_only_dry(shooter)
    return shooter ~= nil and shooter.tags.amphibious and not shooter.water_weapon
        and not shooter.tags.hovercraft and not shooter.air
end

local function no_dry_ground(shooter, from, row)
    if not fires_only_dry(shooter) or not under_sea(row) then
        return false
    end
    local reach = math.max(64, shooter.ground_range > 0 and shooter.ground_range or shooter.range) * 0.85
    if util.dist(from, row) <= reach then
        return under_sea(from)
    end
    return under_sea(util.toward(row, from, reach))
end

-- Whether `shooter` (an entry) standing at `from` cannot get a shot at the
-- enemy record `row` ({x, z, entry}) for where it is: a submerged amphibious
-- target for a shooter that ignores underwater units, a target on the water
-- with no dry ground near for an amphibious shooter without water weapons.
function world.out_of_reach(shooter, from, row)
    return out_of_reach_below(shooter, row) or no_dry_ground(shooter, from, row)
end

-- Enemies and friends in sight, as records {unit, x, z, entry} in a grid
-- of 512-unit squares, built once a tick. Every unit of the army asks for
-- a target; reading positions (f32 values) and entries for every enemy
-- for every shooter cost tens of thousands of calls a step in big fights.
local grid_size = 512
local index_tick = -1
local enemy_rows, enemy_cells = {}, {}
local friend_tick = -1
local friend_cells = {}

local function cell_key(x, z)
    return (x // grid_size) * 65536 + (z // grid_size)
end

local function add_row(cells, row)
    local key = cell_key(row.x, row.z)
    local list = cells[key]
    if list == nil then
        list = {}
        cells[key] = list
    end
    list[#list + 1] = row
end

-- Enemies seen of priority 3 and up (anti-air, tier 3+, commanders):
-- where and when last seen, so units keep after them a while once they
-- slip into the fog (they used to switch targets at once).
world.sightings = {} -- enemy id -> {x, z, tick, priority}
local enemy_ids = {}

function world.enemy_row(id)
    world.enemy_rows()
    return enemy_ids[id]
end

function world.enemy_rows()
    if index_tick == me.tick then
        return enemy_rows
    end
    enemy_rows, enemy_cells, enemy_ids = {}, {}, {}
    for _, enemy in ipairs(world.visible_enemies()) do
        local at = util.pos(enemy)
        local entry = catalog.of(enemy)
        if at ~= nil then
            local row = {unit = enemy, x = at.x, z = at.z, entry = entry}
            enemy_rows[#enemy_rows + 1] = row
            enemy_ids[enemy.id] = row
            add_row(enemy_cells, row)
            local priority = world.priority(entry)
            if priority >= 3 and entry ~= nil and not entry.structure then
                world.sightings[enemy.id] = {x = at.x, z = at.z, tick = me.tick, priority = priority, entry = entry}
            end
        end
    end
    index_tick = me.tick
    return enemy_rows
end

-- Calls fn(row) for every record of `cells` in the squares within `reach`
-- of `from`, until fn returns true.
local function each_near(cells, from, reach, fn)
    local x0, x1 = (from.x - reach) // grid_size, (from.x + reach) // grid_size
    local z0, z1 = (from.z - reach) // grid_size, (from.z + reach) // grid_size
    for gx = x0, x1 do
        for gz = z0, z1 do
            local list = cells[gx * 65536 + gz]
            if list ~= nil then
                for index = 1, #list do
                    if fn(list[index]) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Enemies within `reach` of `from`, as records.
function world.enemies_near(from, reach)
    world.enemy_rows()
    local found = {}
    local limit = reach * reach
    each_near(enemy_cells, from, reach, function(row)
        local dx, dz = row.x - from.x, row.z - from.z
        if dx * dx + dz * dz <= limit then
            found[#found + 1] = row
        end
    end)
    return found
end

-- Own and allied units, built once a tick when asked.
local function friend_index()
    if friend_tick == me.tick then
        return friend_cells
    end
    friend_cells = {}
    for _, row in ipairs(own_units()) do
        local at = util.pos(row.unit)
        if at ~= nil then
            add_row(friend_cells, {unit = row.unit, x = at.x, z = at.z, entry = row.entry})
        end
    end
    local seen = me.seen
    if type(seen) == "table" then
        for index = 1, #seen do
            local unit = seen[index]
            local owner = unit ~= nil and unit.owner
            if owner ~= nil and owner ~= me.player and me:allied(owner) == true and util.alive(unit) then
                local at = util.pos(unit)
                if at ~= nil then
                    add_row(friend_cells, {unit = unit, x = at.x, z = at.z, entry = catalog.of(unit), ally = true})
                end
            end
        end
    end
    friend_tick = me.tick
    return friend_cells
end

-- Whether an own or allied unit (aircraft aside: they fly over the blast)
-- stands within `radius` of `point`.
function world.friends_near(point, radius)
    local limit = radius * radius
    return each_near(friend_index(), point, radius, function(row)
        if row.entry ~= nil and row.entry.air then
            return false
        end
        local dx, dz = row.x - point.x, row.z - point.z
        return dx * dx + dz * dz <= limit
    end)
end

-- Own and allied ground units within `reach` of `from`, as records.
function world.friends_in(from, reach)
    local found = {}
    local limit = reach * reach
    each_near(friend_index(), from, reach, function(row)
        local dx, dz = row.x - from.x, row.z - from.z
        if dx * dx + dz * dz <= limit then
            found[#found + 1] = row
        end
    end)
    return found
end

-- The visible enemy to shoot from `from` within `reach`: the highest
-- priority, the nearest among equals. A commander is chased twice as far,
-- so everything near one turns on it. With `shooter` (the catalog entry of
-- the unit that fires) only what it can hit counts, in its own order
-- (world.rank). An area weapon leaves out ground targets with an own or
-- allied unit within its blast.
function world.best_target(from, reach, shooter)
    world.enemy_rows()
    local best, best_key
    local blast = shooter ~= nil and shooter.blast or 0
    each_near(enemy_cells, from, reach * 2, function(row)
        local entry = row.entry
        if world.can_hit(shooter, entry) then
            local priority = world.rank(shooter, entry)
            local limit = world.priority(entry) == world.commander_priority and reach * 2 or reach
            local dx, dz = row.x - from.x, row.z - from.z
            local d2 = dx * dx + dz * dz
            if d2 <= limit * limit then
                local key = priority * 100000 - math.sqrt(d2)
                if (best_key == nil or key > best_key)
                    and (blast <= 0 or (entry ~= nil and entry.air) or not world.friends_near(row, blast))
                    and not world.out_of_reach(shooter, from, row) then
                    best, best_key = row.unit, key
                end
            end
        end
    end)
    return best
end

-- Whether `entry` leaves submerged units alone (no anti-sub weapon: the
-- table puts `underwater` among its ignored).
function world.ignores_underwater(entry)
    if entry == nil then
        return false
    end
    if entry.no_subs == nil then
        entry.no_subs = false
        for _, token in ipairs(entry.ignored) do
            if token == "underwater" then
                entry.no_subs = true
            end
        end
    end
    return entry.no_subs
end

-- What a contact (no type, only a place) most likely is: in the air (well
-- above the ground or the sea), under the sea (below the surface over sea
-- floor: an underwater extractor, a submarine), or on the ground.
function world.contact_place(contact, at)
    local y = util.num(contact.y)
    local ok, ground = pcall(function() return game.map:ground(at.x, at.z) end)
    ground = ok and ground ~= nil and util.num(ground) or y
    local sea = util.num(game.map.sea_level)
    local surface = math.max(ground, sea)
    if y > surface + 40 then
        return "air"
    end
    if ground < sea and y < sea - 4 then
        return "under"
    end
    return "ground"
end

-- Contacts that stood still: sampled every army step (three seconds) in
-- 96-unit squares; a square held without a break for fifteen seconds is
-- most likely a building. A long-range gun shelled where moving radar
-- blips had been, empty ground by the time the shell came down (user's
-- game: a Big Bertha firing at nothing).
world.still = {} -- square key -> {x, z, first, last}
local still_square = 96
local still_needed = 30 * 15

function world.track_contacts()
    local contacts = me.radar
    local seen = {}
    if type(contacts) == "table" then
        for index = 1, #contacts do
            local contact = contacts[index]
            if contact ~= nil and contact.x ~= nil and contact.current ~= false then
                local x, z = util.whole(contact.x), util.whole(contact.z)
                local key = (x // still_square) * 65536 + (z // still_square)
                if not seen[key] and world.contact_place(contact, {x = x, z = z}) ~= "air" then
                    seen[key] = true
                    local held = world.still[key]
                    if held == nil then
                        world.still[key] = {x = x, z = z, first = me.tick, last = me.tick}
                    else
                        held.last = me.tick
                    end
                end
            end
        end
    end
    for key in pairs(world.still) do
        if not seen[key] then
            world.still[key] = nil
        end
    end
end

-- The radar or sonar contact nearest `from` within `reach`, as a point,
-- for when nothing in sight is worth shooting. With `shooter` (an entry)
-- only contacts it could hit count: aircraft for anti-air only, contacts
-- under the sea not for a shooter without anti-sub weapons (Hurricanes
-- circled a sonar contact, an underwater extractor, they could never
-- bomb). With `still` only contacts that stood still (world.still).
function world.nearest_contact(from, reach, shooter, still)
    local contacts = me.radar
    if type(contacts) ~= "table" then
        return nil
    end
    local best, best_d
    for index = 1, #contacts do
        local contact = contacts[index]
        if contact ~= nil and contact.x ~= nil and contact.current ~= false then
            local at = {x = util.whole(contact.x), z = util.whole(contact.z)}
            local d = util.dist(from, at)
            if d <= reach and (best_d == nil or d < best_d) then
                local fits = true
                if shooter ~= nil then
                    local place = world.contact_place(contact, at)
                    if place == "air" then
                        fits = shooter.anti_air == true
                    elseif place == "under" then
                        fits = not world.ignores_underwater(shooter)
                    else
                        fits = shooter.hits_ground == true
                    end
                end
                if fits and still then
                    local held = world.still[(at.x // still_square) * 65536 + (at.z // still_square)]
                    fits = held ~= nil and held.last - held.first >= still_needed
                end
                if fits then
                    best, best_d = at, d
                end
            end
        end
    end
    return best
end

-- Start positions that may hold an enemy and are not yet explored.
function world.unexplored_starts()
    local found = {}
    local starts = game.map:starts()
    if type(starts) ~= "table" then
        return found
    end
    for _, start in ipairs(starts) do
        local at = {x = util.whole(start.x), z = util.whole(start.z)}
        local own = world.start ~= nil and util.dist(at, world.start) < 600
        if not own then
            local explored = me.explored
            local known = false
            if explored ~= nil then
                local cx, cz = explored:cell_of(at.x, at.z)
                if cx ~= nil then
                    known = explored:at(cx, cz) == true
                end
            end
            if not known then
                found[#found + 1] = at
            end
        end
    end
    return found
end

-- Where the enemy most likely is: the closest remembered building, a
-- recent contact, or an unexplored start.
function world.enemy_target(from)
    local best, best_d
    for _, building in pairs(world.enemy_buildings) do
        -- Underwater buildings (extractors on the sea floor) only for
        -- anti-sub units: a wave sent to one circled it, unable to hit it.
        local under = building.entry ~= nil and building.entry.tags.underwater
        local d = util.dist2(from, building)
        if building.factory then
            d = d * 0.5
        end
        if not under and (best_d == nil or d < best_d) then
            best, best_d = {x = building.x, z = building.z}, d
        end
    end
    if best ~= nil then
        return best
    end
    for index = #world.contacts, 1, -1 do
        local contact = world.contacts[index]
        if me.tick - contact.tick < 30 * 60 then
            return {x = contact.x, z = contact.z}
        end
    end
    local starts = world.unexplored_starts()
    for _, at in ipairs(starts) do
        local d = util.dist2(from, at)
        if best_d == nil or d < best_d then
            best, best_d = at, d
        end
    end
    return best
end

-- The side of the base that faces the enemy, for radar, defences and rally.
function world.front(distance)
    local base = world.base or world.start
    local target = world.enemy_target(base)
    if target == nil then
        target = {x = util.whole(game.map.world_width) // 2, z = util.whole(game.map.world_height) // 2}
    end
    return util.clamp(util.toward(base, target, distance), 96)
end

-- Factory doors ---------------------------------------------------------------

-- The ground in front of and behind each finished factory, along the axis
-- its units leave by, is kept clear (user's game on Ror Shock: factories
-- stood blocked by builders and units waiting nearby). The rally point and
-- the builders' parking spots keep out of it, and idle units standing in it
-- are moved aside (army.lua). Aircraft plants have no lane.
local lane_length = 240 -- past the factory's edge
local lane_side = 48    -- past its sides
local lanes_tick, lanes = -1, {}

local function factory_lanes()
    if lanes_tick == me.tick then
        return lanes
    end
    lanes = {}
    for _, unit in ipairs(world.select(function(u, e) return e.factory and e.line ~= "air" and world.finished(u) end)) do
        local at = util.pos(unit)
        local entry = catalog.of(unit)
        if at ~= nil then
            local quarter = ((util.num(unit.heading) % 65536) + 8192) // 16384 % 4
            lanes[#lanes + 1] = {
                x = at.x, z = at.z,
                half = math.max(util.num(entry.record.footprintx), util.num(entry.record.footprintz)) * 8,
                axis = quarter % 2 == 0 and "z" or "x",
            }
        end
    end
    lanes_tick = me.tick
    return lanes
end

-- The factory lane `point` stands in, or nil.
function world.in_factory_way(point)
    for _, lane in ipairs(factory_lanes()) do
        local dx, dz = math.abs(point.x - lane.x), math.abs(point.z - lane.z)
        local along, across = dz, dx
        if lane.axis == "x" then
            along, across = dx, dz
        end
        if across < lane.half + lane_side and along < lane.half + lane_length then
            return lane
        end
    end
    return nil
end

-- `point`, or the nearest point round it out of every factory lane.
function world.clear_spot(point)
    if world.in_factory_way(point) == nil then
        return point
    end
    for ring = 1, 4 do
        for step = 0, 7 do
            local spot = util.clamp(util.around(point, step / 8, ring * 120), 64)
            if world.in_factory_way(spot) == nil then
                return spot
            end
        end
    end
    return point
end

-- Where a unit standing in a factory lane steps to: straight out of the
-- lane's side, the nearer one.
function world.out_of_lane(point, lane)
    local margin = lane.half + lane_side + 80
    if lane.axis == "z" then
        local side = point.x >= lane.x and 1 or -1
        return util.clamp({x = lane.x + side * margin, z = point.z}, 64)
    end
    local side = point.z >= lane.z and 1 or -1
    return util.clamp({x = point.x, z = lane.z + side * margin}, 64)
end

return world
