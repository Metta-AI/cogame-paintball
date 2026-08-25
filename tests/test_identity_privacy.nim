## The two-name-space pin, asserted from BOTH sides: a seat's frame and the
## composed LLM messages must never carry a policy address, and the spectator
## surfaces must.
import std/[json, strutils, unittest]
import paintball/[global, broadcast]
import helpers

const Sentinel = "daveey"
const Sentinel2 = "daveey-1"

proc seatFrameText(sim: var SimServer, seat: int): string =
  ## Every sprite LABEL in one seat's frame, concatenated. Labels are the only
  ## text a seat's binary frame carries, so this is the whole attack surface.
  var next: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(
    seat, initPlayerViewerState(), next)
  result = ""
  for byteValue in packet:
    let ch = char(byteValue)
    if ch in {' ' .. '~'}:
      result.add(ch)
    else:
      result.add(' ')

suite "identity privacy":
  test "a seat's frame never contains a policy address":
    var sim = newPaintballSim()
    for seat in 0 .. 1:
      let text = sim.seatFrameText(seat)
      check Sentinel notin text
      check Sentinel2 notin text

  test "the composed LLM system + user message never contains one":
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    for seat in 0 .. 1:
      let composed = SystemPrompt &
        userMessage("own the hill", engine.seatViewJson(sim, seat, 0, 20))
      check Sentinel notin composed
      check Sentinel2 notin composed
      ## But the cogs' anonymous aliases ARE there — that is the name space a
      ## commander is given.
      check "RED-alpha" in composed or "BLUE-alpha" in composed

  test "a directive record carries aliases, never a policy address":
    var sim = newPaintballSim()
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    for seat in 0 .. 1:
      let directive = scriptedDirective(
        ctl, sim, blHoldline, sim.commandedCogs(seat))
      let record = directive.boundedDirectiveRecord(
        1, 0, seat, teamText(sim.teamForSlot(seat)), regimeText(sim.regime))
      check Sentinel notin record
      check Sentinel2 notin record
      check "-alpha" in record

  test "the broadcast roster, team policies and results DO carry the real names":
    ## The other half of the pin: the spectator side must be able to say who
    ## is playing, or the league is unwatchable.
    var sim = newPaintballSim()
    let frame = parseJson(sim.buildStateJson(
      newJArray(), true, 1, 100, false, true, -1, -1))
    var rosterNames: seq[string]
    for entry in frame["roster"]:
      rosterNames.add(entry["name"].getStr())
      ## And every roster entry also carries the cog's anonymous alias.
      check "-" in entry["alias"].getStr()
    check Sentinel in rosterNames
    check Sentinel2 in rosterNames
    var policies: seq[string]
    for team in ["red", "blue"]:
      for policy in frame["teams"][team]["policies"]:
        policies.add(policy.getStr())
    check Sentinel in policies
    check Sentinel2 in policies
    let results = parseJson(sim.playerResultsJson())
    check results["names"][0].getStr() == Sentinel
    check results["names"][1].getStr() == Sentinel2
    ## `team` carries the in-game aliases, never a policy name.
    check results["team"][0].getStr() == "red"

  test "a shout is labelled with the shouter's anonymous slot name":
    var sim = newPaintballSim()
    check sim.applyShout(0, "on hill")
    check sim.recentShouts.len == 1
    let label = sim.shoutIdentityName(sim.recentShouts[0])
    check label in IdentityNames
    check Sentinel notin label
