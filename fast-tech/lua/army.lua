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
local economy = require("economy")
local factories = require("factories")
local terrain = require("terrain")
local util = require("util")
local world = require("world")

local army = {
    attacking = {}, -- unit id -> true
    target = nil,
    sent_at = 0,
    grounded = {},  -- aircraft id -> tick it pulled back from anti-air
    air_mending = {}, -- aircraft id -> tick it was sent to a repair pad
}

-- Metal worth a wave needs before it leaves, by the seat's tier.
-- Tier-1 units mostly stay home: the bot spends on tech, not on trades.
-- Lowered after the user's Steel Jungle game, where armies of 20-30 units
-- sat at home for the first fifteen minutes (tier 2 asked for 7 200).
local wave_worth = {[0] = 3000, 3000, 5000, 20000, 60000, 120000}

-- Toward the front, where the city puts its factories: out of their lanes.
local function rally_point()
    return world.clear_spot(world.front(380))
end

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

-- How units keep their distance, by the user's tags. Frontliners close in.
-- A skirmisher steps back when an armed enemy comes within half its reach.
-- Mobile artillery leaves when it stands in reach of an enemy's weapons, and
-- walks out of that reach (only enemies it could shell count: the search
-- stops at its own reach, at most 1 500). An `aoe` unit moves away from
-- friends standing in its blast, whatever is near. Returns whether it
-- stepped away. Each costs a path search, hence the clock.
local artillery_margin = 64
local apart_limit = 400
army.backed = {} -- unit id -> tick it last stepped away
army.escort_moved = {} -- escort id -> tick it was last sent behind its leader
army.stepped = {skirmisher = 0, artillery = 0, apart = 0, escort = 0, scattered = 0} -- counted for the seat log
local scatter_busy = 30 * 5 -- a scattered unit is left to its move this long
army.targets_kept, army.searched = 0, 0 -- targets kept and searched, for the seat log

local function away_from(unit, at, from, step, wait)
    -- Stepped away a moment ago: still on its way.
    local backed = army.backed[unit.id]
    if backed ~= nil and me.tick - backed < wait and not util.free(unit) then
        return true
    end
    army.backed[unit.id] = me.tick
    local dx, dz = at.x - from.x, at.z - from.z
    local length = math.max(1, math.sqrt(dx * dx + dz * dz))
    local back = util.clamp({x = util.whole(at.x + dx / length * step), z = util.whole(at.z + dz / length * step)}, 64)
    return unit:move(back) == true
end

local function armed_on_ground(kind)
    return kind ~= nil and kind.armed and not kind.air and kind.hits_ground
end

local function keep_apart(unit, entry, at)
    local radius = math.min(entry.blast, apart_limit)
    local x, z, count = 0, 0, 0
    for _, row in ipairs(world.friends_in(at, radius)) do
        if row.unit.id ~= unit.id and not (row.entry ~= nil and row.entry.air) then
            x, z, count = x + row.x, z + row.z, count + 1
        end
    end
    if count == 0 then
        return false
    end
    local moved = away_from(unit, at, {x = x / count, z = z / count}, radius + 64, 30 * 10)
    army.stepped.apart = army.stepped.apart + (moved and 1 or 0)
    return moved
end

local function keep_range(unit)
    local entry = catalog.of(unit)
    if entry == nil or entry.air or entry.structure then
        return false
    end
    local at = util.pos(unit)
    if at == nil then
        return false
    end
    if entry.blast > 0 then
        return keep_apart(unit, entry, at)
    end
    if entry.tags.artillery then
        local worst, worst_step
        for _, row in ipairs(world.enemies_near(at, math.min(entry.ground_range, 1500))) do
            if armed_on_ground(row.entry) then
                local step = row.entry.ground_range + artillery_margin - util.dist(at, row)
                if step > 0 and (worst == nil or step > worst_step) then
                    worst, worst_step = row, step
                end
            end
        end
        local moved = worst ~= nil and away_from(unit, at, worst, worst_step + 100, 30 * 5)
        army.stepped.artillery = army.stepped.artillery + (moved and 1 or 0)
        return moved
    end
    if entry.tags.skirmisher then
        local near, near_d
        for _, row in ipairs(world.enemies_near(at, entry.ground_range * 0.5)) do
            if armed_on_ground(row.entry) then
                local d = util.dist(at, row)
                if near_d == nil or d < near_d then
                    near, near_d = row, d
                end
            end
        end
        local moved = near ~= nil and away_from(unit, at, near, entry.ground_range * 0.4, 30 * 5)
        army.stepped.skirmisher = army.stepped.skirmisher + (moved and 1 or 0)
        return moved
    end
    return false
end

-- An attack order, given again only for a new target, or when the unit
-- dropped the old one, or after twelve seconds: each order sends the unit
-- to the path search, and with hundreds of units every three seconds the
-- game slowed down in big fights.
army.aimed = {} -- unit id -> {target id, tick}

local function attack(unit, target)
    local last = army.aimed[unit.id]
    if last ~= nil and last.id == target.id and me.tick - last.tick < 30 * 12 and not util.free(unit) then
        return true
    end
    local kind = catalog.of(target)
    army.aimed[unit.id] = {id = target.id, tick = me.tick, priority = world.rank(catalog.of(unit), kind),
        worth = world.priority(kind)}
    return unit:attack(target)
end

army.attack = attack

-- Units keep their target: one still in sight (within half again the
-- reach) is kept unless something of higher priority shows up; one of
-- priority 3 or more (anti-air, tier 3+, commanders) that slipped into
-- the fog is chased to where it was last seen for up to forty seconds,
-- on an attack-move, unless something of higher priority is in sight.
-- Returns the unit to shoot, or nil and the point to chase to.
local chase_time = 30 * 40
-- A unit keeps its target at least this long before it looks for a better
-- one (user's idea, for speed: the target search for every unit of the
-- army every three seconds was most of the army's cost in big fights).
-- A target that dies, slips out of sight or out of reach is replaced at
-- once.
local target_hold = 30 * 10

local function keeps(entry, from, reach, row)
    return world.can_hit(entry, row.entry) and util.dist(from, row) <= reach * 1.5
        and not world.out_of_reach(entry, from, row)
end

local function pick(unit, from, reach)
    local entry = catalog.of(unit)
    local last = army.aimed[unit.id]
    local row = last and world.enemy_row(last.id)
    if row ~= nil and me.tick - last.tick < target_hold and keeps(entry, from, reach, row) then
        army.targets_kept = army.targets_kept + 1
        return row.unit
    end
    army.searched = army.searched + 1
    local best = world.best_target(from, reach, entry)
    local best_priority = best and world.rank(entry, catalog.of(best)) or 0
    if last == nil then
        return best
    end
    if row ~= nil then
        if (best == nil or best.id == last.id or best_priority <= (last.priority or 0))
            and keeps(entry, from, reach, row) then
            return row.unit
        end
        return best
    end
    local seen = world.sightings[last.id]
    if seen ~= nil and me.tick - seen.tick < chase_time and (last.worth or 0) >= 3
        and best_priority <= (last.priority or 0)
        and world.can_hit(entry, seen.entry) and not world.out_of_reach(entry, from, seen) then
        return nil, seen
    end
    army.aimed[unit.id] = nil
    return best
end

-- A unit whose path failed waits thirty seconds before the next attack-move:
-- ships sent to a point they cannot reach asked for the path again every
-- step, thousands of searches in a match.
army.no_path = {} -- unit id -> tick its path failed
local no_path_wait = 30 * 30

local function no_way(unit)
    local failed = army.no_path[unit.id]
    return failed ~= nil and me.tick - failed < no_path_wait
end

function army.on_path_failed(unit)
    army.no_path[unit.id] = me.tick
end

-- An attack-move toward a target's last known place, keeping the target
-- in mind (dedup like patrol).
local function chase(unit, point)
    if no_way(unit) then
        return true
    end
    point = util.clamp(point, 64)
    local last = army.patrolled[unit.id]
    if last ~= nil and me.tick - last.tick < 30 * 10 and util.dist2(last, point) < 200 * 200
        and not util.free(unit) then
        return true
    end
    army.patrolled[unit.id] = {x = point.x, z = point.z, tick = me.tick}
    return unit:patrol(point)
end

-- A patrol, given again only to a new point (300 units off) or after
-- fifteen seconds, or when the unit stopped.
army.patrolled = {} -- unit id -> {x, z, tick}

local function patrol(unit, point)
    if no_way(unit) then
        return true
    end
    point = util.clamp(point, 64)
    local last = army.patrolled[unit.id]
    if last ~= nil and me.tick - last.tick < 30 * 15 and util.dist2(last, point) < 300 * 300
        and not util.free(unit) then
        return true
    end
    army.patrolled[unit.id] = {x = point.x, z = point.z, tick = me.tick}
    army.aimed[unit.id] = nil
    return unit:patrol(point)
end

-- Escorts (tag `escort`: mobile anti-air) stay out of the waves and get no
-- attack orders: they fire at will at aircraft in reach, from where they
-- stand. Each escort is given to a wave (user's game: waves fought with no
-- anti-air near them, the escorts staying with the units at home or far
-- behind, and enemy gunships tore the skirmishers apart): the wave with
-- the fewest escorts for its size that has units it can follow. It keeps
-- close behind the nearest of them, on the side away from the enemy:
-- 140 units, 90 with enemy aircraft near. Under the guns of a ground enemy
-- it steps back, but no further than 260 units behind that unit, out of
-- the fight but still covering it. With no wave it stays behind the
-- nearest own fighter of its kind, or goes back to the rally point when
-- none is within 1 500.
local escort_search = 1200
local escort_group = 1500
local escort_behind = 140
local escort_close = 90
local escort_cover = 260
local escort_slack = 120
local escort_wait = 30 * 4
army.escort_wave = {} -- escort id -> wave number it covers

local function can_lead(escort, kind)
    if kind.tags.escort or kind.air or not kind.combat then
        return false
    end
    -- Ships lead ships; a hovercraft may follow anything, and land units
    -- follow what is not a ship.
    if escort.tags.hovercraft then
        return true
    end
    return (escort.tags.ship == true) == (kind.tags.ship == true or kind.tags.submarine == true)
end

-- The point `behind` units behind `leader`, away from `enemy` (or the
-- army's target).
local function behind_of(leader, enemy, behind)
    local dx, dz = 0, 0
    local from = enemy or army.target
    if from ~= nil then
        dx, dz = leader.x - from.x, leader.z - from.z
    end
    local length = math.max(1, math.sqrt(dx * dx + dz * dz))
    return {x = leader.x + dx / length * behind, z = leader.z + dz / length * behind}
end

local function nearest_leader(entry, at, leaders)
    local leader, leader_d
    for _, row in ipairs(leaders) do
        if can_lead(entry, row.entry) then
            local d = util.dist(at, row)
            if leader_d == nil or d < leader_d then
                leader, leader_d = row, d
            end
        end
    end
    return leader, leader_d
end

local function step_escort(unit, entry, leaders, wave_leaders)
    local at = util.pos(unit)
    if at == nil then
        return
    end
    local leader, leader_d
    if wave_leaders ~= nil then
        leader, leader_d = nearest_leader(entry, at, wave_leaders)
    end
    local with_wave = leader ~= nil
    if leader == nil then
        leader, leader_d = nearest_leader(entry, at, leaders)
        if leader ~= nil and leader_d > escort_group then
            leader = nil
        end
    end
    local worst, worst_step
    for _, row in ipairs(world.enemies_near(at, escort_search)) do
        if armed_on_ground(row.entry) then
            local step = row.entry.ground_range + artillery_margin - util.dist(at, row)
            if step > 0 and (worst == nil or step > worst_step) then
                worst, worst_step = row, step
            end
        end
    end
    if worst ~= nil and leader == nil then
        if away_from(unit, at, worst, worst_step + 100, 30 * 5) then
            army.stepped.escort = army.stepped.escort + 1
        end
        return
    end
    local backed = army.backed[unit.id]
    if no_way(unit) or (backed ~= nil and me.tick - backed < 30 * 5 and not util.free(unit)) then
        return
    end
    local point
    if worst ~= nil then
        -- Back behind the unit it covers, not out of reach of it.
        point = behind_of(leader, worst, escort_cover)
        if util.dist(at, point) > escort_slack and util.dist(at, worst) < util.dist(point, worst) then
            army.stepped.escort = army.stepped.escort + 1
        end
    elseif leader ~= nil then
        local air_near = false
        for _, row in ipairs(world.enemies_near(leader, 1500)) do
            if row.entry ~= nil and row.entry.air and row.entry.armed then
                air_near = true
                break
            end
        end
        point = behind_of(leader, nil, (with_wave and air_near) and escort_close or escort_behind)
    else
        point = rally_point()
    end
    if util.dist(at, point) > escort_slack then
        local last = army.escort_moved[unit.id]
        if last == nil or me.tick - last >= escort_wait or util.free(unit) then
            army.escort_moved[unit.id] = me.tick
            unit:move(util.clamp(util.around(point, (unit.id % 16) / 16, 50), 64))
        end
    end
end

local function step_escorts(escorts)
    if #escorts == 0 then
        return
    end
    local leaders, by_wave, members = {}, {}, {}
    for _, unit in ipairs(soldiers()) do
        local at = util.pos(unit)
        local kind = catalog.of(unit)
        if at ~= nil and not kind.tags.escort and not kind.air then
            local row = {x = at.x, z = at.z, entry = kind}
            leaders[#leaders + 1] = row
            local wave = army.attacking[unit.id] and army.wave_of[unit.id] or nil
            if wave ~= nil then
                if by_wave[wave] == nil then
                    by_wave[wave] = {}
                    members[#members + 1] = wave
                end
                local list = by_wave[wave]
                list[#list + 1] = row
            end
        end
    end
    table.sort(members)
    -- Escorts already given to a wave that still stands.
    local count = {}
    for _, unit in ipairs(escorts) do
        local wave = army.escort_wave[unit.id]
        if wave ~= nil and by_wave[wave] == nil then
            army.escort_wave[unit.id] = nil
        elseif wave ~= nil then
            count[wave] = (count[wave] or 0) + 1
        end
    end
    for _, unit in ipairs(escorts) do
        local entry = catalog.of(unit)
        if army.escort_wave[unit.id] == nil then
            local best, best_share
            for _, wave in ipairs(members) do
                local followed = 0
                for _, row in ipairs(by_wave[wave]) do
                    if can_lead(entry, row.entry) then
                        followed = followed + 1
                    end
                end
                if followed > 0 then
                    local share = (count[wave] or 0) / followed
                    if best_share == nil or share < best_share then
                        best, best_share = wave, share
                    end
                end
            end
            if best ~= nil then
                army.escort_wave[unit.id] = best
                count[best] = (count[best] or 0) + 1
            end
        end
        local wave = army.escort_wave[unit.id]
        step_escort(unit, entry, leaders, wave and by_wave[wave] or nil)
    end
    for id in pairs(army.escort_wave) do
        if world.own[id] == nil then
            army.escort_wave[id] = nil
        end
    end
end

-- Each unit at `from` turns on the best target it can hit near `centre`;
-- returns whether any had one.
local function engage(units, centre, reach)
    local any = false
    for _, unit in ipairs(units) do
        local target, lost = pick(unit, centre, reach)
        if target ~= nil then
            if not keep_range(unit) then
                attack(unit, target)
            end
            any = true
        elseif lost ~= nil then
            chase(unit, lost)
            any = true
        end
    end
    return any
end


local function defend(home)
    local alarm = world.alarm
    if alarm == nil or me.tick - alarm.tick > 30 * 20 then
        return false
    end
    for _, unit in ipairs(home) do
        local target, lost = pick(unit, alarm, 700)
        if keep_range(unit) then
            -- Stepped back from a close enemy.
        elseif target ~= nil then
            attack(unit, target)
        elseif lost ~= nil then
            chase(unit, lost)
        else
            patrol(unit, alarm)
        end
    end
    return true
end

-- The base in danger (user's rule): three own facilities (tag `facility`)
-- destroyed near the base within two minutes, or the commander hit by a unit
-- that is no aircraft. Then every soldier in a wave comes home and no wave
-- leaves until the enemy is driven off: no armed enemy in sight within 1 600
-- of the base or the commander for twenty seconds. Bombers and gunships come
-- too; fighters stay on their patrols unless enemy aircraft are among the
-- attackers.
local emergency_reach = 1600
local facility_window = 30 * 120
local facilities_lost = 3
local quiet_needed = 30 * 20
army.emergency = nil -- {reason, since, quiet, x, z} while the base is in danger
army.facility_losses = {} -- ticks own facilities were lost near the base
army.facility_at = {} -- own facility id -> {x, z}, read while it stands

local function note_facilities()
    for _, unit in ipairs(world.select(function(u, e) return e.structure and e.tags.facility and world.finished(u) end)) do
        if army.facility_at[unit.id] == nil then
            local at = util.pos(unit)
            if at ~= nil then
                army.facility_at[unit.id] = {x = at.x, z = at.z}
            end
        end
    end
end

local function danger_points()
    local points = {}
    local base = world.base or world.start
    if base ~= nil then
        points[#points + 1] = base
    end
    for _, unit in ipairs(world.select(function(_, e) return e.commander end)) do
        local at = util.pos(unit)
        if at ~= nil then
            points[#points + 1] = at
        end
    end
    return points
end

-- The armed enemy nearest the base or the commander, and whether enemy
-- aircraft are among them.
local function attackers_near()
    local nearest, nearest_d, air = nil, nil, false
    for _, point in ipairs(danger_points()) do
        for _, row in ipairs(world.enemies_near(point, emergency_reach)) do
            local kind = row.entry
            if kind ~= nil and kind.armed then
                if kind.air then
                    air = true
                end
                local d = util.dist(point, row)
                if nearest_d == nil or d < nearest_d then
                    nearest, nearest_d = row, d
                end
            end
        end
    end
    return nearest, air
end

local function raise_emergency(reason, at)
    if army.emergency == nil then
        army.emergency = {reason = reason, since = me.tick, quiet = nil, x = at.x, z = at.z}
        print(string.format("base in danger (%s) at %.0f,%.0f", reason, at.x, at.z))
    end
    world.alarm = {x = at.x, z = at.z, tick = me.tick}
    factories.raise_alarm(60)
end

-- Who comes home: everything on the ground and the sea, bombers and gunships,
-- fighters only against enemy aircraft.
local function called_home(entry, enemy_air)
    if not entry.air then
        return true
    end
    if entry.bomber or entry.tags.gunship then
        return true
    end
    return enemy_air and (entry.fighter or entry.tags.fighter == true)
end

local function watch_emergency()
    local state = army.emergency
    if state == nil then
        return false
    end
    local enemy, enemy_air = attackers_near()
    if enemy ~= nil then
        state.quiet = nil
        state.x, state.z = enemy.x, enemy.z
        world.alarm = {x = enemy.x, z = enemy.z, tick = me.tick}
    elseif state.quiet == nil then
        state.quiet = me.tick
    elseif me.tick - state.quiet >= quiet_needed then
        print(string.format("base safe after %d s (%s)", (me.tick - state.since) // 30, state.reason))
        army.emergency = nil
        return false
    end
    local called = 0
    for id in pairs(army.attacking) do
        local unit = world.own[id]
        local entry = unit ~= nil and catalog.of(unit)
        if entry and called_home(entry, enemy_air) then
            army.attacking[id] = nil
            army.patrolled[id] = nil
            called = called + 1
        end
    end
    if called > 0 then
        print(string.format("base in danger: %d units called home", called))
    end
    return true
end

function army.on_lost(unit, entry)
    local since = army.mending[unit.id]
    if since ~= nil then
        local to = army.mend_to[unit.id]
        print(string.format("repair: %s lost after %d s on its way home or waiting",
            to and to.name or (entry and entry.name) or "?", (me.tick - since) // 30))
        army.mending[unit.id] = nil
        army.mend_to[unit.id] = nil
    end
    local at = army.facility_at[unit.id]
    army.facility_at[unit.id] = nil
    if entry == nil or not entry.tags.facility or not entry.structure then
        return
    end
    local base = world.base or world.start
    if at == nil or base == nil or util.dist(at, base) > emergency_reach then
        return
    end
    local recent = {}
    for _, tick in ipairs(army.facility_losses) do
        if me.tick - tick < facility_window then
            recent[#recent + 1] = tick
        end
    end
    recent[#recent + 1] = me.tick
    army.facility_losses = recent
    if #recent >= facilities_lost then
        raise_emergency(#recent .. " facilities lost", at)
    end
end

local function send_wave(home)
    local base = world.base or world.start
    local target = world.enemy_target(base)
    if target == nil then
        return false
    end
    army.target = target
    army.sent_at = me.tick
    army.wave_count = army.wave_count + 1
    army.wave_size[army.wave_count] = #home
    for _, unit in ipairs(home) do
        unit:patrol(util.clamp(target, 64))
        army.attacking[unit.id] = true
        army.wave_of[unit.id] = army.wave_count
    end
    print(string.format("wave of %d units (worth %.0f) to %.0f,%.0f", #home, worth(home), target.x, target.z))
    return true
end

-- Waves stay together (user's rule, after units fought on alone): a wave
-- down to fewer than five units joins the nearest wave that still has five
-- or more, and its units attack-move to that wave's middle until they are
-- within 700 units of it. With no such wave, the weak waves out join the
-- largest of them when together they make five; else it falls back to the
-- rally point and leaves with the next one. Only a wave that lost units:
-- one sent with fewer than five goes straight on (on Seven Islands small
-- fresh waves chased the middle of the one ahead and won no game). Units
-- back in the waves without a wave (mended in the field) count as a reduced
-- wave of their own. A unit that cannot get to the wave it would join falls
-- back.
army.wave_of = {} -- unit id -> its wave's number
army.wave_size = {} -- wave number -> units it left with
army.wave_count = 0
army.joining = {} -- unit id -> wave number it walks to
local wave_min = 5
local regroup_near = 700

local function regroup(attackers)
    local groups, order = {}, {}
    for _, unit in ipairs(attackers) do
        local wave = army.wave_of[unit.id] or 0
        local group = groups[wave]
        if group == nil then
            group = {wave = wave, units = {}, sx = 0, sz = 0, placed = 0}
            groups[wave] = group
            order[#order + 1] = group
        end
        group.units[#group.units + 1] = unit
        local at = util.pos(unit)
        if at ~= nil and not catalog.of(unit).air then
            group.sx, group.sz, group.placed = group.sx + at.x, group.sz + at.z, group.placed + 1
        end
    end
    for _, group in ipairs(order) do
        if group.placed > 0 then
            group.mid = {x = group.sx / group.placed, z = group.sz / group.placed}
        end
    end
    local strong, weak = {}, {}
    for _, group in ipairs(order) do
        if #group.units >= wave_min then
            strong[#strong + 1] = group
        elseif group.wave == 0 or #group.units < (army.wave_size[group.wave] or 0) then
            weak[#weak + 1] = group
        end
    end
    local rally = rally_point()
    local function fall_back(unit)
        army.attacking[unit.id] = nil
        army.wave_of[unit.id] = nil
        army.joining[unit.id] = nil
        army.patrolled[unit.id] = nil
        army.aimed[unit.id] = nil
        unit:move(world.clear_spot(util.clamp(util.around(rally, brain.random(1000) / 1000, 150), 64)))
    end
    local function join(group, into, why)
        local back = 0
        for _, unit in ipairs(group.units) do
            if catalog.of(unit).air or util.reachable(unit, into.mid) ~= false then
                army.wave_of[unit.id] = into.wave
                army.joining[unit.id] = into.wave
            else
                fall_back(unit)
                back = back + 1
            end
        end
        print(string.format("wave %d (%d units) joins wave %d (%s)%s", group.wave, #group.units - back, into.wave, why,
            back > 0 and string.format(", %d cannot get there and fall back", back) or ""))
    end
    if #strong == 0 and #weak > 1 then
        local total, largest = 0, nil
        for _, group in ipairs(weak) do
            total = total + #group.units
            if largest == nil or #group.units > #largest.units then
                largest = group
            end
        end
        if total >= wave_min and largest.mid ~= nil then
            for _, group in ipairs(weak) do
                if group ~= largest then
                    join(group, largest, "together five or more")
                end
            end
            return
        end
    end
    for _, group in ipairs(weak) do
        local best, best_d
        for _, other in ipairs(strong) do
            if other.mid ~= nil and group.mid ~= nil then
                local d = util.dist(group.mid, other.mid)
                if best_d == nil or d < best_d then
                    best, best_d = other, d
                end
            end
        end
        if best ~= nil then
            join(group, best, "down to " .. #group.units)
        elseif group.wave ~= 0 then
            for _, unit in ipairs(group.units) do
                fall_back(unit)
            end
            print(string.format("wave %d down to %d units: back to the rally point", group.wave, #group.units))
        end
    end
    army.wave_mid = {}
    for _, group in ipairs(order) do
        army.wave_mid[group.wave] = group.mid
    end
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
    util.guard("regroup", regroup, attackers)
    for _, unit in ipairs(attackers) do
        local at = util.pos(unit)
        local entry = catalog.of(unit)
        local joining = army.joining[unit.id]
        local mid = joining ~= nil and army.wave_mid and army.wave_mid[joining]
        if joining ~= nil and (not army.attacking[unit.id] or mid == nil or (at ~= nil and util.dist(at, mid) <= regroup_near)) then
            army.joining[unit.id] = nil
            mid = nil
            -- Its patrol to the wave's middle would go back and forth for
            -- ever (a patrol loops, and only a free unit is sent on): the
            -- joined wave stood still for minutes on Seven Islands.
            if army.attacking[unit.id] and target ~= nil then
                army.patrolled[unit.id] = nil
                patrol(unit, target)
            end
        end
        if mid and at ~= nil then
            -- On its way to the wave it joins, fighting on the way.
            patrol(unit, mid)
        else
            -- Bombers look further for anti-air to take out, then their list.
            local enemy, lost
            if at ~= nil then
                enemy, lost = pick(unit, at, entry.bomber and 1400 or 800)
            end
            local contact = enemy == nil and lost == nil and at and world.nearest_contact(at, 1200, entry)
            if keep_range(unit) then
                -- Stepped back from a close enemy.
            elseif enemy ~= nil then
                attack(unit, enemy)
            elseif lost ~= nil then
                chase(unit, lost)
            elseif contact then
                -- Seen only on radar or sonar: close in, fighting on the way.
                patrol(unit, contact)
            elseif target ~= nil and util.free(unit) then
                patrol(unit, target)
            end
        end
    end
end

-- Aircraft attacking a base pull back when the anti-air around them is
-- too strong for their number: they wait at home a minute and leave with
-- the next wave. Bombers stay (they go for the anti-air), and scouts are
-- not soldiers. Strength is the threat level: a level-3 gun is worth three.
local function strength(entry)
    return math.max(1, entry.threat)
end

local function pull_back_aircraft(attackers)
    local keep = {}
    for _, unit in ipairs(attackers) do
        local entry = catalog.of(unit)
        local at = util.pos(unit)
        local retreat = false
        if entry.air and not entry.bomber and at ~= nil then
            local guns = 0
            for _, row in ipairs(world.enemies_near(at, 1100)) do
                if world.anti_air(row.entry) then
                    guns = guns + strength(row.entry)
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

-- An ally's base under attack (user's rule, after a 4-seat game where the
-- stronger ally sent every wave at the enemy while its ally's base was
-- razed): armed enemies with threat levels adding up to 8 or more within
-- 1 600 units of a live ally's start. While the seat's own base is not in
-- danger, half of its army (the units nearest that base, from home and from
-- the waves) goes to defend it; the other half goes on as before. They come
-- back once no such enemy has been seen there for 20 seconds, the ally is
-- dead, or the seat's own base is in danger. The rule before it looked for
-- enemies among any allied units, so it mostly answered the ally's own
-- waves in the enemy base, and only with the units left at home.
local rescue_threat = 8
local rescue_reach = 1600
army.rescuing = {} -- unit id -> true while it defends an ally's base
army.ally_alarm = nil -- {player, x, z, quiet, staffed}

local function heavy_attack_at_home()
    local base = world.base or world.start
    if base == nil or world.alarm == nil or me.tick - world.alarm.tick > 30 * 30 then
        return false
    end
    local armed = 0
    for _, row in ipairs(world.enemies_near(base, 1500)) do
        local kind = row.entry
        if kind ~= nil and (kind.combat or kind.commander) then
            armed = armed + 1
        end
    end
    return armed >= 5
end

-- The live ally's base with the most armed enemy threat near its start,
-- and that threat.
function army.ally_in_danger()
    local players = me:players()
    if type(players) ~= "table" then
        return nil
    end
    local best, best_threat
    for _, row in ipairs(players) do
        if row.player ~= me.player and row.alive and row.start_x ~= nil and me:allied(row.player) == true then
            local start = {x = util.whole(row.start_x), z = util.whole(row.start_z)}
            local threat = 0
            for _, enemy in ipairs(world.enemies_near(start, rescue_reach)) do
                local kind = enemy.entry
                if kind ~= nil and kind.armed and not kind.structure then
                    threat = threat + math.max(1, kind.threat or 1)
                end
            end
            if threat >= rescue_threat and (best_threat == nil or threat > best_threat) then
                best, best_threat = {player = row.player, x = start.x, z = start.z}, threat
            end
        end
    end
    return best, best_threat
end

local function release_rescuers(reason)
    local count = util.count(army.rescuing)
    army.rescuing = {}
    if army.ally_alarm ~= nil then
        print(string.format("ally base at %.0f,%.0f: %s, %d units back", army.ally_alarm.x, army.ally_alarm.z, reason, count))
    end
    army.ally_alarm = nil
end

-- Sends half the army to the ally's base and keeps the rescuers fighting
-- there; called before the army is split into home, waves and rescuers.
local function watch_allies(pool)
    if army.emergency ~= nil or heavy_attack_at_home() then
        if army.ally_alarm ~= nil then
            release_rescuers("own base in danger")
        end
        return
    end
    local attack, threat = army.ally_in_danger()
    local alarm = army.ally_alarm
    if attack ~= nil then
        if alarm == nil or alarm.player ~= attack.player then
            if alarm ~= nil then
                release_rescuers("another ally attacked")
            end
            alarm = {player = attack.player, x = attack.x, z = attack.z}
            army.ally_alarm = alarm
        end
        alarm.quiet = nil
        alarm.threat = threat
    elseif alarm ~= nil then
        alarm.quiet = alarm.quiet or me.tick
        if me.tick - alarm.quiet >= 30 * 20 then
            release_rescuers("safe")
            return
        end
    else
        return
    end
    -- Staffed once, and again when the rescuers fell (at most every minute).
    for id in pairs(army.rescuing) do
        if world.own[id] == nil then
            army.rescuing[id] = nil
        end
    end
    if util.count(army.rescuing) == 0 and (alarm.staffed == nil or me.tick - alarm.staffed > 30 * 60) then
        local sorted = {}
        for _, unit in ipairs(pool) do
            local at = util.pos(unit)
            if at ~= nil and (terrain.useful(catalog.of(unit)) or catalog.of(unit).air)
                and util.reachable(unit, alarm) ~= false then
                sorted[#sorted + 1] = {unit = unit, d = util.dist(at, alarm)}
            end
        end
        table.sort(sorted, function(p, q) return p.d < q.d end)
        local half = math.ceil(#pool / 2)
        if #sorted >= 3 then
            for index = 1, math.min(half, #sorted) do
                local unit = sorted[index].unit
                army.rescuing[unit.id] = true
                army.attacking[unit.id] = nil
            end
            alarm.staffed = me.tick
            print(string.format("ally base attacked at %.0f,%.0f (threat %d): %d of %d units go to defend it",
                alarm.x, alarm.z, alarm.threat or 0, util.count(army.rescuing), #pool))
        end
    end
end

-- Rescuers fight what is near them; on the way and with nothing in sight
-- they attack-move to the ally's base or the enemies near it.
local function step_rescuers(rescuers)
    local alarm = army.ally_alarm
    if alarm == nil then
        return
    end
    for _, unit in ipairs(rescuers) do
        local at = util.pos(unit)
        if at ~= nil then
            local target, lost
            if util.dist(at, alarm) < rescue_reach + 600 then
                target, lost = pick(unit, at, 900)
            end
            if keep_range(unit) then
                -- Stepped back from a close enemy.
            elseif target ~= nil then
                attack(unit, target)
            elseif lost ~= nil then
                chase(unit, lost)
            else
                local enemy = nearest_enemy(alarm, rescue_reach)
                patrol(unit, (enemy and util.pos(enemy)) or alarm)
            end
        end
    end
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

-- Veterans (user's rule: kills at the first veteran level of the type, the
-- mod's VeterancyThresholds or 5) and units worth 5 000 metal or more fall
-- back below half health and wait until fully mended before they fight
-- again. Aircraft go to repair pads instead. Where to (user's rule, after
-- veterans died on the walk home from the enemy base): to a field medic
-- (tag `repair`) when one is free, can reach the unit and is nearer than
-- home; else home when home is within 2 500 units and some builder could
-- come to mend them; else the unit fights on until a medic comes or it
-- dies. One that waits three minutes unmended goes back to the army.
army.mending = {} -- unit id -> tick it fell back
army.mend_checked = {} -- unit id -> tick its fall-back was last weighed
army.fought_on = 0 -- hurt units that fought on, far from home with no medic
local fight_noted = {} -- unit id -> true once its fighting on was logged
local mend_value = 5000
local mend_below = 50
local mend_wait = 30 * 180
local near_home = 2500

local function veteran(unit, entry)
    return util.num(unit.kills) >= (entry.veteran_kills or 5)
end

local function any_mender(unit)
    for _, builder in ipairs(world.select(function(u, e)
        return (e.mobile_builder or e.medic) and not e.commander and world.finished(u)
    end)) do
        if builders.reaches_work(builder, unit) then
            return true
        end
    end
    return false
end

-- Field medics: the units tagged `repair` that the engine lets repair
-- (catalog `medic`). They keep 900 units behind the waves, out of reach of
-- the enemy guns they know of (`army.field`), or at the rally point with no
-- wave out, on a short patrol there (a patrolling builder mends what it
-- passes). A medic takes up to three patients, mends them one at a time,
-- and goes home itself below half health.
army.medic_job = {} -- medic id -> patient ids
army.medic_order = {} -- medic id -> tick of its last order
army.medic_home = {} -- medic id -> tick it went home hurt
army.medic_to = {} -- medic id -> the spot it was last sent to
army.field = nil -- {x, z}: where the medics wait behind the waves
local medic_reach = 2500
local medic_patients = 3
local field_behind = 900

local function medics()
    return world.select(function(u, e) return e.medic and world.finished(u) end)
end

local function free_medic(unit, at)
    local best, best_d
    for _, medic in ipairs(medics()) do
        local job = army.medic_job[medic.id]
        if army.medic_home[medic.id] == nil and (job == nil or #job < medic_patients) then
            local from = util.pos(medic)
            local d = from and util.dist(from, at)
            if d ~= nil and d <= medic_reach and (best_d == nil or d < best_d)
                and builders.reaches_work(medic, unit) then
                best, best_d = medic, d
            end
        end
    end
    return best, best_d
end

local function send_to_mend(unit)
    local entry = catalog.of(unit)
    if entry == nil or not entry.combat or entry.air or entry.mobile_builder or army.mending[unit.id] then
        return
    end
    -- The killing hit comes as damage too: a unit at 0 % is dead (the
    -- user's log had Champions and Chimeras sent at 0 % and lost at once).
    local health = util.num(unit.health_percent)
    if health >= mend_below or health <= 0 or not util.alive(unit) then
        return
    end
    if entry.metal < mend_value and not veteran(unit, entry) then
        return
    end
    -- Weighed at most every three seconds: hits come many times a second.
    local last = army.mend_checked[unit.id]
    if last ~= nil and me.tick - last < 30 * 3 then
        return
    end
    army.mend_checked[unit.id] = me.tick
    local at = util.pos(unit)
    local home = world.base or world.start
    if at == nil or home == nil then
        return
    end
    local home_d = util.dist(at, home)
    local medic, medic_d = free_medic(unit, at)
    if medic ~= nil and medic_d < home_d then
        local spot = util.pos(medic)
        army.mended_count = (army.mended_count or 0) + 1
        army.field_count = (army.field_count or 0) + 1
        army.mending[unit.id] = me.tick
        army.mend_to[unit.id] = {x = spot.x, z = spot.z, tries = 1, name = entry.name, medic = medic.id}
        army.attacking[unit.id] = nil
        local job = army.medic_job[medic.id] or {}
        job[#job + 1] = unit.id
        army.medic_job[medic.id] = job
        unit:move(util.clamp(spot, 64))
        if #job == 1 then
            medic:repair(unit)
            army.medic_order[medic.id] = me.tick
        end
        print(string.format("repair: %s to medic %s %.0f units off (home %.0f; %d%% health, %d kills)",
            entry.name, catalog.of(medic).name, medic_d, home_d, util.num(unit.health_percent), util.num(unit.kills)))
        return
    end
    if home_d > near_home then
        if not fight_noted[unit.id] then
            fight_noted[unit.id] = true
            army.fought_on = army.fought_on + 1
            print(string.format("repair: %s fights on, home %.0f units off and no medic near (%d%% health)",
                entry.name, home_d, util.num(unit.health_percent)))
        end
        return
    end
    local point = army.mend_point(unit)
    if point == nil or not any_mender(unit) then
        return
    end
    army.mended_count = (army.mended_count or 0) + 1
    army.mending[unit.id] = me.tick
    army.mend_to[unit.id] = {x = point.x, z = point.z, tries = 1, name = entry.name}
    army.attacking[unit.id] = nil
    unit:move(point)
    builders.mend_unit(unit)
    print(string.format("repair: %s home from %.0f units (%d%% health, %d kills)", entry.name,
        util.dist(at, point), util.num(unit.health_percent), util.num(unit.kills)))
end

-- Where a hurt unit waits for repair: by the base, or for a ship (and
-- anything that cannot get to the base) on the water by it. A Torrent
-- sent onto land stood still in Standby, badly hurt, for the rest of
-- the match.
army.mend_to = {} -- unit id -> {x, z, tries, name, medic}

function army.mend_point(unit)
    local home = world.base or world.start
    if home == nil then
        return nil
    end
    local entry = catalog.of(unit)
    local point = world.clear_spot(util.clamp(util.around(home, brain.random(1000) / 1000, 250), 64))
    -- Only a sure no: past the turn's budget reachable answers nil, and a
    -- land unit was then sent to the shore.
    if entry.water_only or util.reachable(unit, point) == false then
        local water = terrain.shore or terrain.water_point
        if water ~= nil then
            point = util.clamp(util.around(water, brain.random(1000) / 1000, 120), 64)
        end
    end
    return point
end

-- Lets a patient go: it is weighed again at once (another medic, home, or
-- fighting on).
local function drop_patient(id)
    army.mending[id] = nil
    army.mend_to[id] = nil
    army.mend_checked[id] = nil
end

-- A unit falling back that stands idle short of its spot (a failed path
-- stops it, see hooks.onPathFailed) is sent again. It used to rejoin the
-- army after three tries, nine seconds of army steps: in the user's game a
-- Penetrator turned home and was back on patrol a few seconds later. Now it
-- keeps trying, from the third try by a point halfway home (a shorter path),
-- and only the three minutes unmended let it go. A patient of a medic
-- follows its medic; with the medic dead or gone home it is weighed again.
local function keep_mending()
    for id in pairs(army.mending) do
        local unit = world.own[id]
        local to = army.mend_to[id]
        local at = unit and util.pos(unit)
        if unit ~= nil and to ~= nil and at ~= nil and to.medic ~= nil then
            local medic = world.own[to.medic]
            local spot = medic and army.medic_home[to.medic] == nil and util.pos(medic)
            if not spot then
                drop_patient(id)
            elseif util.dist(at, spot) > 250 and (util.free(unit) or util.dist(to, spot) > 400) then
                to.x, to.z = spot.x, spot.z
                unit:move(util.clamp(spot, 64))
            end
        elseif unit ~= nil and to ~= nil and at ~= nil and util.free(unit) and util.dist(at, to) > 300 then
            local point = army.mend_point(unit)
            if point == nil then
                break
            end
            to.tries = to.tries + 1
            to.x, to.z = point.x, point.z
            if to.tries >= 3 and util.dist(at, point) > 1200 then
                point = util.clamp({x = (at.x + point.x) / 2, z = (at.z + point.z) / 2}, 64)
            end
            unit:move(point)
        end
    end
end

-- Where the medics wait while waves are out: 900 units from the middle of
-- the front (the attackers at least 70 % as far from home as the farthest:
-- waves leave one after another, and the middle of all of them lay by the
-- base) toward home, then further back, 400 at a time, while a known enemy
-- gun reaches it; never past home.
local function field_zone(attackers)
    local home = world.base or world.start
    if home == nil then
        army.field = nil
        return
    end
    local placed, farthest = {}, 0
    for _, unit in ipairs(attackers) do
        local at = not catalog.of(unit).air and util.pos(unit)
        if at then
            local d = util.dist(at, home)
            placed[#placed + 1] = {at = at, d = d}
            farthest = math.max(farthest, d)
        end
    end
    local sx, sz, count = 0, 0, 0
    for _, row in ipairs(placed) do
        if row.d >= farthest * 0.7 then
            sx, sz, count = sx + row.at.x, sz + row.at.z, count + 1
        end
    end
    if count == 0 then
        army.field = nil
        return
    end
    local cx, cz = sx / count, sz / count
    local dx, dz = home.x - cx, home.z - cz
    local length = math.sqrt(dx * dx + dz * dz)
    if length < field_behind * 1.5 then
        army.field = nil
        return
    end
    local ux, uz = dx / length, dz / length
    local back = field_behind
    local point = {x = cx + ux * back, z = cz + uz * back}
    for _ = 1, 4 do
        local danger = false
        for _, row in ipairs(world.enemies_near(point, 1500)) do
            if armed_on_ground(row.entry) and util.dist(point, row) < row.entry.ground_range + 250 then
                danger = true
                break
            end
        end
        if not danger or back + 400 > length then
            break
        end
        back = back + 400
        point = {x = cx + ux * back, z = cz + uz * back}
    end
    army.field = world.clear_spot(util.clamp(point, 64))
end

local function step_medics()
    local home = world.base or world.start
    local rally = rally_point()
    for _, medic in ipairs(medics()) do
        local id = medic.id
        local at = util.pos(medic)
        local health = util.num(medic.health_percent)
        local last = army.medic_order[id] or 0
        if army.medic_home[id] ~= nil then
            if health >= builders.mend_done then
                army.medic_home[id] = nil
            elseif at ~= nil and home ~= nil and util.free(medic) and util.dist(at, home) > 500 then
                local point = army.mend_point(medic)
                if point ~= nil then
                    medic:move(point)
                end
            end
        elseif health < mend_below then
            army.medic_home[id] = me.tick
            for _, patient in ipairs(army.medic_job[id] or {}) do
                drop_patient(patient)
            end
            army.medic_job[id] = nil
            local point = army.mend_point(medic)
            if point ~= nil then
                medic:move(point)
                builders.mend_unit(medic)
                print(string.format("repair: medic %s goes home (%d%% health)", catalog.of(medic).name, health))
            end
        end
        if army.medic_home[id] == nil and at ~= nil then
            local keep, patient = {}, nil
            for _, patient_id in ipairs(army.medic_job[id] or {}) do
                local other = world.own[patient_id]
                local to = army.mend_to[patient_id]
                if other ~= nil and army.mending[patient_id] and to ~= nil and to.medic == id then
                    keep[#keep + 1] = patient_id
                    if patient == nil and util.num(other.health_percent) < builders.mend_done then
                        patient = other
                    end
                end
            end
            army.medic_job[id] = #keep > 0 and keep or nil
            if patient ~= nil then
                if util.free(medic) or me.tick - last > 30 * 10 then
                    medic:repair(patient)
                    army.medic_order[id] = me.tick
                end
            else
                local spot = army.field or rally
                if spot ~= nil then
                    -- A new order only when the spot moved on or the medic
                    -- stopped: every new order is a new path search, and a
                    -- Necro given one every few seconds hardly left the base.
                    local going = army.medic_to[id]
                    if util.dist(at, spot) > 300 then
                        if util.free(medic) or going == nil or util.dist(going, spot) > 500 then
                            local point = world.clear_spot(util.clamp(util.around(spot, brain.random(1000) / 1000, 120), 64))
                            medic:move(point)
                            army.medic_order[id] = me.tick
                            army.medic_to[id] = {x = spot.x, z = spot.z}
                        end
                    elseif util.free(medic) then
                        medic:patrol(util.clamp(util.around(spot, brain.random(1000) / 1000, 150), 64))
                        army.medic_order[id] = me.tick
                    end
                end
            end
        end
    end
    for _, table_ in ipairs({army.medic_job, army.medic_order, army.medic_home, army.medic_to}) do
        for id in pairs(table_) do
            if world.own[id] == nil then
                table_[id] = nil
            end
        end
    end
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
    for _, row in ipairs(world.enemies_near(at, reach)) do
        local kind = row.entry
        if world.anti_air(kind) and not kind.air then
            local d = util.dist(at, row)
            if best_key == nil or kind.tier * 100000 - d > best_key then
                best, best_key = row.unit, kind.tier * 100000 - d
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
    world.track_contacts()
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
                        if d <= reach and world.can_hit(entry, building.entry) then
                            local key = world.rank(entry, building.entry) * 100000 + building.cost - d
                            if best_key == nil or key > best_key then
                                best, best_key = building, key
                            end
                        end
                    end
                    -- Nothing remembered in range: a radar or sonar contact
                    -- the gun can hit that stood still (a building); a
                    -- moving one is gone by the time the shell lands.
                    local what = best ~= nil and best.entry ~= nil and best.entry.name or "remembered building"
                    if best == nil then
                        best = world.nearest_contact(at, reach, entry, true)
                        what = "still contact"
                    end
                    if best ~= nil then
                        gun:attack_ground({x = best.x, z = best.z})
                        army.gun_orders[gun.id] = me.tick
                        print(string.format("%s shells %s at %.0f,%.0f", entry.name, what, best.x, best.z))
                    end
                end
            end
        end
    end
end

-- Units that can cloak by order (tag `invisible` with a cost at rest), but
-- for the commander (builders.lua): one more cloaks each step while the
-- energy store is over 60 % and income pays for it, all drop it under 20 %.
army.cloaked = {} -- unit id -> true

local function manage_cloak()
    local e = economy.now
    if e == nil then
        return
    end
    for id in pairs(army.cloaked) do
        if world.own[id] == nil then
            army.cloaked[id] = nil
        end
    end
    if e.energy_share < 0.2 then
        for id in pairs(army.cloaked) do
            world.own[id]:cloak(false)
            army.cloaked[id] = nil
        end
        return
    end
    if e.energy_share <= 0.6 then
        return
    end
    local spare = e.energy_income - e.energy_demand
    for _, unit in ipairs(world.select(function(u, k) return k.cloakable and not k.commander and world.finished(u) end)) do
        if not army.cloaked[unit.id] then
            local record = catalog.of(unit).record
            local cost = math.max(util.num(record.cloakcost), util.num(record.cloakcostmoving))
            if spare > cost then
                unit:cloak(true)
                army.cloaked[unit.id] = true
                return
            end
        end
    end
end

-- Careful shooters hold fire and are given their targets: paralyzers
-- (they would waste shots on units immune to them) and Bastion (its blast
-- hits own and allied units near the target, and it must never fire at
-- aircraft). A careful building with no fit target stops.
army.held = {} -- unit id -> true once put on hold fire

local function aim_careful()
    for _, unit in ipairs(world.select(function(u, e) return e.careful and world.finished(u) end)) do
        if not army.held[unit.id] then
            unit:stance({fire = "hold"})
            army.held[unit.id] = true
        end
        local entry = catalog.of(unit)
        if entry.structure then
            local at = util.pos(unit)
            if at ~= nil then
                local target = world.best_target(at, entry.range, entry)
                if target ~= nil then
                    attack(unit, target)
                elseif army.aimed[unit.id] ~= nil then
                    army.aimed[unit.id] = nil
                    unit:stop()
                end
            end
        end
    end
end

-- Air raids on ground units. A swarm is four or more enemy aircraft that
-- hit ground targets within 600 units of own or allied ground units. Own
-- ground units without anti-air near a swarm fall back to the nearest
-- anti-air (mobile or a tower, own or allied) within 2 000 units, and
-- every fighter of the seat goes for the raiders.
local swarm_size = 4
army.sheltering = {} -- unit id -> tick it fell back to anti-air
army.intercepting = {} -- fighter id -> tick it was sent

local function swarms()
    local raiders = {}
    for _, row in ipairs(world.enemy_rows()) do
        local kind = row.entry
        if kind ~= nil and kind.air and kind.armed and kind.hits_ground then
            raiders[#raiders + 1] = row
        end
    end
    local found = {}
    if #raiders < swarm_size then
        return found, raiders
    end
    local used = {}
    for index, row in ipairs(raiders) do
        if not used[index] then
            local count, sx, sz = 0, 0, 0
            for other, near in ipairs(raiders) do
                if not used[other] and util.dist2(row, near) <= 600 * 600 then
                    count, sx, sz = count + 1, sx + near.x, sz + near.z
                    used[other] = true
                end
            end
            if count >= swarm_size then
                local centre = {x = sx // count, z = sz // count, count = count}
                local victims = 0
                for _, friend in ipairs(world.friends_in(centre, 600)) do
                    if friend.entry ~= nil and not friend.entry.air then
                        victims = victims + 1
                    end
                end
                if victims > 0 then
                    found[#found + 1] = centre
                end
            end
        end
    end
    return found, raiders
end

local function nearest_anti_air(at, reach)
    local best, best_d
    for _, row in ipairs(world.friends_in(at, reach)) do
        local kind = row.entry
        if kind ~= nil and not kind.air and kind.anti_air and kind.armed and (kind.mobile_anti_air or kind.defense) then
            local d = util.dist(at, row)
            if d > 150 and (best_d == nil or d < best_d) then
                best, best_d = row, d
            end
        end
    end
    return best
end

local function air_cover(units)
    local found, raiders = swarms()
    if #found == 0 then
        return
    end
    local sheltered, sent = 0, 0
    for _, unit in ipairs(units) do
        local entry = catalog.of(unit)
        local at = util.pos(unit)
        local last = army.sheltering[unit.id]
        local moving = last ~= nil and me.tick - last < 30 * 15
        if at ~= nil and not moving and not entry.air and not entry.anti_air and not entry.structure then
            for _, swarm in ipairs(found) do
                if util.dist(at, swarm) <= 700 then
                    local shelter = nearest_anti_air(at, 2000)
                    if shelter ~= nil then
                        unit:move(util.clamp(util.around(shelter, brain.random(1000) / 1000, 80), 64))
                        army.sheltering[unit.id] = me.tick
                        sheltered = sheltered + 1
                    end
                    break
                end
            end
        end
    end
    for _, fighter in ipairs(world.select(function(u, e) return e.fighter and world.finished(u) end)) do
        local at = util.pos(fighter)
        if at ~= nil and not army.air_mending[fighter.id] then
            local best, best_d
            for _, swarm in ipairs(found) do
                local d = util.dist(at, swarm)
                if best_d == nil or d < best_d then
                    best, best_d = swarm, d
                end
            end
            local target = world.best_target(best, 900, catalog.of(fighter))
            local chased = army.intercepting[fighter.id]
            if target ~= nil then
                attack(fighter, target)
            elseif chased == nil or me.tick - chased > 30 * 8 then
                fighter:patrol(util.clamp(best, 64))
            end
            army.intercepting[fighter.id] = me.tick
            sent = sent + 1
        end
    end
    if sheltered + sent > 0 and (army.cover_log == nil or me.tick - army.cover_log > 30 * 30) then
        army.cover_log = me.tick
        print(string.format("air raid (%d raiders): %d units to anti-air, %d fighters sent", #raiders, sheltered, sent))
    end
end

-- Units falling back to anti-air or chasing raiders are left to it for a
-- while.
local function busy(unit)
    local shelter = army.sheltering[unit.id]
    if shelter ~= nil and me.tick - shelter < 30 * 10 then
        return true
    end
    local scattered = army.scattered[unit.id]
    if scattered ~= nil and me.tick - scattered < scatter_busy then
        return true
    end
    local chase = army.intercepting[unit.id]
    return chase ~= nil and me.tick - chase < 30 * 8
end

-- Gunships and bombers flee enemy fighters (user's rule): with more enemy
-- fighters within 1 400 than own fighters there, by threat level, they
-- fly to the nearest own or allied anti-air within 5 000 (else home) and
-- sit out the next minute, like aircraft pulling back from anti-air.
local function is_fighter(kind)
    return kind ~= nil and kind.air and (kind.fighter or kind.tags.fighter == true)
end

local function flee_fighters()
    local strikers = world.select(function(u, e)
        return e.air and e.combat and not is_fighter(e) and not e.scout and world.finished(u)
    end)
    if #strikers == 0 then
        return
    end
    local own_fighters = {}
    for _, fighter in ipairs(world.select(function(u, e) return is_fighter(e) and world.finished(u) end)) do
        local at = util.pos(fighter)
        if at ~= nil then
            own_fighters[#own_fighters + 1] = {x = at.x, z = at.z, entry = catalog.of(fighter)}
        end
    end
    local fled = 0
    for _, unit in ipairs(strikers) do
        local at = util.pos(unit)
        local last = army.sheltering[unit.id]
        if at ~= nil and not army.air_mending[unit.id] and (last == nil or me.tick - last >= 30 * 10) then
            local foes = 0
            for _, row in ipairs(world.enemies_near(at, 1400)) do
                if is_fighter(row.entry) then
                    foes = foes + strength(row.entry)
                end
            end
            if foes > 0 then
                local own = 0
                for _, row in ipairs(own_fighters) do
                    if util.dist(at, row) <= 1400 then
                        own = own + strength(row.entry)
                    end
                end
                if foes > own then
                    local shelter = nearest_anti_air(at, 5000) or world.front(200)
                    unit:move(util.clamp(util.around(shelter, brain.random(1000) / 1000, 100), 64))
                    army.sheltering[unit.id] = me.tick
                    army.attacking[unit.id] = nil
                    army.patrolled[unit.id] = nil
                    army.aimed[unit.id] = nil
                    army.grounded[unit.id] = me.tick
                    fled = fled + 1
                end
            end
        end
    end
    if fled > 0 then
        print(string.format("aircraft flee enemy fighters: %d", fled))
    end
end

-- Units without anti-air leave aircraft alone (user's rule): the engine's
-- own target pick on a patrol lets ground weapons take low-flying aircraft
-- (construction aircraft at work), which they hardly hit. A unit whose
-- current attack is on an aircraft in the air gets the best ground target
-- near it, else steps on toward where it was going.
local function airborne(target)
    local x, z = util.whole(target.x), util.whole(target.z)
    local ok, ground = pcall(function() return game.map:ground(x, z) end)
    if not ok or ground == nil then
        return true
    end
    local surface = math.max(util.num(ground), util.num(game.map.sea_level))
    return util.num(target.y) > surface + 24
end

local function drop_air_chases(units)
    local dropped = 0
    for _, unit in ipairs(units) do
        local entry = catalog.of(unit)
        local at = util.pos(unit)
        if at ~= nil and not entry.anti_air and not entry.air and not army.mending[unit.id] then
            local air_near = false
            for _, row in ipairs(world.enemies_near(at, 900)) do
                if row.entry ~= nil and row.entry.air then
                    air_near = true
                    break
                end
            end
            if air_near then
                -- The engine's attack may come behind a short move.
                local orders = unit:orders()
                local head, target = nil, nil
                for index = 1, 2 do
                    local order = type(orders) == "table" and orders[index] or nil
                    if head == nil and order ~= nil and type(order.kind) == "string"
                        and string.sub(order.kind, 1, 6) == "Attack" then
                        head, target = order, order.target
                    end
                end
                if head ~= nil and (type(target) == "userdata" or type(target) == "table") and target.x ~= nil then
                    local kind = catalog.of(target)
                    if kind ~= nil and kind.air and airborne(target) then
                        army.aimed[unit.id] = nil
                        local best = world.best_target(at, 800, entry)
                        if best ~= nil then
                            attack(unit, best)
                        else
                            local onward = army.attacking[unit.id] and army.target or rally_point()
                            unit:move(util.clamp(util.toward(at, onward, 250), 64))
                            army.scattered[unit.id] = me.tick
                        end
                        dropped = dropped + 1
                    end
                end
            end
        end
    end
    army.air_dropped = (army.air_dropped or 0) + dropped
end

-- Under shells and bombs (artillery, area weapons, any weapon with a wide
-- blast) a wave scatters (user's rule): the soldiers within 450 units of
-- the hit move 180-300 units out from their middle, each its own way
-- with some chance in it, so that one shell hits as few as it can. Then
-- they fight on. At most once in eight seconds round one place. A hit by
-- an unseen shooter counts when two units 200 units apart are hit within
-- three ticks of each other: one blast.
army.scattered = {} -- unit id -> tick it scattered
army.scatters = {}  -- {x, z, tick} of recent scatters
local unknown_hits = {} -- {x, z, tick} of recent hits from unseen shooters
local scatter_reach = 450
local scatter_again = 30 * 8
local scatter_min_splash = 40

local function splashes(kind)
    return kind ~= nil and (kind.tags.artillery or kind.tags.aoe or kind.bomber
        or (kind.splash or 0) >= scatter_min_splash)
end

local function scatter(at)
    local keep = {}
    for _, done in ipairs(army.scatters) do
        if me.tick - done.tick < scatter_again then
            if util.dist(at, done) < scatter_reach * 0.6 then
                return
            end
            keep[#keep + 1] = done
        end
    end
    army.scatters = keep
    local group, sx, sz = {}, 0, 0
    for _, unit in ipairs(soldiers()) do
        local kind = catalog.of(unit)
        local there = util.pos(unit)
        if there ~= nil and kind.mobile and not kind.air and not kind.commander
            and not army.mending[unit.id] and util.dist(at, there) <= scatter_reach then
            group[#group + 1] = {unit = unit, x = there.x, z = there.z}
            sx, sz = sx + there.x, sz + there.z
        end
    end
    if #group < 2 then
        return
    end
    army.scatters[#army.scatters + 1] = {x = at.x, z = at.z, tick = me.tick}
    local mid = {x = sx / #group, z = sz / #group}
    for _, row in ipairs(group) do
        local dx, dz = row.x - mid.x, row.z - mid.z
        local angle
        if dx * dx + dz * dz < 30 * 30 then
            angle = brain.random(1000) / 1000 * 2 * math.pi
        else
            angle = math.atan(dz, dx) + (brain.random(1000) / 1000 - 0.5) * 1.2
        end
        local step = 180 + brain.random(120)
        row.unit:move(util.clamp({x = util.whole(row.x + math.cos(angle) * step),
            z = util.whole(row.z + math.sin(angle) * step)}, 64))
        army.scattered[row.unit.id] = me.tick
        army.patrolled[row.unit.id] = nil
    end
    army.stepped.scattered = (army.stepped.scattered or 0) + #group
end

local function on_splash_hit(unit, attacker, at)
    local kind = catalog.of(unit)
    if kind == nil or not kind.combat or not kind.mobile or kind.air or kind.commander then
        return
    end
    if attacker ~= nil then
        if splashes(catalog.of(attacker)) then
            scatter(at)
        end
        return
    end
    local keep, blast = {}, false
    for _, hit in ipairs(unknown_hits) do
        if me.tick - hit.tick <= 3 then
            keep[#keep + 1] = hit
            if util.dist(at, hit) <= 200 and util.dist(at, hit) > 0 then
                blast = true
            end
        end
    end
    keep[#keep + 1] = {x = at.x, z = at.z, tick = me.tick}
    unknown_hits = keep
    if blast then
        scatter(at)
    end
end

-- Idle units of the seat standing in a factory's lane step out of its side,
-- each at most every ten seconds; looked at every other army step.
army.cleared = {} -- unit id -> tick it was moved out of a lane
local lane_wait = 30 * 10

local function clear_lanes()
    local moved = 0
    for _, unit in ipairs(world.select(function(u, e) return e.mobile and not e.air and world.finished(u) end)) do
        local last = army.cleared[unit.id]
        if last == nil or me.tick - last >= lane_wait then
            local at = util.pos(unit)
            local lane = at and world.in_factory_way(at)
            if lane ~= nil and util.free(unit) then
                army.cleared[unit.id] = me.tick
                unit:move(world.out_of_lane(at, lane))
                moved = moved + 1
            end
        end
    end
    army.lanes_cleared = (army.lanes_cleared or 0) + moved
    for id in pairs(army.cleared) do
        if world.own[id] == nil then
            army.cleared[id] = nil
        end
    end
end

function army.step()
    if (me.tick // 90) % 2 == 0 then
        util.guard("lanes", clear_lanes)
    end
    util.guard("guns", aim_guns)
    util.guard("air repair", send_aircraft_to_pads)
    util.guard("facilities", note_facilities)
    util.guard("emergency", watch_emergency)
    local home, attackers, escorts, rescuers = {}, {}, {}, {}
    for id, since in pairs(army.mending) do
        local unit = world.own[id]
        local to = army.mend_to[id]
        local field = to ~= nil and to.medic ~= nil
        local health = unit ~= nil and util.num(unit.health_percent) or 0
        local mended = unit ~= nil and health >= builders.mend_done
        -- Three minutes, counted from the last gain in health: a Behemoth
        -- mended by one Necro gains slowly and was let go half mended.
        if to ~= nil and (to.best == nil or health > to.best) then
            to.best, to.gained = health, me.tick
        end
        local idle_since = math.max(since, to and to.gained or since)
        local waited = unit ~= nil and not mended and me.tick - idle_since > mend_wait
            and (field or builders.crew_for(unit) == 0)
        if unit == nil or mended or waited then
            -- Mended in the field: back to the wave it left.
            if field and mended and army.target ~= nil then
                army.attacking[id] = true
            end
            if mended then
                fight_noted[id] = nil
            end
            if unit ~= nil then
                print(string.format("repair: %s %s after %d s (%d tries)", catalog.of(unit).name,
                    mended and "mended" or "left unmended", (me.tick - since) // 30,
                    army.mend_to[id] and army.mend_to[id].tries or 0))
            end
            army.mending[id] = nil
            army.mend_to[id] = nil
            if unit ~= nil then
                builders.mend[id] = nil
            end
        end
    end
    for id in pairs(army.mend_checked) do
        if world.own[id] == nil then
            army.mend_checked[id] = nil
            fight_noted[id] = nil
        end
    end
    -- Hurt units not hit again are weighed here too (a medic may have come).
    for _, unit in ipairs(soldiers()) do
        if util.num(unit.health_percent) < mend_below and army.mending[unit.id] == nil then
            send_to_mend(unit)
        end
    end
    util.guard("mending", keep_mending)
    local pool = {}
    for _, unit in ipairs(soldiers()) do
        if not (army.mending[unit.id] or army.air_mending[unit.id] or catalog.of(unit).tags.escort) then
            pool[#pool + 1] = unit
        end
    end
    util.guard("allies", watch_allies, pool)
    util.guard("careful", aim_careful)
    util.guard("cloak", manage_cloak)
    util.guard("air cover", air_cover, soldiers())
    util.guard("flee fighters", flee_fighters)
    util.guard("air chases", drop_air_chases, soldiers())
    for _, unit in ipairs(soldiers()) do
        if army.mending[unit.id] or army.air_mending[unit.id] or busy(unit) then
            -- Waiting at home for the builders, or on a repair pad.
        elseif army.rescuing[unit.id] then
            rescuers[#rescuers + 1] = unit
        elseif catalog.of(unit).tags.escort then
            escorts[#escorts + 1] = unit
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
    for id in pairs(army.wave_of) do
        if not army.attacking[id] then
            army.wave_of[id] = nil
            army.joining[id] = nil
        end
    end
    for id, failed in pairs(army.no_path) do
        if me.tick - failed >= no_path_wait then
            army.no_path[id] = nil
        end
    end
    util.guard("rescuers", step_rescuers, rescuers)
    util.guard("field", field_zone, attackers)
    util.guard("medics", step_medics)
    util.guard("escorts", step_escorts, escorts)
    for id in pairs(army.escort_moved) do
        if world.own[id] == nil then
            army.escort_moved[id] = nil
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
    local mark = wave_worth[math.min(5, world.tier)]
    -- Hard levels wait less; a single experimental may go with an escort.
    if me.difficulty ~= "hard" then
        mark = mark * 0.8
    end
    -- An army idle at home for five minutes leaves with half the mark.
    if me.tick - army.sent_at > 30 * 300 and #ready >= 8 then
        mark = mark * 0.5
    end
    if worth(ready) >= mark and #ready >= 3 and army.emergency == nil then
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
    -- A contact near the rally point, for each unit one it could hit.
    local any = false
    for _, unit in ipairs(home) do
        local contact = world.nearest_contact(rally, 900, catalog.of(unit))
        if contact ~= nil then
            patrol(unit, contact)
            any = true
        end
    end
    if any then
        return
    end
    for _, unit in ipairs(home) do
        local at = util.pos(unit)
        if at ~= nil and util.free(unit) then
            -- An area weapon waits to the side of the others.
            local aside = math.min(catalog.of(unit).blast, apart_limit) * 1.5
            if util.dist(at, rally) > 250 + aside then
                unit:move(world.clear_spot(util.clamp(util.around(rally, brain.random(1000) / 1000, 120 + aside), 64)))
            elseif aside > 0 then
                keep_range(unit)
            end
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
    -- The commander hit by something that is no aircraft.
    if entry ~= nil and entry.commander and attacker ~= nil then
        local kind = catalog.of(attacker)
        if kind ~= nil and not kind.air then
            raise_emergency("commander attacked", at)
        end
    end
    if attacker ~= nil and util.alive(attacker) then
        world.remember(attacker)
    end
    util.guard("scatter", on_splash_hit, unit, attacker ~= nil and util.alive(attacker) and attacker or nil, at)
end

return army
