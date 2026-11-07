# Fast Tech — notes for continuing the work

Fast Tech is a computer player ("brain", Lua) for the **TA: Escalation** mod
in **Open Annihilation** (OA, engine 0.9.0). It races up the tech tiers,
winds the lower tiers down, builds the base as a city grid and plays without
full awareness. The brain package is `fast-tech/`; this file, the README and
`.gitignore` sit outside it because a brain package may hold only its own
files (`oabrain.yaml`, `brain.lua`, `lua/*.lua`, `README.md`, `LICENSE`).

What the brain does, rule by rule, is in `fast-tech/README.md`. Keep that
README in step with the code.

## Working with the user

- The user writes in Italian; answer in Italian.
- **Privacy**: the author is `Lambda993` everywhere (manifest, SPDX lines,
  commits). Never write the user's real name. The repo-local git identity is
  set to `Lambda993`.
- **Every change updates the notes and the README**: this file (state,
  engine facts, what the user asked for) and `fast-tech/README.md` (the
  rules), in the same round as the code, so everything is tracked.
- **Never commit or push unless the user says so.** The user usually says
  "comitta e installa": then commit, pack, install, check (see below).
- The repo is a private GitHub repo: remote `origin` is
  `git@github.com:lambda993/OA-Fast-Tech-Brain.git` (SSH, the user's key
  `~/.ssh/id_ed25519`). `git push` works from the session; push only when
  the user asks. The repo-local git email is `lambda.sigma93@gmail.com`.
- Commit messages: short imperative subject, wrapped body explaining why,
  ending with the `Co-Authored-By` line the harness gives.

## Paths on this machine

| What | Where |
| --- | --- |
| Repo | `/usr/prg/OABrains/fast-tech` |
| OA engine source and build | `/usr/prg/OpenAnnihilation/open-annihilation` (binaries in `build-relwithdebinfo/`: `open-annihilation`, `oa-tool`) |
| Engine docs | `docs/brains/oabrain-standard.md`, `docs/brains/authoring.md`, `docs/command-line.md` in the engine repo; examples in `brains/examples/` (steady-commander, learned-scout) and `brains/classic` |
| TA game data | `~/.steam/debian-installation/steamapps/common/Total Annihilation` |
| OA user folder | `~/Documents/Open Annihilation` (Mods/escalation, Brains, Maps) |
| Installed brain | `~/Documents/Open Annihilation/Brains/fast-tech` (an unpacked copy) |
| Seat logs of real games | `~/.local/share/open-annihilation/logs/brains/seat-N.log` |
| Reference brains repo | `/usr/prg/OABrains/ai-brains` (Classic; read-only, do not modify) |

## Pack, install, check

```sh
OA=/usr/prg/OpenAnnihilation/open-annihilation/build-relwithdebinfo
TA="$HOME/.steam/debian-installation/steamapps/common/Total Annihilation"
ESC="$HOME/Documents/Open Annihilation/Mods/escalation"
cd /usr/prg/OABrains/fast-tech
$OA/oa-tool brain pack fast-tech --out fast-tech.oabrain --force
B="$HOME/Documents/Open Annihilation/Brains/fast-tech"
rm -rf "$B" && mkdir "$B" && python3 -I -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' fast-tech.oabrain "$B"
diff -r fast-tech "$B" && $OA/oa-tool brain check "$B" --game-dir "$TA" --mod "$ESC"
```

`brain check` must end with `result: ok`. Without `--mod` it is refused on
purpose (`works-with: escalation >= 10`). The user restarts the game to load
a new install.

## Headless test matches

Only two seats; the brain plays seat 1 (Arm) or, listed second, seat 2
(Core). Use a scratch folder for `--data-dir`/`--log-dir`; the seat log is
`<data-dir>/logs/brains/seat-N.log`.

```sh
S=/tmp/ft-run; rm -rf $S; mkdir -p $S
$OA/open-annihilation --skip-intro --mute --headless-check --game-dir "$TA" --mod-dir "$ESC" \
  --data-dir $S/data --log-dir $S/log \
  --brain-match /usr/prg/OABrains/fast-tech/fast-tech,builtin --brain-levels rich,hard \
  --brain-map "Painted Desert" --seed 4242 --match-ticks 54000
grep -h 'brain match' $S/log/*
```

- 30 ticks = 1 second; 54000 ticks = 30 minutes, about 2–3 minutes of real time.
- Swap the seats (`builtin,<folder>`) to play Core.
- Add `--brain-trace $S/trace.txt` to log every order (`move`, `build`,
  `order help/guard/cloak/attack_ground ...`; seat 0 is report seat 1).
- Maps used: `Painted Desert` (land, deposits), `Ashap Plateau` (hilly,
  corner start, Core got stuck there before), `A tale of two cities@a-tale-of-two-cities`
  (map pack, far deposits), `Coremageddon`, `Core Prime Industrial Area`
  (metal map, surface metal 255, no deposits), `Luschaven` (65 % water),
  `Crater Islands` (islands, enemy not reachable on land).
- Levels: `fair` (difficulty hard, 1x income), `boosted` (medium, 2x),
  `rich` (easy, 4x) — Escalation's `ai.income-multipliers` are 4/2/1.
- A probe brain (a folder with `oabrain.yaml` + `brain.lua` that `print`s
  what it reads in `onTick`) is the quickest way to check an API field or a
  build list; put it in a scratch folder (extra files in a brain folder make
  it refuse to seat).

## Seat log

Every minute: `builders: ...`, `artillery shot needs X energy, store holds Y`,
`defence: decoys/anti-air/artillery/cloaked`, and a `status` line (tier,
goal and its builders, stores and income, unit counts, extractors per tier).
Every ten minutes (`hooks.dump_city = true` in `brain.lua`) an ASCII map of
the city: `F` factory, `E` adjacency family, `#` building, `=` street, `x`
block left out for poor ground. Events: `tech goal`, `tier a -> b`,
`building`, `reclaim`, `upgrade`, `storage:`, `artillery:`, `jammer:`,
`commander flees`, `commander d-guns`, `<gun> shells x,z`, `<gun> fires at`,
`map: ...`, `error in <part>: ...` (each part runs under `util.guard`, so an
error is logged once and the seat keeps playing).

## Engine facts found the hard way

- **What a brain may build** is the computer player's list, not the player's
  menus: `[CANBUILD]` of the mod's `gamedatE/SIDEDATA.tdf`, then the
  `downloadsE/*.tdf` menus, cut at `limits.build-list-entries` (36 for
  Escalation, `overflow: truncate`). The `guiE/*.gui` menu pages are not
  included. Orders outside the list are refused (`not_buildable`).
  Consequences in Escalation: no radar for the commander or tier-1 builders,
  no nuke silos (incl. Tribulation) and no anti-nukes at all, the kbot line
  stops at tier 2, vehicles and aircraft at tier 3, only hovercraft reach the
  tier-4 Exp. Unit Fabricator. A fix would need the engine to validate brain
  orders against the full menus (an issue was proposed, not filed).
- **`category` is empty for unit types at Lua index ≥ 512** (engine
  type ≥ 511): `Match::unit_definition` is null past `input_.fields`.
  All other record fields are fine. See README "Engine limitations".
- Escalation buildings with `builder=true` besides fusion: Big Bertha,
  Intimidator, Guardian, Punisher (their armour upgrade). `defense` used
  to need `not builder`, so they were no defences/artillery; now only a
  real factory (builds mobile units) is excluded.
- Stockpile: a weapon with `stockpile` fires rounds built by the unit
  (engine `build_weapon` mission, order kind 13); a round is a build-list
  entry whose unit name holds `MAKENUKE`/`MAKEANTI`.
- `HelpBuild` on a finished factory that is producing never ends (it is
  help on each unit). Holding helpers on frames until done cost wins (3
  wins/5 draws vs 5/3); kept instead: `try_resume` for frames nobody
  works on.
- `game.build_list` lists contain duplicates (Escalation weighs AI choices
  with them); the catalog removes them.
- The sandbox forbids `pairs` over tables with table keys (non-deterministic
  order): use sequences.
- `map:reachable(unit_handle, ...)` can answer false from a blocked cell;
  use positions (`{x, z}`) as both ends. Points work. A position on a
  blocked cell (a builder beside a building or in its factory) is no good
  start either: `util.reachable` starts from the nearest open cell.
- **Extractors and makers stop in an energy stall**: the engine credits
  their metal only on a tick whose energy gate is open
  (`src/sim/match-runtime/src/tick_economy.cpp`), so `me.metal_produced`
  falls to a fraction while energy runs short. Reading that as "metal
  short" builds extractors instead of power (fixed with a fading peak).
- **`map:reachable` is optimistic without full awareness**: cells the seat
  has never seen count as open (`sight_pass` in the engine's
  `src/sim/brains/src/lua_map.cpp`), so at the start it says yes to almost
  everything. Only its no is reliable. `map:route` reads the real movement
  map (nil = cannot meet) but costs real time: tens of ms on a big map,
  and a turn over **250 ms of real time stops the seat**
  (`tick ran for more than 250 milliseconds`). The survey asks one route a
  turn. `os.clock` is not available to time things.
- Order kinds a unit rests in: `Standby`, `Park` (hovercraft), `VTOL_Standby`,
  `VTOL_LandIfCan`, `Stop`; `util.free` must count them all, or builders of
  that kind never get an order (hover builders once idled a whole match).
  Help on a finished factory turns into `Follow_Ground` (a guard) that never
  ends. A failed path leaves the `Move_Ground` at the head of the queue:
  `onPathFailed` stops the unit. `unit:orders()` gives `kind`, `target`,
  `x`, `z`, `parameter_1` (the type index of a build) for debugging.
- A unit's `heading` (0..65535): 0 and 32768 face along z. A factory's
  units leave along that axis; a building or deposit there traps them.
- Every map in the TA set has some surface metal (3 to 7 on ordinary maps,
  20 on Pincushion, Lava Mania, Red Hot Lava); metal maps have 255 and no
  deposits. Underwater deposits: Crater Islands 14 of 41, Luschaven 76 of
  160, Sail Away 37 of 85 (`map:ground(x, z) < sea_level`).
- A water grid cell (`brain.grid({"water"})` share > 0.6) can still be
  shallows a boat class cannot enter: check `map:passable(class, cx, cz)`
  (3 = clear) before using it as a ship endpoint.
- Without full awareness: `brain.place`/`brain.site` only accept explored
  ground; `me:nearest_enemy`/`game.units` are nil; enemies come from
  `me.seen`, radar/sonar contacts from `me.radar` (positions only).
- A seat may start before players are placed: start position and
  commander can be missing in `start`; `world.located()` retries each turn.
- Unit record fields are lower-case FBI keys (`buildcostmetal`,
  `footprintx`, `movementclass`, `weapon1`, `energystorage`, `cloakcost`,
  `candgun` ...). `tedclass` is not exposed. Weapons: `weapons[name]`, fields
  `range`, `energypershot`, `toairweapon`, `waterweapon`, `stockpile`.
- Escalation data: tier from category `LEV0`..`LEV5` (`LEV_2` = unit-level
  upgrades, skipped); line from selection groups `CTRL_K` kbot, `CTRL_V`
  vehicle, `CTRL_H` hover (many kbots use `TANK*` movement classes);
  `*_UPGRADE` buildings (fusion/geothermal armour) are built from the
  building's own list; decoy commanders have `DECOM` in the unit name;
  `RANGE_*` and `LAB_*` weapons are markers, not real weapons. Fusion
  reactors have `builder=true` (they only build their upgrade) — not
  factories. Floating/underwater buildings and tidal generators are water-only.
- Long-range guns rarely see targets; they must be ordered
  (`attack`, `attack_ground`). Shot energy: Big Bertha 5 400, Intimidator
  6 000, Armageddon/Dictator 120 000, B.F.G. 1 000 000.

## Code map (`fast-tech/`)

| File | Role |
| --- | --- |
| `brain.lua` | Hooks; the work of a second spread over six turns (`think`, every 5 ticks): world, tech goal and builders; status (60 s) and city dump (600 s); factories (2 s); scouts and pruning (5 s); army (3 s). Map survey on its own timer. |
| `lua/unit_table.lua` | Generated from `data/units.json`: threat, target lists, tags per type. |
| `lua/catalog.lua` | Every unit type sorted into roles: tier, line, builder/factory, combat, defence, anti-air, artillery, radar/sonar/jammer, economy, storage, decoy, upgrade, water-only, shot energy; wind/tide judged against solar. |
| `lua/world.lua` | Own units, base and start, tier, enemy memory (buildings, contacts, wrecks, enemy air), target priority and `best_target`, radar contacts. |
| `lua/terrain.lua` | Water share, water point (route-checked) and shore for water buildings, enemy starts, reach per movement class, which lines reach the enemy, line ranking. |
| `lua/tech.lua` | Line reach planner, next goal (climb, else bridge to the preferred line), affordability, lab reclaiming. |
| `lua/economy.lua` | Income goals per tier, what is short (energy ≈ 15 × metal income), power/extractor/maker choice, metal spots, geothermal vents, maker on/off. |
| `lua/city.lua` | Grid: blocks (24 cells), streets (widest ground unit + 1 = 14), alleys (widest builder, 4), block quality from `map:passable`, districts (factories to the front, power behind), adjacency families, fill cap 60 %, `on_street`, ASCII dump. |
| `lua/builders.lua` | Every builder's next task, commander (opening, safety, cloak, D-gun, help, home), decoys fighting, repairs, wrecks, sweeps, radar/sonar, jammers, defences, anti-air, artillery, shot storage, storage, extra factories, scout lab. |
| `lua/factories.lua` | What each factory makes: builders by missing ability, decoys, scouts, combat units weighted by tier and wound down below the top tier, guard minimum, armour upgrades of buildings. |
| `lua/army.lua` | Rally, waves, defence, focus fire, radar contacts, heavy units home for repair, aiming the long-range guns. |
| `lua/scouts.lua` | Scouts to unexplored starts, then unseen grid cells. |
| `lua/util.lua` | Numbers, positions, distances, `free`, `explored`, `guard`. |

## What the user asked for (all implemented unless marked)

1. Fast tech: race to higher tiers; on each new tier wind down lower
   tiers, tier 2 weighs far more than tier 1; reclaim old labs (also to make
   room for big labs).
2. No full awareness: radar (and sonar, jammers) and scouts; endgame scout
   lab (aircraft or vehicles) keeps up to 8 scouts going to unseen ground.
3. Commander: builds at base, helps buildings and factories, never wanders;
   cloaks with spare energy; flees from > 8 T1, > 5 T2 or any T3/T4 nearby,
   and from aircraft it cannot hit only once they hit it; D-guns lone T3/T4
   in its base when cloaked and safe.
4. Up to 15 decoy commanders from tier 2; they build and, like the
   commander, avoid fights (run from danger and enemy commanders/decoys,
   ignore aircraft), but never leave an emergency repair. (Earlier they
   fought without fear and chased commanders; the user changed this.)
5. Line order: land map kbot/vehicle > air > ships > hover; water map
   kbot/vehicle/ships > air > hover; enemy across water hover and ships
   first, then air; enemy cut off: air first. Units that cannot reach the
   enemy are not built; torpedo-only units and floating labs only with water.
6. City grid with wide streets, factory blocks, alleys, adjacency families
   (fusion, energy storage, resource generators, forge/vault) edge to edge,
   nothing but extractors on metal, districts, poor-ground blocks skipped.
7. Economy: extractors on the richest cells; replace lower-tier extractors
   (not on metal maps); extractors on bare ground on metal maps; metal and
   energy storage for surpluses; energy storage for the hungriest gun's shot;
   wind/tidal only if their best output ≥ 50 % of a solar collector.
8. Repairs: buildings ≥ 5 000 metal (was 7 500) below 50 % during an attack (3 builders
   each); units worth ≥ 5 000 metal (any tier; was T3/T4 only) below 30 %
   go home and get repaired.
9. Clear large wrecks in the base after fights; sweep blocks where nothing
   fits (feature positions are not in the API).
10. Fusion and geothermal armour upgrades.
11. Lots of static anti-air T1–T3; long-range artillery (Bertha/Intimidator,
    Vulcan/Buzzsaw, Armageddon/Dictator, B.F.G.), aimed by the brain. Every
    kind gets built (fewest owned first, cheapest among them; 1/3/5/6 guns
    at tiers 2/3/4/5): before, the longest range won and only
    Armageddon/Dictator were built, and Bertha/Intimidator were not even
    defences (they are `builder=true`, see engine facts).
12. Target priority: commander/decoy > T4 > T3 > economy, factories and
    builders > rest; focus fire on commanders; radar/sonar contacts are
    targets when nothing is in sight.
13. **Not possible** (not in the AI build list): nukes and anti-nukes 3:1,
    Tribulation, tier-1 radar. Rechecked: no static silo or anti-nuke is in
    any AI list; mobile stockpile units are (Scarab/Hedgehog in the adv.
    vehicle plants, carriers Colossus/Hive, Atlantis/Nexus, Armada/
    Anchorage), but their rounds (`MAKENUKE`/`MAKEANTI`, queued with
    `unit:queue` on the carrier, engine `queue_factory_build`) are in no
    AI list, and Scarab/Hedgehog are not even builders. Units armed only
    with stockpile weapons are no longer combat units.
14. Builders run from danger and when hit; with a store below 20 %
    wrecks/features nearby are reclaimed before new extractors or power.
15. Escalation unit upgrades (`ALL_L2` Level 2 in ARMALAB/ARMAVP/CORALAB/
    CORAVP, `ALL_L3` Level 3 in ARMELAB/ARMGANT/COREVP/CORGANT, category
    `LEV_2`): first thing a factory builds, max 1 per factory (else it
    blocks production). They stay out of `builds` (skipped) and sit in
    `entry.unit_upgrades`. In a match it takes ~2 minutes, then stays
    attached to the factory (`BeCarried`) and the factory goes on.
16. Commander stays near the base (see state below).
17. Big frames left half built get taken up again (see state below).
18. A builder alone on a frame is never redirected until it is up (no
    new task, emergency repair or economy call-back); it may run only
    when hit in the last 10 s and at ≤ 75 % health. Commander exempt
    (its own safety rules). `count_crews` in builders.step counts the
    builders per frame from their head orders.
19. Ships by weapon reach, not hull reach; Core amphibious T3 ships
    cross land. Frames finished before new ones; diverted builders
    resume their frame. Units and buildings chosen within the economy.
20. Factories hold fire (weapon3); sub hunters on subs/commanders;
    long-range units keep their distance; commander to an ally when
    75 % of the base is lost, else stands; resurrect wrecks ≥ 2 500
    metal (1 250 heap) — **not possible**, no API order.
21. Factories stuck between trees and buildings (user, Ring Atoll):
    factory sites need open lanes out of both ends (`map:passable`),
    blocked lanes of finished factories are reclaimed.
22. User's Steel Jungle game (2026-11-01, 4 seats, rich, stopped at 52
    min): reclaim what blocks building; commander built more factories
    instead of guarding the tier-1 lab; geothermal upgrades sooner; FPS
    in big fights; shields/charge fields beside heavy reactors and
    long-range guns; paralyzers ignore immune units and aircraft;
    Bastion never fires near own/allied units (its blast) nor at
    aircraft; old factories stop producing, reclaimed only for room;
    repair pads/carriers sooner; units without anti-air fall back to
    anti-air in air raids, 3+ mobile anti-air per group; mobile anti-air
    a bomber target (already was); fighters intercept raiders on own and
    allied units.
23. User's second Steel Jungle game (2v2, rich, 39 min): keep vents for
    geothermal plants; armies idle at home 15 minutes; slowdowns in
    fights; many more scouts, aimed at enemy starts; one seat stopped
    making army; commander leash too tight, underwater deposits left
    (decoys take them); radar/sonar spread apart; jammers never seen.
24. User's Two Continents game (4 seats, rich, 19 min): units from armed
    factories inherited hold fire (ships); slowdowns at start and in
    fights; targets forgotten as soon as they enter the fog; scout ships
    stuck going for land points (try timer).
25. A table of all Escalation units with targets, threat level and tags
    (`data/units.json`, see state below), and the brain playing by it.
    User's choices for the brain: bombers and guns take anti-air first when
    the seat has strike aircraft, then the table; `aoe` units do not fire
    with friends in their blast and stay apart; a skirmisher steps back at
    half its reach; every cloakable unit cloaks with spare energy.
26. User's 7-seat Seven Islands game (2026-11-07): veterans of any tier
    (and units ≥ 5 000 metal) go home below 50 % and wait for full repair
    by free builders before the next wave; builders always go home for
    repair below 50 %; a delay before a unit changes target, for speed
    (the user's idea; done as a 10 s hold); water builders must not help
    frames they cannot reach, nor land builders water frames; at most 10
    mobile anti-air (escorts; static excluded) until enemy aircraft are
    seen; non-torpedo units must not attack submerged amphibious units,
    amphibious units without water weapons must not attack from under
    the sea. Also asked to check: no tier-4 lab (Fleet Shipyard) though
    many tier-3 builders, Core winning more often than Arm, a script stop,
    no aircraft/seaplane plants (see state below).

## State and open points

- User's 4-seat Ror Shock game (2026-11-07, all Fast Tech, rich, 47 min,
  no errors): factories blocked by builders and units standing by them;
  speed still drops in medium fights; asked whether the brain, repo and
  every name can become `escalated` (yes: manifest id and folder together,
  install folder, repo via `gh repo rename`; the user put it off for now).
  - The rally point (`world.front(380)`) lies in the city's front
    district, where the factories are. Now `world.in_factory_way` keeps a
    lane of 240 units past each end and 48 past the sides of every finished
    non-air factory; rally point, waiting spots, mend spots and builder
    parking take `world.clear_spot`, and every 6 s idle own units in a
    lane step out of its side (`clear_lanes`, log `moved out of factory
    lanes N`: 19-253 a match in tests).
  - Speed: a traced 20-minute Painted Desert mirror gave about 5 000 brain
    orders for both seats (4 a second) and 675 M Lua instructions in 104 s
    of run time: the brain is a small part; fights cost in the engine.
  - Seven Islands seats still stopped (3 in 8 tests) in turns where
    builders, army, scouts and status ran together: `think` now runs every
    5 ticks and each module has its own slot in the second. Still two stops,
    both in builders.step: a profiling copy (counting brain.place, selects,
    reachable, passable per step) showed the heavy steps were one builder's
    wide lab-site search, ~40 `brain.place` of an 18×18 lab on the water
    (each some milliseconds in the engine). `place_wide` now goes 5 explored
    ring points a turn and resumes where it stopped (`builders.wide_pass`).
  - Then Core's commander on 8Islands (seed 7) stayed at tier 0 all game:
    it held a `MobileBuild` for a Shipyard 110 units off, never starting
    and never moving, so it was never free for new work (the engine gives
    no reason). Now a build order with no frame for 90 s is dropped
    (`build order dropped: no frame in 90 s at x,z`), the site is avoided
    ten minutes (`builders.bad_sites`), and the builder first walks back to
    the base (given new work at once, it was sent to the same spot); no
    factory site within its half size + 96 of the map's edge. Then it
    reached tier 1 at 7 500 ticks. About 20 real drops a match on Core
    Prime (poor ground); most `dropped` lines there are the older leash
    lines.
  - Tests after all of it: 8 vs built-in 5 wins 1 draw, 6 mirrors all
    draws (8Islands Core 300 built, before 4), no errors, no stops.
  - Seen in the logs: escorts 30 of ~100 units (seats 2, 4) and seat 1's
    army almost all Swatters at the end: with enemy aircraft seen there is
    no cap, and a poor seat takes its cheapest units. Not changed.

- User's 7-seat Seven Islands game (2026-11-07, all Fast Tech, rich, 73
  min; 93 % water, oversized like 8Islands). Findings and fixes:
  - Arm seats 1, 5, 7 died, Core 2, 4, 6 won. Cause found: Arm's
    commander puts its first Floating Wind Generator on the shore point,
    and the 160 units of open water a shipyard keeps (`rings`) then left
    no site for the first Shipyard (6 seats of 7 `no site for Shipyard`,
    about two minutes lost); the exit check also wanted open water at both
    ends, by the shore one is land. Now non-factory water buildings keep
    320 units off the shore point (`shore_reserve`) until a water factory
    stands, and water factories need one open end. Mirrors after it (6
    maps, 30 min): all draws, Arm ahead on kills on 4, even on Seven
    Islands (before: Core far ahead there).
  - Seat 3 stopped at 63 minutes in builders.step (40 builders, 15 of them
    decoys). Mirror tests on Seven Islands/8Islands then stopped seats in
    builders, army and scouts: map:reachable rebuilds regions for every
    class past four in a tick. Now at most 8 builder turns a step (in turn
    round the list) and a budget in `util.reachable` (24 fresh questions,
    4 classes a tick; past it nil = not now). After it: no stops.
  - Start lag: 40 failed land routes a seat (TANKSH* from an island
    search the whole million cells). Mostly-sea oversized maps now take the
    coarse map's no for land classes; map line at tick 12-45 instead of
    252-315; 900 ticks two Fast Tech seats 7.68 s vs 10.24 s (built-in
    7.36 s). The survey now waits for the catalog refresh (it finished
    before it once and judged hover unreachable).
  - Water builders helping unreachable frames: help, frame help, resume,
    assist and repairs now need `builders.reaches_work` (the target or a
    point at its edge within build distance reachable).
  - Repairs (user's rules, item 26): `veteran_kills` added to
    `data/units.json` from the FBI `VeterancyThresholds` (first level; 197
    types, 5 for the rest, the engine default); the brain reads
    `unit.kills` (engine: the veteran count). Builders below 50 % go home
    (`builders.self_mend`). Mended to 99 %. Seen in tests: units sent home
    1-5 a match, `builders home for repair` up to 12.
  - Target hold 10 s (`target_hold` in army.lua). Log `targets kept N,
    searched M`: most searches are units with nothing near (cheap with the
    enemy grid), so the gain is small; speed in fights is still mostly
    the engine. The user's log again shows 8×8 anti-aliasing and frames of
    958 977 vertices at zoom 0.17.
  - Escorts capped at 10 until enemy aircraft are seen (`escort_cap`).
  - Submerged amphibious targets are dropped and not chased; amphibious
    shooters without water weapons (`entry.water_weapon`) skip targets on
    the water without dry ground in reach (`world.out_of_reach`).
  - Fleet Shipyard (24×24, tier 4, its line reads "air": it builds
    aircraft carriers) and the 18×18 tier-3 water labs: `no site` all game
    on the islands; probably the same rings round floating power. Not
    verified after the shore fix (needs a 60-minute game).
  - No aircraft or seaplane plants: by the line order (item 5), with
    the enemy across water hover and ships rank before air, and extra
    factories score `- rank * 300`, so air came only when every water
    lab had no site (seat 2 once). User: from tier 2 there must be
    aircraft. Now the first extra factory from tier 2 is an air factory
    when the seat has none (seaplanes on maps ≥ 50 % water), and
    `tech.air_factory()` (the best finished one) keeps producing a tier
    behind and is never reclaimed for room. Tests (8 vs built-in): air
    factory in every seat at 7-16 minutes (Seaplane Platform for Core on
    Seven Islands), 5 wins 1 draw as before. One stop on Seven Islands
    (scouts after a wide lab-site search in the same turn): after a wide
    search (`builders.heavy_tick`) no more builder turns and the scouts
    wait a turn. Six mirrors after it: no stops, Arm ahead on kills on all
    six (Luschaven an Arm win); watch that Arm is not now the stronger.
  - Engine log: `runtime type has no FBI definition` at tick 89 491 in the
    earlier 8Islands game (known limitation).
  - Tests after all of it, 8 matches vs built-in hard on rich: 5 wins and 1
    draw of 6 (wins: Seven Islands Arm, before a draw, and Core; Ashap,
    Crater Islands, Luschaven; Core Prime a draw on time), 2 mirror draws, no errors, no
    stops.

- User's Two Continents game (2026-11-01, 4 seats Fast Tech, rich, 19
  min, no script errors). Fixes:
  - Stance is inherited from the factory: armed factories hold fire, so
    their ships did too. `hooks.onUnitFinished` sets fire at will on
    armed mobile non-careful units.
  - Speed: measured by repeating a module 5 times a turn in a scratch
    copy (no clock in the sandbox): builders, factories, army, scouts
    together explain ~2-3 s of a 15-minute two-seat Core Prime match.
    Lua instructions there: ~250-280 M in all (~150 k a second a seat,
    budget 2 M a tick), so most of the cost in big fights is the
    engine (simulation, path searches, rendering). Start (900 ticks,
    Two Continents): survey costs ~2 s of 8 (disabling it: same as
    builtin). Survey now routes every 6 ticks on alternating seats
    (spreads, not cuts, the cost), 3 ship points per enemy instead of 5;
    damage events throttled to one per unit every 10 ticks.
  - Target memory: `army.aimed` keeps target and priority, `pick`
    keeps a visible target (reach × 1.5) unless higher priority shows
    up, chases priority ≥ 3 targets to `world.sightings` positions for
    40 s (`chase`, attack-move).
  - Scouts: time limit 20 s + 2 × distance / speed; misses go to
    `scouts.failed` (per movement class, 256-unit squares, 10 min);
    water-only scouts take only water points.
  - Seat 4 spent 4.5 minutes at tier 0 looking for a Shipyard site
    (commander walking to unexplored ring points): first lab not begun
    90 s after being chosen is set aside (`tech.goal_since`).
  - Tests (10 matches, parallel): 7 of 7 wins vs built-in, no script
    errors; one engine `runtime type has no FBI definition` in a mirror
    match on Two Continents (known, README limitation).

- User's second Steel Jungle game (2026-11-01, 2v2 all Fast Tech, rich,
  39 min). Findings and fixes:
  - No wave before ~24 minutes: tier-2 mark 7 200 (9 000 × 0.8); only
    rescues left home. Marks lowered (3 000/5 000/20 000/60 000/120 000)
    and halved after 5 idle minutes with 8+ units. Tests: first waves
    at 5-11 minutes.
  - Seat 1 army flat 16-25 for 25 minutes: it reached tier 2 with one
    Advanced Kbot Lab, and the previous round's rule (lower tiers make
    nothing) idled its two Vehicle Plants; extra factories could also be
    one tier down and then made nothing. Now lower tiers stop only with
    2 top-tier combat factories; extra factories top tier only.
  - Slowdowns: `air cover` re-moved up to 82 units every 3 s (one path
    search each). Now a sheltering unit is not moved again for 15 s;
    patrols (`army.patrolled`), fighter patrols and keep_range step-backs
    are deduplicated like attacks.
  - AI lists (probe of game.build_list): static jammers ARMJAMMER/
    CORJAMMER only from ARMACH/CORACH (adv. construction hovercraft),
    ARMSONJAM/CORSONJAM from ARMACSUB/CORACSUB; underwater extractors
    ARMUWMEX/CORUWMEX from commanders, decoys (ARMDECOM/CORDECOM), CH,
    CS, CSA; shields/charge fields only from ARMECV/CORECV (Exp.
    Construction Vehicle, tier 4).
  - Leash 1 400 (`builders.leash`), commander reach 1 400, walk 1 200;
    decoys' first task is underwater deposits (`try_underwater`).
  - `economy.on_vent` keeps everything but geothermal plants off vents
    (crowds_factory and city.fits).
  - Scouts: 3/6/10 by tier from any factory, scout lab 12; two in three
    watch enemy starts (`terrain.targets`, `scouts.seen_start`).
  - Radar/sonar placed at the explored point farthest from towers of
    the same kind, never within half the range.
  - Tests (10 matches): 9 of 9 wins vs built-in, no errors.

- User's Steel Jungle game (2026-11-01, 4 seats all Fast Tech, rich,
  52 minutes, stopped): all seats stuck at tier 2, labs `no site` all
  game (even a 6×6 Kbot Lab), one seat no extractor in 52 minutes. Probe:
  the map has 43 deposits, every one with all 25 cells round it blocked
  (features, 20-60 metal each; some features are not reclaimable), and
  starts 1 and 5 have no deposit within 1 500. `map:passable` reads
  blocking features; `unit:reclaim(point)` takes the feature on that
  exact cell (engine `feature_at_position`, cell = world >> 20) and an
  empty cell fails at once. Probe: reclaiming 30 blocked cells round the
  commander freed 12 in 20 s; reclaiming the full 2×2 probe footprint
  freed 3 more; 15 stayed (slopes or unreclaimable). Added
  `feature_cells`/`clear_cells`/`clear_for`/`clear_deposit` in
  builders.lua (`builders.sweeping` keeps the builder on it 3 minutes,
  `builders.tried` avoids tiles still blocked after two clearings).
  Tests: Vehicle Plant now goes up after clearing; the 17×18 Ultra
  Aircraft Hangar still finds no clear ground; extractors there are not
  asked for (metal sits full because nothing can be built).
- FPS in big fights: `best_target` walked every visible enemy for every
  shooter (util.pos = pcall per f32), keep_range and builder danger too,
  `world.select` walked and sorted all own units per call (dozens a
  turn, inside placement loops), attack orders re-issued every 3 s.
  Now: per-tick enemy grid (`world.enemy_rows`, `enemies_near`,
  `friends_near`), per-tick own list, `army.attack` dedupes orders.
  Core Prime two Fast Tech 30 min: 193 s vs 251 s.
- Engine: hold fire (`fire_order != at_will`) skips the auto-targeting
  pass (`match-runtime/src/targeting.cpp`); attack orders are forced
  (`combat-state` `issue_attack_order`), so careful units (paralyzers,
  Bastion `CORSPUN`, blast 352) hold fire and get brain targets.
- Escalation data (probe): paralyzer first weapons ARMSPID Spider,
  ARMHSTUN Medusa, ARMSTUN Warden, ARMCBT Mirage, mSCORP Scorpion (Gorgon
  ARMASPID has it as weapon2: left out); `immunetoparalyzer` on ~90 types
  (aircraft, commanders, Spider, Warden...). Shields ARMSHGEN Aegis /
  CORSHGEN Corona (8 000 E/s, `ActivateWhenBuilt=0`: switched with
  `unit:on`), charge fields ARMFIELD Obelisk / CORFIELD Monolith (250
  E/s). Heavy reactors ARMSFUS Heavy Fusion, CORSFUS Anti-Matter.
- Tests after all of it (10 maps vs built-in hard, both sides): 10 wins,
  no errors; `booster:` and `air raid` seen once each.

- User's 4-seat Ring Atoll game (96 % water, rich, all Fast Tech; seat
  logs of the 2026-11-01 game): seat 1 (Arm, start 5312,9376) logged
  `building Shipyard` 13 times in 14 minutes and never raised it, metal
  full, then died. Cause: `place` near the shore failed, the wide search
  (once a minute per type) was run by the commander, found a site past
  the 900 leash, and `leashed` dropped the order but not the search
  clock, so the construction kbots that could build it never searched.
  Fixed: the commander's wide search keeps to 900 units on its own
  clock; a lab ordered 6 times with no frame is set aside
  (`tech.no_site(goal, true)`, no lab reclaimed for it); leash drops are
  logged. Factories stuck between trees and buildings: `map:passable`
  reads blocking features and settled buildings (engine
  `spatial-state/src/cell_classifier.cpp`), so factory sites need three
  open cells for the widest built unit at both ends of the exit axis
  (`exit_cells` in builders.lua, also for city sites via
  `city.exit_blocked`), and builders reclaim blocked lanes of finished
  factories (`try_clear_door`, task `door` after `resume`). Idle units
  in a lane also read as blocked: a placement is just tried elsewhere,
  a reclaim of a point with no feature is a short walk. Seats 2-4 also
  logged `no site` for 7×7/8×6 plants all game (most blocks poor ground
  on the islets). Tests after the fix (8 matches): 7 wins; the loss is
  Crater Islands seed 4242 as Arm, lost by the committed version too
  (also Crater Islands seed 99 as Core: both versions lose).

- Crater Islands (seed 4242) used to stall at tier 2 forever: the Ultra
  Vehicle Plant (18×18) fits nowhere on that map and the goal never
  changed. Fixed: wide search, then the lab is set aside for ten minutes
  (`tech.no_site`, log line `no site for ...`). On that map no tier-3 lab
  found a site in the test runs; the brain still wins at tier 2.
- Crater Islands: `enemy by land false` now (routes checked); only hover,
  deep-water tanks (`TANKDH*`), spiders/crabs and some boat classes get
  through. Luschaven: as Arm only `BOATS6` ships reach the enemy.
- Engine 0.8.9 (from 0.8.7): only path handling (UTF-8) and interface
  changes for brains; the brain API and docs are unchanged. `brain check`
  passes and the test matches give the same results as before.
- Engine 0.8.10: six commits after 0.8.9 (3D view speed, fonts, macOS),
  nothing in `src/sim/brains`, `src/sim/match-runtime` or `docs/brains`.
  `brain check` passes and six test matches give the same results.
- Engine 0.8.11: battle room (one human against computer players, the
  `setup.allow-start-with-ai` hack retired), key bindings on AZERTY and
  other layouts, order wheel, water explosions, rendering speed. Nothing
  in `src/sim/brains`, `src/sim/match-runtime` or `docs/brains` (only a
  model-runtime test). `brain check` passes.
- Engine 0.9.0 (2026-11-06, the Boneyards lobby, MCP server): `src/sim`,
  `docs/brains` and `brains` unchanged since 0.8.11. Escalation is now
  10.2.0 (packaging revision 6, requires engine >= 0.9.0). No brain change
  needed: `brain check` ok (Fast Tech and Classic), six test matches vs
  built-in hard on rich: 4 wins, 2 draws on time (Core Prime seed 7,
  Luschaven seed 7), no script errors. 4-seat games not tested.
- User's 4-seat game on 8Islands (91 % water, 20 480 × 20 480, map pack
  `8islands`, "bots building vehicles and kbots"): all four seats stopped at
  tick 3-6 (`tick ran for more than 250 milliseconds`), so the engine played
  them with its built-in player, and that is what built those units; the seat
  log holds only the stop. Any such game: read the log for `stopped:` first.
  Cause: the map has 1 638 400 cells, past route's cap of 1 048 576, and
  `meets` then asked `map:reachable` without ending the turn: 383 checks at
  once, regions rebuilt for each class (four are cached in a tick), and
  reachable's yes was optimistic anyway. Now `meets` always routes first and
  each check takes its own turn. A nil past the cap is ambiguous (the search
  gives up after 1 048 576 cells and answers nil too): reachable's no settles
  it; after its yes a 64 × 64 land/water grid decides for shallow land classes
  and ships, others count as through (`coarse_meets`). Maps under the cap take
  the same path as before. Tests on 8Islands, 4 matches at once for the load,
  30 minutes: 3 wins vs built-in hard (Arm twice, Core once), 1 mirror draw,
  no stops, no errors; `enemy by land false`, first goal Shipyard, map line
  after 33-35 s. 4-seat games still not tested. All stayed at tier 2 to the
  end: the 18×18 labs find `no site` on this map's islands.
- User's 8-seat game on 8Islands (all Fast Tech, 57 min, no stop): a lag
  of about ten seconds at the start, bases not defended, poor speed
  overall. Measured headless (`/usr/bin/time`, 900 ticks): each Fast Tech
  seat adds ~2.3 s, nearly all long sea routes of the survey. Ships, hover
  and sea-floor classes past 3 000 units are now judged on the coarse map
  alone on oversized maps (`far_water` in terrain.lua): map line at tick 252
  instead of 984, 40 s of game in 7.98 s instead of 10.95 s for two seats.
  Speed over a whole match is mostly the engine: 30 min on Two Continents,
  two seats, built-in 86 s (no fighting), Fast Tech 102 s, the brain before
  the table 113 s. The user's log shows anti-aliasing 8×8 (64 samples a
  pixel, 535 MiB) and frames of 211 810 vertices: worth a try lower.
  Defence: waves never came back (only `home` units answered the alarm).
  User's rule, `watch_emergency` in army.lua: three own facilities lost
  within 1 600 of the base in two minutes, or the commander hit by a non-air
  unit; waves come home, bombers and gunships too, fighters only against
  enemy aircraft; no waves until no armed enemy in sight within 1 600 of the
  base or commander for 20 s. Facility positions are kept while they stand
  (`army.facility_at`), a dead unit has no position. Seats 1 and 6 started
  42 units apart (18 704/18 746, 4 176) and had no builder or building after
  a minute: 9 commanders on the map, likely more players than starts; asked
  the user. One test then stopped at tick 42 600 in `scouts.step`: scouts
  asked map:reachable with up to 6 points each, several classes in a turn
  (regions rebuilt per class past four); now util.reachable (cached), 3
  points, two sends a tick.
- The brain plays by the table (2026-11-07): `catalog.lua` reads
  `entry.tags`, `threat`, `first_targets`, `ignored`, `only`; `world.can_hit`
  applies the lists (memoised per pair), `world.rank` orders targets (bomber
  on anti-air 40, list place 30 - index, else `world.priority`, now by threat
  level); `entry.scout` is the `scout` tag, so A.K., Peewee, Jeffy, Freaker
  and Zipper no longer count as army. `keep_range` in army.lua holds the
  skirmisher, artillery and `aoe` rules, `manage_cloak` the cloak. Engine: a
  blast's radius is `areaofeffect` / 2 (`detonate_area`), Bastion used to
  count all of it. **No `kamikaze` unit is in any AI list**, nor Pounder,
  Defiler, Matriarch: the brain cannot build them. Orders are limits on what
  the brain tells a unit: a unit on fire at will still picks by itself in
  the engine, only `careful` units hold fire.
  A soldier whose path failed waits 30 s before its next attack-move: with
  the new lists idle ships asked for one unreachable point over and over
  (Luschaven seed 7: 9 302 patrols and 7 675 stops, 1 078 and 381 after;
  the old brain had 1 818 and 1 222). Log line `distance: ...` each minute.
  Escorts (user, after a 4-seat game on a 75 % water map: anti-air fighting
  like frontliners in the melee): dedicated anti-air had no target among
  ground units, so it took the wave's attack-move to the enemy base and the
  engine fired its ground missile by itself. Now tag `escort` (user's name)
  on 20 units, the 16 dedicated and Scorpion, Thrasher, Monsoon, Flail;
  `step_escort` in army.lua: no waves, no attack orders, behind the nearest
  fighter of its kind, out of reach of ground guns, back to the rally point
  with no fighter within 1 500. Anti-air with another role (Marauder, Widow,
  Panther, Riptide, Slipstream, Cerberus, Centurion...) keeps that role. Same
  8 setups after it: 6 wins, 2 draws, no errors; escorts in waves 0 of 511
  samples (before: 260 of 334, one sample a minute over 3 setups). Too few
  samples under fire to judge: 2 of 511 vs 4 of 334. More of them stay
  alive (peak 21 vs 19 on Core Prime, 10 vs 6 Steel Jungle, 11 vs 7 Painted
  Desert) and Core Prime seed 7 gave 9 500 move orders vs 6 600 (not measured
  with the back-off alone). No test had escorts in a 4-seat game.
  Tests, 8 matches vs built-in hard on rich: 6 wins (Painted Desert Arm and
  Core, Ashap seed 99 Core, Crater Islands seed 99 Arm, Luschaven seeds 7 and
  99), 2 draws on time (Core Prime seeds 7 and 99), no script errors. Same
  six setups as the 0.9.0 check: 4 wins and 2 draws before. A probe of 21
  target rules passes. Seen in matches: skirmishers and artillery stepping
  back, cloak. Not seen: `aoe` moving apart (no such unit in these games),
  4-seat games. Core Prime seed 7: metal produced 506 k vs 823 k before
  (seed 99: 437 k vs 433 k), cause not looked into; cloak switched 67 times
  there.
- `data/units.json` (tracked; the user renamed `examples/` to `data/`):
  the user's table, all 549 unit types with `id`, `name`, `description`,
  `faction`, `built_by`, `threat_level`, `veteran_kills` (kills for the first
  veteran level, from the FBI `VeterancyThresholds`, else 5),
  `priority_targets`, `ignore_units`, `attack_only`, `tags`. It is the source now: the scripts that generated
  it were scratch files and are not kept, so change the file itself, then
  run `python3 data/make_unit_table.py` from the repo's top folder: it writes
  `fast-tech/lua/unit_table.lua`, which is what the brain reads (the package
  format allows `data/` files but the docs give no way to read them). All
  tags with their units, for reading (a snapshot, republish after changes):
  https://claude.ai/artifact/BzimK4tatcJJV3UZXJDUj2 (private).
  Read from the FBI files of the mod and checked against `units[]` in a
  probe. `built_by` is the union of the `guiE/*.gui` player menus (buttons,
  `id=1`, page file = builder), the `downloadsE` menus (without
  `UNITMENU=BLANK`) and `[CANBUILD]`: 1 821 builder/unit pairs, of which
  only 936 are in `game.build_list` (a brain gets `not_buildable` on the
  rest; 73 units have no brain builder at all). 15 units have no builder
  (commanders, mission units, `ZZZ`). Abilities such as `xHACK`/`xOMNI`
  count as built by ARMZIG/CORZIG (`builder=0`, `WorkerTime=0`).
  The other fields are deduced from the user's six example rows and rules:
  movement class, FBI keys, weapon flags and the description. User's
  rules: armed buildings have no targets, except static artillery
  (priority `commander, decoy, economy, facility, defense`, then `t5` down
  to `t1`) and nukes (`attack_only` those three); commanders and decoys
  are the top target (`threat_level` 6); bombers (not torpedo bombers)
  `commander, decoy, economy, facility, defense`; mobile artillery
  has the target lists of other mobile units; only its movement differs
  (user's rule: stays at range, retreats out of the reach of enemy weapons
  when they close in; `keep_range` in army.lua); a unit without anti-sub weapons ignores
  `underwater`; any anti-air weapon gives the `anti-air` tag (also
  Torrent; so does any anti-sub weapon for `anti-sub`). Mine, confirmed by
  the user: `economy` = static energy/metal/storage; `facility` = static
  factory, teleporter, radar, sonar, jammer, repair, shield, charge field,
  ARMTECH/CORTECH; `threat_level` = tier if armed, else 0 (crawling bombs
  by tier); `attack_only` only when all weapons are nukes (confirmed by
  the user). `skirmisher` (user's name) = mobile non-air units that keep
  their distance while firing: best surface weapon ≥ 700 at T1-T3, ≥ 1 300
  at T4-T5, no builders, artillery or `aoe` (the T3 threshold came out of a
  misunderstanding; the user keeps it, it may turn out interesting); Vandal
  `CORLART` is `artillery`. `frontliner` (user's name) = mobile non-air
  units fighting up close: a surface weapon, none of `skirmisher`,
  `artillery`, `aoe`, builder, mine layer, scout, commander, decoy or
  dedicated or heavy anti-air (subs and bombs are out). User's list on top
  of these rules: `skirmisher` also Crusader, Enforcer, Nixer, Wombat, Fido,
  Manticore, Behemoth, Centurion, Cerberus, Overseer, Renegade; `scout` also
  A.K., Jeffy, Peewee, Freaker, Zipper. `aoe` (name accepted) = special area
  weapons, must stay away from allies: Pounder, Gorgon, Gargant, Decimator,
  Zenith, Bastion (also `artillery`), Matriarch, Defiler, Tsar. An `aoe`
  unit is neither `skirmisher` nor `frontliner`. Mirage is to fight from
  range, paralyzing what can be paralyzed (user). `kamikaze` (user's name; the
  brain will use them in a special way) = FBI `kamikaze=1`: crawling bombs,
  mines but Perimeter Beacon, also Tick. `invisible` (user's name) =
  `cloakcost` or `cloakcostmoving` > 0, or mines with `init_cloaked`.
  `stealth` (user's name; invisible to radar) = `stealth=1`. Upgrades take
  these two from the building: their own `init_cloaked`/`stealth` only mark
  the hidden add-on. Engine: `can_cloak` needs `cloakcost` > 0, so Mirage,
  Revenant, Invader, Roach, Vermin and Tick (cost 0 standing, 40 M moving,
  `init_cloaked`) start cloaked but cannot be switched by order. Subs attack
  only water units (user's rule; `submarine` stays): `attack_only: water` on
  Lurker, Snake, Piranha, Shark, Maelstrom, Megalodon. Left out on the user's
  word, as their missiles reach the surface: Stalker, Leviathan, Deluge,
  Hammerhead, Abyssal, Vortex. Mines keep `threat_level` 0 (confirmed).
  `hunter` (user's name) = concentrates fire on the first of its
  `priority_targets`: Piranha, Shark (`submarine, commander, decoy` first,
  as the brain does), Zephyr, Cormorant (`submarine` first); not Archer,
  Shredder, Whirlwind, Banshee, Leviathan, Centaur, Shooter (user's choice).
  Weapon damage tables: every torpedo and depth charge does ×4 on subs,
  anti-air weapons hit aircraft; no bonus against tanks or tiers, except
  Leviathan's torpedoes (×2 on commanders and decoys). `paralyzer-immune` (name accepted) =
  `immunetoparalyzer=1`, 114 types (for upgrades their own flag, not the
  building's); every `paralyzer` has it in
  `ignore_units` (user's rule, also Warden; the mixed Medusa and Gorgon too,
  as their other guns only tickle immune units, mostly T3+).
  `carrier` = carriers (no `transport`); `transport` only for
  units that load and unload, teleporters included (user's rule). VTOL
  transports have no `canload`/`transportcapacity` in their FBI (commented
  out, the mod loads them by script, "ferry" in its changelog): they stay
  `transport`. Mission `mTRUCK` shows no way to load: no `transport`.
  Conflicts between lists (user's rule): `underwater` in
  `ignore_units` always wins, otherwise `priority_targets` wins. The 15
  upgrades bolted on one building carry that building's tags, priority and
  ignore lists (user's rule), but keep their own tier from the mod's
  category and `threat_level` 0 (confirmed by the user; 9 share the
  building's tier, 6 are one above it); ARMTECH/
  CORTECH and ALL_L2/ALL_L3 do not inherit. The `amphibious` tag means land
  and water: no `BOATD*` submarine has it (those classes have a minimum water
  depth), Ark `ARMTSUB` does (`TANKDH6`, no minimum depth). In the
  `priority_targets` of 12 armed subs `amphibious` names a target, as in the
  user's ARMAABOAT row. Weapon facts (engine `ballistic.cpp`):
  a non-water weapon never hits a submerged target; a water weapon hits
  only floating or submerged targets, not hovercraft, unless it has
  `surfacefire`; `nottounderwater` rules out submerged targets. Facts:
  the engine cuts Lua `name` at 31 characters (2 `*SFUS_UPGRADE` names);
  CORSONJAM and CORUSUB say `side=ARM` in the mod, written as CORE; other
  sides are ALL (9), MIS (6, mission units), GOK (1); `print` keeps at most
  256 lines and 16 384 bytes in a tick, so a probe must spread long lists
  over ticks.
- Fixed after the user's 4-seat Core Prime game on 0.8.11 (all Fast Tech,
  rich; "economy hiccuping on a metal map"): metal income swung 45 ↔ 1 000
  with the same extractors, as energy stalls closed the extractors' gate,
  and `economy.need` then asked for extractors. Now from tier 2 metal is
  the fading peak income (`metal_peak`, 0.997 a second) and energy
  spending above income (20 s averages) with the store under half asks
  for power. Also on Core Prime: most grid blocks are poor ground
  (`passable` 0 on about half the cells even for small classes), the
  18×18 labs fit only on far plateaus, and the one vehicle builder that
  could build the Ultra Vehicle Plant was sent there again and again
  (unreachable, 20+ minutes at tier 2). In the user's game one seat
  stayed at tier 0 for 3 minutes and another kept the Aircraft Plant goal
  19 minutes ("building" again and again, no frame): likely the same
  cause, not checked (4 seats cannot run headless). Every
  build site is now checked with `util.reachable`, lab sites also with
  one `map:route` a turn. Tests (Core Prime seeds 7/99/4242/951589622,
  Painted Desert, Crater Islands, Ashap): 5 wins, 2 draws; tier-1 timing
  equal to before; Crater Islands now reaches tier 3. Applied to the
  economy rules only from tier 2: on tier 1 they cost a minute.
- Arm vs Core (user: Arm wins far more often). I first reported that
  Core has no Vehicle Plant in its AI lists: **wrong**, the user
  corrected it (Arm and Core have equivalent units and each builder
  builds its side's next factory; only tier 4 is shared). Real cause: the
  engine gives an empty `category` for unit types from Lua index 512 on
  (38 Escalation types incl. CORVP, CORWIN, CORUWMEX, CORVROC, CORZIG),
  so the catalog found no `LEVn` and skipped them. Fixed by
  `infer_missing_tiers` in catalog.lua (tier from who builds the type).
  Now Core races kbot -> vehicle -> hover like Arm. Lesson: the mod
  tables can be read directly (`oa-tool list/extract` on `TAESC.gp3`
  etc.: `gamedatE/SIDEDATA.tdf`, `downloadsE/`, `guiE/`); cross-check
  probe results with them before telling the user about the mod.
- Engine limitations for the engine's author are listed in the README
  ("Engine limitations"); the user reports them. Add new ones there.
- Commander far from base (user): it went 1 300-2 100 units out (far
  build sites from the anywhere/wide fallbacks, help on far frames and
  factories) and `world.base` (middle of all buildings) drifted 1 100
  from the start. Now a 900-unit leash on every commander task
  (`leashed` in builders.lua drops the order and rests the task 20 s)
  and the base is the middle of non-extractor buildings within 1 500 of
  the start: max distance about 900-980 in tests.
- Builders leaving big frames (user: Armageddon, experimental reactor):
  helpers are `parked`, and after 15 s `ready()` gives them new work even
  mid-help. `try_resume` (after the goal) sends a builder to a frame of
  ≥ 5 000 metal nobody works on (`resume <name>`, logged once per builder
  and frame).
- Test after all of the above (8 matches vs built-in): 5 wins, 3 draws,
  same as before the changes. After the category fix and the lone-builder
  rule: 3 wins, 5 draws; the two lost wins are Core seats that now go
  vehicles instead of air and stay far ahead (Core Prime seed 7: 377
  units vs 181, metal 620k vs 82k) without finishing in 30 minutes.
  Mirror matches: Arm and Core take the same lines, all draws.
- User's 4-seat game on Icy Bergs (99 % water, ~13 000 units across)
  and fixes after it:
  - Lag at the start: the survey called `map:reachable` before each
    route; on a big map it costs more than the route (~2 s per seat in
    the first 15 s). `meets` now routes only (reachable only past the
    route cap); `util.reachable` caches answers 60 s per class and
    256-unit squares; the ship-survey planning asked `map:passable` for
    every water point × class × enemy (~50 000 calls in one turn, a
    first turn over 250 ms on Flooded Glaciers): now sorted by distance,
    first 5 sailable, memoised; the first think only refreshes the
    catalog. Timing with `/usr/bin/time` of 500-tick headless runs vs
    builtin,builtin is the way to measure (no clock in the sandbox, no
    perf on this machine); disable modules in a copy to bisect.
  - Shipyard boxed in: water factories keep 160 units clear all round
    (`rings` in crowds_factory).
  - Armed factories (weapon3 turns the unit exit) set to hold fire
    (`unit:stance({fire = "hold"})`, factories.hold_fire).
  - Sub hunters (`CTRL_U` + weapon name with SNIPE: ARMSUBK, CORSHARK)
    target subs/commanders/decoys first (priority 8).
  - Long-range units (range ≥ 700) step back when an armed enemy is
    within half their range (`keep_range` in army.lua).
  - Commander leaves for the nearest live ally's start when 75 % of the
    peak building metal is gone; with no ally it stands and stops
    fleeing (`builders.evacuating`).
  - Resurrection: no brain order exists (README limitation 11).
    Resurrectors (`canresurrect`: ARMFARK, CORNECRO, ARMREZ, CORREZ)
    stay builders.
  - Torrent idle when badly hurt: mend point was on land; now water by
    the base for ships/unreachable, re-sent up to 3 times
    (`army.mend_to`).
  - Icy Bergs logs: ships first everywhere; 18×18/24×24 shipyards often
    find no site; one seat had energy income 45 760 and an army of 2
    (energy overshoot still open).
- User's games on Core Prime, Dark Side, Flooded Glaciers (only the
  last one's seat logs survive: they are overwritten each game; the
  engine log in `~/.local/share/open-annihilation/logs/` lists the
  matches). Fixed after them:
  - Ships judged by weapon reach (user's rule): per boat class the
    nearest water point reached near each enemy start
    (`ship_approach`), ship useful when range + 300 covers it
    (`terrain.ship_hits_base`); BOATA classes (Core Monitor, Inferno,
    Rancor) are ground classes. Across water ships rank before hover
    when they shell the enemy. Flooded Glaciers: Shipyard first now.
  - Builders idle in Standby: a repairer that never got to its target
    (sub sent to a land building) kept `builders.repairing` forever and
    took no work; now dropped after 10 s idle and the pair skipped for
    a minute, repairers must reach the target, `can_mend` too. The
    commander assisted a random far factory (dropped by the leash):
    now the nearest busy one within 800.
  - Resume: own last frame first, then any frame nobody works on
    (any cost) within 1 500, before any other task (`resume <name>`).
  - Cost: factories build what their share of income pays in ~2 min
    (`economy.affords`), artillery budget 2 min (5 from tier 4), metal
    and energy.
  - A first turn over 250 ms stopped a seat on Flooded Glaciers during
    a test with 10 matches in parallel: catalog.refresh_builds now
    reads each build list once (the tier inference read them 3 times).
  - Engine fault in the user's log: `runtime type has no FBI
    definition` (Flooded Glaciers); added to README limitations.
- User's 4-seat game on Coast To Coast (54 % water, hover line): weak
  economies (1-4 extractors, the map has few deposits near the starts),
  two seats dead by 7-10 minutes, one stuck at tier 1 for 16 minutes
  while harassed: its builders fled 81 times and metal sat full. Fleeing
  builders may stall a base under constant raids. Fixed: inside the base
  (800 units) a hit alone makes a builder flee only below 50 % health;
  real danger (big groups, T3+, enemy commanders) still does.
- `brain.place` stops after 4 096 cells (radius about 500 world units),
  whatever radius is passed.
- Not yet seen in a match: guns firing at remembered buildings or contacts,
  commander fleeing or D-gunning, jammers (depends on the AI list), ally
  rescue, carriers.
- Fixed after the user's 4-seat Crater Islands game (all four seats were
  Fast Tech): the survey took 2-4 minutes, so the first lab was a kbot lab;
  now ~15 s and the first lab waits for it, and lines that cannot reach the
  enemy rank last even when they climb. Hover builders idled in `Park`; a
  hovercraft platform built with an extractor at its door trapped its
  builders; the nearest water was a lake no builder reached. Water-only
  buildings were dropped from the build lists: underwater extractors,
  tidal/floating power, floating anti-air and defences are now built. Tier-1
  stutter (metal full, nothing spent): the commander built energy storage
  and the first builder built anti-air before the lab; now storage waits
  for tier 2, the lab comes first, and the commander helps the factories
  when metal piles up. Ring Atoll: builders walked to unexplored grid
  blocks all game; walks are limited to 600 units from the base.
- Seat logs print `extractor off deposit: ...` when a finished extractor
  covers under 90 % of the deposit; none in the test runs after the 80 %
  rule. The user still saw badly placed extractors once: ask for the seat
  log line if it happens again.
- Commander and decoys flee any enemy commander or decoy within 1 100.
  Not yet seen in a test match (neither `decoy flees`).
- Builders flee (`builders flee: N`): 15 times on Crater Islands, once on
  Painted Desert fair, no loss in results. `onUnitDamaged` gives the
  attacker only when the seat may know it.
- Salvage: feature (rock/tree) positions are not in the API; the engine's
  RepairPatrol reclaims features in sight only while a store is below 20 %
  (`reserve_fraction`), so the brain patrols crowded blocks then. Wrecks
  come from `onUnitDestroyed`'s `wreck` ({name, x, z}, nil for many
  deaths). `salvage sweep` seen (Coremageddon, Painted Desert fair);
  `salvage wreck` never in tests: low stores and nearby wrecks rarely
  coincide.
- Added on user request (after a 4-seat game on Ooooweeee, where only
  aircraft reach): no torpedo units unless ships reach the enemy; units
  only shoot what their weapons can hit (`world.can_hit`); anti-air is a
  target above the economy, bombers go for it first; aircraft pull back
  from strong anti-air (`aircraft pull back from anti-air: N`); guns fire
  at anti-air first while the seat has strike aircraft; the home army
  helps an ally in grave danger (`ally in danger at ...`; needs a game
  with allies, never tested headless); repair pads and carriers with
  enough aircraft (aircraft go to pads by the engine's repair retreat);
  commander under 75 % is repaired by up to four builders; it walks back
  to the base and waits there until mended (it used to hold still where
  it was hit, an easy target);
  commander upgrade building from tier 3 (Arm Research Facility `ARMTECH`,
  Core Upgrade Center `CORTECH`, both in the AI lists); lines that do not
  reach the enemy are no tech goal and no extra factory.
- Wind and tide (fixed after the user saw no wind generators on
  Ooooweeee, wind 2 500..4 500): a wind generator makes `windgenerator *
  strength / 5000` (engine `default_wind_strength_divisor`), a tidal one
  `tidalgenerator * map.tide` (Tidal Generator rating 1, tide 20-30). The
  catalog took `min(rating, strength)` and judged against the best tier-1
  plant, which was the geothermal (300): wind and tidal were never built.
- Aircraft go to repair pads by themselves only in some missions: below
  75 % health, on a patrol waypoint or an air attack pass, with a pad of
  the owner within 3 840 (`repair_pads_in_reach`). A brain cannot order a
  landing directly (`guard` gives VTOL_Follow, `load` VTOL_Pickup); it
  sends aircraft under 50 % on a patrol to the nearest pad
  (`aircraft to repair pads: N`). Not yet seen working in a test match.
- `city.place` had no bound on the positions it scanned (the metal test
  reads every footprint cell): on Core Prime (seed 7) a turn passed 250 ms
  and the seat stopped, in the committed version too. Capped at 1 500
  positions per placement.
- With metal piling up, builders that cannot start the next lab must still
  help its frame first: sending them to guard factories instead slowed the
  tier-2 air plant from 6 700 to 15 000 ticks on Coremageddon.
- Fixed after user reports: extractors beside taken deposits (60 % rule),
  Moho upgrades half off the deposit, units built that cannot reach the
  enemy (reach per class via routes), energy short at tier 3 (ratio by
  tier, metal-full + energy-dry is urgent), big metal stores and too many
  factories, far deposits never reached (walk timeout by distance, starving
  builders do economy only).
- Matches are chaotic: a small change shifts a whole game, so judge a
  change on several maps and both sides, not one run.
- Known weaknesses: on the fair level (1x income) the built-in hard AI
  beats the brain on Painted Desert (the committed version lost too);
  energy can still run dry at tier 3 on boosted; late on rich levels
  energy overshoots (income 2-4x spending); the `map:` line was once
  printed twice in a 4-seat game (the survey was rewritten since; not seen
  again, but 4-seat games cannot run headless).
- Grid ideas proposed but not done: verify factory exits with
  `map:reachable`; two block sizes (24 for labs, 12 for town).
