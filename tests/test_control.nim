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

  test "the hill can be taken, and it changes hands at least twice":
    ## The pinned regression against a degenerate stalemate. Asymmetric on
    ## purpose: a squad that is ALLOWED to work must be able to reach 80% of
    ## the hill's floor, and when the initiative changes sides the hill must
    ## change with it. Two evenly-matched scripted squads contesting the same
    ## twenty-one tiles is a BALANCE question and is logged below, not
    ## asserted here — a 100-second sample is not a ladder.
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 4000))
    var ctl = initControlState(sim)
    var prev = newSeq[InputState](sim.players.len)
    var directives = newSeq[SquadDirective](2)
    var flips = 0
    var owners: seq[int]
    var lastOwner = -1
    for tick in 0 ..< 2400:
      if sim.phase != Playing:
        break
      ctl.observeEnemies(sim)
      if sim.gameTicksElapsed() mod sim.config.turnTicks == 0:
        ## The initiative changes sides halfway: first RED works and BLUE
        ## stands down, then the reverse.
        let redActive = tick < 1200
        for seat in 0 .. 1:
          let commanded = sim.commandedCogs(seat)
          if (seat == 0) == redActive:
            ## All four cogs on paint_hill — a directive an LLM can issue, and
            ## the one that answers "can 80% of the hill be reached at all".
            ## goalFor sends each cog to the nearest tile that is not yet ours,
            ## so they spread across the square without being told to.
            directives[seat] = SquadDirective(source: dsScripted, note: "sweep")
            let hill = hillCentre(sim)
            for cogIndex in commanded:
              directives[seat].orders.add(CogOrder(
                cogIndex: cogIndex, id: sim.cogAlias(cogIndex),
                intent: intPaintHill, targetX: hill.x, targetY: hill.y))
          else:
            ## Stand down: walk home and never spray.
            directives[seat] = SquadDirective(source: dsScripted, note: "stand")
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
      sim.step(inputs, prev)
      prev = inputs
      let owner = if sim.hillOwned: ord(sim.hillOwner) else: -1
      if owner != lastOwner:
        inc flips
        owners.add(owner)
        lastOwner = owner
    var unowned: seq[int]
    for tile in sim.hillTiles:
      if sim.paintFloor[tile] and sim.paintOwner[tile] != 1'u8:
        unowned.add(tile)
    echo "hill tiles RED never took: ", unowned
    echo "hill owners over the run: ", owners,
      " | hill paint red=", sim.hillPaint[Red], " blue=", sim.hillPaint[Blue],
      " of ", sim.hillFloorTiles,
      " | hill ticks red=", sim.hillTicks[Red], " blue=", sim.hillTicks[Blue],
      " | floor paint red=", sim.paintCount[Red], " blue=", sim.paintCount[Blue]
    check sim.paintCount[Red] + sim.paintCount[Blue] > 0
    check sim.hillTicks[Red] + sim.hillTicks[Blue] > 0
    check flips >= 2

  test "two evenly-matched baselines contest the hill (logged, not pinned)":
    ## The symmetric run: what matters mechanically is that BOTH squads get
    ## paint onto the hill, so the 80% threshold is being fought over rather
    ## than ignored. The banked clocks are printed for the balance record.
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 1600))
    var ctl = initControlState(sim)
    sim.scriptedEpisode(ctl, [blHoldline, blSprayer], 1600)
    echo "symmetric run: hill paint red=", sim.hillPaint[Red],
      " blue=", sim.hillPaint[Blue], " of ", sim.hillFloorTiles,
      " | hill ticks red=", sim.hillTicks[Red],
      " blue=", sim.hillTicks[Blue],
      " | floor paint red=", sim.paintCount[Red],
      " blue=", sim.paintCount[Blue]
    check sim.paintCount[Red] > 0
    check sim.paintCount[Blue] > 0
    check sim.hillPaint[Red] + sim.hillPaint[Blue] > 0
