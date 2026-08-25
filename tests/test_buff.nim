## The floor-paint buff: the exact integer speeds, the heal clock, and that a
## buff-off game is byte-identical in the hash to one with the gate off.
import std/unittest
import helpers

proc speedsFor(sim: SimServer, cogIndex: int): tuple[speed, accel: int] =
  let
    player = sim.players[cogIndex]
    paintPct = sim.paintSpeedPct(cogIndex)
    speedScale = if player.carryingFlag: sim.config.carrierSpeedPct else: 100
  (
    (sim.config.maxSpeedFor(player.team, player.perks) * speedScale div 100) *
      paintPct div 100,
    (sim.config.accel * speedScale div 100) * paintPct div 100
  )

suite "floor-paint buff":
  test "the composition rule's exact integer results":
    var sim = newPaintballSim()
    check sim.config.maxSpeed == MaxSpeed
    sim.players[0].paintUnder = puNone
    check sim.speedsFor(0) == (704, 76)
    sim.players[0].paintUnder = puOwn
    check sim.speedsFor(0) == (880, 95)
    sim.players[0].paintUnder = puEnemy
    check sim.speedsFor(0) == (598, 64)

  test "the buff gate off leaves every cog at 100%":
    var sim = newPaintballSim(paintballConfigJson(paintBuff = false))
    sim.players[0].paintUnder = puOwn
    check sim.speedsFor(0) == (704, 76)
    sim.players[0].paintUnder = puEnemy
    check sim.speedsFor(0) == (704, 76)

  test "48 continuous ticks on own paint heals exactly one hit point":
    var sim = newPaintballSim()
    let cog = 0
    sim.placePlayer(cog, MapWidth div 2, MapHeight div 2)
    let tile = sim.paintTileAt(sim.players[cog].x, sim.players[cog].y)
    check tile >= 0
    check sim.paintTile(tile, sim.players[cog].team)
    sim.players[cog].hp = 1
    sim.players[cog].ownPaintTicks = 0
    for _ in 0 ..< sim.config.paintHealTicks - 1:
      sim.updatePaintBuff()
    check sim.players[cog].hp == 1              ## 47 ticks is not enough
    sim.updatePaintBuff()
    check sim.players[cog].hp == 2
    check sim.players[cog].ownPaintTicks == 0

  test "stepping off own paint for one tick restarts the clock":
    var sim = newPaintballSim()
    let cog = 0
    sim.placePlayer(cog, MapWidth div 2, MapHeight div 2)
    let tile = sim.paintTileAt(sim.players[cog].x, sim.players[cog].y)
    check sim.paintTile(tile, sim.players[cog].team)
    sim.players[cog].hp = 1
    for _ in 0 ..< sim.config.paintHealTicks - 1:
      sim.updatePaintBuff()
    ## One tick on neutral ground and the streak is gone.
    sim.paintOwner[tile] = 0
    sim.updatePaintBuff()
    check sim.players[cog].ownPaintTicks == 0
    check sim.players[cog].hp == 1

  test "a heal never exceeds maxHpFor":
    var sim = newPaintballSim()
    let cog = 0
    sim.placePlayer(cog, MapWidth div 2, MapHeight div 2)
    let tile = sim.paintTileAt(sim.players[cog].x, sim.players[cog].y)
    check sim.paintTile(tile, sim.players[cog].team)
    let cap = sim.config.maxHpFor(sim.players[cog].team, sim.players[cog].perks)
    sim.players[cog].hp = cap
    for _ in 0 ..< 3 * sim.config.paintHealTicks:
      sim.updatePaintBuff()
    check sim.players[cog].hp == cap

  test "taking damage and dying both reset the heal clock":
    var sim = newPaintballSim()
    let cog = 0
    sim.players[cog].ownPaintTicks = 40
    discard sim.absorbDamage(cog, 1)
    check sim.players[cog].ownPaintTicks == 0
    sim.players[cog].ownPaintTicks = 40
    sim.killPlayer(cog, 1)
    check sim.players[cog].ownPaintTicks == 0
    check sim.players[cog].paintUnder == puNone

  test "a tagged-out cog keeps its spray can":
    var sim = newPaintballSim()
    check sim.players[0].hasSprayPaint
    sim.killPlayer(0, 1)
    check sim.players[0].hasSprayPaint
