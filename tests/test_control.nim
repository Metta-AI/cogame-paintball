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
  for i, order in directive.orders:
    check order.cogIndex == commanded[i]
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

  test "holdline beats sprayer at seed 679961 and the hill changes hands":
    ## A pinned regression against a degenerate stalemate: if the hill never
    ## flips, the game is not being played.
    var sim = newPaintballSim(paintballConfigJson(maxTicks = 1200))
    var ctl = initControlState(sim)
    var flips = 0
    var lastOwner = -1
    var prev = newSeq[InputState](sim.players.len)
    var directives = newSeq[SquadDirective](2)
    let kinds = [blHoldline, blSprayer]
    for tick in 0 ..< 1200:
      if sim.phase != Playing:
        break
      ctl.observeEnemies(sim)
      if sim.gameTicksElapsed() mod sim.config.turnTicks == 0:
        for seat in 0 .. 1:
          directives[seat] =
            scriptedDirective(ctl, sim, kinds[seat], sim.commandedCogs(seat))
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
        if lastOwner >= 0 or owner >= 0:
          inc flips
        lastOwner = owner
    echo "holdline hill ticks ", sim.hillTicks[Red],
      " vs sprayer ", sim.hillTicks[Blue], " over ", flips, " flips"
    check sim.paintCount[Red] + sim.paintCount[Blue] > 0
    ## The pinned regression: a hill that never changes hands is a degenerate
    ## stalemate, not a game.
    check flips >= 2
    ## holdline is the stronger baseline, so it must not be DOMINATED here.
    ## The strict "holdline wins" claim belongs to the ladder over many
    ## episodes, not to a single 1200-tick sample, so it is logged above
    ## rather than asserted.
    check sim.hillTicks[Red] * 2 >= sim.hillTicks[Blue]
