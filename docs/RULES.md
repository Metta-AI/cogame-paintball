# Paintball rules

Two squads of four cogs. One hill. The floor is the scoreboard.

## The board

The hand-tuned `arena`: **1235 × 659** map pixels, mirror-symmetric, fixed for
every episode. One **game** is `maxTicks` = 2160 ticks = **90 s** at 24 ticks/s.
One **episode** is `maxGames` = 2 games: game 0 plays the `resident` regime,
game 1 plays `visitor`. Map, seed and connected seats are identical across the
two; the paint grid, the hill counters and every cog reset between them.

## Loadout

Under `loadout: "paintball"`:

1. Every cog spawns and respawns holding a **spray can** and never loses it.
2. The **gun is disabled** — that is already the engine's rule for a can
   carrier, so `resolveSimultaneousFire` never fires in a paintball game.
3. **No pickups are placed at all**: no grenades, med kits, shields, spray cans
   or cardboard barriers, and `barrageMaxPerSec` is 0.
4. There is **no heart objective**: `hill` replaces the capture win condition,
   and the hearts are retired at game start so nothing draws them.

Cone numbers are the engine's, unchanged: reach **170 px** (5 cog bodies) along
the centreline, widening to **85 px** at the tip (half-angle ≈ 14°), victims
tested as **17 px discs**, cone **active 5 ticks** holding the aim it was fired
at, **20 ticks** to repressurize, line of sight required, friendly fire on.

One number changes: **`sprayDamage` is 1** (the engine's default is 3). A cog
has 3 hit points, so a cog is **tagged out by three touches**. That is what
makes the heal half of the paint buff meaningful and what stops a 90-second
game being decided by one ambush.

Tag-out: hp 0 → out for `respawnTicks` = 48 ticks (2 s), then back at a random
spot in its own endzone at full hp, can still in hand. `lives: 12` per cog.

## Mechanic 1 — the paint grid and the floor-paint buff

The map is divided into square **paint tiles of 34 px** — one cog body. On the
arena that is 37 × 20 = **740 tiles**. A tile is **paintable** when its centre
pixel is not wall with the spinning diamonds at spin frame 0 — computed once at
map install, so the native server and the browser viewer agree exactly.

**Painting.** On every active cone tick, every paintable tile whose *centre*
lies inside the cone flips to the sprayer's team colour. A burst lays roughly
eight tiles. Nothing else paints the floor.

**The buff.** Once per tick each living cog reads the tile under its **body
centre** — the same "you are in it exactly while your centre is inside" rule
trenches and puddles use:

| Under your feet | Max speed & acceleration | Health |
|---|---|---|
| **your own colour** | **×125 %** | after **48 consecutive ticks (2.0 s)**: **+1 hp**, capped at max, counter resets |
| unpainted | ×100 % | — |
| **the enemy's colour** | **×85 %** | — |

With the stock max speed of 704: own paint 880, unpainted 704, enemy paint 598
motion units — a ~47 % swing between a cog on its own lane and one wading
through the enemy's. The heal counter is reset by stepping off own paint for
even one tick, by taking any damage, by dying, and at the start of each game.

## Mechanic 2 — King of the Hill

**Where.** The **5 × 5 block of paint tiles centred on the map centre** — a
170 × 170 px square at (617, 329). Wall tiles inside the square are excluded
from **both** the numerator and the denominator, so "80 % of the hill" always
means 80 % of the floor a cog can actually stand on. The square is centred on
the map's symmetry centre, so its floor set is team-fair by construction.

**Ownership.**

```
owns(T)  ==  hillPaint[T] * 1000 >= hillFloorTiles * 800
```

800 > 500, so at most one team can qualify. Every tick a team owns the hill it
banks **one hill point** (24 per second). The scorebug shows the banked time as
`M:SS`. An ownership change is a scrubber beat and a feed line.

## Mechanic 3 — resident / visitor

Each game runs a **regime**:

- **`resident`** — every cog of a team is driven by that team's seat.
- **`visitor`** — only `alpha` is driven by the seat. `beta`, `gamma` and
  `delta` run the **`holdline`** scripted baseline, compiled by the identical
  control layer. Both seats are visitors in the same game, so the comparison
  stays symmetric.

The scripted partners are always `holdline`, documented below, so ad-hoc
teamwork here means "adapt to a partner you know the rules of but do not
control" — the Melting Pot construction, not "guess a mystery partner".

## How a game ends

| `reason` | `endRule` | When |
|---|---|---|
| `complete` | `full_time` | both games played their 2160 ticks (the normal ending) |
| `complete` | `mercy` | the hill lead exceeded the ticks remaining |
| `complete` | `wipe` | a team ran out of cogs; the survivor is credited every remaining tick |
| `deadline` | `wall_clock` | the 690 s engine budget elapsed; the half is scored from its hill counts at that instant |
| `fault` | `sim_fault` / `host_error` | scores 0.5 / 0.5, `win` both false |

A seat that never connects does **not** end the episode: the no-show is
reported to `COGAME_PLAYER_FAILURE_URI`, its squad plays `holdline` for the
whole episode, and both games play to full time.

## The directive

Every 4.5 seconds (108 ticks) a seat issues one directive for the cogs it
commands. 20 turns per game, 40 per episode.

```json
{"note": "flood the west rim, beta screens",
 "cogs": [{"id": "RED-alpha", "intent": "hold_hill", "target": [617, 329],
           "face": [700, 300], "say": "on hill"}]}
```

| Field | Cap / legal values | Repair when violated |
|---|---|---|
| `note` | ≤ 160 runes | truncated on a rune boundary |
| `cogs` | exactly the commanded cogs (4 resident, 1 visitor) | extras dropped; a missing cog keeps last turn's, else `holdline`'s |
| `cogs[].id` | one of the commanded ids, case-insensitive, ≤ 12 runes | unmatched entries assigned by position |
| `cogs[].intent` | `paint_hill` `hold_hill` `hunt` `guard` `paint_path` `fall_back` | → `paint_hill` |
| `cogs[].target` | `[x, y]`, clamped to the map box | missing / non-finite → the hill centre |
| `cogs[].face` | `[x, y]` or null | → null (the control layer picks the aim) |
| `cogs[].say` | ≤ 10 runes — a real in-game **shout**, audible to both teams within 247 px | truncated on a rune boundary, then printable-ASCII |

Every cap is measured in **runes**, never bytes: a byte-truncated multi-byte
character renders in a browser and then fails a strict UTF-8 parser.

## The control layer

Both LLM directives and scripted directives are compiled by the *same*
deterministic code, so the two policy kinds are strictly comparable.

1. **Goal point** by intent — `paint_hill` the nearest non-own hill tile,
   `hold_hill` the nearest own hill tile (else the centre), `hunt` the last
   known position of the nearest enemy seen within 72 ticks, `guard` the
   target, `paint_path` the nearest non-own tile on the line to the target,
   `fall_back` the target clamped into your own endzone.
2. **D-pad** = the octant of the flow-field steering vector. A cog within 20 px
   of its goal stops.
3. **Aim** — the nearest enemy inside vision within 300 px, else `face`, else
   the goal when the intent paints, else the hill. No turn button inside 4
   brads of error.
4. **Trigger** — the can is ready, the aim error is ≤ 24 brads, and either an
   enemy body is within the cone's reach with line of sight, or the intent
   paints and the tile 85 px ahead is paintable and not ours. `fall_back` never
   fires.
5. Up+Down and Left+Right are never set together; `C` is never set.

## The scripted baselines

- **`holdline`** — the certification player, the fallback directive, the driver
  of every scripted teammate in a `visitor` game, and the default. Of the cogs
  it governs: the one nearest the hill centre is `hold_hill` at the centre; the
  next two are `paint_hill` at the two non-own hill tiles furthest from each
  other; the furthest is `guard` at a point 250 px off the hill on its own
  side, facing the hill. Any governed cog with a known enemy within 200 px
  switches to `hunt`.
- **`sprayer`** — deliberately weaker and different in shape: every governed
  cog gets `paint_hill` at the nearest non-own hill tile, nobody guards, and
  `hunt` fires only inside 120 px.

## Two name spaces

Prompts, in-game labels and shouts carry only `RED`/`BLUE` and
`RED-alpha … RED-delta`. Real policy names appear only spectator-side: the
replay config JSON, `roster[].name`, `teams.<color>.policies`, the DOM
scorebug/endcard and `results.names`.
