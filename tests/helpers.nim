## Shared fixtures for the paintball suite.
##
## Every test builds its sim through `newPaintballSim` so one place owns the
## "what a paintball config looks like" knowledge, and so a config field that
## grows a validation rule breaks one line rather than fourteen files.

import
  std/[json, strutils],
  bitworld/spriteprotocol,
  paintball/[sim, control, directives, baselines, llm, decide]

export sim, control, directives, baselines, llm, decide, spriteprotocol

proc paintballConfigJson*(
  maxTicks = 600,
  maxGames = 1,
  regimes = @["resident"],
  paintBuff = true,
  hill = true,
  floorPaint = true,
  seed = 679961
): string =
  ## The config every fixture starts from: two seats, four cogs a squad, the
  ## paintball loadout, on the hand-tuned arena.
  var regimeArray = newJArray()
  for regime in regimes:
    regimeArray.add(%regime)
  $(%*{
    "seed": seed,
    "num_agents": 2,
    "minPlayers": 2,
    "cogsPerTeam": 4,
    "maxTicks": maxTicks,
    "maxGames": maxGames,
    "regimes": regimeArray,
    "lives": 12,
    "hitPoints": 3,
    "sprayDamage": 1,
    "respawnTicks": 48,
    "mapPath": "arena",
    "loadout": "paintball",
    "floorPaint": floorPaint,
    "paintBuff": paintBuff,
    "hill": hill,
    "turnTicks": 108,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 4,
    "lobbyJoinTimeoutTicks": 0,
    "fastMode": true,
    "showPlayerLabels": false,
    "tokens": ["t0", "t1"],
    "players": [{"name": "daveey"}, {"name": "daveey-1"}],
    "slots": [{"team": "red"}, {"team": "blue"}]
  })

proc cogAliasFor*(sim: SimServer, order: int): string =
  toUpperAscii(teamText(sim.teamForSlot(order))) & "-" &
    IdentityNames[sim.slotIdentityIndex(order)]

proc newPaintballSim*(configJson: string): SimServer =
  ## A sim with both squads seated and the first game started, exactly as the
  ## server builds them: seats first (slots 0 and 1, carrying the real policy
  ## names), then the rest of both squads as trusted joins carrying only the
  ## cogs' anonymous aliases.
  var config = defaultGameConfig()
  config.update(configJson)
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("daveey", 0, "t0")
  discard result.addPlayer("daveey-1", 1, "t1")
  for order in 2 ..< result.totalCogs():
    discard result.addPlayer(result.cogAliasFor(order), order, "", trusted = true)
  result.seatNames[0] = "daveey"
  result.seatNames[1] = "daveey-1"
  result.startGame()

proc newPaintballSim*(): SimServer =
  newPaintballSim(paintballConfigJson())

proc rescanPaint*(sim: SimServer): tuple[red, blue, hillRed, hillBlue: int] =
  ## A full rescan of `paintOwner`, so a test can prove the incremental
  ## counters never drift from the truth.
  for tile in 0 ..< sim.paintOwner.len:
    case sim.paintOwner[tile]
    of 1'u8: inc result.red
    of 2'u8: inc result.blue
    else: discard
  for tile in sim.hillTiles:
    case sim.paintOwner[tile]
    of 1'u8: inc result.hillRed
    of 2'u8: inc result.hillBlue
    else: discard

proc stepWithControl*(
  sim: var SimServer, ctl: var ControlState, directives: seq[SquadDirective],
  ticks: int
) =
  ## Drives `ticks` ticks with the control layer, exactly as the server does:
  ## one mask per cog, in cog index order, from the seat's directive when the
  ## seat commands that cog and from `holdline` otherwise.
  var prev = newSeq[InputState](sim.players.len)
  for _ in 0 ..< ticks:
    if sim.phase != Playing:
      break
    ctl.observeEnemies(sim)
    var inputs = newSeq[InputState](sim.players.len)
    for cogIndex in 0 ..< sim.players.len:
      let seat = sim.cogSeat(cogIndex)
      var order: CogOrder
      var found = false
      if sim.seatCommands(seat, cogIndex) and seat < directives.len:
        for candidate in directives[seat].orders:
          if candidate.cogIndex == cogIndex:
            order = candidate
            found = true
            break
      if not found:
        let scripted = scriptedDirective(ctl, sim, blHoldline, @[cogIndex])
        if scripted.orders.len == 0:
          continue
        order = scripted.orders[0]
      inputs[cogIndex] = decodeInputMask(ctl.compileMask(sim, order, cogIndex))
    sim.step(inputs, prev)
    prev = inputs

proc scriptedEpisode*(
  sim: var SimServer, ctl: var ControlState, kinds: array[2, Baseline],
  ticks: int
) =
  ## A scripted-vs-scripted run: each seat re-issues its baseline's directive
  ## on the real turn cadence, and the control layer compiles it every tick.
  var prev = newSeq[InputState](sim.players.len)
  var directives = newSeq[SquadDirective](2)
  for tick in 0 ..< ticks:
    if sim.phase == GameOver and sim.config.maxGames <= 1:
      break
    ctl.observeEnemies(sim)
    if sim.phase == Playing and
        sim.gameTicksElapsed() mod max(1, sim.config.turnTicks) == 0:
      for seat in 0 .. 1:
        directives[seat] =
          scriptedDirective(ctl, sim, kinds[seat], sim.commandedCogs(seat))
    var inputs = newSeq[InputState](sim.players.len)
    if sim.phase == Playing:
      for cogIndex in 0 ..< sim.players.len:
        let seat = sim.cogSeat(cogIndex)
        var order: CogOrder
        var found = false
        for candidate in directives[seat].orders:
          if candidate.cogIndex == cogIndex:
            order = candidate
            found = true
            break
        if not found:
          let scripted = scriptedDirective(ctl, sim, blHoldline, @[cogIndex])
          if scripted.orders.len == 0:
            continue
          order = scripted.orders[0]
        inputs[cogIndex] = decodeInputMask(ctl.compileMask(sim, order, cogIndex))
    sim.step(inputs, prev)
    prev = inputs
