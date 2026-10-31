-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- The base as a city grid. Square blocks, as wide as the largest factory
-- the side can build, are separated by streets as wide as its widest
-- ground unit, so even the largest units pass. Nothing is built on a
-- street, and blocks on poor ground (cliffs, lava, water) are left out.
-- Factories stand toward the front, power and storage behind the base. Factories take blocks of their own, at the corners with their
-- doors on the street; every other building goes in the other blocks,
-- packed from the corner. Buildings that gain from a neighbour of their
-- kind (fusion reactors, energy storage, resource generators, forges and
-- vaults) are put side by side, edge to edge, never corner to corner.
-- Only extractors may stand on metal.

local catalog = require("catalog")
local util = require("util")
local world = require("world")

local city = {
    ready = false,
    block = 24,   -- cells
    street = 14,  -- cells
    origin = nil, -- cell of block (0, 0)'s top-left corner
    pending = {}, -- rectangles ordered lately, before their frame appears
    crowded = {}, -- middles of explored blocks where a building found no site
}

local cell = 16
local rings = 4
local site_checks = 160
local alley = 3          -- free cells kept round a town building; set from the builders
local fill_cap = 0.6     -- share of a town block buildings may cover

-- Families that gain from an adjacent building of their own family, by
-- words in the name. Escalation gives the bonus in unit scripts, so the
-- data carries no flag for it.
local families = {
    {name = "fusion", words = {"FUSION"}},
    {name = "energy-storage", words = {"ENERGY STORAGE", "COMBINED STORAGE"}},
    {name = "resource", words = {"RESOURCE GENERATOR", "RESOURCE POWERPLANT"}},
    {name = "forge", words = {"FORGE", "VAULT"}},
}

function city.family(entry)
    if entry.family ~= nil then
        return entry.family or nil
    end
    local upper = string.upper(entry.name)
    entry.family = false
    for _, family in ipairs(families) do
        for _, word in ipairs(family.words) do
            if string.find(upper, word, 1, true) then
                entry.family = family.name
                return family.name
            end
        end
    end
    return nil
end

local function footprint(entry)
    local record = entry.record
    return math.max(1, util.whole(record.footprintx)), math.max(1, util.whole(record.footprintz))
end

-- Sizes the grid from the seat's side: blocks fit its largest land factory,
-- streets its widest ground unit.
function city.setup()
    if city.ready or world.start == nil then
        return
    end
    local side = me.side_name
    local widest, largest = 2, 8
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and not entry.skip and (side == nil or entry.side == "" or entry.side == side) then
            local w, d = footprint(entry)
            if entry.mobile and not entry.air and not entry.water_only then
                if math.max(w, d) > widest and type(entry.record.movementclass) == "string"
                    and entry.record.movementclass ~= "" then
                    city.class = entry.record.movementclass
                end
                widest = math.max(widest, w, d)
            elseif entry.factory and not entry.water_only then
                largest = math.max(largest, w, d)
            end
        end
    end
    city.street = widest + 1
    -- Alleys as wide as the widest builder, so builders never get boxed in.
    local builder_width = 2
    for index = 1, #units do
        local entry = catalog.types[index]
        if entry ~= nil and entry.mobile_builder and not entry.air and not entry.skip
            and (side == nil or entry.side == "" or entry.side == side) then
            local w, d = footprint(entry)
            builder_width = math.max(builder_width, w, d)
        end
    end
    alley = math.max(2, math.min(4, builder_width))
    city.block = math.max(16, math.min(24, largest))
    local start_x = world.start.x // cell
    local start_z = world.start.z // cell
    city.origin = {x = start_x - city.block // 2, z = start_z - city.block // 2}
    city.ready = true
    print(string.format("city grid: blocks %d cells, streets %d cells, alleys %d cells", city.block, city.street, alley))
end

local function block_rect(i, j)
    local period = city.block + city.street
    local x0 = city.origin.x + i * period
    local z0 = city.origin.z + j * period
    return {x0 = x0, z0 = z0, x1 = x0 + city.block - 1, z1 = z0 + city.block - 1}
end

local function overlaps(a, b)
    return a.x0 <= b.x1 and b.x0 <= a.x1 and a.z0 <= b.z1 and b.z0 <= a.z1
end

-- Every rectangle the seat's buildings take, with whether it is a factory
-- and its family; recent orders included.
local function taken()
    local found = {}
    for _, unit in ipairs(world.select(function(_, e) return e.structure end)) do
        local entry = catalog.of(unit)
        local at = util.pos(unit)
        if at ~= nil then
            local w, d = footprint(entry)
            local x0 = (at.x - w * 8) // cell
            local z0 = (at.z - d * 8) // cell
            found[#found + 1] = {
                x0 = x0, z0 = z0, x1 = x0 + w - 1, z1 = z0 + d - 1,
                factory = entry.factory, family = city.family(entry),
            }
        end
    end
    local keep = {}
    for _, rect in ipairs(city.pending) do
        if me.tick - rect.tick < 30 * 60 then
            keep[#keep + 1] = rect
            found[#found + 1] = rect
        end
    end
    city.pending = keep
    return found
end

-- The first rectangle of `rects` the footprint overlaps, or nil.
local function blocker(rect, rects)
    for _, other in ipairs(rects) do
        if overlaps(rect, other) then
            return other
        end
    end
    return nil
end

-- Whether the footprint at top-left cell (x, z) is free, inside `block`,
-- on the map, off metal unless it is an extractor, and a clear site.
local function fits(entry, x, z, w, d, block, rects, budget, facing)
    local rect = {x0 = x, z0 = z, x1 = x + w - 1, z1 = z + d - 1}
    if block ~= nil and (rect.x0 < block.x0 or rect.z0 < block.z0 or rect.x1 > block.x1 or rect.z1 > block.z1) then
        return false
    end
    local map_height = util.whole(game.map:height())
    if x < 1 or z < 1 or rect.x1 >= util.whole(game.map.width) - 1 or rect.z1 >= map_height - 1 then
        return false
    end
    if blocker(rect, rects) ~= nil then
        return false
    end
    local map = game.map
    if not entry.extractor then
        local surface = util.num(map.surface_metal)
        for cz = rect.z0, rect.z1 do
            for cx = rect.x0, rect.x1 do
                if util.num(map:metal(cx, cz)) > surface then
                    return false
                end
            end
        end
    end
    local centre = {x = x * cell + w * 8, z = z * cell + d * 8}
    if not util.explored(centre) then
        return false
    end
    if budget.left <= 0 then
        return false
    end
    budget.left = budget.left - 1
    return brain.site(entry.record, x, z, facing or 0) == true
end

-- The share of a block's ground the largest ground units can stand on:
-- not cliffs, lava, deep water or off the map. Read once per block.
local quality = {}
local good_ground = 0.5

local function block_quality(i, j, block)
    local key = i * 1000 + j
    local known = quality[key]
    if known ~= nil then
        return known
    end
    local map = game.map
    local class = city.class
    local width, height = util.whole(map.width), util.whole(map:height())
    local total, good = 0, 0
    for cz = block.z0, block.z1, 3 do
        for cx = block.x0, block.x1, 3 do
            total = total + 1
            if cx >= 0 and cz >= 0 and cx < width and cz < height then
                local ok = true
                if class ~= nil then
                    local passable = map:passable(class, cx, cz)
                    ok = passable ~= nil and passable > 0
                end
                if ok then
                    good = good + 1
                end
            end
        end
    end
    local share = total > 0 and good / total or 0
    quality[key] = share
    return share
end

-- Blocks around the base with good ground, nearest `toward` first.
local function blocks_by_distance(toward)
    local list = {}
    for j = -rings, rings do
        for i = -rings, rings do
            local block = block_rect(i, j)
            if block_quality(i, j, block) >= good_ground then
                local middle = {
                    x = (block.x0 + city.block / 2) * cell,
                    z = (block.z0 + city.block / 2) * cell,
                }
                block.middle = middle
                block.d = util.dist(middle, toward)
                list[#list + 1] = block
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

-- Districts: factories toward the front, so units leave on the right side;
-- power, makers and storage behind the base, away from the fighting;
-- everything else round the middle. Callers may name a point instead.
local function district(entry)
    local home = world.base or world.start
    local reach = (city.block + city.street) * cell
    local front = world.front(reach)
    if entry.factory then
        return front
    end
    if entry.power or entry.metal_maker or entry.metal_storage or entry.energy_storage
        or entry.extractor or city.family(entry) ~= nil then
        return util.clamp({x = 2 * home.x - front.x, z = 2 * home.z - front.z}, 64)
    end
    return home
end

-- What a block holds now: "industry" with a factory in it, "town" with
-- anything else, nil when empty.
local function block_use(block, rects)
    local use = nil
    for _, rect in ipairs(rects) do
        if overlaps(block, rect) then
            if rect.factory then
                return "industry"
            end
            use = "town"
        end
    end
    return use
end

local function order(unit, entry, x, z, w, d, facing)
    local centre = {x = x * cell + w * 8, z = z * cell + d * 8}
    if unit:build(entry.record, centre, facing) then
        city.pending[#city.pending + 1] = {
            x0 = x, z0 = z, x1 = x + w - 1, z1 = z + d - 1, tick = me.tick,
            factory = entry.factory, family = city.family(entry),
        }
        return true
    end
    return false
end

-- A factory in a block of its own kind: the corners of the block, doors
-- facing the street to the north or the south.
local function place_factory(unit, entry, blocks, rects, budget, anywhere)
    local w, d = footprint(entry)
    for _, block in ipairs(blocks) do
        local use = block_use(block, rects)
        if anywhere or use ~= "town" then
            local spots
            if w * 2 <= city.block and d * 2 <= city.block then
                spots = {
                    {block.x0, block.z0, 2}, {block.x1 - w + 1, block.z0, 2},
                    {block.x0, block.z1 - d + 1, 0}, {block.x1 - w + 1, block.z1 - d + 1, 0},
                }
            else
                spots = {{block.x0 + (city.block - w) // 2, block.z1 - d + 1, 0}}
            end
            for _, spot in ipairs(spots) do
                if fits(entry, spot[1], spot[2], w, d, block, rects, budget, spot[3]) then
                    return order(unit, entry, spot[1], spot[2], w, d, spot[3])
                end
            end
        end
    end
    return false
end

-- Next to a building of the same family, edge to edge and aligned.
local function place_family(unit, entry, family, rects, budget)
    local w, d = footprint(entry)
    for _, rect in ipairs(rects) do
        if rect.family == family then
            local block = nil
            for j = -rings, rings do
                for i = -rings, rings do
                    local candidate = block_rect(i, j)
                    if overlaps(candidate, rect) then
                        block = candidate
                    end
                end
            end
            if block ~= nil then
                local spots = {
                    {rect.x1 + 1, rect.z0}, {rect.x0 - w, rect.z0},
                    {rect.x0, rect.z1 + 1}, {rect.x0, rect.z0 - d},
                }
                for _, spot in ipairs(spots) do
                    if fits(entry, spot[1], spot[2], w, d, block, rects, budget) then
                        return order(unit, entry, spot[1], spot[2], w, d, 0)
                    end
                end
            end
        end
    end
    return false
end

-- Packed into the first town block with room, scanning from its corner.
-- A row skips past whatever building is in the way. A block with free
-- ground where nothing fits may hold rocks or wrecks: it is noted for a
-- builder to sweep.
local function note_crowded(block, rects)
    local used = 0
    for _, rect in ipairs(rects) do
        if overlaps(block, rect) then
            if rect.factory then
                return
            end
            used = used + (rect.x1 - rect.x0 + 1) * (rect.z1 - rect.z0 + 1)
        end
    end
    if used * 2 < city.block * city.block and util.explored(block.middle) then
        city.crowded[#city.crowded + 1] = {x = block.middle.x, z = block.middle.z, tick = me.tick}
        if #city.crowded > 8 then
            table.remove(city.crowded, 1)
        end
    end
end

-- The cells of `block` that buildings cover.
local function used_cells(block, rects)
    local used = 0
    for _, rect in ipairs(rects) do
        if overlaps(block, rect) then
            local x0, z0 = math.max(block.x0, rect.x0), math.max(block.z0, rect.z0)
            local x1, z1 = math.min(block.x1, rect.x1), math.min(block.z1, rect.z1)
            used = used + (x1 - x0 + 1) * (z1 - z0 + 1)
        end
    end
    return used
end

-- Town buildings keep an alley of free cells round them, and no town
-- block is filled past its cap. Blocks are tried least full first among
-- those near the base, so the town spreads instead of piling up in the
-- middle.
local function place_town(unit, entry, blocks, rects, budget)
    local w, d = footprint(entry)
    local area = city.block * city.block
    local order_list = {}
    for _, block in ipairs(blocks) do
        if block_use(block, rects) ~= "industry" then
            block.used = used_cells(block, rects)
            if block.used + w * d <= area * fill_cap then
                block.key = block.d * (1 + 2 * block.used / area)
                order_list[#order_list + 1] = block
            end
        end
    end
    table.sort(order_list, function(a, b) return a.key < b.key end)
    for index, block in ipairs(order_list) do
        if index > 1 and budget.left > 0 then
            note_crowded(order_list[index - 1], rects)
        end
        do
            local inside = {}
            for _, rect in ipairs(rects) do
                if overlaps(block, rect) then
                    inside[#inside + 1] = rect
                end
            end
            for z = block.z0, block.z1 - d + 1 do
                local x = block.x0
                while x <= block.x1 - w + 1 do
                    if budget.left <= 0 then
                        return false
                    end
                    local in_way = blocker({
                        x0 = x - alley, z0 = z - alley, x1 = x + w - 1 + alley, z1 = z + d - 1 + alley,
                    }, inside)
                    if in_way ~= nil then
                        x = math.max(x + 1, in_way.x1 + 1 + alley)
                    else
                        if fits(entry, x, z, w, d, block, inside, budget) then
                            return order(unit, entry, x, z, w, d, 0)
                        end
                        x = x + 1
                    end
                end
            end
        end
    end
    return false
end

-- Whether a building of `entry` centred at world point (x, z) would cover
-- any street cell.
function city.on_street(entry, x, z)
    if not city.ready then
        return false
    end
    local w, d = footprint(entry)
    local x0 = (x - w * 8) // cell
    local z0 = (z - d * 8) // cell
    local period = city.block + city.street
    for cx = x0, x0 + w - 1 do
        if (cx - city.origin.x) % period >= city.block then
            return true
        end
    end
    for cz = z0, z0 + d - 1 do
        if (cz - city.origin.z) % period >= city.block then
            return true
        end
    end
    return false
end

-- The middle of the nearest block with unexplored ground, for a builder
-- to walk to when nothing explored has room.
function city.unexplored_block(toward)
    if not city.ready then
        return nil
    end
    for _, block in ipairs(blocks_by_distance(toward or world.start)) do
        if not util.explored(block.middle) then
            return util.clamp(block.middle, 64)
        end
    end
    return nil
end

-- Orders `unit` to build `entry` in the city. `toward` puts the blocks
-- nearest that point first (the front, for radar and defences).
function city.place(unit, entry, toward)
    city.setup()
    if not city.ready then
        return false
    end
    local rects = taken()
    local budget = {left = site_checks}
    local blocks = blocks_by_distance(toward or district(entry))
    if entry.factory then
        -- Industrial blocks first; with none in reach, a town block's corner.
        return place_factory(unit, entry, blocks, rects, budget, false)
            or place_factory(unit, entry, blocks, rects, budget, true)
    end
    local family = city.family(entry)
    if family ~= nil and place_family(unit, entry, family, rects, budget) then
        return true
    end
    return place_town(unit, entry, blocks, rects, budget)
end

-- Prints the base as a map, one character per two cells: F factory,
-- E energy family, # other building, = street, . free block ground,
-- x a block left out for poor ground.
function city.dump()
    if not city.ready then
        return
    end
    local rects = taken()
    local period = city.block + city.street
    local x0 = city.origin.x - period * 2
    local z0 = city.origin.z - period * 2
    local size = period * 5
    for z = z0, z0 + size, 2 do
        local row = {}
        for x = x0, x0 + size, 2 do
            local mark = "."
            local i = (x - city.origin.x) % period
            local j = (z - city.origin.z) % period
            if i >= city.block or j >= city.block then
                mark = "="
            else
                local bi = (x - city.origin.x) // period
                local bj = (z - city.origin.z) // period
                local share = quality[bi * 1000 + bj]
                if share ~= nil and share < good_ground then
                    mark = "x"
                end
            end
            for _, rect in ipairs(rects) do
                if x >= rect.x0 and x <= rect.x1 and z >= rect.z0 and z <= rect.z1 then
                    mark = rect.factory and "F" or (rect.family and "E" or "#")
                end
            end
            row[#row + 1] = mark
        end
        print(table.concat(row))
    end
end

return city
