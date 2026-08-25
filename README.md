> **ARCHIVED (2026-08-25).** Paintball King of the Hill was merged back into
> [Metta-AI/coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (PR #307) as a
> config-gated mode of the paintbot engine, and now runs as the **KOTH** league
> under the paintbot coworld (softmax.com/paintbot/koth). This repo is frozen;
> the living code, docs and tests are in coworld-ctf (`docs/paintball/`,
> `tests/test_pb_*.nim`).

# Paintball — King of the Hill

Two four-cog squads fight over one central hill by **painting the floor**.

Every cog carries a paint sprayer. The cone tags enemies *and* repaints the
floor tiles it covers. Standing on your own colour makes a cog faster and heals
it; standing on the enemy's slows it down. The team whose colour covers **≥ 80 %
of the hill's floor tiles owns the hill** and banks one point per tick for as
long as it holds it.

An episode is played **twice** — once with each seat commanding its whole squad
(**resident**), once with each seat commanding a single cog beside three
scripted teammates (**visitor**) — and the two halves are averaged. A policy
that only works with clones of itself ranks below one that also works beside
strangers.

## Seats

`num_agents` is **2**. One seat = one squad commander. Seat 0 commands RED,
seat 1 commands BLUE; each squad is four cogs, `RED-alpha … RED-delta` and the
same for BLUE. A seat never drives a motor or a trigger: every 4.5 seconds it
issues **one directive** and a deterministic control layer executes it.

## A policy is just a prompt

```bash
coworld upload-policy coworld-paintball:latest \
  --name my-paintball --run /bin/paintball-player \
  --secret-env PLAYER_PROMPT="Own the hill and never give it back. …"
```

The same image also ships two published scripted baselines, selected by
`PLAYER_SCRIPTED=holdline` or `PLAYER_SCRIPTED=sprayer`. A seat that sets
neither plays `holdline`.

The decision happens in the **game** server, not the player container: the
`anthropic_api_key` coworld secret is injected into the game pod, and keeping
the control layer server-side is what makes the recorded action log
reproducible with no network in the loop.

## Scoring

```
gameScore(seat) = 0.5 + 0.5 * clamp((hillTicks[you] - hillTicks[them]) / 720, -1, +1)
score(seat)     = 0.5 * gameScore(resident) + 0.5 * gameScore(visitor)
```

Higher is better, every score is in `[0, 1]`, and the two seats' scores sum to
exactly 1. A 30-second hold advantage in a game is a 1.000; a dead-even game is
0.500. A `fault` episode scores 0.5 / 0.5 — an infra fault is nobody's loss.

## Docs

- [docs/RULES.md](docs/RULES.md) — the rules, the numbers, the baselines.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — the wire protocol and what a seat sees.
- [docs/COMMANDING.md](docs/COMMANDING.md) — writing a paintball prompt.
- [docs/plans/2026-08-25-paintball-design.md](docs/plans/2026-08-25-paintball-design.md)
  — the accepted design note this repo implements.

## Layout

```
src/paintball.nim            game server entrypoint (seed randomisation)
src/paintball_player.nim     the thin seat registrar (/bin/paintball-player)
src/paintball/paint.nim      the paint grid, the buff, King of the Hill
src/paintball/control.nim    directive -> per-tick actuator masks
src/paintball/directives.nim the reply schema, tolerant parse, rune caps
src/paintball/baselines.nim  holdline + sprayer
src/paintball/llm.nim        Bedrock / Anthropic transport
src/paintball/decide.nim     the per-turn parallel batch and its deadlines
src/paintball/…              the inherited coworld-ctf engine (sim, server,
                             replays, broadcast, global, arena, roster)
client/                      the broadcast chrome (inherited + one game block)
replay-viewer/               the static wasm replay bundle
tools/ci/                    docker smoke, viewer smoke, policy set
tests/                       the Nim suite CI runs in debug AND release
```

Forked from **`Metta-AI/coworld-ctf`** (paintbot). The 24 Hz tick loop, the
Sprite v1 input mask, the continuous movement and per-pixel wall/LoS masks, the
fog of war, the spray cone, the shout channel, the `COWLD…` replay codec with
its per-tick `gameHash` chain, the mummy server and its `COGAME_*` contract,
the broadcast chrome and the emscripten static replay bundle are all inherited.

## Building

The sandbox that authored this repo has no Docker, no Nim and no emsdk:
`.github/workflows/ci.yml` is the only harness. It runs every `tests/*.nim`
twice (debug and release), builds the production image and plays one real
episode in raw Docker, then builds the static replay bundle and **opens it in
headless chromium**.

```bash
docker build --platform=linux/amd64 -t coworld-paintball:ci .
tools/ci/docker_smoke.sh coworld-paintball:ci
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```
