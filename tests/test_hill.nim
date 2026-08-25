## King of the Hill: the tile set, the 80% threshold, the banked clock and the
## three end rules.
import std/[json, math, unittest]
import paintball/broadcast
import helpers

proc fillHill(sim: var SimServer, team: Team, count: int) =
  var placed = 0
  for tile in sim.hillTiles:
    if placed >= count:
      break
    if not sim.paintFloor[tile]:
      continue
    if sim.paintTile(tile, team):
      inc placed

suite "king of the hill":
  test "the hill's floor set is big enough and symmetric about the midline":
    let sim = newPaintballSim()
    check sim.hillTiles.len == 25          ## the 5x5 block at the map centre
    check sim.hillFloorTiles >= 15
    ## Mirror symmetry: every hill floor tile's image across the vertical
    ## midline is also a hill floor tile, which is what makes 80% team-fair.
    for tile in sim.hillTiles:
      if not sim.paintFloor[tile]:
        continue
      let
        (cx, cy) = sim.paintTileCentre(tile)
        mirrored = sim.paintTileAt(MapWidth - 1 - cx, cy)
      check mirrored >= 0
      check sim.paintFloor[mirrored]

  test "ownership flips exactly at the 80% threshold and never for two teams":
    var sim = newPaintballSim()
    let
      need = int(ceil(0.8 * float(sim.hillFloorTiles)))
      justUnder = need - 1
    sim.fillHill(Red, justUnder)
    check not sim.hillOwnsFor(Red)
    check not sim.hillOwnsFor(Blue)
    sim.updateHill()
    check not sim.hillOwned
    sim.fillHill(Red, need)
    check sim.hillOwnsFor(Red)
    check not sim.hillOwnsFor(Blue)          ## 800 > 500: never both
    sim.updateHill()
    check sim.hillOwned
    check sim.hillOwner == Red

  test "hillTicks increments once per owned tick and not while unowned":
    var sim = newPaintballSim()
    sim.updateHill()
    check sim.hillTicks[Red] == 0
    for _ in 0 ..< 10:
      sim.updateHill()
    check sim.hillTicks[Red] == 0
    check sim.hillTicks[Blue] == 0
    sim.fillHill(Red, sim.hillFloorTiles)
    for _ in 0 ..< 10:
      sim.updateHill()
    check sim.hillTicks[Red] == 10
    check sim.hillTicks[Blue] == 0

  test "a wipe credits the survivor with every remaining tick":
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 600))
    ## Take BLUE off the board entirely: no cog alive, no lives left.
    for i in 0 ..< sim.players.len:
      if sim.players[i].team == Blue:
        sim.players[i].alive = false
        sim.players[i].lives = 0
    let remaining = sim.config.maxTicks - sim.gameTicksElapsed()
    sim.checkKothEnd()
    check sim.phase == GameOver
    check sim.endRule == EndRuleWipe
    check sim.winner == Red
    check sim.hillTicks[Red] == remaining

  test "mercy fires on the first tick the lead exceeds the remainder":
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 600))
    let remaining = sim.config.maxTicks - sim.gameTicksElapsed()
    sim.hillTicks[Red] = remaining
    sim.hillTicks[Blue] = 0
    sim.checkKothEnd()
    check sim.phase == Playing               ## equal, not greater: not yet
    sim.hillTicks[Red] = remaining + 1
    sim.checkKothEnd()
    check sim.phase == GameOver
    check sim.endRule == EndRuleMercy
    check sim.winner == Red

  test "equal hill ticks at the limit is a full-time draw":
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 1))
    sim.hillTicks[Red] = 5
    sim.hillTicks[Blue] = 5
    while sim.gameTicksElapsed() < sim.config.maxTicks:
      inc sim.tickCount
    sim.checkKothEnd()
    check sim.phase == GameOver
    check sim.endRule == EndRuleFullTime
    check sim.isDraw

  test "the hill box reported to a commander is the tile block itself":
    ## The seats' view JSON prints this box, and a commander aims at it: it has
    ## to be the pixels of the tiles that must be painted. Derived from the
    ## hill CENTRE it was half a tile out on every side.
    var sim = newPaintballSim()
    let
      box = sim.hillPixelBox()
      size = sim.paintTileSize()
    var
      x0 = MapWidth
      y0 = MapHeight
      x1 = 0
      y1 = 0
    for tile in sim.hillTiles:
      let centre = sim.paintTileCentre(tile)
      x0 = min(x0, centre.x - size div 2)
      y0 = min(y0, centre.y - size div 2)
      x1 = max(x1, centre.x + size div 2 - 1)
      y1 = max(y1, centre.y + size div 2 - 1)
    check box == [x0, y0, x1, y1]
    ## Every hill tile centre is inside the box, and the box is inside the map.
    for tile in sim.hillTiles:
      let centre = sim.paintTileCentre(tile)
      check centre.x >= box[0] and centre.x <= box[2]
      check centre.y >= box[1] and centre.y <= box[3]
    check box[0] >= 0 and box[1] >= 0
    check box[2] < MapWidth and box[3] < MapHeight
    ## And it is the 5x5 block the design note names, not a radius off centre.
    check box[2] - box[0] + 1 == 5 * size
    check box[3] - box[1] + 1 == 5 * size
    echo "hill box ", box, " for ", sim.hillTiles.len, " tiles of ", size, " px"

  test "the broadcast hillflip is throttled like the sim's own":
    ## Design §Mechanic 2: the flip event is "throttled to at most one per 12
    ## ticks so a contested rim cannot flood the feed". The SIM event was
    ## throttled; the derived broadcast event was not, and every one of those
    ## becomes a clickable scrubber beat — a rim oscillating on the 80%
    ## boundary would have produced one per tick.
    var sim = newPaintballSim()
    var tracker = initBroadcastTracker()
    var events = newJArray()
    sim.stepEvents(tracker, events)          ## first call only snapshots
    proc flips(sim: var SimServer, tracker: var BroadcastTracker): int =
      var node = newJArray()
      sim.stepEvents(tracker, node)
      for event in node:
        if event["k"].getStr() == "hillflip":
          inc result
    ## Paint the hill red, then hand it back and forth every tick.
    for tile in sim.hillTiles:
      discard sim.paintTile(tile, Red)
    sim.updateHill()
    check flips(sim, tracker) == 1           ## the first change IS announced
    var announced = 0
    for i in 0 ..< HillFlipThrottleTicks - 1:
      inc sim.tickCount
      for tile in sim.hillTiles:
        discard sim.paintTile(tile, if i mod 2 == 0: Blue else: Red)
      sim.updateHill()
      announced += flips(sim, tracker)
    check announced == 0                     ## nothing inside the window
    ## And the change is not LOST: the first tick past the window announces
    ## whatever the owner is by then.
    inc sim.tickCount
    for tile in sim.hillTiles:
      discard sim.paintTile(tile, Blue)
    sim.updateHill()
    check flips(sim, tracker) == 1
