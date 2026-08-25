# Agent operating guide — cogame-paintball

Orientation for coding agents working in this repo. Gameplay rules live in
[docs/RULES.md](docs/RULES.md) and the accepted design note in
[docs/plans/2026-08-25-paintball-design.md](docs/plans/2026-08-25-paintball-design.md);
this file covers the workflows that are easy to get wrong.

## Where it came from

Forked from **`Metta-AI/coworld-ctf`** (paintbot). Everything not listed below
is that engine, renamed and otherwise untouched, and should stay that way: the
24 Hz tick loop, the Sprite v1 button-mask input, continuous movement with
per-pixel wall/LoS masks, the fog of war, the spray cone, the shout channel,
the replay codec and its per-tick `gameHash` chain, the mummy server and its
`COGAME_*` contract, the broadcast chrome, the emscripten static replay bundle.

Paintball adds exactly three mechanics — floor paint as a buff, King of the
Hill, and resident/visitor scoring — and every one of them is a **config gate
that is off by default**. A gate-off config plays the starter's rules
unchanged, which is what keeps the inherited engine meaningful.

## Layout

- `src/paintball.nim` — server entrypoint (seed randomisation happens HERE,
  before `config.update`).
- `src/paintball_player.nim` — the thin seat registrar (`/bin/paintball-player`).
- `src/paintball/paint.nim` — **the only new hashed arithmetic**: the tile
  grid, the cone→tile predicate, the buff, the hill. Integer-only, end to end.
- `src/paintball/control.nim` — directive → per-tick actuator masks. OUTSIDE
  the determinism boundary (the viewer replays recorded masks and never runs
  this), so ordinary floating-point navigation maths is fine here.
- `src/paintball/directives.nim` — the reply schema, tolerant parse, repair,
  and every rune cap.
- `src/paintball/baselines.nim` — `holdline` and `sprayer`.
- `src/paintball/llm.nim` — Bedrock/Anthropic transport, ported from
  cogame-bullwhip.
- `src/paintball/decide.nim` — the per-turn parallel batch, its deadlines, the
  budget guard and the fallbacks.
- `src/paintball/{sim,sim_types,sim_state,sim_config,server,roster,replays,
  replay_runtime,broadcast,global,arena,map_art,labels,rig_art,
  wire_constants,map_pool}.nim` — the inherited engine.
- `tests/` — run from the repo ROOT (`nim r --path:src tests/test_paint.nim`);
  assets resolve via `data/`. Debug builds are 10–50× slower through the
  per-pixel map code, so keep fixtures short and put anything heavy behind the
  `NIM_TESTS_RELEASE_ONLY` repo variable.

## The three rules that are easy to break

### 1. New hashed arithmetic is INTEGER ONLY

`paint.nim` is re-derived tick for tick by the wasm viewer. Nim's `int` is
32-bit under `--cpu:wasm32`, and a compile-time `cos`/`sin` would be evaluated
by whichever libm the build container shipped — so the cone predicate reads its
direction out of the fixed-point `AimUnitX`/`AimUnitY` literals in
`sim_types.nim` and takes its products in `int64`. Do not introduce a float
into `paint.nim`, into `gameHash`, or into anything `sim.step` calls under a
paintball gate.

If you change what `gameHash` mixes, every existing replay stops
re-simulating: bump `GameVersion` and say what the number means in its
prepend-only changelog comment.

### 2. Truncate on RUNE boundaries, never bytes

Every string that can reach the replay — `note`, `say`, the policy label, the
fallback detail, the whole serialized directive record — is capped in RUNES and
cut with `runeLen`/`runeSubStr` (`directives.truncateRunes`). Slicing a string
by byte index on any path to the replay is forbidden: a byte-truncated
multi-byte character renders in a browser and then fails a strict UTF-8 parser.
`tests/test_directives.nim` pins the case with a 4-byte emoji on the boundary.

### 3. Two name spaces, both directions

In-game — prompts, sprite labels, shouts, directive records — carries only
`RED`/`BLUE` and `RED-alpha … RED-delta`. Real policy names live spectator side
only: the replay config JSON, `roster[].name`, `teams.<color>.policies`, the
DOM chrome and `results.names`. `tests/test_identity_privacy.nim` asserts
BOTH sides, so a change that leaks a name and a change that hides one both
fail.

## Seats and cogs are different things

`num_agents` = 2. `sim.players` holds the **eight cogs**; the two websockets
are the **seats**. Cogs are dealt round-robin across the teams by the roster's
own slot rule, so cog index parity IS the team ordinal and therefore the seat:
0/2/4/6 are RED-alpha…delta, 1/3/5/7 are BLUE-alpha…delta. That interleave is
deliberate — it means `teamForSlot` and `slotIdentityIndex` are inherited
unchanged. Use `sim.cogSeat`, `sim.cogIdentityIndex`, `sim.cogAlias`,
`sim.squadCogs`, `sim.commandedCogs` and `sim.seatCommands` rather than
re-deriving any of it.

Consequences worth remembering:

- The seats join first (slots 0 and 1, token-checked, carrying the real policy
  names); the server then fills 2…7 with trusted joins carrying only aliases.
- A seat that drops **does not** remove its cogs. Deleting the row would
  renumber every later cog mid-replay; the squad is fixed for the episode and
  the directive source just degrades to `holdline`.
- A seat that never connects does not end the episode: the no-show is reported
  to `COGAME_PLAYER_FAILURE_URI` and the squads are built anyway.

## The replay chat stream carries two different things

Told apart by a leading `{`:

| First byte | Meaning |
|---|---|
| `{` | a paintball CONTROL record (`register`, `directive`, `fallback`, `budget_guard`, `result`) — re-applied at playback into NON-hashed fields only |
| anything else | a cog's real in-game **shout** — hashed state, re-applied identically |

`sanitizeSay` therefore drops braces: a shout that could start with `{` would
make that discrimination ambiguous. Keep it that way.

## The chrome is inherited, not rewritten

- `client/chrome_common.js` is **byte-identical** to coworld-ctf's, pinned by a
  fingerprint in `tests/test_viewer.nim`. It reads its wire block off the
  starter's global name, so `wire_constants.nim` publishes that name as a
  one-line alias. Those two places are the only `CTF_` survivors in the repo.
- `client/broadcast_core.js` differs in **exactly** the one wire identifier.
- `client/replay_broadcast.html` is the starter's page plus an appended block
  under the banner `PAINTBALL additions to the inherited coworld-ctf chrome`.
  Edit inside the page only where the design note names — the scorebug plates'
  contents, the feed and beat routing, the endcard's stat columns — and put
  everything else in the appended block.
- The appended block's beat builder is `pbBeat`, NOT `markBeat`: the page's
  chrome alias block hoists `var markBeat = C.markBeat`, and a game-block
  function of that name is silently swallowed by it.
- `#viewpanel` (zoom bar + minimap) is **removed**, not hidden: the arena is
  fixed at 1235 × 659 and `relayout()` always fits it whole.

## Building and testing

The sandbox that authored this repo has no Docker, no Nim and no emsdk;
`.github/workflows/ci.yml` is the only harness and phase 20's exit criterion is
that workflow green on `main`. It runs every `tests/*.nim` twice — debug (range
and overflow checks) and `-d:release` (release-only codegen bugs) — builds the
production image and plays one real episode in raw Docker, then builds the
static replay bundle, **opens it in headless chromium**, and re-simulates the
recorded masks inside the emitted wasm module as a native↔wasm hash gate.

Three repo variables narrow the test job: `NIM_TESTS`,
`NIM_TESTS_DEBUG_ONLY`, `NIM_TESTS_RELEASE_ONLY` (currently
`tests/test_perf.nim`).

Do not make CI pass by weakening or deleting a test. If a behavioural threshold
is genuinely a property of a ladder rather than of one sample, log the number
and assert the invariant — `tests/test_control.nim` shows the shape.
