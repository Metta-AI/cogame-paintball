## Startup and config hygiene: a bad runtime config fails cleanly, the seed is
## randomised when unpinned, and both entrypoints exist.
import std/[json, os, strutils, unittest]
import helpers

suite "startup":
  test "an unparseable config raises a clean PaintballError, not a traceback":
    var config = defaultGameConfig()
    expect PaintballError:
      config.update("{not json")
    var other = defaultGameConfig()
    expect PaintballError:
      other.update("[1, 2, 3]")

  test "an out-of-range paintball field is rejected with a named message":
    var config = defaultGameConfig()
    try:
      config.update("""{"hillOwnPermille": 400}""")
      check false
    except PaintballError as error:
      check "hillOwnPermille" in error.msg
    var second = defaultGameConfig()
    try:
      second.update("""{"loadout": "lasertag"}""")
      check false
    except PaintballError as error:
      check "loadout" in error.msg
    var third = defaultGameConfig()
    try:
      third.update("""{"regimes": ["resident", "sightseeing"]}""")
      check false
    except PaintballError as error:
      check "regimes" in error.msg

  test "paintBuff and hill both require floorPaint":
    var config = defaultGameConfig()
    expect PaintballError:
      config.update("""{"paintBuff": true, "floorPaint": false}""")
    var second = defaultGameConfig()
    expect PaintballError:
      second.update("""{"hill": true, "floorPaint": false}""")

  test "a pinned seed is honoured and echoed into the replay config":
    var config = defaultGameConfig()
    config.update(paintballConfigJson(seed = 424242))
    check config.seed == 424242
    let echoed = parseJson(config.configJson())
    check echoed["seed"].getInt() == 424242
    ## Every paintball field the viewer re-derives from must be in the echo.
    for key in ["num_agents", "cogsPerTeam", "loadout", "floorPaint",
                "paintBuff", "hill", "paintTile", "hillRadiusTiles",
                "hillOwnPermille", "hillDecisiveTicks", "paintSpeedOwnPct",
                "paintSpeedEnemyPct", "paintHealTicks", "sprayDamage",
                "regimes", "turnTicks", "wallClockBudgetSeconds"]:
      check echoed.hasKey(key)
    check echoed["regimes"][0].getStr() == "resident"

  test "the config echo round-trips through update unchanged":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    var round = defaultGameConfig()
    round.update(config.configJson())
    check round.configJson() == config.configJson()

  test "the gate-off default is the starter's game, untouched":
    let config = defaultGameConfig()
    check config.loadout == LoadoutCtf
    check not config.floorPaint
    check not config.paintBuff
    check not config.hill
    check config.sprayDamage == SprayPaintDamage
    check config.numAgents == 0

  test "the paintball loadout places NO pickups at all":
    ## Design §Loadout 3: grenades, med kits, shields, spray cans and cardboard
    ## barriers are skipped. The pickup/update path was already skipped, so
    ## nothing could be TAKEN — but the spawns were still drawn on the board and
    ## listed to the seats, so the picture and the LLM's view carried objects
    ## the rules do not have.
    var sim = newPaintballSim()
    check sim.paintballLoadout()
    check sim.medKitSpawns.len == 0
    check sim.shieldSpawns.len == 0
    check sim.sprayPaintSpawns.len == 0
    check sim.barrierSpawns.len == 0
    for spawn in sim.grenadeSpawns:
      check not spawn.present
    ## Every consumer keys off `present` / the family length — the seats'
    ## first-person item list (broadcast.firstPersonJson), the spectator's map
    ## items (broadcast.rosterJson) and all five board draw passes — so an
    ## empty family is the one place that makes them all agree with the rules.
    ## And the cog still holds its can: the loadout issues it for good.
    check sim.players[0].hasSprayPaint

  test "the ctf loadout still places the starter's pickups":
    ## The gate composes: a gate-off config plays the starter's rules, which is
    ## what keeps the inherited engine meaningful.
    var sim = newPaintballSim(paintballConfigJson(
      paintBuff = false, hill = false, floorPaint = false, loadout = "ctf"))
    check not sim.paintballLoadout()
    check sim.medKitSpawns.len > 0
    check sim.shieldSpawns.len > 0
    var anyGrenade = false
    for spawn in sim.grenadeSpawns:
      if spawn.present:
        anyGrenade = true
    check anyGrenade

  test "both entrypoints are declared in the Dockerfile and the manifest":
    let dockerfile = readFile("Dockerfile")
    check "src/paintball.nim" in dockerfile
    check "src/paintball_player.nim" in dockerfile
    check "/bin/paintball\"" in dockerfile or "/bin/paintball " in dockerfile
    check "/bin/paintball-player" in dockerfile
    let manifest = parseJson(readFile("coworld_manifest_template.json"))
    check manifest["game"]["runnable"]["run"][0].getStr() == "/bin/paintball"
    check manifest["player"][0]["run"][0].getStr() == "/bin/paintball-player"

  test "the CI scaffold is present and the hooks are executable":
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh", "tools/ci/viewer_smoke.mjs",
                 "tools/ci/policies.json", "tools/build_replay_viewer.sh",
                 "tools/replay_summary.py"]:
      check fileExists(path)
    when defined(posix):
      for path in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"]:
        check (getFilePermissions(path) * {fpUserExec, fpGroupExec, fpOthersExec}).len > 0

  test "no unsubstituted scaffold placeholder survives":
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh", "tools/ci/policies.json"]:
      let body = readFile(path)
      check "<slug>" notin body
      check "<IMAGE>" notin body
      check "<SEATS>" notin body
