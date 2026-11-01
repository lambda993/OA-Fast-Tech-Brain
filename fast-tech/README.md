# Fast Tech

Fast Tech is a computer player for **TA: Escalation** in Open Annihilation.
It races up the tech tiers: each new tier winds down the factories below
it, reclaims the labs that are left behind, and puts the seat's metal into
the strongest units it can build. It plays without full awareness, so it
learns the map with radar and expendable scouts.

## Levels

Escalation sets its own income rules for computer seats: easy earns four
times the base income, medium twice, hard once. The levels use them.

| Level | Difficulty | Income |
| --- | --- | --- |
| Fair | hard | 1× |
| Boosted | medium | 2× |
| Rich | easy | 4× |

## How it plays

**Tiers.** Escalation marks every unit with a tier category: `LEV0` the
commander, `LEV1` to `LEV3` the three factory tiers, `LEV4` experimentals
and `LEV5` the largest experimentals. The brain reads these, never unit
names, so it follows the mod's data.

**What a computer seat may build.** A brain builds from the same list as
the built-in computer player. The engine makes it from the `[CANBUILD]`
table in the mod's `gamedatE/SIDEDATA.tdf`, then the `downloadsE` menus,
and cuts it at the mod's `limits.build-list-entries` (36 entries for
Escalation). The players' menu pages in `guiE` are not part of it, and the
engine refuses any other build order. Escalation's AI table is written by
hand and fills most of the 36 entries, with duplicates that weigh a choice,
so the list is much shorter than the players' menus: the commander's and
the tier-1 builders' radar towers, for one, are not in it. Neither are
the nuke and anti-nuke silos, nor the rounds (`MAKENUKE`, `MAKEANTI`)
that the units with stockpile weapons would need: the mobile anti-nukes
(Scarab, Hedgehog) have nothing else to fire and are never built; ships
and carriers that also carry other weapons are built for those. Escalation's
Big Bertha, Intimidator, Guardian and Punisher are builders (each makes
its own armour upgrade), and count as defences all the same. Everything
below plays inside that list; the brain reads it, never unit names.
The engine gives an empty category list for the last unit types (see
Engine limitations); their tier is taken from who builds them: a unit a
factory makes has the factory's tier, a building a mobile builder puts
down the builder's (at least 1), the lowest such.

**Which line first.** Each factory belongs to a line, read from its units'
selection groups: kbots (`CTRL_K`), vehicles (`CTRL_V`), hovercraft
(`CTRL_H`), aircraft, ships. When the seat knows where it stands it reads
the map: how much of it is water, and whether the enemy starts can be
reached on land or by hovercraft. Each movement class of the side's combat
units is judged on its own: a unit is built only when its class reaches
the enemy (a kbot for shallows may not, where a deep-water tank does). A
seat without full awareness is told by `map:reachable` that ground it has
never seen is open, so a yes is checked with `map:route`, one route every
tenth of a second, and a class stops being asked once its answer is
settled; the `map:` line comes about fifteen seconds into the match and
names the classes that get through. The first lab waits for it (at most
90 seconds). Ships are judged by their guns, not their hulls: for each
boat class the survey routes from water near the base deep enough for it
to the five such points nearest each enemy start (as far out as the
longest-ranged ship shoots), and keeps the nearest one reached. A ship is
built when its weapons reach every enemy start (most of them, when the
starts are guessed) from there, with 300 units for the buildings round
the start; torpedo boats never count. Core's amphibious tier-3 ships
(Monitor, Inferno, Rancor) also cross land and are judged like ground
units, by a route from base to base. The lines are then preferred in
this order:

| Map | Order |
| --- | --- |
| Land, maybe some water | kbots, vehicles > aircraft > ships > hovercraft |
| Mostly water | kbots, vehicles, ships > aircraft > hovercraft |
| Enemy across water, ships shell it | ships > hovercraft > aircraft > kbots, vehicles |
| Enemy across water, no ship does | hovercraft > aircraft > ships > kbots, vehicles |
| Enemy cut off (lava, cliffs) | aircraft > ships > hovercraft > kbots, vehicles |

Ships count only with open water near the base, where the shipyard goes.
A line whose units cannot reach the enemy is no goal at all while some
line can, even when it would climb a tier: on islands the race takes the
hovercraft, ships or aircraft, not the kbots, and where only aircraft get
through no shipyard or hover plant is built. Extra factories follow the
same rule.

**The race.** The next goal climbs the seat's own line: a factory one tier
up. When that line ends (in the AI list the kbot line stops at tier 2, the
vehicle and aircraft lines at tier 3, and for Arm and Core only the
hovercraft line reaches the experimental fabricator), the brain builds a
bridge into the preferred line that leads higher, and climbs that. For
every factory it works out the highest tier its line leads to (factory →
builder → factory …). A factory still on the way up is never reclaimed. A
lab is started once the income would pay for it in about four minutes
(five on the boosted and rich levels).

**The city.** The base is a grid of square blocks, as wide as the side's
largest factory (24 cells in Escalation), with streets as wide as its
widest ground unit plus one cell (14 cells), so the largest units pass.
Nothing is built on a street. Factories take blocks of their own, at the
corners, doors facing the street; other buildings are packed into the
other blocks. Builders walk out to see unexplored blocks only within 600
units of the base; past that (islands, a thin ring of land) a building
goes anywhere near the base, and the commander tries that first.
Outside the grid nothing hems a factory in: no building stands at a
factory's door or back, and a factory is not put where a deposit or a
building would sit there. Every factory site, in the grid or outside it,
also needs open ground for its widest unit three cells out of both ends
along the axis its units leave by: `map:passable` sees trees, rocks,
cliffs, water for a land plant and buildings already up (factories were
put down between trees and a building and their units stayed in). When a
finished factory's lanes are blocked anyway, a builder within 1 200 units
reclaims what stands there (reclaiming a point takes features only; under
the sea or inside an own building is skipped), at most three times per
factory, a minute apart (`clear door of ...`). Fusion reactors, energy storage, resource generators and
forges or vaults gain from a neighbour of their kind, so they are put edge
to edge with one, never only corner to corner; the families are a table in
`lua/city.lua`, matched by name, because Escalation gives the bonus in unit
scripts. No building but an extractor stands on metal, and none but a
geothermal plant on or within two cells of a geothermal vent (a lab on
a vent once took a seat's geothermal plant away). Radar and defences
take the blocks nearest the front. When the ground is too rough for the
grid, a building goes anywhere near the base instead.

**Builders.** In the AI table Escalation's builders differ: a construction
vehicle has no metal extractor, a construction kbot has. Factories make the
builder that brings what the seat lacks first (extractors, the next lab,
radar, metal makers, power), then more of the best kind, twice as many while metal piles up (they help
the factories). Half the builders
lean on the race and half on the economy; when metal has run out the
economy half sees to the economy first, builds nothing else (anti-air,
artillery, defences, storage, more factories) unless attacked, and is
called back from helping frames that cannot rise. A builder that can put
down the next lab, once the seat can pay for it, does that before anti-air
and artillery. Builders walk out to ground the seat has never seen before
they build there, and give up a walk after 40 seconds plus one for every
20 world units of the way (far deposits) or when the engine reports no
path. With metal piling up, builders help the next lab's frame first,
then add factories, then help the factories, before smaller work. A
builder parked by the engine (hovercraft "park", aircraft land)
counts as free, and so does one left on a guard or a move the brain did
not order. Frames are finished before new ones are started: a builder
back from running, a repair or a walk takes up its own frame again, and
a free builder takes up the frame nobody works on that is nearest done,
within 1 500 units, before any other task (`resume <building>`); helpers
are not held on a frame, which left the economy short of builders in the
test matches. A repairer that stands idle ten seconds after it was sent
(it could not get there) drops the repair, and is not sent to that
target again for a minute; repairers are only builders that can reach
the target, and the commander waits at home for repair only when one
can. A builder alone on a frame is never sent to other work (no new task,
no emergency repair, no call back for the economy) until the frame is
up; it runs only when it is under fire (hit in the last ten seconds) and
down to 75 % health. The commander keeps its own rules. No builder is sent to a site it cannot get to: every site is
checked with `map:reachable` from the builder (from the nearest open cell
when it stands beside a building or in its factory), and a lab's site
also with `map:route` (one a turn), as `map:reachable` takes ground never
seen for open. A deposit out of one builder's reach stays free for the
others.

**Economy.** Free metal spots near the base come first, those the seat
can already see before those it must walk to. An extractor goes where its
footprint covers the most of the deposit, and only where it covers at
least 80 % of what the best position would: a deposit taken by an enemy
extractor or a building is passed over, not answered with an extractor
on the bare ground beside it. A deposit under the sea takes an underwater
extractor. The bare ground gets extractors only on metal maps (surface
metal 100 or more, or 20 with hardly any deposits). From tier 2 a builder that can
make a better extractor replaces the lower-tier ones, nearest the base
first: it reclaims the old extractor and builds the new one where it
covers the deposit best. Only then do builders walk to far spots. A free
builder with nothing else to do also upgrades extractors. An upgrade that
did not take on a deposit is not tried there again for ten minutes.
Without spots the builders put up metal makers when energy allows, and
power when the makers would starve.
Wind and tidal generators count at what the engine gives them: a wind
generator makes its rating times the wind strength over 5 000 (the map's
range, 2 500 to 4 500 on Ooooweeee, gives 15 to 27 from a rating of 30),
taken at the middle of the range; a tidal generator makes its rating times
the map's tide. They are built when their best output is at least half a
solar collector's.
Energy is kept at about fifteen per unit of metal income up to tier 2,
twenty-five at tier 3 and thirty above (the big units burn far more), and
metal piling up while the energy store runs dry makes power the first
task. Extractors and makers yield nothing while the energy cannot pay for
them (the engine closes their gate), so in a stall the metal income drops
to a fraction: from tier 2 the brain measures metal by its peak income,
fading slowly, not by what comes in that second, and builds power, not
extractors, while the energy spent (averaged over about twenty seconds)
passes the income and the store is below half. Large plants are preferred to many small ones, geothermal plants go on vents, and metal
makers switch off when the metal store is nearly full. Fusion and
geothermal plants build their own upgrade (armour, shield, weapon) once
the income pays for it in about two minutes at half share, whenever the
energy store holds more than 15 % (they used to wait for both stores to
be 40 % full and a geothermal plant went half an hour without one).

**Water.** With open water by the base the builders also use the
water-only buildings of their lists: tidal, floating and underwater power
when it gives more for its cost, floating makers, anti-air and defences
(some on the water by choice when much of the map is water, otherwise
when the land has no room). They go into the sea nearest the base that a
hovercraft reaches (checked with a route), by its shore. A shipyard or
floating plant keeps 160 units of open water all round it, so nothing
put down by the shore boxes its ships in.

**Unit upgrades.** A factory that offers one of Escalation's unit
upgrades (Level 2 in the advanced kbot and vehicle labs, Level 3 in the
tier-3 ones) builds it first, once per factory (`unit upgrade <factory>:
<upgrade>`); a second would only hold up production. The finished
upgrade stays with the factory, which goes on building. Factories being
wound down (two tiers below the top) skip it, and so does a seat whose
metal store is under 30 %.

**What the economy pays for.** A factory builds only units its share of
the income (the income split among the factories at work) pays for in
about two minutes, metal and energy both, plus a third of the stores;
with nothing that cheap it builds the cheapest units it offers. The tier
weights below then choose among them.

**Lower tiers stop.** A factory at the top tier builds freely; factories
below it stop making combat units once the seat has two finished combat
factories of the top tier (until then one tier below builds 60 % of its
turns, two or more 30 %); builders still, when an ability is missing.
Extra factories are of the top tier only. Inside a factory's list, tier 2 units
weigh eight times as much as tier 1, tier 3 fourteen times, tier 4
twenty-two and tier 5 thirty-four.

**Old labs.** Old factories are not reclaimed for being old: they stop
making units (above). When a large lab finds no room twice, the lowest
factory near the base is reclaimed to make room, but only one whose
footprint is at least six tenths of the lab's (an 8×6 plant gone leaves
no room for an 18×18 lab). A factory that fits
neither the grid nor a spot near the base is searched for on all explored
ground in rings out to about 1 500 units, once a minute; between searches
the builder walks to unexplored ground nearby. After three searches that
found nothing, with no old lab to reclaim, the factory is set aside for ten
minutes and the race takes another line (rough or island maps, where the
tier-3 labs of 18×18 cells fit nowhere). A lab ordered six times
without its frame ever rising (a site no builder gets to) is set aside the
same way (`<lab> ordered 6 times, never begun`).

**Features in the way.** Trees and rocks are not in the API, but
`map:passable` reads blocking features: a cell blocked for the smallest
kbot class, on land above the sea and outside own buildings, most likely
holds one. Reclaiming a point takes only the feature on that very cell
and fails at once on an empty one, so a builder is given every cell of
each blocked probe tile, up to 120, then the build. A lab that finds no
room is given ground cleared this way: spots in rings 240-720 units round
the base whose footprint (and a factory's exit lanes) holds nothing but
features, the fewest first (`clearing ground for <lab> at x,z (n
cells)`); a deposit covered by features is cleared and its extractor
queued (`clearing deposit at x,z`). A builder clearing ground is left to
it up to three minutes. A tile still blocked after two clearings is
taken for a slope or an unreclaimable feature and avoided.

**Scouting.** With no full awareness the brain builds the best radar its
builders offer (in Escalation's AI table that starts at tier 2–3). Any
factory that makes scouts adds them up to 3 at tier 1, 6 at tier 2 and 10
from tier 3, and from tier 3 a cheap tier-1 aircraft or vehicle factory is
kept as a scout lab with up to twelve out. Two scouts in three watch the
enemy starts (their own when the match tells them, else every start not
the seat's, read from the map): up to two head for each, the one seen
longest ago first, each seen again at most once a minute. The rest go to
unexplored starts, then to grid cells the seat cannot see, unexplored
ground first, never where another scout is going.

**Radar and sonar spread out.** The first tower faces the enemy (a sonar
by the shore); each later one of the same kind goes to the explored
point round the base (400 to 1 400 units out, on land for radar, on
water for sonar) farthest from the towers of its kind, and never within
half its range of one (`radar: <name> at x,z`). Static jammers (Veil,
Shroud and their floating kin) are in the AI lists only of the advanced
construction hovercraft and submarine: a seat that never makes those
builders never builds a jammer.

**Army.** Units gather in front of the base and leave in waves once their
worth passes the tier's mark (3 000 metal to tier 1, 5 000 at tier 2,
20 000 at tier 3, 60 000 at tier 4, 120 000 above; a fifth less below the
hard difficulty), or half of it when no wave left for five minutes and
eight units wait (armies of 20-30 units stood at home for the first
fifteen minutes). Patrols, attacks and step-backs are not ordered again
while the unit is still on the same one. Waves go for the nearest remembered enemy
building, a recent contact, or a start position nobody has looked at. A
small guard stays home, and when the base is hit, every factory builds and
the home army answers. Torpedo-only units (torpedo bombers too) are built
only when ships reach the enemy.

**Range.** Units whose weapons reach 700 or more keep to the edge of
their reach: when an armed enemy comes within half of it they step back
from it by four tenths of their range and leave the close fight to the
units with shorter weapons.

**Targets.** Submarine hunters (Escalation's submarines, selection group
`CTRL_U`, with sniping torpedoes: Piranha, Shark) shoot submarines,
commanders and decoys before anything else. Each unit shoots what its weapons can hit: only anti-air
weapons fire at aircraft, so the rest ignore them, and pure anti-air
units ignore the ground. Paralyzers (first weapon a paralyzer: Spider,
Medusa, Warden, Mirage, Scorpion) ignore units immune to paralysis
(`immunetoparalyzer`) and aircraft. Bastion (Core's hardened battery)
never fires at aircraft nor at a target with an own or allied ground unit
within its weapon's blast (352). Both hold fire and are given their
targets by the brain (a unit on hold fire picks nothing itself but
obeys an attack order). Fighters go for aircraft first. Commanders and decoys come first, then tier 4
and 5, tier 3, anti-air, the economy and the rest; bombers go for
anti-air before anything else, and look further for it. Aircraft
attacking a base pull back to the front of their own base when the
anti-air around them outweighs half their number (tiers counted), and
sit out the next minute; bombers stay. While the seat has strike
aircraft (scouts do not count), its long-range guns fire at anti-air in
range first, seen or remembered.

**Air raids.** Four or more enemy aircraft that hit the ground, within
600 units of each other and of own or allied ground units, are a swarm.
Own ground units without anti-air near one fall back to the nearest
anti-air (mobile or a tower, own or allied) within 2 000 units for ten
seconds, and every fighter of the seat goes for the raiders (`air raid
(n raiders): a units to anti-air, b fighters sent`). Factories keep at
least three mobile anti-air units in the army, one more for every ten
other ground units, so every group that leaves has some.

**Orders and speed.** An attack order is given again only for a new
target, when the unit dropped the old one, or after twelve seconds (each
order sends the unit to the path search). Targets are picked from a grid
of the enemies in sight built once a tick, and the seat's own units are
listed once a tick: a 30-minute match of two Fast Tech seats on Core
Prime ran in 193 s instead of 251 s.

**Shields and charge fields.** From tier 3, beside each heavy reactor
(tier-3 power: Heavy Fusion, Anti-Matter) and long-range gun, builders
put a shield generator (Aegis, Corona) and a charge field emitter
(Obelisk, Monolith) within 350 units, when the spare energy income is
half again what it burns (a shield takes 8 000 a second) and the income
pays for it in three minutes (`booster: <name> beside <building>`).
They do not switch on when built: they are on while the energy store
holds a fifth, off below a twentieth.

**Long-range artillery.** From tier 2 the builders put up long-range
guns toward the enemy: one at tier 2, three at tier 3, five at tier 4,
six above. Each gun is the kind the seat has fewest of, the cheapest
first, among those the income pays for, metal and energy, within two
minutes (five from tier 4) plus a third of the stores: so Big Bertha or Intimidator comes first, then Vulcan or
Buzzsaw, then Armageddon or Dictator, and the B.F.G. at tier 5. The
brain aims them, as they rarely see their targets.

**Allies.** When an ally is in grave danger (eight or more armed enemies
among its units, read from the `allies` and `threat` grid layers) the
home army goes to help, at most every two minutes, unless the seat's own
base is under heavy attack (five armed enemies near it).

**Aircraft repair.** Once the seat flies four attacking aircraft its
builders put up a repair pad, one for every four up to ten, right after
the anti-air in their order while pads are short (a pad mends
one aircraft at a time); with twelve or more the factories also make
carriers (mobile pads that can reach the enemy), one for every sixteen.
An aircraft below half health is sent on a patrol to the nearest pad: a
patrolling aircraft under three quarters health lands on a pad within
3 840 units by itself (the engine's repair retreat, which an attack far
from home never triggers).

**Commander.** The commander opens with an extractor, the first lab, then
more extractors and power, and keeps to the base; it walks out only to see
deposits within 1 200 units. Nothing it is told to build, help or guard may
lie more than 1 400 units from the base (900 was too tight): such an order is dropped and that
task rests for twenty seconds (`leash: commander <task> at x,z dropped`).
With metal piling up it adds a factory before guarding one (it used to
stand guard at the tier-1 lab).
Its wide search for a lab site keeps to sites within 900 units and runs
on its own clock, so a search of its never holds the other builders off
(on Ring Atoll a Shipyard was ordered thirteen times by the commander,
dropped each time, while the construction kbots that could build it
waited for the next search). The base is the middle of the seat's
buildings within 1 500 units of the start, extractors left out (far
deposits used to drag it, and the commander with it, a thousand units
away). With metal piling up from tier 1 it helps the
next lab's frame, then the factories (they are short of build power); with nothing
of its own to build it helps what goes up at the base, then the factories,
and looks for work again every fifteen seconds. It walks back toward the
middle only when far away, and when badly hurt. Below 75 % health up to
four builders come to repair it: it walks back to the base, out of the
fight (`commander walks home for repair`), and waits there until mended
(95 %) before it works again, unless danger sends it running. With no
other builder left it works on.

**Base lost.** Once three quarters of the metal the seat ever had in
finished buildings is gone (and it had 3 000 or more), the commander
leaves for the start of the nearest live ally and stays there
(`commander leaves for ally at x,z`). With no ally left it stays, stops
running from danger and defends what remains (`base lost, no ally`).

**Factories hold fire.** Some of Escalation's factories carry a special
weapon (weapon3) that does no damage and only turns the way their units
come out; every armed factory is set to hold fire once it is finished.

**Emergency repairs.** While the base is under attack (an alarm within
the last minute), buildings worth 5 000 metal or more below half health
get three builders each, who drop what they do. Units worth 5 000 metal
or more, whatever their tier, go home below 30 % health; within 900
units of the base three builders mend each, and the unit rejoins the
army at 95 %. Ships, and any unit that cannot get to the base, wait on
the water by it (within 1 600 units); one that stands idle short of its
spot is sent again, and after three tries rejoins the army. From tier 3 the builders put up the
commander upgrade building (Arm's Research Facility, Core's Upgrade
Center) right after the next lab. It runs from any enemy
commander or decoy within 1 100 units: two commanders D-gunning each other
both die.

**Decoys.** Decoy commanders keep out of fights as the commander does:
they run from the same dangers (more than eight tier-1 or five tier-2
enemies, any tier 3 or heavier) and from any enemy commander or decoy
within 1 100 units, but aircraft never move them. A decoy on an emergency
repair (the commander or a large building) never runs, and decoys are
picked first for those repairs (`decoy flees from x,z`). Decoys take the
underwater deposits first (out to 4 000 units): land builders cannot
build underwater extractors; the water builders (hovercraft, ships,
seaplanes) take them right after their frames (`underwater extractor at
x,z by <builder>`).

**Builders in danger.** Builders run from the same dangers, and from
anything that hits them (inside the base, within 800 units of its middle
where the defences stand, a hit alone sends them away only below half
health): back to the base when it lies away from the
threat, else 700 units straight away from it; they work again after eight
quiet seconds. A walk they were on is given up and its spot set aside for
two minutes. Aircraft count only once they hit (`builders flee: N`).

**Salvage.** When a store falls below a fifth (where the engine's own
patrolling builders start reclaiming), wrecks near a builder come before
new extractors and power: the nearest known wreck within 1 200 units
(every wreck the seat saw left within 3 000 of the base, worth half the
unit's cost), away from enemies, up to three builders at a time
(`salvage wreck at x,z`). With no wreck known, a crowded block nearby
(rocks and trees; the API gives no feature positions) is patrolled, and
the patrol reclaims what it passes (`salvage sweep at x,z`).

**Storage.** From tier 2, when a store sits full and the income would fill it again
within a minute or so, builders add metal storage (first) or energy
storage, until the stores hold about two minutes of income; for metal
at most 2 000 plus twenty seconds of income, so a large late income is
spent rather than stored.

**More factories.** With metal and energy to spare and the next lab not
going up, builders add factories of the top tier or the one below, up to
three (fair) or four of each, never while energy is short and never past
three times that in all.

## Engine limitations

What the brain ran into in Open Annihilation 0.8.11 that looks like a
limit or a fault of the engine or its brain API. Each item says what was
seen and how; whether it is a fault is for the engine's author to judge.

1. **`category` empty for the last unit types.** `units[i].category` is
   an empty list for every type from index 512 on (Lua, 1-based; engine
   type 511 on); every other field of those records reads fine. With
   Escalation that is 38 types, among them CORVP (Vehicle Plant),
   CORWIN, CORUWMEX, CORUWMS, CORUWMOHO, CORVROC, CORVIPE, CORVAMP,
   CORVENG, CORVAULT, CORZIG. `push_categories` (`src/sim/brains/src/
   lua_defs.cpp`) reads the categories from `Match::unit_definition(type)`
   (`tick_ai_builders.cpp`), which is null when `type >= input_.fields.
   size()`: the fields seem to hold only 511 types. Seen with a probe
   brain printing `#units[i].category` for every type (549 types, first
   empty 512, last 549). A brain that reads tiers from `LEVn` loses
   those types (Core lost its Vehicle Plant); this brain works round it.
   Likely related: `src/data/defs/include/oa/data/defs/categories.hpp`
   keeps category masks 512 type ids wide, as 3.1c does, and drops type
   ids 512 and above, so those types belong to no category in the game
   either (targeting categories such as `NOTAIR` may miss them).
   In a 4-seat game on Flooded Glaciers the engine also reported
   `simulation error: match tick 23743: runtime type has no FBI
   definition` (`Match::fields`, `match.cpp`): a unit whose type has no
   definition in the runtime table, probably one of these types (Core
   builds CORUWMEX, CORUWMOHO, CORVP there). Units of these types are
   built and finish (CORVP, CORVROC seen in test matches).
2. **What a brain may build is the AI table, not the players' menus.**
   `game.build_list` is `[CANBUILD]` of `gamedatE/SIDEDATA.tdf` plus the
   `downloadsE` menus, cut at `limits.build-list-entries` (36); the
   `guiE` menu pages are not read, and other orders are refused
   (`not_buildable`). With Escalation no brain can build nuke silos,
   anti-nukes, tier-1 radar, and the advanced kbot builders list no
   factory. Escalation also blanks its `downloadsE` entries for the AI
   (`UNITMENU=BLANK`). Possibly by design (the built-in AI has the same
   list); a brain option to use the full menus would lift it.
3. **Stockpile rounds cannot be ordered.** A stockpile weapon fires rounds
   the unit builds from a build-list entry whose name holds `MAKENUKE` or
   `MAKEANTI` (`stockpile_round`, `tick_orders.cpp`). No AI list holds
   them, and the mobile anti-nukes (Scarab, Hedgehog) are not builders
   at all, so a brain's stockpile units never get a round.
4. **`game.build_list` holds fewer entries than the table.** The lists
   came back with 31 entries (`build_list_cap` 37) where `[CANBUILD]`
   plus `downloadsE` hold 36 or more; the entries missing are the
   `*_C`, `*CHEAT` and `*_L_70/50/30` names of the table. Maybe types
   the mod does not define; worth a look.
5. **`map:reachable` is optimistic and answers no from a blocked cell.**
   Without full awareness cells never seen count as open (`sight_pass`,
   `lua_map.cpp`), so only its no can be trusted; and from a position on
   a blocked cell (a builder beside a building or in its factory) it
   answers no even when the way is open. `map:route` reads the real
   movement map but costs tens of milliseconds on a large map, and a
   turn over 250 ms stops the seat; `os.clock` is not available to time
   it.
6. **Help on a finished factory never ends.** `unit:help` on a factory
   turns into `Follow_Ground` once the factory's frame is up, a guard
   with no end; on a factory turning out units `HelpBuild` lasts as long
   as the factory works.
7. **No direct landing order.** A brain cannot send an aircraft to land
   on a repair pad: `guard` gives `VTOL_Follow`, `load` `VTOL_Pickup`;
   only the engine's own repair retreat (below 75 %, on a patrol or an
   attack pass, pad within 3 840) lands it.
8. **No feature positions without full awareness.** Rocks and trees are
   not in the API, so a brain cannot reclaim them except by patrolling
   ground and letting the engine's patrol reclaim what it passes.
   `onUnitDestroyed` gives a `wreck` for only part of the deaths.
9. **`brain.place` stops after 4 096 cells,** a radius of about 500
   world units, whatever radius is asked.
10. **A failed path leaves its move at the head of the queue.** The unit
    is not free again until the brain stops it (`onPathFailed`).

11. **No resurrect order.** The engine runs resurrection (ground mission
    `resurrect`, kind 37, for units with `canresurrect`), but the unit
    methods offer no `resurrect`, and `reclaim` on a wreck consumes it.
    A brain cannot raise wrecks with Escalation's Rector, Necro and their
    tier-3 kin; this brain uses them as builders.
12. **`map:reachable` is costly on a large map.** On Icy Bergs (99 %
    water, about 13 000 world units across) a few hundred calls in the
    first fifteen seconds cost about 2 s of real time per seat, more
    than `map:route` for the same pairs; four seats made the game stall
    at the start. The brain now asks routes only and caches its
    `map:reachable` answers.

## Files

| File | What it does |
| --- | --- |
| `oabrain.yaml` | Manifest: Escalation only, three levels, no full awareness. |
| `brain.lua` | Hooks and the once-a-second turn. |
| `lua/catalog.lua` | Unit types sorted into roles, tiers and build lists. |
| `lua/world.lua` | The seat's units, base, tier and memory of the enemy. |
| `lua/economy.lua` | Income goals, what is short, metal spots, maker switching. |
| `lua/terrain.lua` | Water, reach of the enemy, and the order of the lines. |
| `lua/city.lua` | The base grid, streets, factory blocks and adjacent families. |
| `lua/tech.lua` | The tech line planner, the race and lab reclaiming. |
| `lua/builders.lua` | What every builder and the commander does next. |
| `lua/factories.lua` | What every factory makes, and the scout lab. |
| `lua/army.lua` | Rally, waves and defence. |
| `lua/scouts.lua` | Where scouts go. |
| `lua/util.lua` | Shared helpers. |

The seat log (`logs/brains/seat-N.log` in the game's data folder) gets a
status line every minute: tier, goal, stores and income, and unit counts.

## Checking

```sh
oa-tool brain check fast-tech --game-dir /path/to/totala \
  --mod "/path/to/Open Annihilation/Mods/escalation"
open-annihilation --headless-check --game-dir /path/to/totala \
  --mod-dir "/path/to/Open Annihilation/Mods/escalation" \
  --brain-match ./fast-tech,builtin --brain-levels rich,hard \
  --brain-map "Painted Desert" --seed 4242 --match-ticks 54000
```

## Licence

GPL-3.0-only, see `LICENSE`.
