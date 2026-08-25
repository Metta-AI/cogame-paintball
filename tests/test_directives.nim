## Tolerant parsing and repair, and the RUNE-boundary truncation rule.
import std/[json, strutils, unicode, unittest]
import curly
import helpers

const
  Ids = @["RED-alpha", "RED-beta", "RED-gamma", "RED-delta"]
  Cogs = @[0, 2, 4, 6]
  HillX = 617
  HillY = 329
  MaxX = 1234
  MaxY = 658

proc parse(text: string): SquadDirective =
  parseSquadDirective(extractJsonObject(text), Ids, Cogs, HillX, HillY, MaxX, MaxY)

suite "directive parsing":
  test "prose-prefixed and fenced JSON both parse":
    let prose = """Sure! Here is my plan.
```json
{"note":"push west","cogs":[{"id":"RED-alpha","intent":"hold_hill","target":[600,300]}]}
```
Hope that helps."""
    let directive = parse(prose)
    check directive.note == "push west"
    check directive.orders[0].intent == intHoldHill
    check directive.orders[0].targetX == 600

  test "cogs as an id-keyed object":
    let text = """{"note":"n","cogs":{
      "RED-alpha":{"intent":"hunt","target":[100,100]},
      "RED-beta":{"intent":"guard","target":[200,200]}}}"""
    let directive = parse(text)
    check directive.orders[0].intent == intHunt
    check directive.orders[1].intent == intGuard

  test "unknown intents repair to paint_hill":
    let directive = parse("""{"cogs":[{"id":"RED-alpha","intent":"nuke_them"}]}""")
    check directive.orders[0].intent == intPaintHill
    ## And a case/hyphen variant is accepted rather than repaired away.
    let ok = parse("""{"cogs":[{"id":"RED-alpha","intent":"Paint-Path"}]}""")
    check ok.orders[0].intent == intPaintPath

  test "absent, non-finite and off-map targets":
    let missing = parse("""{"cogs":[{"id":"RED-alpha","intent":"hunt"}]}""")
    check missing.orders[0].targetX == HillX
    check missing.orders[0].targetY == HillY
    let nan = parse(
      """{"cogs":[{"id":"RED-alpha","target":["not a number","x"]}]}""")
    check nan.orders[0].targetX == HillX
    let offMap = parse("""{"cogs":[{"id":"RED-alpha","target":[99999,-4000]}]}""")
    check offMap.orders[0].targetX == MaxX
    check offMap.orders[0].targetY == 0
    ## Numeric strings are accepted (models emit them).
    let stringy = parse("""{"cogs":[{"id":"RED-alpha","target":["120","240"]}]}""")
    check stringy.orders[0].targetX == 120
    check stringy.orders[0].targetY == 240

  test "a target inside a wall is snapped by the control layer, not rejected":
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    let order = CogOrder(cogIndex: 0, id: "RED-alpha", intent: intGuard,
                         targetX: 1, targetY: 1)
    let cell = ctl.grid.nearestOpenCell(order.targetX, order.targetY)
    check cell >= 0
    check ctl.grid.open[cell]

  test "five cogs drops the extra; zero cogs is the one fatal case":
    let five = parse("""{"cogs":[
      {"id":"RED-alpha"},{"id":"RED-beta"},{"id":"RED-gamma"},
      {"id":"RED-delta"},{"id":"RED-epsilon"}]}""")
    check five.orders.len == 4
    expect DirectiveError:
      discard parse("""{"note":"nothing","cogs":[]}""")
    expect DirectiveError:
      discard parse("""{"note":"nothing"}""")

  test "an id from the other team is assigned by position":
    let directive = parse("""{"cogs":[{"id":"BLUE-delta","intent":"guard"}]}""")
    check directive.orders[0].id == "RED-alpha"
    check directive.orders[0].intent == intGuard

  test "a 300-character note is cut to 160 RUNES":
    let long = repeat("x", 300)
    let directive = parse("""{"note":"""" & long &
      """","cogs":[{"id":"RED-alpha"}]}""")
    check directive.note.runeLen == MaxNoteRunes

  test "a say whose 10th and 11th characters are a 4-byte emoji cuts on the rune":
    ## The pinned case: nine ASCII characters, then an astral emoji straddling
    ## the boundary. A BYTE cut here leaves half a codepoint, which renders in
    ## a browser and then fails a strict UTF-8 parser.
    let raw = "abcdefghi\u{1F600}\u{1F600}"
    check raw.runeLen == 11
    let say = sanitizeSay(raw)
    ## The emoji is not printable ASCII, so the shout filter drops it — but the
    ## cut that preceded it landed on a rune boundary, so what remains is
    ## valid UTF-8 and round-trips through the JSON codec.
    check say == "abcdefghi"
    let roundTrip = parseJson($(%*{"say": say}))
    check roundTrip["say"].getStr() == say
    check validateUtf8(say) == -1
    ## And a note of pure astral characters cut at the cap is still valid UTF-8.
    let astral = repeat("\u{1F600}", 300)
    let cut = truncateRunes(astral, MaxNoteRunes)
    check cut.runeLen == MaxNoteRunes
    check validateUtf8(cut) == -1
    check parseJson($(%*{"note": cut}))["note"].getStr() == cut

  test "the serialized directive record stays inside its rune cap":
    var directive = SquadDirective(source: dsLlm, note: repeat("n", 400))
    for i, id in Ids:
      directive.orders.add(CogOrder(
        cogIndex: Cogs[i], id: id, intent: intPaintHill,
        targetX: HillX, targetY: HillY, say: repeat("s", 40)))
    let record = directive.boundedDirectiveRecord(1, 3, 0, "red", "resident")
    check record.runeLen <= MaxDirectiveRunes
    check parseJson(record)["k"].getStr() == "directive"

  test "a shout can never be mistaken for a control record":
    ## The replay chat stream tells cog shouts from paintball control records
    ## by a leading '{'; sanitizeSay must therefore never emit one.
    check sanitizeSay("{\"k\":x") == "\"k\":x"
    check not sanitizeSay("{}{}{}{}{}").startsWith("{")

  test "two consecutive failures leave the holdline directive":
    var sim = newPaintballSim()
    var engine = DecisionEngine(ctl: initControlState(sim))
    engine.seats = newSeq[SeatPolicy](2)
    engine.directives = newSeq[SquadDirective](2)
    engine.haveDirective = newSeq[bool](2)
    let fallback = engine.holdlineFor(sim, sim.commandedCogs(0))
    check fallback.orders.len == 4
    check fallback.source == dsScripted
    for order in fallback.orders:
      check order.cogIndex in sim.commandedCogs(0)

  test "a provider error body is cut on a RUNE boundary, never a byte":
    ## The one string on the path to the replay that is NOT authored here: an
    ## arbitrary provider body, quoted into `fallback.detail`. A byte slice at
    ## the cap can cut a multi-byte codepoint in half, and the downstream
    ## truncateRunes only shortens — it cannot repair one. So the cut happens
    ## once, in runes, where the body is first quoted.
    var client = LlmClient(transport: ltAnthropic)
    ## 4-byte emoji straddling every plausible byte cap.
    let body = repeat("\u{1F600}", 400)
    var raised = ""
    try:
      discard client.textOf(Response(code: 429, body: body), "", "url")
    except LlmError as error:
      raised = error.msg
    check raised.len > 0
    check validateUtf8(raised) == -1
    check raised.runeLen <= MaxFallbackDetailRunes + 40
    check parseJson($(%*{"detail": raised}))["detail"].getStr() == raised
    ## The same for the auth path, which quotes the body at its own cap.
    var authClient = LlmClient(transport: ltAnthropic)
    raised = ""
    try:
      discard authClient.textOf(Response(code: 403, body: body), "", "url")
    except LlmError as error:
      raised = error.msg
    check validateUtf8(raised) == -1
    check parseJson($(%*{"detail": raised}))["detail"].getStr() == raised
