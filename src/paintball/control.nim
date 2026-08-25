## The control layer: the ONE deterministic function that turns a directive
## into per-tick Sprite v1 actuator masks.
##
## Both LLM directives and scripted directives are compiled by this same code,
## so the two policy kinds are strictly comparable and a scripted baseline is
## legal by construction. It is a pure function of
## `(sim state, directive, cogIndex) -> uint8`.
##
## It sits OUTSIDE the determinism boundary: the server records the masks this
## produces into the replay, and the wasm viewer feeds those recorded masks to
## the identical sim. Nothing here is re-run at playback, which is why this
## module may use ordinary floating-point navigation maths where the hashed
## paint grid may not.

import
  std/[math, tables],
  bitworld/spriteprotocol,
  sim, directives

const
  NavCell* = 12               ## nav grid cell side, in px.
                              ## Sized to the ARENA, not to the paint grid: the
                              ## arena's corridors are ~26 px wide for a 13 px
                              ## footprint, so a cell the size of a paint tile
                              ## (34 px) has no open cell anywhere inside a gap
                              ## between two obstacles and the flow field
                              ## reports the whole far side of every obstacle
                              ## column UNREACHABLE. Measured on that grid, a
                              ## sweeping squad fell back to the straight line,
                              ## walked into the first wall and pressed the same
                              ## d-pad direction for two thousand ticks. At
                              ## 12 px every 26 px corridor contains a cell
                              ## centre with the full footprint's clearance.
  FieldRefreshTicks* = 12     ## a flow field is recomputed at most this often.
  MaxCachedFields* = 64       ## flow fields kept before the cache is dropped.
                              ## A field is one int per cell, so an unbounded
                              ## cache on a fine grid is an unbounded leak over
                              ## a long episode; eight cogs never need more.
  ArriveRadius* = 20          ## px: a cog this close to its goal stops moving.
  AimMinRangeSq* = 16 * 16    ## an aim target nearer than this gives a vector
                              ## too short to mean a direction.
  AimDeadBrads* = 4           ## no turn button inside this error.
  FireAimBrads* = 24          ## widest aim error that still pulls the trigger.
  HuntMemoryTicks* = 72       ## how long a seen enemy stays "known".
  HuntRangePx* = 300          ## aim priority radius for a known enemy.
  StuckTicks* = 8             ## ticks of zero displacement after which a cog
                              ## steers along the obstacle instead of into it.
                              ## The flow field is built once, over the wall
                              ## mask alone: it cannot know about the spinning
                              ## diamonds' later frames, and it cannot know
                              ## about the other seven COGS at all — four cogs
                              ## sharing one goal in a 26 px corridor jam each
                              ## other. Degrade-never-hang applies to a cog as
                              ## much as to a network call.
  PaintProbeSteps* = [34, 68, 102, 136, 170]
                              ## px along the aim the trigger samples for floor
                              ## worth painting: one probe at a single distance
                              ## misses both the tile under the cog's nose and
                              ## the far end of the cone's reach.

type
  NavGrid* = object
    w*, h*: int
    open*: seq[bool]

  ControlState* = object
    ## Everything the control layer remembers between ticks. Lives on the
    ## SERVER, never on the sim, so it can never enter gameHash.
    grid*: NavGrid
    fields*: Table[int, seq[int]]      ## goal cell -> BFS distance field
    fieldTick*: Table[int, int]        ## goal cell -> tick it was built
    lastSeenX*, lastSeenY*: seq[int]   ## per cog: last known enemy position
    lastSeenTick*: seq[int]
    lastSeenIndex*: seq[int]
    lastX*, lastY*: seq[int]           ## per cog: position at the last observe
    stuckTicks*: seq[int]              ## per cog: consecutive motionless ticks

proc navCellOf*(grid: NavGrid, x, y: int): int =
  ## The flat nav cell containing a map pixel, or -1 off the grid.
  let
    cx = x div NavCell
    cy = y div NavCell
  if x < 0 or y < 0 or cx >= grid.w or cy >= grid.h:
    return -1
  cy * grid.w + cx

proc navCentre*(grid: NavGrid, cell: int): tuple[x, y: int] =
  ((cell mod grid.w) * NavCell + NavCell div 2,
   (cell div grid.w) * NavCell + NavCell div 2)

proc buildNavGrid*(sim: SimServer): NavGrid =
  ## A NavCell-px occupancy grid over the sim's REAL wall mask (not an
  ## observation stream): a cell is open when a cog footprint fits at its
  ## centre. Built once per episode, against the mask as it stands at build
  ## time — a spinning diamond that later rotates into a cell this grid calls
  ## open is handled by the stuck deflection in `compileMask`, not by rebuilding
  ## a five-thousand-cell grid every tick.
  result.w = (MapWidth + NavCell - 1) div NavCell
  result.h = (MapHeight + NavCell - 1) div NavCell
  result.open = newSeq[bool](result.w * result.h)
  for cell in 0 ..< result.open.len:
    let (cx, cy) = result.navCentre(cell)
    if cx < MapWidth and cy < MapHeight:
      result.open[cell] = sim.canOccupy(cx, cy)

proc nearestOpenCell*(grid: NavGrid, x, y: int): int =
  ## The open cell nearest a map point, by expanding ring search. -1 only
  ## when the grid has no open cell at all.
  let start = grid.navCellOf(clamp(x, 0, MapWidth - 1), clamp(y, 0, MapHeight - 1))
  if start >= 0 and grid.open[start]:
    return start
  let
    sx = clamp(x, 0, MapWidth - 1) div NavCell
    sy = clamp(y, 0, MapHeight - 1) div NavCell
  for r in 1 .. (grid.w + grid.h):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          cx = sx + dx
          cy = sy + dy
        if cx < 0 or cy < 0 or cx >= grid.w or cy >= grid.h:
          continue
        let cell = cy * grid.w + cx
        if grid.open[cell]:
          return cell
  -1

proc computeField*(grid: NavGrid, goal: int): seq[int] =
  ## Breadth-first flow field to `goal` over 4-connected open cells: the
  ## number of steps from every cell to the goal, -1 where unreachable.
  result = newSeq[int](grid.open.len)
  for i in 0 ..< result.len:
    result[i] = -1
  if goal < 0 or goal >= result.len or not grid.open[goal]:
    return
  var
    queue = @[goal]
    head = 0
  result[goal] = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod grid.w
      cy = cell div grid.w
      d = result[cell]
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= grid.w or ny >= grid.h:
        continue
      let next = ny * grid.w + nx
      if not grid.open[next] or result[next] >= 0:
        continue
      result[next] = d + 1
      queue.add(next)

proc fieldFor*(ctl: var ControlState, tick, goal: int): seq[int] =
  ## The cached flow field for one goal cell, rebuilt at most once every
  ## FieldRefreshTicks. Cheap enough that eight cogs chasing eight distinct
  ## goals still costs a handful of BFS passes per second.
  if goal < 0:
    return @[]
  if ctl.fields.hasKey(goal) and
      tick - ctl.fieldTick.getOrDefault(goal, low(int) div 2) < FieldRefreshTicks:
    return ctl.fields[goal]
  if ctl.fields.len >= MaxCachedFields and not ctl.fields.hasKey(goal):
    ctl.fields.clear()
    ctl.fieldTick.clear()
  let field = computeField(ctl.grid, goal)
  ctl.fields[goal] = field
  ctl.fieldTick[goal] = tick
  field

proc navSteer*(
  ctl: var ControlState, tick, fromX, fromY, goalX, goalY: int
): tuple[dx, dy: int] =
  ## The steering vector for one cog: straight at the goal when the line of
  ## sight is clear (so a cog does not stair-step around an open floor), else
  ## down the flow field toward the neighbouring cell nearest the goal.
  let goalCell = ctl.grid.nearestOpenCell(goalX, goalY)
  if goalCell < 0:
    return (0, 0)
  let (gx, gy) = ctl.grid.navCentre(goalCell)
  let field = ctl.fieldFor(tick, goalCell)
  let here = ctl.grid.nearestOpenCell(fromX, fromY)
  if here < 0 or field.len == 0 or field[here] <= 1:
    return (gx - fromX, gy - fromY)
  let
    cx = here mod ctl.grid.w
    cy = here div ctl.grid.w
  var
    best = field[here]
    bestCell = -1
  for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= ctl.grid.w or ny >= ctl.grid.h:
      continue
    let next = ny * ctl.grid.w + nx
    if not ctl.grid.open[next] or field[next] < 0:
      continue
    if dx != 0 and dy != 0:
      # No corner cutting: a diagonal is only taken when both of the cells it
      # squeezes between are open. A cell is barely wider than a cog, so
      # clipping the corner of an obstacle wedges the cog against it and it
      # presses the same direction forever.
      if not ctl.grid.open[cy * ctl.grid.w + nx] or
          not ctl.grid.open[ny * ctl.grid.w + cx]:
        continue
    if field[next] < best:
      best = field[next]
      bestCell = next
  if bestCell < 0:
    return (gx - fromX, gy - fromY)
  let (nxp, nyp) = ctl.grid.navCentre(bestCell)
  (nxp - fromX, nyp - fromY)

proc bradsErr*(desired, current: int): int =
  ## Signed shortest turn from `current` to `desired`, in brads: positive is
  ## counter-clockwise (button B), negative clockwise (button Select).
  var d = (desired - current) mod AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  d

proc initControlState*(sim: SimServer): ControlState =
  result.grid = buildNavGrid(sim)
  result.fields = initTable[int, seq[int]]()
  result.fieldTick = initTable[int, int]()
  result.lastSeenX = newSeq[int](MaxPlayers)
  result.lastSeenY = newSeq[int](MaxPlayers)
  result.lastSeenTick = newSeq[int](MaxPlayers)
  result.lastSeenIndex = newSeq[int](MaxPlayers)
  result.lastX = newSeq[int](MaxPlayers)
  result.lastY = newSeq[int](MaxPlayers)
  result.stuckTicks = newSeq[int](MaxPlayers)
  for i in 0 ..< MaxPlayers:
    result.lastSeenTick[i] = low(int) div 2
    result.lastSeenIndex[i] = -1
    result.lastX[i] = low(int) div 2
    result.lastY[i] = low(int) div 2

proc observeEnemies*(ctl: var ControlState, sim: SimServer) =
  ## The control layer's ONCE-PER-TICK observation: each cog's memory of the
  ## nearest enemy it can currently see, and whether it is making progress.
  ## Vision is the sim's own fog rule, so the control layer never knows more
  ## than the cog does.
  ##
  ## Both are updated here rather than in `compileMask` so that compiling a
  ## mask stays a pure read of this state: the same (state, directive) pair
  ## yields the same byte however many times it is asked.
  while ctl.lastSeenX.len < sim.players.len:
    ctl.lastSeenX.add(0)
    ctl.lastSeenY.add(0)
    ctl.lastSeenTick.add(low(int) div 2)
    ctl.lastSeenIndex.add(-1)
  while ctl.lastX.len < sim.players.len:
    ctl.lastX.add(low(int) div 2)
    ctl.lastY.add(low(int) div 2)
    ctl.stuckTicks.add(0)
  for i in 0 ..< sim.players.len:
    if sim.players[i].x == ctl.lastX[i] and sim.players[i].y == ctl.lastY[i]:
      inc ctl.stuckTicks[i]
    else:
      ctl.stuckTicks[i] = 0
    ctl.lastX[i] = sim.players[i].x
    ctl.lastY[i] = sim.players[i].y
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    var
      bestDist = high(int)
      bestIndex = -1
    for j in 0 ..< sim.players.len:
      if j == i or not sim.players[j].alive:
        continue
      if sim.players[j].team == sim.players[i].team:
        continue
      if not sim.playerVisibleTo(i, j):
        continue
      let d = distSq(sim.players[i].x, sim.players[i].y,
                     sim.players[j].x, sim.players[j].y)
      if d < bestDist:
        bestDist = d
        bestIndex = j
    if bestIndex >= 0:
      ctl.lastSeenX[i] = sim.players[bestIndex].x
      ctl.lastSeenY[i] = sim.players[bestIndex].y
      ctl.lastSeenTick[i] = sim.tickCount
      ctl.lastSeenIndex[i] = bestIndex

proc knownEnemy*(
  ctl: ControlState, sim: SimServer, cogIndex: int
): tuple[known: bool, x, y, index, ticksAgo: int] =
  ## The nearest enemy this cog knows about — seen now, or seen within
  ## HuntMemoryTicks. That memory is intel a commander legitimately has.
  if cogIndex >= ctl.lastSeenTick.len:
    return (false, 0, 0, -1, 0)
  let age = sim.tickCount - ctl.lastSeenTick[cogIndex]
  if age > HuntMemoryTicks or ctl.lastSeenIndex[cogIndex] < 0:
    return (false, 0, 0, -1, 0)
  (true, ctl.lastSeenX[cogIndex], ctl.lastSeenY[cogIndex],
   ctl.lastSeenIndex[cogIndex], age)

proc hillCentre*(sim: SimServer): tuple[x, y: int] =
  (MapWidth div 2, MapHeight div 2)

proc nearestHillTile*(
  sim: SimServer, x, y: int, wantOwner: int, team: Team
): tuple[found: bool, x, y: int] =
  ## The hill tile centre nearest (x, y) whose owner matches `wantOwner`:
  ##  0 = "not this team's" (a tile worth painting),
  ##  1 = "this team's"     (a tile worth standing on).
  result = (false, 0, 0)
  var best = high(int)
  for tile in sim.hillTiles:
    if not sim.paintFloor[tile]:
      continue
    let
      mine = sim.paintOwner[tile] == paintTeamCode(team)
      wanted = if wantOwner == 1: mine else: not mine
    if not wanted:
      continue
    let (cx, cy) = sim.paintTileCentre(tile)
    let d = distSq(x, y, cx, cy)
    if d < best:
      best = d
      result = (true, cx, cy)

proc farthestHillTile*(
  sim: SimServer, x, y: int, team: Team
): tuple[found: bool, x, y: int] =
  ## The hill floor tile FURTHEST from (x, y) that is not this team's colour.
  ##
  ## This is what `paint_hill` walks toward, and the reason is mechanical: the
  ## cone starts AT the cog and reaches forward, so a cog can never paint the
  ## tile it is standing on. Sending it to the NEAREST unpainted tile therefore
  ## parks it on that tile forever — measured, four cogs converged on the
  ## western rim and the squad plateaued at 13 of 21 tiles. Sending it to the
  ## far side instead makes it a paint roller: it crosses the hill, its cone
  ## covers the ground ahead of it, and when it arrives the far side is
  ## whatever it has not covered yet, so it sweeps back.
  result = (false, 0, 0)
  var best = -1
  for tile in sim.hillTiles:
    if not sim.paintFloor[tile]:
      continue
    if sim.paintOwner[tile] == paintTeamCode(team):
      continue
    let (cx, cy) = sim.paintTileCentre(tile)
    let d = distSq(x, y, cx, cy)
    if d > best:
      best = d
      result = (true, cx, cy)

proc goalFor*(
  ctl: ControlState, sim: SimServer, order: CogOrder, cogIndex: int
): tuple[x, y: int] =
  ## The goal point one intent resolves to for one cog. Every branch has a
  ## defined answer, so a cog is never left without somewhere to be.
  let
    player = sim.players[cogIndex]
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    hill = hillCentre(sim)
  case order.intent
  of intPaintHill:
    let tile = farthestHillTile(sim, px, py, player.team)
    if tile.found: (tile.x, tile.y) else: (hill.x, hill.y)
  of intHoldHill:
    let tile = nearestHillTile(sim, px, py, 1, player.team)
    if tile.found: (tile.x, tile.y) else: (hill.x, hill.y)
  of intHunt:
    let enemy = ctl.knownEnemy(sim, cogIndex)
    if enemy.known:
      (enemy.x, enemy.y)
    else:
      let tile = nearestHillTile(sim, px, py, 0, player.team)
      if tile.found: (tile.x, tile.y) else: (hill.x, hill.y)
  of intGuard:
    (order.targetX, order.targetY)
  of intPaintPath:
    # The nearest point on the straight line to the target whose tile is not
    # ours yet: paint the lane you are about to run down.
    var
      bx = order.targetX
      by = order.targetY
      found = false
    let steps = 24
    for step in 1 .. steps:
      let
        lx = px + (order.targetX - px) * step div steps
        ly = py + (order.targetY - py) * step div steps
        tile = sim.paintTileAt(lx, ly)
      if tile < 0 or not sim.paintFloor[tile]:
        continue
      if sim.paintOwner[tile] != paintTeamCode(player.team):
        bx = lx
        by = ly
        found = true
        break
    if found: (bx, by) else: (order.targetX, order.targetY)
  of intFallBack:
    let zone = sim.captureZone(player.team)
    (clamp(order.targetX, zone.xLo, zone.xHi),
     clamp(order.targetY, zone.yLo, zone.yHi))

proc paintsAhead(order: CogOrder): bool {.inline.} =
  order.intent in {intPaintHill, intPaintPath, intHoldHill}

proc compileMask*(
  ctl: var ControlState,
  sim: SimServer,
  order: CogOrder,
  cogIndex: int
): uint8 =
  ## One cog's Sprite v1 actuator mask for this tick.
  ##
  ## Legality is structural, not checked afterwards: Up and Down are chosen
  ## from one sign so they can never both be set (same for Left/Right), B and
  ## Select come from one signed error, and C — the grenade/barrier button —
  ## is never touched, because the paintball loadout places neither.
  result = 0
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let player = sim.players[cogIndex]
  if not player.alive:
    return
  let
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    goal = ctl.goalFor(sim, order, cogIndex)

  # --- d-pad: the octant of the steering vector, unless we have arrived ---
  # A painting cog WALKS ONTO its target and keeps going: the cone starts at
  # the cog and reaches forward, so ground is painted while it is still ahead
  # and a squad sweeping across the hill covers it. Holding a cog a cone-length
  # short of its target instead was tried and measured WORSE — it stopped
  # moving as soon as everything in front of it was already its colour, and a
  # squad with no opposition covered nothing at all.
  if distSq(px, py, goal.x, goal.y) > ArriveRadius * ArriveRadius:
    var steer = ctl.navSteer(sim.tickCount, px, py, goal.x, goal.y)
    if cogIndex < ctl.stuckTicks.len and ctl.stuckTicks[cogIndex] >= StuckTicks:
      # Wedged: steer a quarter turn clockwise instead, which slides the cog
      # ALONG whatever it is pressed against — another cog, a diamond that has
      # rotated into the lane, a wall the once-built field could not see. One
      # consistent rotation makes this a wall follower, so a convex obstacle is
      # always escaped rather than oscillated against.
      steer = (dx: -steer.dy, dy: steer.dx)
    let
      ax = abs(steer.dx)
      ay = abs(steer.dy)
      major = max(ax, ay)
    if major > 0:
      # Diagonals only when the minor axis is a real share of the major one,
      # so a nearly-straight run does not chatter between two octants.
      if ax * 5 >= major * 2:
        result = result or (if steer.dx > 0: ButtonRight else: ButtonLeft)
      if ay * 5 >= major * 2:
        result = result or (if steer.dy > 0: ButtonDown else: ButtonUp)

  # --- aim: nearest known enemy in range, else the face hint, else the goal ---
  let enemy = ctl.knownEnemy(sim, cogIndex)
  var
    aimX = goal.x
    aimY = goal.y
  if enemy.known and enemy.ticksAgo == 0 and
      distSq(px, py, enemy.x, enemy.y) <= HuntRangePx * HuntRangePx:
    aimX = enemy.x
    aimY = enemy.y
  elif order.hasFace:
    aimX = order.faceX
    aimY = order.faceY
  elif order.paintsAhead():
    ## Point the can at something worth painting. Two degenerate cases matter:
    ## a cog STANDING ON its goal has an aim vector of length ~0 (which reads
    ## as due east), and a hill intent whose target is already our colour has
    ## nothing to spray. Both are fixed by aiming at the nearest hill tile that
    ## is NOT ours — which is also what makes `hold_hill` keep the rim painted
    ## instead of guarding one tile and firing at nothing.
    var aimed = false
    if order.intent == intHoldHill:
      let tile = nearestHillTile(sim, px, py, 0, player.team)
      if tile.found and distSq(px, py, tile.x, tile.y) > AimMinRangeSq:
        aimX = tile.x
        aimY = tile.y
        aimed = true
    if not aimed and distSq(px, py, goal.x, goal.y) <= AimMinRangeSq:
      let hill = hillCentre(sim)
      aimX = hill.x
      aimY = hill.y
  else:
    let hill = hillCentre(sim)
    aimX = hill.x
    aimY = hill.y
  let
    desired = bradsOfVector(aimX - px, aimY - py)
    err = bradsErr(desired, player.aimBrads)
  if err > AimDeadBrads:
    result = result or ButtonB          ## counter-clockwise
  elif err < -AimDeadBrads:
    result = result or ButtonSelect     ## clockwise

  # --- trigger ---
  if order.intent == intFallBack:
    return
  if player.fireCooldown > 0 or player.arcTicksLeft > 0 or
      not player.hasSprayPaint:
    return
  if abs(err) > FireAimBrads:
    return
  var worthIt = false
  if enemy.known and enemy.ticksAgo == 0:
    let d2 = distSq(px, py, enemy.x, enemy.y)
    if d2 <= SprayPaintReach * SprayPaintReach and
        sim.paintPathClear(px, py, enemy.x, enemy.y):
      worthIt = true
  if not worthIt and order.paintsAhead() and sim.config.floorPaint:
    let (ux, uy) = aimVector(player.aimBrads)
    for ahead in PaintProbeSteps:
      let
        probeX = px + int(ux * float(ahead))
        probeY = py + int(uy * float(ahead))
        tile = sim.paintTileAt(probeX, probeY)
      if tile >= 0 and sim.paintFloor[tile] and
          sim.paintOwner[tile] != paintTeamCode(player.team) and
          sim.paintPathClear(px, py, probeX, probeY):
        worthIt = true
        break
  if worthIt:
    result = result or ButtonA
