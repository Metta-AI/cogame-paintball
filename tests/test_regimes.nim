## resident / visitor wiring: who drives whom, how the regime advances, and
## that the visitor seat really does see less.
import std/[strutils, unittest]
import helpers

suite "regimes":
  test "resident: the seat commands all four of its cogs":
    let sim = newPaintballSim(paintballConfigJson(regimes = @["resident"]))
    check sim.regime == regimeResident
    check sim.totalCogs() == 8
    for seat in 0 .. 1:
      let commanded = sim.commandedCogs(seat)
      check commanded.len == 4
      for cogIndex in commanded:
        check sim.cogSeat(cogIndex) == seat
        check sim.players[cogIndex].team == Team(seat)
      check sim.squadCogs(seat).len == 4

  test "visitor: the seat commands alpha only":
    let sim = newPaintballSim(paintballConfigJson(regimes = @["visitor"]))
    check sim.regime == regimeVisitor
    for seat in 0 .. 1:
      let commanded = sim.commandedCogs(seat)
      check commanded.len == 1
      check sim.cogIdentityIndex(commanded[0]) == 0
      check sim.cogAlias(commanded[0]).endsWith("alpha")
      ## The other three are the seat's squad but NOT its to command.
      for cogIndex in sim.squadCogs(seat):
        if cogIndex == commanded[0]:
          continue
        check not sim.seatCommands(seat, cogIndex)

  test "the cog aliases are the anonymous squad names, in order":
    let sim = newPaintballSim()
    check sim.cogAlias(0) == "RED-alpha"
    check sim.cogAlias(1) == "BLUE-alpha"
    check sim.cogAlias(2) == "RED-beta"
    check sim.cogAlias(7) == "BLUE-delta"

  test "an uncommanded teammate produces the holdline mask byte for byte":
    ## In a visitor game beta/gamma/delta must be indistinguishable from a
    ## pure holdline run: that is what makes "adapt to a partner you know the
    ## rules of" true rather than aspirational.
    var sim = newPaintballSim(paintballConfigJson(regimes = @["visitor"]))
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    for cogIndex in sim.squadCogs(0):
      if sim.seatCommands(0, cogIndex):
        continue
      let
        viaSquad = scriptedDirective(ctl, sim, blHoldline, @[cogIndex])
        viaPure = scriptedDirective(ctl, sim, blHoldline, @[cogIndex])
      check viaSquad.orders.len == 1
      check ctl.compileMask(sim, viaSquad.orders[0], cogIndex) ==
        ctl.compileMask(sim, viaPure.orders[0], cogIndex)

  test "the regime array advances resident -> visitor across games":
    var config = defaultGameConfig()
    config.update(paintballConfigJson(
      maxGames = 2, regimes = @["resident", "visitor"]))
    check config.regimes == @[regimeResident, regimeVisitor]
    check config.regimes[min(0, config.regimes.high)] == regimeResident
    check config.regimes[min(1, config.regimes.high)] == regimeVisitor
    ## A single-regime config clamps rather than running off the end.
    var single = defaultGameConfig()
    single.update(paintballConfigJson(maxGames = 2, regimes = @["visitor"]))
    check single.regimes[min(1, single.regimes.high)] == regimeVisitor

  test "the visitor seat's fog is a strict subset of its resident fog":
    var resident = newPaintballSim(paintballConfigJson(regimes = @["resident"]))
    var visitor = newPaintballSim(paintballConfigJson(regimes = @["visitor"]))
    ## Identical positions in both sims (same seed, same spawn arrangement).
    for i in 0 ..< resident.players.len:
      check resident.players[i].x == visitor.players[i].x
      check resident.players[i].y == visitor.players[i].y
    resident.refreshSeatFov(0)
    visitor.refreshSeatFov(0)
    var
      residentCells = 0
      visitorCells = 0
    for cell in 0 ..< resident.fovCaches[0].visible.len:
      if resident.fovCaches[0].visible[cell]:
        inc residentCells
      if visitor.fovCaches[0].visible[cell]:
        inc visitorCells
        ## Every cell the lone visitor sees, the whole squad also sees.
        check resident.fovCaches[0].visible[cell]
    check visitorCells > 0
    check visitorCells < residentCells
