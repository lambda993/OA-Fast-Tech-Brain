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

**What a computer seat may build.** A brain builds from the same table as
the built-in computer player: the `[CANBUILD]` lists in the mod's
`SIDEDATA.tdf`, read as Total Annihilation's own AI reads them and cut at
the mod's `limits.build-list-entries` (36 entries for Escalation). The
engine refuses any other build order. Escalation writes that table by hand
for the AI, so it is much shorter than the players' build menus: duplicates
weigh a choice, some units are left out on purpose (the commander's radar
tower sits past the limit, "because lower priority"), and some lines stop
early. Everything below plays inside that table; the brain reads it, never
unit names.

**The race.** In the AI table the tech lines end at different tiers; for
Arm and Core only the hovercraft line reaches the experimental fabricator.
For every factory the brain works out the highest tier its line leads to
(factory → builder → factory …) and races along the line that reaches
highest. When the seat's own line ends early it builds a bridge lab of the
same tier. A lab is started once the income would pay for it in about four
minutes (five on the boosted and rich levels).

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
Whenever it is idle, or badly hurt, it walks back to the middle of the base.

## Files

| File | What it does |
| --- | --- |
| `oabrain.yaml` | Manifest: Escalation only, three levels, no full awareness. |
| `brain.lua` | Hooks and the once-a-second turn. |
| `lua/catalog.lua` | Unit types sorted into roles, tiers and build lists. |
| `lua/world.lua` | The seat's units, base, tier and memory of the enemy. |
| `lua/economy.lua` | Income goals, what is short, metal spots, maker switching. |
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
