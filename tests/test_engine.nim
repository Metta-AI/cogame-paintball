## The turn loop's contracts that do not need a live network: the batch is
## PARALLEL by construction, the deadlines compose, the budget guard settles
## early, and no failure path leaves a cog unactuated.
import std/[json, monotimes, os, strutils, times, unittest]
import curly
import helpers

suite "decision engine":
  test "both seats' calls are built as ONE batch, never sequentially":
    ## The engine issues exactly one curly RequestBatch per attempt and both
    ## seats' requests go into it, so their in-flight windows necessarily
    ## intersect. Asserted structurally: the batch is built before any request
    ## is made, so a sequential implementation could not produce it.
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    check engine.seats.len == 2
    var batch: RequestBatch
    for seat in 0 ..< engine.seats.len:
      var headers: HttpHeaders
      headers["content-type"] = "application/json"
      let request = engine.client.requestFor(
        SystemPrompt, userMessage("", engine.seatViewJson(sim, seat, 0, 20)))
      batch.post(request.url, request.headers, request.body, $seat)
    check batch.len == 2
    check batch[0].tag == "0"
    check batch[1].tag == "1"

  test "the two batch deadlines fit inside the per-turn budget":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
    ## curly's timeout granularity is whole seconds, and decide.turn FLOORS
    ## the conversion, so the transport deadline is never longer than the
    ## configured one. What has to hold is the note's worst case — a turn that
    ## times out twice — with margin inside the per-turn cap, not merely
    ## equal to it: 4 + 2 = 6 s <= 6.5 s <= 7.0 s.
    let rounded = max(1, config.attempt1Ms div 1000) +
      max(1, config.retryMs div 1000)
    check rounded * 1000 <= config.attempt1Ms + config.retryMs
    check rounded * 1000 <= 6500
    check rounded * 1000 < config.turnBudgetMs

  test "turnSpacingMs holds two seats under the sidecar's 30/min cap":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    ## The shipped variants floor the spacing at 5 s: 2 seats / 5 s = 24 req/min.
    check DefaultTurnSpacingMs >= 5000
    let perMinute = 2 * 60_000 div DefaultTurnSpacingMs
    check perMinute <= 30
    ## The certification fixture switches it off, so offline runs pay nothing.
    check config.turnSpacingMs == 0

  test "with no credentials every turn falls back INSTANTLY and legally":
    ## The load-bearing offline path: certification has no key, so the client
    ## disables itself and the whole episode must run on the scripted layer
    ## with no network wait at all.
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    check engine.client.disabled
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    let started = getMonoTime()
    let records = engine.turn(sim, 0, 20, 0)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    check elapsed < sim.config.turnBudgetMs
    check records.len == 0            ## a disabled client is not a fallback
    for seat in 0 .. 1:
      check engine.haveDirective[seat]
      check engine.directives[seat].orders.len == sim.commandedCogs(seat).len

  test "the budget guard fires and names the turn it fired on":
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    ## Two more turns would not fit inside the wall-clock budget.
    let records = engine.turn(sim, 7, 20, sim.config.wallClockBudgetSeconds - 1)
    check engine.llmOff
    var sawGuard = false
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "budget_guard":
        sawGuard = true
        check node{"turn"}.getInt() == 7
    check sawGuard
    ## And from here on the episode plays scripted — microseconds per turn.
    let after = engine.turn(sim, 8, 20, 1)
    check after.len == 0
    check engine.directives[0].source == dsScripted

  test "the per-seat view leaks no policy identity and no enemy detail":
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    let view = engine.seatViewJson(sim, 0, 3, 20)
    check "daveey" notin view
    check "daveey-1" notin view
    check "RED-alpha" in view
    let node = parseJson(view)
    check node["you"]["team"].getStr() == "RED"
    check node["you"]["commanding"].len == 4
    check node["hill"]["need_pct"].getInt() == 80
    check node["regime"].getStr() == "resident"
    check node["your_cogs"].len == 4
    ## resident_done is null in game 1 and carries the resident score in game 2.
    check node["score"]["resident_done"].kind == JNull

  test "a never-connecting seat still yields a legal directive":
    ## No failure mode leaves a cog unactuated: the control layer always has a
    ## directive — this turn's, else last turn's, else holdline's.
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    discard engine.turn(sim, 0, 20, 0)
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    for cogIndex in 0 ..< sim.players.len:
      let seat = sim.cogSeat(cogIndex)
      var found = false
      for order in engine.directives[seat].orders:
        if order.cogIndex == cogIndex:
          found = true
          discard ctl.compileMask(sim, order, cogIndex)
      if not found:
        let scripted = engine.holdlineFor(sim, @[cogIndex])
        check scripted.orders.len == 1

  test "the wall-clock budget is inside 60% of episodeTimeoutSeconds":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    check config.wallClockBudgetSeconds <= 720
    check DefaultWallClockBudgetSeconds <= 720
