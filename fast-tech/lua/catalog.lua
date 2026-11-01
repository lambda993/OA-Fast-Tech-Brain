-- SPDX-FileCopyrightText: Lambda993
-- SPDX-License-Identifier: GPL-3.0-only

-- Every unit type sorted once into the roles the brain plays with.
-- Escalation marks each type's tier with a LEVn category: LEV0 is the
-- commander, LEV1 to LEV3 the three factory tiers, LEV4 the experimentals
-- and LEV5 the largest experimentals. Upgrades and stockpiled rounds are
-- left out.

local util = require("util")

local catalog = {}

local num = util.num

local function categories(record)
    local found = {}
    local list = record.category
    if type(list) == "table" then
        for index = 1, #list do
            found[string.upper(list[index])] = true
        end
    end
    return found
end

local function tier_of(words)
    for level = 0, 5 do
        if words["LEV" .. level] then
            return level
        end
    end
    return nil
end

local function has_weapon(record)
    local weapon = record.weapon1
    if type(weapon) ~= "string" or weapon == "" then
        return false
    end
    return string.find(string.upper(weapon), "NULL", 1, true) == nil
end

local function flag(value)
    return value == true or num(value) > 0
end

-- What a type's weapons do: whether any hits aircraft, whether all of them
-- only work in water (torpedoes), the longest range, the hungriest shot,
-- whether any hits the ground (a weapon not made for aircraft) and whether
-- any is a dropped bomb. Escalation's RANGE_ and LAB_ weapons only mark a
-- range or a factory door.
local function weapon_info(record)
    local anti_air, any, water, range, shot = false, false, true, 0, 0
    local ground, bomb, stockpile, other = false, false, false, false
    for slot = 1, 3 do
        local weapon_name = record["weapon" .. slot]
        if type(weapon_name) == "string" and weapon_name ~= "" then
            local upper = string.upper(weapon_name)
            local weapon = weapons[weapon_name]
            if weapon ~= nil and string.find(upper, "NULL", 1, true) == nil
                and string.sub(upper, 1, 6) ~= "RANGE_" and string.sub(upper, 1, 4) ~= "LAB_" then
                any = true
                if flag(weapon.toairweapon) then
                    anti_air = true
                else
                    ground = true
                end
                if flag(weapon.dropped) then
                    bomb = true
                end
                if flag(weapon.stockpile) then
                    stockpile = true
                else
                    other = true
                end
                if not flag(weapon.waterweapon) then
                    water = false
                end
                range = math.max(range, num(weapon.range))
                shot = math.max(shot, num(weapon.energypershot))
            end
        end
    end
    return anti_air, any and water, range, shot, ground, bomb, stockpile, stockpile and not other
end

local function text(value)
    if type(value) == "string" then
        return value
    end
    return ""
end

-- The engine's wind: the map gives a strength range (2500 to 4500 on
-- Ooooweeee) and a generator makes its windgenerator times strength / 5000,
-- at most its windgenerator. A tidal generator makes tidalgenerator times
-- the map's tide.
local wind_divisor = 5000

local function wind_share(strength)
    return math.max(0, math.min(1, strength / wind_divisor))
end

catalog.wind_share = wind_share

-- The energy and metal a finished building adds each second, before the
-- difficulty's income rule. Wind counts at the middle of the map's range.
local function yields(record)
    local map = game.map
    local wind, tide = 0, 0
    if map ~= nil then
        wind = wind_share((num(map.wind_min) + num(map.wind_max)) / 2)
        tide = num(map.tide)
    end
    local energy = num(record.energymake) - num(record.energyuse)
        + num(record.windgenerator) * wind
        + num(record.tidalgenerator) * tide
    local metal = num(record.metalmake) + num(record.makesmetal)
    return energy, metal
end

local function classify(index, record, inferred_tier)
    local words = categories(record)
    local tier = tier_of(words) or inferred_tier
    local name = text(record.name)
    local unit_name = string.upper(text(record.unitname))
    local entry = {
        words = words,
        index = index,
        record = record,
        name = name,
        unit_name = unit_name,
        side = text(record.side),
        tier = tier or 1,
        metal = num(record.buildcostmetal),
        energy = num(record.buildcostenergy),
        structure = num(record.bmcode) == 0,
        builder = record.builder == true,
        commander = record.commander == true or words.LEV0 == true,
        air = record.canfly == true,
        armed = has_weapon(record),
        speed = num(record.maxvelocity),
        sight = num(record.sightdistance),
        radar = num(record.radardistance),
        extracts = num(record.extractsmetal),
        water_only = num(record.minwaterdepth) > 0 or num(record.tidalgenerator) > 0
            or string.find(string.upper(name), "FLOATING", 1, true) ~= nil
            or string.find(string.upper(name), "UNDERWATER", 1, true) ~= nil,
        footprint = math.max(num(record.footprintx), num(record.footprintz)),
        builds = {},
    }
    entry.cost = entry.metal + entry.energy / 60
    entry.energy_yield, entry.metal_yield = yields(record)
    -- An upgrade a building makes of itself, such as a reactor's armour.
    -- The unit-level upgrades (LEV_2) stay out.
    entry.upgrade = words.LEV_2 ~= true and string.find(string.upper(name), "UPGRADE", 1, true) ~= nil
    entry.skip = tier == nil
        or words.LEV_2 == true
        or string.find(unit_name, "MAKENUKE", 1, true) ~= nil
        or string.find(unit_name, "MAKEANTI", 1, true) ~= nil
    -- Escalation's unit upgrades (Level 2 and Level 3 Unit Upgrade): a
    -- factory builds one and its units come out stronger. They stay out
    -- of every other role (skipped) and go in the factory's own list.
    entry.unit_upgrade = words.LEV_2 == true and not entry.structure
    entry.decoy = string.find(unit_name, "DECOM", 1, true) ~= nil
    entry.commander = entry.commander and not entry.decoy
    -- shot_energy: what one shot of the hungriest weapon draws from the store.
    local ground, bomb
    entry.anti_air, entry.torpedo_only, entry.range, entry.shot_energy, ground, bomb, entry.stockpile, entry.stockpile_only = weapon_info(record)
    -- Whether its weapons can hit ground targets: units with only
    -- anti-air weapons cannot, units without them cannot hit aircraft.
    entry.hits_ground = ground
    entry.bomber = entry.air and bomb
    -- Repair pads, carriers: aircraft land on them to be repaired.
    entry.air_base = record.isairbase == true or num(record.isairbase) > 0
    -- The building that makes the commander tougher (Arm's Research
    -- Facility, Core's Upgrade Center).
    entry.commander_upgrade = unit_name == "ARMTECH" or unit_name == "CORTECH"
    entry.mobile = not entry.structure
    entry.factory = entry.structure and entry.builder
    entry.mobile_builder = entry.mobile and entry.builder and num(record.workertime) > 0
    entry.scout = entry.mobile and not entry.builder and entry.metal <= 80
        and entry.speed >= 2.5 and entry.sight >= 300
    -- Stockpile weapons fire only rounds built in the unit (MAKENUKE,
    -- MAKEANTI), and no AI build list holds them: a unit armed with
    -- nothing else (Scarab, Hedgehog: mobile anti-nukes) never fires.
    entry.combat = entry.mobile and not entry.builder and entry.armed and not entry.scout
        and not entry.stockpile_only
    -- Escalation's Big Bertha, Intimidator, Guardian and Punisher are
    -- builders (they make their own armour upgrade): only a real factory
    -- is no defence (catalog.refresh_builds).
    entry.defense = entry.structure and entry.armed and record.canattack == true
        and not entry.stockpile_only
    entry.radar_tower = entry.structure and not entry.armed and entry.radar >= 1000
    entry.sonar_tower = entry.structure and not entry.armed and not entry.radar_tower
        and num(record.sonardistance) >= 600
    entry.jammer = entry.structure and not entry.armed
        and (num(record.radardistancejam) > 0 or num(record.sonardistancejam) > 0)
    entry.extractor = entry.structure and entry.extracts > 0
    entry.metal_maker = entry.structure and num(record.makesmetal) > 0 and num(record.energyuse) > 0
    entry.metal_storage = entry.structure and not entry.builder and not entry.armed
        and num(record.metalstorage) >= 200 and entry.energy_yield <= 0 and entry.extracts == 0
    entry.energy_storage = entry.structure and not entry.builder and not entry.armed
        and num(record.energystorage) >= 500 and num(record.makesmetal) == 0 and entry.extracts == 0
        and num(record.energymake) <= num(record.energyuse)
    entry.metal_capacity = num(record.metalstorage)
    entry.energy_capacity = num(record.energystorage)
    entry.geo = string.find(string.upper(name), "GEOTHERMAL", 1, true) ~= nil
    entry.power = entry.structure and not entry.extractor and not entry.metal_maker
        and entry.energy_yield > 0 and num(record.energystorage) < num(record.energymake) * 4 + 1
        and string.find(string.upper(name), "STORAGE", 1, true) == nil
    -- Long-range plasma cannons and the like.
    -- Not the stockpile weapons (nuke and tactical silos, anti-nukes):
    -- they shoot what they have built up, not plasma shells.
    entry.artillery = entry.defense and entry.range >= 3000 and not entry.stockpile
    if entry.upgrade then
        for _, role in ipairs({"factory", "mobile_builder", "scout", "combat", "defense", "radar_tower",
            "sonar_tower", "jammer",
            "extractor", "metal_maker", "metal_storage", "energy_storage", "geo", "power", "artillery"}) do
            entry[role] = false
        end
    end
    return entry
end

-- Fills `catalog.types` (type index to entry) and each entry's build list.
function catalog.load()
    catalog.types = {}
    local count = #units
    for index = 1, count do
        local record = units[index]
        if record ~= nil then
            catalog.types[index] = classify(index, record)
        end
    end
    catalog.refresh_builds()
end

-- The engine hands brains an empty `category` for the last unit types
-- (index 512 on: Escalation's last 38, CORVP, CORWIN, CORZIG and more),
-- so their tier is unknown and they were left out: Core seemed to have
-- no Vehicle Plant. Their tier is read from who builds them instead: a
-- unit made by a factory has the factory's tier, a building put down by
-- a mobile builder the builder's (at least 1), the lowest such.
local function infer_missing_tiers(lists)
    local missing = {}
    for index, entry in pairs(catalog.types) do
        local record = entry.record
        if type(record.category) ~= "table" or #record.category == 0 then
            missing[index] = true
        end
    end
    for _ = 1, 3 do
        local found = {}
        for _, maker in pairs(catalog.types) do
            if maker.builder and not missing[maker.index] then
                local list = lists[maker.index]
                if type(list) == "table" then
                    for slot = 1, #list do
                        local built = list[slot]
                        local built_index = built and built:index()
                        if built_index ~= nil and missing[built_index] then
                            local made = catalog.types[built_index]
                            local level = math.max(1, maker.tier)
                            if made ~= nil and (found[built_index] == nil or level < found[built_index]) then
                                found[built_index] = level
                            end
                        end
                    end
                end
            end
        end
        local any = false
        for index, level in pairs(found) do
            catalog.types[index] = classify(index, catalog.types[index].record, level)
            missing[index] = nil
            any = true
        end
        if not any then
            break
        end
    end
end

-- Build lists are complete once the match has set its players up, so the
-- first tick reads them again.
function catalog.refresh_builds()
    -- Each builder's list is read once: the engine call is costly, and a
    -- first turn over 250 ms stops the seat (seen on Flooded Glaciers).
    local lists = {}
    for index, entry in pairs(catalog.types) do
        if entry.builder then
            lists[index] = game.build_list(entry.record)
        end
    end
    infer_missing_tiers(lists)
    for index, entry in pairs(catalog.types) do
        entry.builds = {}
        entry.unit_upgrades = {}
        if entry.builder then
            local list = lists[index]
            if type(list) == "table" then
                local seen = {}
                for slot = 1, #list do
                    local built = list[slot]
                    local built_index = built and built:index()
                    local other = built_index and catalog.types[built_index]
                    -- Water-only buildings are kept too; catalog.buildable
                    -- leaves them out unless the caller asks for water.
                    local keep = other ~= nil and not other.skip
                    if keep and not seen[built_index] then
                        seen[built_index] = true
                        entry.builds[#entry.builds + 1] = other
                    elseif other ~= nil and other.unit_upgrade and not seen[built_index] then
                        seen[built_index] = true
                        entry.unit_upgrades[#entry.unit_upgrades + 1] = other
                    end
                end
            end
        end
    end
    -- A factory makes real mobile units. Escalation's reactors and other
    -- buildings that only make upgrades are not factories.
    for _, entry in pairs(catalog.types) do
        if entry.structure and entry.builder then
            local mobile = false
            for _, built in ipairs(entry.builds) do
                if built.mobile and not built.upgrade then
                    mobile = true
                    break
                end
            end
            entry.factory = mobile
            if mobile then
                entry.defense, entry.artillery = false, false
            end
        end
    end
    for _, entry in pairs(catalog.types) do
        if entry.factory then
            entry.line = catalog.line_of(entry)
        end
    end
    catalog.judge_wind_and_tide()
end

-- Wind and tidal generators make what the map's wind and tide give. Where
-- their best output is under half a solar collector's, as on airless moons,
-- they are not built: solar collectors are. The solar collector is the
-- tier-1 plant that draws its energy from nothing (a negative energy use);
-- geothermal plants do not count.
function catalog.judge_wind_and_tide()
    local map = game.map
    if map == nil then
        return
    end
    local solar = 0
    for _, entry in pairs(catalog.types) do
        local record = entry.record
        if entry.power and entry.tier <= 1 and not entry.geo and num(record.windgenerator) == 0
            and num(record.tidalgenerator) == 0 and num(record.energyuse) < 0 then
            solar = math.max(solar, entry.energy_yield)
        end
    end
    local wind_max, tide = wind_share(num(map.wind_max)), num(map.tide)
    for _, entry in pairs(catalog.types) do
        local record = entry.record
        local most = nil
        if num(record.windgenerator) > 0 then
            most = num(record.windgenerator) * wind_max
        elseif num(record.tidalgenerator) > 0 then
            most = num(record.tidalgenerator) * tide
        end
        if most ~= nil and most < solar * 0.5 then
            entry.power = false
        end
    end
end

-- The kind of unit a factory mostly makes: "kbot", "vehicle", "air",
-- "ship" or "hover", from its combat units' movement.
function catalog.line_of(factory)
    local votes = {kbot = 0, vehicle = 0, air = 0, ship = 0, hover = 0}
    for _, built in ipairs(factory.builds) do
        if built.mobile and not built.builder then
            local record = built.record
            local class = string.upper(type(record.movementclass) == "string" and record.movementclass or "")
            -- Escalation's selection groups name the line: CTRL_K kbots,
            -- CTRL_V vehicles, CTRL_H hovercraft. Many kbots use TANK
            -- movement classes, so the class alone cannot tell.
            local words = built.words or {}
            local kind
            if built.air then
                kind = "air"
            elseif built.water_only or string.find(class, "BOAT", 1, true) then
                kind = "ship"
            elseif words.CTRL_H or record.canhover == true or string.find(class, "HOVER", 1, true) then
                kind = "hover"
            elseif words.CTRL_K then
                kind = "kbot"
            elseif words.CTRL_V or string.find(class, "TANK", 1, true) then
                kind = "vehicle"
            else
                kind = "kbot"
            end
            votes[kind] = votes[kind] + 1
        end
    end
    local best, best_votes = "kbot", -1
    for _, kind in ipairs({"kbot", "vehicle", "air", "ship", "hover"}) do
        if votes[kind] > best_votes then
            best, best_votes = kind, votes[kind]
        end
    end
    return best
end

-- The movement class a factory's combat units mostly use, for reach tests.
function catalog.line_class(factory)
    for _, built in ipairs(factory.builds) do
        if built.combat and not built.air and type(built.record.movementclass) == "string"
            and built.record.movementclass ~= "" then
            return built.record.movementclass
        end
    end
    return nil
end

function catalog.of(unit)
    if unit == nil then
        return nil
    end
    local index = unit.type_index
    if type(index) ~= "number" then
        return nil
    end
    return catalog.types[index]
end

-- What a mobile builder can do for the seat on land, as a set of words.
-- Water buildings do not count.
function catalog.abilities(entry)
    local found = {}
    for _, built in ipairs(entry.builds) do
        if not built.water_only or built.factory then
            if built.extractor then found.extractor = true end
            if built.radar_tower then found.radar = true end
            if built.metal_maker then found.maker = true end
            if built.power and not built.geo then found.power = true end
            if built.geo then found.geo = true end
            if built.defense then found.defense = true end
            if built.factory then found.factory = true end
        end
    end
    return found
end

-- Entries in `builder`'s list for which `test(entry)` holds. Water-only
-- entries count only when `water` is set.
function catalog.buildable(builder, test, water)
    local found = {}
    if builder == nil then
        return found
    end
    for _, entry in ipairs(builder.builds) do
        if (water or not entry.water_only) and test(entry) then
            found[#found + 1] = entry
        end
    end
    return found
end

function catalog.can_build(builder, target)
    if builder == nil or target == nil then
        return false
    end
    for _, entry in ipairs(builder.builds) do
        if entry == target then
            return true
        end
    end
    return false
end

-- The tier a factory works at. A factory whose list holds only lower
-- units still counts at its own tier.
function catalog.factory_tier(entry)
    return math.max(1, entry.tier)
end

-- How good a factory is as the main line of a tier: combat units it
-- offers, more for land and hover than for air.
function catalog.factory_score(entry)
    local score = 0
    for _, built in ipairs(entry.builds) do
        if built.combat then
            score = score + (built.air and 1 or 2)
        end
        if built.mobile_builder then
            score = score + 3
            -- A line whose builders can claim metal is worth much more.
            if catalog.abilities(built).extractor then
                score = score + 12
            end
        end
    end
    return score
end

return catalog
