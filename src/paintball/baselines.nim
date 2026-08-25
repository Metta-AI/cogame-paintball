## The two published scripted baselines.
##
## Both emit the SAME directive object an LLM does, on the same 4.5 s cadence,
## so their output is legal by construction and directly comparable. Both are
## pure functions of the world state, which is what makes the bounded-orders
## test in tests/test_control.nim meaningful.
##
## `holdline` is load-bearing in four places: it is the certification player,
## the per-turn fallback when a seat's LLM call fails twice, the driver of
## every scripted teammate in a `visitor` game, and the default for a seat
## that registers with neither PLAYER_PROMPT nor PLAYER_SCRIPTED. It is
## documented in docs/RULES.md precisely so "ad-hoc teamwork" here means
## "adapt to a partner whose rules you know but do not control" — the Melting
## Pot construction — rather than "guess a mystery partner".

import
  std/[math, strutils],
  sim, control, directives

type
  Baseline* = enum
    blHoldline = "holdline"
    blSprayer = "sprayer"

const HuntRadiusHoldline = 200   ## px: switch a governed cog to `hunt`.
const HuntRadiusSprayer = 120    ## px: the weaker baseline commits later.
const GuardStandoff = 250        ## px off the hill, on the team's own side.

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `holdline`: a seat that
  ## says nothing useful still plays the published default rather than
  ## sitting out.
  case text.strip().toLowerAscii()
  of "sprayer", "spray": blSprayer
  else: blHoldline

proc guardPoint(sim: SimServer, team: Team): tuple[x, y: int] =
  ## A point GuardStandoff px off the hill on this team's own side of the
  ## map — "a flank has to go through somebody".
  let
    hill = hillCentre(sim)
    anchor = sim.gameMap.teamAnchor(team)
  var
    dx = anchor.x - hill.x
    dy = anchor.y - hill.y
  let span = max(1, abs(dx) + abs(dy))
  (clamp(hill.x + dx * GuardStandoff div span, 0, MapWidth - 1),
   clamp(hill.y + dy * GuardStandoff div span, 0, MapHeight - 1))

proc farthestNonOwnHillTiles(
  sim: SimServer, team: Team
): seq[tuple[x, y: int]] =
  ## The two hill floor tiles NOT this team's colour that are furthest apart
  ## — simultaneous edges is how 80% breaks. Falls back to the hill centre
  ## when the hill is already entirely ours.
  var tiles: seq[tuple[x, y: int]]
  for tile in sim.hillTiles:
    if not sim.paintFloor[tile]:
      continue
    if sim.paintOwner[tile] == paintTeamCode(team):
      continue
    tiles.add(sim.paintTileCentre(tile))
  let hill = hillCentre(sim)
  if tiles.len == 0:
    return @[(hill.x, hill.y), (hill.x, hill.y)]
  if tiles.len == 1:
    return @[tiles[0], tiles[0]]
  var
    bestA = 0
    bestB = 1
    best = -1
  for i in 0 ..< tiles.len:
    for j in i + 1 ..< tiles.len:
      let d = distSq(tiles[i].x, tiles[i].y, tiles[j].x, tiles[j].y)
      if d > best:
        best = d
        bestA = i
        bestB = j
  @[tiles[bestA], tiles[bestB]]

proc baseOrder(sim: SimServer, cogIndex: int, id: string): CogOrder =
  let hill = hillCentre(sim)
  CogOrder(
    cogIndex: cogIndex,
    id: id,
    intent: intPaintHill,
    targetX: hill.x,
    targetY: hill.y
  )

proc scriptedDirective*(
  ctl: ControlState,
  sim: SimServer,
  kind: Baseline,
  governed: seq[int]
): SquadDirective =
  ## The directive one baseline issues for the cogs it governs this turn.
  ##
  ## `holdline` — of the cogs it governs: the one nearest the hill centre
  ## holds it, the next two paint the two non-own hill tiles furthest from
  ## each other, and the furthest guards a standoff point on the team's own
  ## side. Any governed cog with a known enemy inside HuntRadiusHoldline
  ## switches to `hunt`.
  ##
  ## `sprayer` — deliberately weaker and different in SHAPE, so the ladder
  ## gets a spread rather than two versions of one bot: every governed cog
  ## paints the nearest non-own hill tile, nobody guards, and `hunt` fires
  ## only at point-blank range.
  result.source = dsScripted
  result.note =
    if kind == blSprayer: "spray the hill" else: "hold the hill"
  if governed.len == 0:
    return
  let hill = hillCentre(sim)
  var ranked = governed
  # Nearest the hill centre first: a stable, purely state-derived order, so
  # the same world always produces the same directive.
  for i in 1 ..< ranked.len:
    let key = ranked[i]
    var j = i - 1
    while j >= 0 and
        distSq(sim.players[ranked[j]].x, sim.players[ranked[j]].y, hill.x, hill.y) >
        distSq(sim.players[key].x, sim.players[key].y, hill.x, hill.y):
      ranked[j + 1] = ranked[j]
      dec j
    ranked[j + 1] = key

  let edges = farthestNonOwnHillTiles(sim, sim.players[ranked[0]].team)
  for rank, cogIndex in ranked:
    var order = baseOrder(sim, cogIndex, sim.cogAlias(cogIndex))
    if kind == blSprayer:
      let tile = nearestHillTile(
        sim, sim.players[cogIndex].x, sim.players[cogIndex].y, 0,
        sim.players[cogIndex].team)
      order.intent = intPaintHill
      if tile.found:
        order.targetX = tile.x
        order.targetY = tile.y
      order.say = "paint"
    else:
      case rank
      of 0:
        order.intent = intHoldHill
        order.targetX = hill.x
        order.targetY = hill.y
        order.say = "hold"
      of 1, 2:
        order.intent = intPaintHill
        let edge = edges[rank - 1]
        order.targetX = edge.x
        order.targetY = edge.y
        order.say = "paint"
      else:
        let guard = guardPoint(sim, sim.players[cogIndex].team)
        order.intent = intGuard
        order.targetX = guard.x
        order.targetY = guard.y
        order.hasFace = true
        order.faceX = hill.x
        order.faceY = hill.y
        order.say = "watch"
    let enemy = ctl.knownEnemy(sim, cogIndex)
    let radius =
      if kind == blSprayer: HuntRadiusSprayer else: HuntRadiusHoldline
    if enemy.known and
        distSq(sim.players[cogIndex].x, sim.players[cogIndex].y,
               enemy.x, enemy.y) <= radius * radius:
      order.intent = intHunt
      order.targetX = enemy.x
      order.targetY = enemy.y
      order.say = "on it"
    result.orders.add(order)
