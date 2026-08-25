## The paint grid: what is paintable, what a cone flips, and that the
## incremental counters never drift from a full rescan.
import std/[random, unittest]
import helpers

suite "paint grid":
  var sim = newPaintballSim()

  test "paintFloor marks exactly the tiles whose centre is walkable":
    check sim.paintGridW == (MapWidth + PaintTile - 1) div PaintTile
    check sim.paintGridH == (MapHeight + PaintTile - 1) div PaintTile
    check sim.paintOwner.len == sim.paintGridW * sim.paintGridH
    var floorTiles = 0
    for tile in 0 ..< sim.paintFloor.len:
      let (cx, cy) = sim.paintTileCentre(tile)
      if cx >= MapWidth or cy >= MapHeight:
        continue
      check sim.paintFloor[tile] == (not sim.wallMask[mapIndex(cx, cy)])
      if sim.paintFloor[tile]:
        inc floorTiles
    # A 1235x659 arena is mostly open floor; a grid that marked almost nothing
    # paintable would silently make the hill unwinnable.
    check floorTiles > sim.paintFloor.len div 2

  test "a cone fired due east paints ahead and never behind":
    ## Search for a spot whose cone reaches open floor rather than pinning one:
    ## the arena's spinning diamonds sit near the centre, and which exact pixel
    ## has 170px of clear ground east of it is map geometry, not a rule.
    var probe = newPaintballSim()
    let cog = 0
    var px, py, tiles = 0
    for y in countup(MapHeight div 4, 3 * MapHeight div 4, 17):
      probe = newPaintballSim()
      probe.placePlayer(cog, MapWidth div 3, y)
      probe.players[cog].aimBrads = 0            ## due east
      probe.players[cog].arcAimBrads = 0
      probe.players[cog].arcTicksLeft = SprayPaintActiveTicks
      let painted = probe.paintConeTiles(cog)
      if painted.tiles > 0:
        px = probe.players[cog].x + CollisionW div 2
        py = probe.players[cog].y + CollisionH div 2
        tiles = painted.tiles
        break
    check tiles > 0
    check py > 0
    for tile in 0 ..< probe.paintOwner.len:
      if probe.paintOwner[tile] == 0:
        continue
      let (cx, _) = probe.paintTileCentre(tile)
      check cx > px                            ## strictly downrange
      check cx - px <= SprayPaintReach + PaintTile

  test "a repaint moves one tile from each count and leaves the total constant":
    var probe = newPaintballSim()
    let tile = probe.paintTileAt(MapWidth div 2, MapHeight div 2)
    check tile >= 0
    check probe.paintTile(tile, Red)
    let total = probe.paintCount[Red] + probe.paintCount[Blue]
    check probe.paintCount[Red] == 1
    check probe.paintTile(tile, Blue)
    check probe.paintCount[Red] == 0
    check probe.paintCount[Blue] == 1
    check probe.paintCount[Red] + probe.paintCount[Blue] == total
    ## Repainting a tile that is already ours is a no-op, not a double count.
    check not probe.paintTile(tile, Blue)
    check probe.paintCount[Blue] == 1

  test "the incremental counters equal a full rescan after 500 random bursts":
    var probe = newPaintballSim()
    var rng = initRand(20260825)
    for burst in 0 ..< 500:
      let cog = rng.rand(probe.players.high)
      probe.placePlayer(cog, 60 + rng.rand(MapWidth - 120),
                        60 + rng.rand(MapHeight - 120))
      probe.players[cog].arcAimBrads = rng.rand(AimBradsTurn - 1)
      probe.players[cog].arcTicksLeft = SprayPaintActiveTicks
      discard probe.paintConeTiles(cog)
    let scan = probe.rescanPaint()
    check probe.paintCount[Red] == scan.red
    check probe.paintCount[Blue] == scan.blue
    check probe.hillPaint[Red] == scan.hillRed
    check probe.hillPaint[Blue] == scan.hillBlue
    check scan.red + scan.blue > 0

  test "the cone predicate is exactly mirror-symmetric":
    ## Team fairness lives in the PREDICATE, not in the tile counts: the 34px
    ## grid does not divide 1235 evenly, so the grid itself is not mirror-
    ## aligned and comparing painted-tile counts across the midline would be
    ## testing quantisation. What must hold exactly is that spraying east from
    ## the origin covers a point iff spraying west covers its x-mirror — the
    ## integer fixed-point aim table has to be symmetric to the bit.
    for dx in countup(-400, 400, 7):
      for dy in countup(-200, 200, 7):
        check tileInCone(0, 0, 0, SprayPaintReach, SprayPaintMaxWidth, dx, dy) ==
          tileInCone(0, 0, AimBradsTurn div 2, SprayPaintReach,
                     SprayPaintMaxWidth, -dx, dy)
        ## And the same for the vertical axis: north vs south.
        check tileInCone(0, 0, AimBradsTurn div 4, SprayPaintReach,
                         SprayPaintMaxWidth, dx, dy) ==
          tileInCone(0, 0, 3 * AimBradsTurn div 4, SprayPaintReach,
                     SprayPaintMaxWidth, dx, -dy)

  test "the cone reaches forward and nothing behind the sprayer":
    check tileInCone(0, 0, 0, SprayPaintReach, SprayPaintMaxWidth, 40, 0)
    check not tileInCone(0, 0, 0, SprayPaintReach, SprayPaintMaxWidth, -40, 0)
    check not tileInCone(0, 0, 0, SprayPaintReach, SprayPaintMaxWidth,
                         SprayPaintReach + 20, 0)
    ## It widens with distance: a lateral offset legal far out is illegal close in.
    check tileInCone(0, 0, 0, SprayPaintReach, SprayPaintMaxWidth, 160, 30)
    check not tileInCone(0, 0, 0, SprayPaintReach, SprayPaintMaxWidth, 20, 30)
