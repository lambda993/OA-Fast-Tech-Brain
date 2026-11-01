# Fast Tech — notes for continuing the work

Fast Tech is a computer player ("brain", Lua) for the **TA: Escalation** mod
in **Open Annihilation** (OA, engine 0.8.11). It races up the tech tiers,
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
| `brain.lua` | Hooks; one turn a second (`think`): world, map survey, tech goal, then builders, factories (2 s), army (3 s), scouts and pruning (5 s), status (60 s), city dump (600 s). |
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

## State and open points

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
