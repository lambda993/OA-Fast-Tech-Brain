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
the tier-1 builders' radar towers, for one, are not in it. Everything
below plays inside that list; the brain reads it, never unit names.

**Which line first.** Each factory belongs to a line, read from its units'
selection groups: kbots (`CTRL_K`), vehicles (`CTRL_V`), hovercraft
(`CTRL_H`), aircraft, ships. When the seat knows where it stands it reads
the map: how much of it is water, and whether the enemy starts can be
reached on land or by hovercraft. The lines are then preferred in this
order:

| Map | Order |
| --- | --- |
| Land, maybe some water | kbots, vehicles > aircraft > ships > hovercraft |
| Mostly water | kbots, vehicles, ships > aircraft > hovercraft |
| Enemy across water | hovercraft > aircraft > ships > kbots, vehicles |
| Enemy cut off (lava, cliffs) | aircraft > ships > hovercraft > kbots, vehicles |

Ships count only with open water near the base, where the shipyard goes.

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
other blocks. Fusion reactors, energy storage, resource generators and
forges or vaults gain from a neighbour of their kind, so they are put edge
to edge with one, never only corner to corner; the families are a table in
`lua/city.lua`, matched by name, because Escalation gives the bonus in unit
scripts. No building but an extractor stands on metal. Radar and defences
take the blocks nearest the front. When the ground is too rough for the
grid, a building goes anywhere near the base instead.

**Builders.** In the AI table Escalation's builders differ: a construction
vehicle has no metal extractor, a construction kbot has. Factories make the
builder that brings what the seat lacks first (extractors, the next lab,
radar, metal makers, power), then more of the best kind. Half the builders
lean on the race and half on the economy. Builders walk out to ground the
seat has never seen before they build there, and give up a walk after 40
seconds or when the engine reports no path.

**Economy.** Free metal spots near the base come first. From tier 2 a
builder that can make a better extractor replaces the lower-tier ones,
nearest the base first: it reclaims the old extractor and builds the new
one on the same spot. Only then do builders walk to far spots. A free
builder with nothing else to do also upgrades extractors. Without spots the
builders put up metal makers when energy allows, and power when the makers
would starve.
Energy is kept at about fifteen per unit of metal income, large plants are
preferred to many small ones, geothermal plants go on vents, and metal
makers switch off when the metal store is nearly full.

**Lower tiers wind down.** A factory at the top tier builds freely, one tier
below builds 40 % of its turns, two tiers below 10 %, and tier 1 builds 15 %
once tier 2 is reached and nothing after that. While the next lab is going
up the lower factories halve again. Inside a factory's list, tier 2 units
weigh eight times as much as tier 1, tier 3 fourteen times, tier 4
twenty-two and tier 5 thirty-four.

**Old labs.** Factories two tiers behind the top, and tier-1 factories once
tier 3 is reached, are reclaimed. When a large lab finds no room twice, the
lowest factory near the base is reclaimed to make room.

**Scouting.** With no full awareness the brain builds the best radar its
builders offer (in Escalation's AI table that starts at tier 2–3), sends one early
scout, and from tier 3 keeps a cheap tier-1 aircraft or vehicle factory as a
scout lab that keeps up to eight scouts out. Each scout heads for an
unexplored start position first, then for a grid cell the seat cannot see,
unexplored ground first, and never where another scout is going.

**Army.** Units gather in front of the base and leave in waves once their
worth passes the tier's mark. Waves go for the nearest remembered enemy
building, a recent contact, or a start position nobody has looked at. A
small guard stays home, and when the base is hit, every factory builds and
the home army answers.

**Commander.** The commander builds the opening and then keeps to the base.
With nothing of its own to build it helps what goes up at the base, then
the factories. It walks back toward the middle only when far away, and when
badly hurt.

**Storage.** When a store sits full and the income would fill it again
within a minute or so, builders add metal storage (first) or energy
storage, until the stores hold about two minutes of income.

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
