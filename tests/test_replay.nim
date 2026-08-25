## An end-to-end episode that WRITES a replay, then proves the recorded masks
## re-simulate to the identical hash chain — the property the wasm viewer
## depends on — and that tools/replay_summary.py reads it as strict UTF-8 JSON.
import std/[json, os, osproc, strutils, unicode, unittest]
import paintball/[replays, replay_runtime, broadcast]
import helpers

const
  Ticks = 240          ## short on purpose: this runs in DEBUG too.
  Games = 2

proc recordEpisode(path: string): tuple[hashes, records: int] =
  ## Plays a scripted-vs-scripted episode straight through the SIM (no
  ## sockets), writing exactly the records the server writes: joins per cog,
  ## per-cog mask changes, the control records, cog shouts, and one gameHash
  ## per tick.
  var config = defaultGameConfig()
  config.update(paintballConfigJson(
    maxTicks = Ticks, maxGames = Games,
    regimes = @["resident", "visitor"]))
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var writer = openReplayWriter(path, config.configJson())
  defer: writer.closeReplayWriter()

  proc seatCog(order: int): string =
    toUpperAscii(teamText(sim.teamForSlot(order))) & "-" &
      IdentityNames[sim.slotIdentityIndex(order)]

  ## A deliberately NON-ASCII policy label so the strict-UTF-8 path is real.
  discard sim.addPlayer("daveey", 0, "t0")
  discard sim.addPlayer("daveey-1", 1, "t1")
  for order in 2 ..< sim.totalCogs():
    discard sim.addPlayer(seatCog(order), order, "", trusted = true)
  sim.seatNames[0] = "daveey"
  sim.seatNames[1] = "daveey-1"
  for order in 0 ..< sim.players.len:
    writer.writeJoin(tickTime(sim.tickCount), order,
      sim.players[order].address, order,
      (if order < 2: "t" & $order else: ""))
    writer.lastMasks.add(0)
  for seat in 0 .. 1:
    let record = registerRecord(seat, teamText(sim.teamForSlot(seat)),
      "pötten-" & $seat, "scripted", "holdline")
    writer.writeChat(tickTime(sim.tickCount), seat, record)
    inc result.records

  var ctl = initControlState(sim)
  var directives = newSeq[SquadDirective](2)
  let kinds = [blHoldline, blSprayer]
  sim.startGame()
  var gamesPlayed = 0
  var prev = newSeq[InputState](sim.players.len)
  while gamesPlayed < Games and sim.tickCount < Ticks * Games + 400:
    ctl.observeEnemies(sim)
    if sim.phase == Playing and
        sim.gameTicksElapsed() mod sim.config.turnTicks == 0:
      let turn = sim.gameTicksElapsed() div sim.config.turnTicks
      for seat in 0 .. 1:
        directives[seat] =
          scriptedDirective(ctl, sim, kinds[seat], sim.commandedCogs(seat))
        ## A non-ASCII note, so the record really carries multi-byte text.
        directives[seat].note = "hüll " & $turn
        let record = directives[seat].boundedDirectiveRecord(
          sim.gameIndex + 1, turn, seat, teamText(sim.teamForSlot(seat)),
          regimeText(sim.regime))
        check record.runeLen <= MaxDirectiveRunes
        writer.writeChat(tickTime(sim.tickCount), seat, record)
        sim.pushFeedDirective(record)
        inc result.records
        for order in directives[seat].orders:
          if order.say.len > 0 and sim.applyShout(order.cogIndex, order.say):
            writer.writeChat(tickTime(sim.tickCount), order.cogIndex, order.say)
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
        let mask = ctl.compileMask(sim, order, cogIndex)
        inputs[cogIndex] = decodeInputMask(mask)
        writer.writeInputMaskChange(tickTime(sim.tickCount), cogIndex, mask)
    let phaseBefore = sim.phase
    sim.step(inputs, prev)
    prev = inputs
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc result.hashes
    if phaseBefore != GameOver and sim.phase == GameOver:
      inc gamesPlayed
      sim.gameHill.add(sim.hillTicks)
      sim.gameRegimes.add(sim.regime)
      sim.gameIndex = gamesPlayed
      if gamesPlayed < config.regimes.len:
        sim.regime = config.regimes[gamesPlayed]
    if sim.needsReregister:
      ## The lobby reset dropped the roster: re-seat the squads exactly as the
      ## server does, and record the joins so playback re-derives them.
      sim.needsReregister = false
      for order in 0 ..< sim.totalCogs():
        discard sim.addPlayer(
          (if order < 2: sim.seatNames[order] else: seatCog(order)),
          order, "", trusted = true)
        writer.writeJoin(tickTime(sim.tickCount), order,
          sim.players[order].address, order, "")
      while writer.lastMasks.len < sim.players.len:
        writer.lastMasks.add(0)
      prev = newSeq[InputState](sim.players.len)
  let results = sim.playerResultsJson()
  writer.writeChat(tickTime(sim.tickCount), 0,
    $(%*{"k": "result", "results": parseJson(results)}))
  inc result.records
  writeFile(path.changeFileExt("results.json"), results)

suite "replay":
  let dir = getTempDir() / "paintball-test-replay"
  createDir(dir)
  let path = dir / "episode.bitreplay"

  test "an episode writes a COWLDPNT replay and a results document":
    let written = recordEpisode(path)
    check written.hashes > Ticks
    check written.records > 4
    check fileExists(path)
    check getFileSize(path) > 1000
    let results = parseJson(readFile(path.changeFileExt("results.json")))
    check results["names"].len == 2
    check results["reason"].getStr() in
      [ReasonComplete, ReasonDeadline, ReasonFault]

  test "parseReplayBytes accepts it and every recorded hash re-simulates":
    let data = parseReplayBytes(readFile(path))
    check data.hashes.len > Ticks
    check data.joins.len >= 8
    check data.inputs.len > 100
    check data.chats.len > 4
    ## mismatchQuit = true: a single divergent bit RAISES here rather than
    ## being tolerated, because this test IS the determinism gate.
    var runtime = initReplayRuntime(data, mismatchQuit = true,
      gameEventLoggingEnabled = false)
    var player = runtime.player
    var sim = runtime.sim
    var steps = 0
    while player.playing and sim.tickCount < player.replayMaxTick():
      player.stepReplay(sim)
      inc steps
    check steps > Ticks
    check not player.hashValidationFailed
    check player.hashMismatchTick == -1

  test "the recorded stream carries the beats a spectator needs":
    let data = parseReplayBytes(readFile(path))
    var
      directives = 0
      registers = 0
      results = 0
      shouts = 0
    for chat in data.chats:
      if chat.message.len > 0 and chat.message[0] == '{':
        let node = parseJson(chat.message)
        case node{"k"}.getStr()
        of "directive": inc directives
        of "register": inc registers
        of "result": inc results
        else: discard
      else:
        inc shouts
    check registers == 2
    check results == 1
    check directives >= 4              ## one per seat per turn, both games
    check shouts > 0
    ## And re-simulating derives the gameplay beats from state deltas.
    var runtime = initReplayRuntime(data, mismatchQuit = false,
      gameEventLoggingEnabled = false)
    var player = runtime.player
    var sim = runtime.sim
    var tracker = initBroadcastTracker()
    var kinds: seq[string]
    while player.playing and sim.tickCount < player.replayMaxTick():
      player.stepReplay(sim)
      let events = newJArray()
      sim.stepEvents(tracker, events)
      for event in events:
        let kind = event["k"].getStr()
        if kind notin kinds:
          kinds.add(kind)
    check "gamestart" in kinds
    check "paint" in kinds

  test "replay_summary.py prints strict UTF-8 JSON with the non-ASCII text":
    let (output, code) = execCmdEx(
      "python3 tools/replay_summary.py " & quoteShell(path))
    check code == 0
    check validateUtf8(output) == -1
    let node = parseJson(output)
    check node["protocol"].getStr() == "paintball/v1"
    check node["seed"].getInt() == 679961
    check node["names"][0].getStr() == "daveey"
    check node["fallbacks"].getInt() == 0
    check node["directives"].len >= 4
    ## The non-ASCII policy label and note survived the round trip intact.
    var sawUmlaut = false
    for kind in node["policyKinds"]:
      check kind.getStr() == "scripted"
    for directive in node["directives"]:
      if "hüll" in directive["note"].getStr():
        sawUmlaut = true
    check sawUmlaut
    check node["results"]["names"].len == 2
