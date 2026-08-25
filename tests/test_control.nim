## The bounded-orders / legality assertion on the scripted baselines, and the
## control layer's mask legality.
import std/[random, strutils, unicode, unittest]
import helpers

const IntentNames = ["paint_hill", "hold_hill", "hunt", "guard", "paint_path",
                     "fall_back"]

proc validate(sim: SimServer, directive: SquadDirective, commanded: seq[int]) =
  ## The reply schema, applied to a SCRIPTED directive: exactly the commanded
  ## cog ids, every intent in the enum, every target inside the map and on
  ## walkable ground, and both string caps honoured in RUNES.
  check directive.orders.len == commanded.len
  check directive.note.runeLen <= MaxNoteRunes
  ## The orders are RANKED (nearest the hill first), so what has to hold is
  ## that the SET is exactly the commanded cogs, each named once.
  var seen: seq[int]
  for order in directive.orders:
    check order.cogIndex in commanded
    check order.cogIndex notin seen
    seen.add(order.cogIndex)
  for order in directive.orders:
    check order.id == sim.cogAlias(order.cogIndex)
    check order.id.runeLen <= MaxCogIdRunes
    check $order.intent in IntentNames
    check order.targetX >= 0 and order.targetX < MapWidth
    check order.targetY >= 0 and order.targetY < MapHeight
    check order.say.runeLen <= MaxSayRunes
    if order.hasFace:
      check order.faceX >= 0 and order.faceX < MapWidth
      check order.faceY >= 0 and order.faceY < MapHeight

proc assertLegalMask(mask: uint8) =
  check (mask and ButtonUp) == 0 or (mask and ButtonDown) == 0
  check (mask and ButtonLeft) == 0 or (mask and ButtonRight) == 0
  check (mask and ButtonC) == 0

suite "control layer and scripted baselines":
  test "500 random world states x both baselines emit legal orders and masks":
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    var rng = initRand(20260825)
    for iteration in 0 ..< 500:
      ## Shake the world: random positions, random aims, random paint.
      for i in 0 ..< sim.players.len:
        sim.placePlayer(i, 60 + rng.rand(MapWidth - 120),
                        60 + rng.rand(MapHeight - 120))
        sim.players[i].aimBrads = rng.rand(AimBradsTurn - 1)
        sim.players[i].alive = rng.rand(9) > 0
        sim.players[i].hp = 1 + rng.rand(2)
      if iteration mod 5 == 0:
        let tile = rng.rand(sim.paintOwner.high)
        discard sim.paintTile(tile, Team(rng.rand(1)))
      ctl.observeEnemies(sim)
      for kind in [blHoldline, blSprayer]:
        for seat in 0 .. 1:
          let commanded = sim.commandedCogs(seat)
          let directive = scriptedDirective(ctl, sim, kind, commanded)
          sim.validate(directive, commanded)
          for order in directive.orders:
            assertLegalMask(ctl.compileMask(sim, order, order.cogIndex))

  test "the same (state, directive) pair always yields the same byte":
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    let directive = scriptedDirective(ctl, sim, blHoldline, sim.commandedCogs(0))
    for order in directive.orders:
      let first = ctl.compileMask(sim, order, order.cogIndex)
      for _ in 0 ..< 5:
        check ctl.compileMask(sim, order, order.cogIndex) == first

  test "fall_back never pulls the trigger":
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    for cogIndex in 0 ..< sim.players.len:
      sim.players[cogIndex].fireCooldown = 0
      sim.players[cogIndex].arcTicksLeft = 0
      let order = CogOrder(
        cogIndex: cogIndex, id: sim.cogAlias(cogIndex), intent: intFallBack,
        targetX: MapWidth div 2, targetY: MapHeight div 2)
      check (ctl.compileMask(sim, order, cogIndex) and ButtonA) == 0

  test "the trigger is never set while the can is repressurizing":
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    for cogIndex in 0 ..< sim.players.len:
      sim.players[cogIndex].fireCooldown = SprayPaintResetTicks
      let order = CogOrder(
        cogIndex: cogIndex, id: sim.cogAlias(cogIndex), intent: intPaintHill,
        targetX: MapWidth div 2, targetY: MapHeight div 2)
      check (ctl.compileMask(sim, order, cogIndex) and ButtonA) == 0

  test "a cog ordered to an unreachable target still moves every tick":
    ## An unreachable goal must never stall a cog: it keeps walking toward the
    ## nearest open cell to it, so a bad directive costs position, not agency.
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    let cogIndex = 0
    sim.placePlayer(cogIndex, MapWidth div 4, MapHeight div 2)
    let order = CogOrder(
      cogIndex: cogIndex, id: sim.cogAlias(cogIndex), intent: intGuard,
      targetX: 1, targetY: 1)        ## inside the border wall
    var moved = 0
    var prev = newSeq[InputState](sim.players.len)
    for _ in 0 ..< 120:
      ctl.observeEnemies(sim)
      let mask = ctl.compileMask(sim, order, cogIndex)
      if (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0:
        inc moved
      var inputs = newSeq[InputState](sim.players.len)
      inputs[cogIndex] = decodeInputMask(mask)
      sim.step(inputs, prev)
      prev = inputs
    check moved >= 100

  test "either squad can take the hill, and the hill changes hands":
    ## The pinned regression against a degenerate stalemate: if the hill can
    ## never be owned, every episode is a 0.500 draw and the ladder is dead.
    ##
    ## Proven per side, from a fresh board each time, because that is the
    ## property the RULES owe: neither colour may be structurally unable to
    ## reach 80% of the hill's floor. Across the pair the hill demonstrably
    ## changes hands — unowned to RED, and unowned to BLUE.
    ##
    ## This is also the regression that caught a wedged squad: on a nav grid
    ## too coarse for the arena's corridors, BLUE covered 0% of the hill where
    ## RED covered 95%, because the flow field called the far side of every
    ## obstacle column unreachable and the cogs pressed one d-pad direction
    ## into a wall for two thousand ticks. Both sides now reach 100%. Asserting
    ## it PER COLOUR is what makes that failure visible: an asymmetry between
    ## the two halves of a mirror-symmetric arena is always a defect.
    for sweeper in [Red, Blue]:
      ## maxTicks far beyond the run: once a squad owns the hill it banks a
      ## tick a tick, and the MERCY rule would otherwise end the game the
      ## moment the lead exceeds the clock remaining.
      var sim = newPaintballSim(paintballConfigJson(maxTicks = 20_000))
      var ctl = initControlState(sim)
      var prev = newSeq[InputState](sim.players.len)
      var directives = newSeq[SquadDirective](2)
      var owners: seq[int]
      var lastOwner = -1
      var peak = 0
      let sweeperSeat = ord(sweeper)
      for tick in 0 ..< 2400:
        if sim.phase != Playing:
          break
        ctl.observeEnemies(sim)
        if sim.gameTicksElapsed() mod sim.config.turnTicks == 0:
          for seat in 0 .. 1:
            let commanded = sim.commandedCogs(seat)
            directives[seat] = SquadDirective(source: dsScripted, note: "run")
            if seat == sweeperSeat:
              ## All four cogs on paint_hill — a directive an LLM can issue,
              ## and the one that answers "can 80% be reached at all". goalFor
              ## sends each cog to the FURTHEST tile that is not yet ours, so
              ## the four of them roll across the square rather than parking
              ## on its near rim.
              let hill = hillCentre(sim)
              for cogIndex in commanded:
                directives[seat].orders.add(CogOrder(
                  cogIndex: cogIndex, id: sim.cogAlias(cogIndex),
                  intent: intPaintHill, targetX: hill.x, targetY: hill.y))
            else:
              ## Stand down: walk home and never spray (fall_back never fires).
              for cogIndex in commanded:
                let anchor = sim.gameMap.teamAnchor(sim.players[cogIndex].team)
                directives[seat].orders.add(CogOrder(
                  cogIndex: cogIndex, id: sim.cogAlias(cogIndex),
                  intent: intFallBack, targetX: anchor.x, targetY: anchor.y))
        var inputs = newSeq[InputState](sim.players.len)
        for cogIndex in 0 ..< sim.players.len:
          let seat = sim.cogSeat(cogIndex)
          for order in directives[seat].orders:
            if order.cogIndex == cogIndex:
              inputs[cogIndex] = decodeInputMask(
                ctl.compileMask(sim, order, cogIndex))
              break
        if tick mod 400 == 0:
          ## A wedged cog is invisible in the totals but obvious here: its
          ## position stops changing while its mask keeps naming one
          ## direction. Cheap enough to leave in, and it is what turned "blue
          ## covers 0%" into a diagnosis in one CI round.
          var line = ""
          for cogIndex in sim.commandedCogs(sweeperSeat):
            let p = sim.players[cogIndex]
            var gx, gy, mask = 0
            for order in directives[sweeperSeat].orders:
              if order.cogIndex == cogIndex:
                let g = ctl.goalFor(sim, order, cogIndex)
                gx = g.x
                gy = g.y
                mask = int(ctl.compileMask(sim, order, cogIndex))
            line.add " #" & $cogIndex & " " & $p.x & "," & $p.y &
              (if p.alive: "" else: "!dead") & " brads " & $p.aimBrads &
              " -> " & $gx & "," & $gy & " mask " & $mask
          echo "  trace ", teamText(sweeper), " t", tick, line
        sim.step(inputs, prev)
        prev = inputs
        let owner = if sim.hillOwned: ord(sim.hillOwner) else: -1
        if owner != lastOwner:
          owners.add(owner)
          lastOwner = owner
        peak = max(peak, sim.hillCoveragePct(sweeper))
      block:
        var hills = ""
        for tile in sim.hillTiles:
          let c = sim.paintTileCentre(tile)
          hills.add " " & $c.x & "," & $c.y & ":" &
            (if sim.paintFloor[tile]: $sim.paintOwner[tile] else: "W")
        echo "  trace hill ", teamText(sweeper), " anchors red ",
          sim.gameMap.teamAnchor(Red), " blue ", sim.gameMap.teamAnchor(Blue),
          " map ", MapWidth, "x", MapHeight, " grid ", sim.paintGridW, "x",
          sim.paintGridH, " |", hills
      echo teamText(sweeper), " sweeping: peak coverage ", peak, "% (need ",
        sim.config.hillOwnPermille div 10, "%) | owners ", owners,
        " | hill paint ", sim.hillPaint[sweeper], " of ", sim.hillFloorTiles,
        " | hill ticks ", sim.hillTicks[sweeper],
        " | floor paint ", sim.paintCount[sweeper]
      check sim.paintCount[sweeper] > 0
      check peak >= sim.config.hillOwnPermille div 10
      check sim.hillTicks[sweeper] > 0
      check sim.hillOwned
      check sim.hillOwner == sweeper
      ## The hill started unowned and ended this squad's: it changed hands.
      check owners.len >= 1
      if owners.len >= 1:
        ## Guarded so an empty seq FAILS the test above rather than aborting
        ## the whole suite on an IndexDefect.
        check owners[^1] == ord(sweeper)

  test "two evenly-matched baselines both spray, and the hill stays contested":
    ## The symmetric run — the filler-vs-filler episode a league actually
    ## plays. Three things are STRUCTURAL and asserted: both squads lay floor
    ## paint, the episode completes without a fault, and the hill is banked by
    ## somebody. That last one is the anti-stalemate invariant: two squads that
    ## both walk to the centre and neither of which can ever own it produce a
    ## 0.500 draw every time, and a ladder of draws ranks nothing. It is also
    ## exactly what a wedged-cog regression looks like from the outside.
    ##
    ## WHICH baseline wins is a balance property of two scripted policies
    ## meeting head-on, so it is logged rather than pinned. As measured,
    ## `sprayer` beats `holdline` clearly — it reaches 18 of 21 hill tiles and
    ## banks ~730 hill ticks to holdline's 0, because holdline switches cogs to
    ## `hunt` inside 200px where sprayer only does so inside 120px and keeps
    ## painting for longer. A later balance pass has the number here.
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 3000))
    var ctl = initControlState(sim)
    sim.scriptedEpisode(ctl, [blHoldline, blSprayer], 3000)
    echo "symmetric run: hill paint red=", sim.hillPaint[Red],
      " blue=", sim.hillPaint[Blue], " of ", sim.hillFloorTiles,
      " | hill ticks red=", sim.hillTicks[Red],
      " blue=", sim.hillTicks[Blue],
      " | floor paint red=", sim.paintCount[Red],
      " blue=", sim.paintCount[Blue],
      " | phase=", sim.phase
    check sim.paintCount[Red] > 0
    check sim.paintCount[Blue] > 0
    check sim.hillTicks[Red] + sim.hillTicks[Blue] > 0
    check sim.endReason in ["", ReasonComplete]
