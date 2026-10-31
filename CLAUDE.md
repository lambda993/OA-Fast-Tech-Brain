# Fast Tech — notes for continuing the work

Fast Tech is a computer player ("brain", Lua) for the **TA: Escalation** mod
in **Open Annihilation** (OA, engine 0.8.7). It races up the tech tiers,
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
- **Never commit or push unless the user says so.** The user usually says
  "comitta e installa": then commit, pack, install, check (see below).
- The repo is meant for a private GitHub repo
  (`https://github.com/lambda993/OA-Fast-Tech-Brain.git`); no remote is set
  and nothing was pushed (the harness refused adding the remote; the user
  pushes by hand if wanted).
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
- `game.build_list` lists contain duplicates (Escalation weighs AI choices
  with them); the catalog removes them.
- The sandbox forbids `pairs` over tables with table keys (non-deterministic
  order): use sequences.
- `map:reachable(unit_handle, ...)` can answer false from a blocked cell;
  use positions (`{x, z}`) as both ends. Points work.
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
| `lua/terrain.lua` | Water share, water point for shipyards, enemy starts, reach per movement class, which lines reach the enemy, line ranking. |
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
4. Up to 15 decoy commanders from tier 2; they build and fight without fear.
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
8. Repairs: buildings ≥ 7 500 metal below 50 % during an attack (3 builders
   each); T3/T4 units below 30 % go home and get repaired.
9. Clear large wrecks in the base after fights; sweep blocks where nothing
   fits (feature positions are not in the API).
10. Fusion and geothermal armour upgrades.
11. Lots of static anti-air T1–T3; long-range artillery (Bertha/Intimidator,
    Vulcan/Buzzsaw, Armageddon/Dictator, B.F.G.), aimed by the brain.
12. Target priority: commander/decoy > T4 > T3 > economy, factories and
    builders > rest; focus fire on commanders; radar/sonar contacts are
    targets when nothing is in sight.
13. **Not possible** (not in the AI build list): nukes and anti-nukes 3:1,
    Tribulation, tier-1 radar.

## State and open points

- Crater Islands (seed 4242) used to stall at tier 2 forever: the Ultra
  Vehicle Plant (18×18) fits nowhere on that map and the goal never
  changed. Fixed: wide search, then the lab is set aside for ten minutes
  (`tech.no_site`, log line `no site for ...`). On that map no tier-3 lab
  found a site in the test runs; the brain still wins at tier 2 in about
  35 minutes.
  The map line there says `enemy by land true`, and land units do reach the
  enemy, so the earlier expectation of `false` was wrong.
- `brain.place` stops after 4 096 cells (radius about 500 world units),
  whatever radius is passed.
- Not yet seen in a match: guns firing at remembered buildings or contacts,
  commander fleeing or D-gunning, jammers (depends on the AI list).
- Known weaknesses: energy runs short at tier 3 on some maps; many factories
  and big stockpiles late on rich levels; the `map:` line was once printed
  twice in a 4-seat game (harmless, unexplained).
- Grid ideas proposed but not done: verify factory exits with
  `map:reachable`; two block sizes (24 for labs, 12 for town).
