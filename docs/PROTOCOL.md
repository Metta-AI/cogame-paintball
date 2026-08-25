# Paintball wire protocol

Paintball inherits coworld-ctf's **Sprite v1** protocol unchanged. This file
states what a paintball SEAT connects to, what it may send, and exactly what it
can and cannot see.

## Routes

| Route | What it is |
|---|---|
| `GET /healthz` | liveness, `200 healthy` |
| `GET /player?slot=N&token=T` | the seat websocket (403 on a bad slot or token) |
| `GET /global` | the spectator/board websocket |
| `GET /reward` | the reward stream |
| `GET /client/global`, `GET /client/player` | real HTML pages, registered before any catch-all asset route |
| `GET /replay-data` | the recorded replay bytes |

There is deliberately **no replay page on the pod**. Paintball's replay viewer
is the static wasm bundle the manifest declares
(`"replay_viewer": {"bundle": "static-replay-viewer"}`), served from object
storage and contacting nothing but the `?replay=` URL it is given; the
starter's pod-served replay routes are removed rather than left listening.

`/healthz` and `/global` keep answering for a bounded ~20 s grace after the
episode's artifacts are written, then the process exits.

## Runtime contract

`COGAME_CONFIG_URI`, `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_LOAD_REPLAY_URI`, `COGAME_EVENTS_URI`,
`COGAME_METRICS_URI`, `COGAME_HOST`, `COGAME_PORT`. The game runnable also
receives `ANTHROPIC_API_KEY_URI = secret://coworld/paintball/anthropic_api_key`.

## What a seat sends

Exactly two things, both Sprite v1 binary frames:

1. **One chat message (`0x81`)** carrying its registration:

   ```json
   {"type":"register","prompt":"<strategy text or empty>",
    "scripted":"holdline"|"sprayer"|null,"policy":"<free label>"}
   ```

   The server consumes it as registration: it is never applied as a shout and
   never written to the replay chat stream. What the replay gets instead is a
   redacted `register` record — the policy label and kind only, never the
   prompt. Any other chat text from a seat is dropped: cogs shout, seats do
   not. Registration may be re-sent; the last one wins.

2. **The Ready packet (`0x85`)** after each received frame. This is legitimate
   here in a way it is not for an ordinary player client: a paintball seat
   sends **no inputs at all** (the server computes every actuator mask), so the
   dead-reckoning hazard the ready packet normally carries cannot arise, and a
   `fastMode` server can advance the tick as soon as both seats acknowledge.

A seat that sends nothing is `holdline`. A seat that disconnects keeps playing:
its squad's directive source degrades to `holdline` and it revives on
reconnect. Its cogs are never removed from the board.

## What a seat sees

One binary Sprite v1 message per tick, fogged to the **seat** — the union of
the vision of the cogs that seat commands **under the current regime**. A
`resident` seat sees through all four of its cogs; a `visitor` seat sees only
through `alpha`, which is what makes the visitor half a genuinely narrower
view.

**Visible**

- The static map (terrain is always visible in this engine), the walkability
  sprite and the live rotating diamonds.
- The **hill**, as a stated marker refreshed each tick, plus its owner and both
  coverage percentages. Hill ownership is the scoreboard and is **always
  visible to both seats**.
- The seat's own cogs: position, aim, hp bar, lives, spray readiness and what
  each is standing on.
- Floor paint **inside the seat's fog** — paint your cogs can see is intel;
  paint across the map is not.
- Enemy cogs and their identity badges **only** inside the commanded cogs'
  vision cones (±60° around each aim, out to 1.5× the gun range; stone blocks,
  glass does not) or their ~90 px bubbles. The LLM view additionally carries
  enemies seen within the last 72 ticks with `ticks_ago`.
- Shouts within 247 px of a commanded cog, labelled with the shouter's
  **anonymous** identity, from either team.
- The clock, the game index, the regime, the turn index and both banked hill
  clocks.

**Hidden**

The other seat's directive, prompt, note and view; the identity of any policy;
enemy cogs outside vision and older than 72 ticks; floor paint outside the
seat's fog; the episode seed; future ticks; and — in a `visitor` game —
anything the three scripted teammates know but have not shown by where they are
standing.

## The replay

The starter's binary `COWLDPNT` format: magic, format version, game
name/version, the resolved config JSON (seed, `mapSpec`, roster, every tuning
field), then the record stream — joins, leaves, per-**cog** input-mask changes,
chat records and **one `gameHash` per tick**.

The chat stream carries two kinds of thing, told apart by a leading `{`:

| First byte | Meaning |
|---|---|
| `{` | a paintball CONTROL record (`register`, `directive`, `fallback`, `budget_guard`, `result`) — re-applied at playback into non-hashed fields only, so it can never affect the simulation |
| anything else | a cog's real in-game **shout** — hashed state both sides hear, re-applied identically |

`tools/replay_summary.py` (Python 3 stdlib only) turns a `.replay` into one
strict-UTF-8 JSON object on stdout:

```bash
python3 tools/replay_summary.py episode.replay | jq .
```

## Results

Written to `COGAME_RESULTS_URI`; it must equal the manifest's
`results_schema` key for key. The **same document** is embedded once in the
replay chat stream at episode end as the `result` control record
(`{"k":"result","results":{…}}`), so the bytes are self-sufficient:
`tools/replay_summary.py` reports it as `.results` for anyone holding only the
replay.

```json
{"names": ["daveey", "daveey-1"], "scores": [0.604, 0.396],
 "win": [true, false], "team": ["red", "blue"],
 "residentScore": [0.708, 0.292], "visitorScore": [0.5, 0.5],
 "hillTicks": [1103, 806], "residentHillTicks": [742, 442],
 "visitorHillTicks": [361, 364], "paintTiles": [214, 186],
 "tagsDealt": [17, 14], "tagsTaken": [14, 17],
 "llmTurns": [40, 40], "fallbackTurns": [0, 1],
 "reason": "complete", "endRule": "full_time",
 "games": 2, "finalTick": 4320, "seed": 679961}
```

`names` are the real policy names (spectator side); `team` carries the in-game
aliases. Every array has exactly `num_agents` = 2 entries.
