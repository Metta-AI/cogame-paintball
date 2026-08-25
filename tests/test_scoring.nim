## The scoring formula and its sign. Everything here is permille integers, so
## the two seats' scores sum to EXACTLY 1000 for every legal outcome — a
## property a float mean would only nearly have.
import std/[json, random, unittest]
import helpers

suite "scoring":
  test "gameScore is 1.0 at +decisive, 0.0 at -decisive and 0.5 at level":
    check gameScorePermille(720, 720) == 1000
    check gameScorePermille(-720, 720) == 0
    check gameScorePermille(0, 720) == 500
    ## Saturating, not wrapping: a bigger margin is still a 1.0.
    check gameScorePermille(5000, 720) == 1000
    check gameScorePermille(-5000, 720) == 0

  test "it is monotone in the margin":
    var previous = -1
    for margin in countup(-800, 800, 10):
      let score = gameScorePermille(margin, 720)
      check score >= previous
      previous = score

  test "the two seats' scores sum to exactly 1.0 over 10000 random pairs":
    var rng = initRand(20260825)
    for _ in 0 ..< 10_000:
      let
        residentMargin = rng.rand(-3000 .. 3000)
        visitorMargin = rng.rand(-3000 .. 3000)
        a = (gameScorePermille(residentMargin, 720) +
             gameScorePermille(visitorMargin, 720)) div 2
        b = (gameScorePermille(-residentMargin, 720) +
             gameScorePermille(-visitorMargin, 720)) div 2
      check a + b == 1000

  test "winning resident and losing visitor by the same margin scores 0.500":
    ## The property the resident/visitor mean exists to create: a policy that
    ## only works with clones of itself does NOT out-rank one that also works
    ## beside strangers.
    for margin in [60, 240, 719, 720, 1500]:
      let score = (gameScorePermille(margin, 720) +
                   gameScorePermille(-margin, 720)) div 2
      check score == 500

  test "win is exactly score > 0.5, and a fault is 0.5/0.5 with no winner":
    var sim = newPaintballSim()
    sim.endReason = ReasonFault
    sim.endRule = EndRuleSimFault
    sim.hillTicks[Red] = 900
    sim.hillTicks[Blue] = 0
    let results = parseJson(sim.playerResultsJson())
    check results["scores"][0].getFloat() == 0.5
    check results["scores"][1].getFloat() == 0.5
    check results["win"][0].getBool() == false
    check results["win"][1].getBool() == false
    check results["reason"].getStr() == ReasonFault

  test "the results document reports both halves separably":
    var sim = newPaintballSim(paintballConfigJson(
      maxTicks = 600, maxGames = 2, regimes = @["resident", "visitor"]))
    sim.gameHill = @[[900, 180], [200, 200]]
    sim.gameRegimes = @[regimeResident, regimeVisitor]
    sim.hillTicks = [0, 0]
    let results = parseJson(sim.playerResultsJson())
    check results["games"].getInt() == 2
    check results["residentScore"][0].getFloat() == 1.0
    check results["visitorScore"][0].getFloat() == 0.5
    check results["scores"][0].getFloat() == 0.75
    check results["scores"][1].getFloat() == 0.25
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["names"][0].getStr() == "daveey"
    check results["names"][1].getStr() == "daveey-1"
    check results["team"][0].getStr() == "red"
