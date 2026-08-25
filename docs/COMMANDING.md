# Writing a paintball prompt

A policy here is just a prompt. Your prompt is handed to Claude every 4.5
seconds under a "GUIDANCE FROM YOUR OPERATOR" heading, together with a fogged
report of what your squad can see, and the reply is your directive for the next
4.5 seconds.

You are not driving. A deterministic control layer walks each cog toward its
target around walls, turns it to face what you told it to face, and pulls the
trigger when the shot is worth taking. What you control is **intent and
geometry**: who goes where, who paints what, who holds.

## What the model is told (you do not need to repeat it)

The system prompt already states the board size, the hill rule, the 80 %
threshold, the paint buff, the three-touch tag-out, the fog, the reply schema
and every intent. Do not spend your prompt restating rules — spend it on a
**policy**.

## What you are choosing between

| Intent | What the controller does |
|---|---|
| `paint_hill` | walk to the nearest hill tile that is not yours and paint it |
| `hold_hill` | stay on the hill, keep it yours, spray anyone who steps on |
| `hunt` | close on the nearest enemy you know about and spray it |
| `guard` | hold `target` and watch the hill |
| `paint_path` | paint a lane from where you are toward `target` |
| `fall_back` | walk to `target` without spraying |

`face` biases the aim when nothing is in range. `say` is SHOUTED and the enemy
hears it if they are close.

## What actually decides games

- **80 % is a lot.** A single burst lays about eight tiles and the hill has
  about twenty-one floor tiles, so one cog alone cannot flip a defended hill.
  Simultaneous edges break 80 %; one cog grinding one edge does not.
- **Paint is speed.** A cog on its own colour is 25 % faster and heals; on the
  enemy's it is 15 % slower. A painted lane between your side and the hill is
  the difference between reinforcing and arriving late.
- **Time held is the whole score.** `gameScore` is the margin in banked hill
  ticks over 720 (30 seconds). Chasing a tag across the map costs more hill
  time than the tag is worth unless the enemy is already near the hill.
- **You play twice.** Game 1 you command all four cogs. Game 2 you command
  `alpha` only; `beta`, `gamma` and `delta` run the published `holdline`
  baseline (see docs/RULES.md) and you cannot instruct them. Write a prompt
  that says what `alpha` should do *around* three cogs that hold the centre,
  paint the far edges and keep one guard — not one that assumes four obedient
  cogs.
- **The report tells you `ticks_ago`.** An enemy seen 60 ticks ago is a guess,
  not a target.

## Shape of a good prompt

State a standing assignment for every cog, then the conditions that change it.
Be concrete about geometry — pixel targets, distances, which edge — because the
controller can act on those and cannot act on adjectives.

```
Own the hill and never give it back. Every turn, put at least two cogs on the
hill: the one already closest to the centre gets "hold_hill" at the hill
centre, and the next closest gets "paint_hill" at the hill tile nearest the
enemy side. Keep exactly one cog on "guard" about 250 pixels off the hill on
YOUR side, facing the hill. The last cog runs "paint_path" between the guard
point and the hill. Switch a cog to "hunt" only when the report shows an enemy
within about 250 pixels of the hill and seen this turn.
```

## Failure modes to avoid

- **Prose instead of JSON.** The system prompt demands a reply that begins with
  `{`; a prompt that asks for reasoning gets prose, the parse fails twice, and
  the seat plays `holdline` for that turn. `fallbackTurns` in the results tells
  you how often that happened.
- **Naming cogs that are not yours.** Use only the ids in
  `you.commanding`. Entries that name nothing get assigned by position, which
  is rarely what you meant.
- **Long notes.** `note` is capped at 160 runes and `say` at 10. Longer text is
  truncated, not rejected — but the tokens are wasted.
- **A plan that needs four cogs in game 2.** Half your score comes from the
  visitor half.

## Fielding it

```bash
coworld upload-policy coworld-paintball:latest \
  --name my-paintball --run /bin/paintball-player \
  --secret-env PLAYER_PROMPT="$(cat my-prompt.txt)"
```
