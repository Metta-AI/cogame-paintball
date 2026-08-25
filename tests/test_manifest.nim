## The manifest contract. The certifier validates every variant and the
## certification fixture against config_schema (additionalProperties: false)
## and rejects any results key the schema does not name, so these are the
## assertions that stop a phase-40 surprise.
import std/[json, os, strutils, unittest]
import helpers

const
  ManifestPath = "coworld_manifest_template.json"
  ComposePath = "compose.yaml"
  ProtocolPath = "docs/PROTOCOL.md"
  Image = "coworld-paintball"
  Placeholder = "{{PAINTBALL_IMAGE}}"
  Seats = 2
  EpisodeTimeoutSeconds = 1200

suite "coworld manifest":
  let manifest = parseJson(readFile(ManifestPath))
  let game = manifest["game"]

  test "num_agents is 2 in EVERY variant and in the certification fixture":
    check manifest["variants"].len == 4
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == Seats
      check variant.hasKey("description")
      check variant["description"].getStr().len > 0
    check manifest["certification"]["game_config"]["num_agents"].getInt() == Seats
    check manifest["certification"]["players"].len == Seats

  test "every declared player occupies a certification slot":
    ## The raid 0.1.2 `players_missing` scar: a fixture that names fewer
    ## players than the manifest declares fails cert outright.
    var declared: seq[string]
    for player in manifest["player"]:
      declared.add(player["id"].getStr())
    var seated: seq[string]
    for slot in manifest["certification"]["players"]:
      seated.add(slot["player_id"].getStr())
    for id in declared:
      check id in seated

  test "results_schema names exactly the keys playerResultsJson writes":
    var sim = newPaintballSim()
    var half: array[Team, int]
    half[Red] = 600
    half[Blue] = 300
    sim.gameHill = @[half]
    sim.gameRegimes = @[regimeResident]
    let
      produced = parseJson(sim.playerResultsJson())
      schema = game["results_schema"]
    check schema["additionalProperties"].getBool() == false
    var schemaKeys: seq[string]
    for key in schema["properties"].keys:
      schemaKeys.add(key)
    var producedKeys: seq[string]
    for key in produced.keys:
      producedKeys.add(key)
    for key in producedKeys:
      check key in schemaKeys
    for key in schemaKeys:
      check key in producedKeys
    var required: seq[string]
    for value in schema["required"]:
      required.add(value.getStr())
    for key in ["names", "scores", "win", "team", "reason", "endRule"]:
      check key in required

  test "the reason and endRule enums are the closed sets the sim can emit":
    let props = game["results_schema"]["properties"]
    var reasons: seq[string]
    for value in props["reason"]["enum"]:
      reasons.add(value.getStr())
    check reasons == @[ReasonComplete, ReasonDeadline, ReasonFault]
    var rules: seq[string]
    for value in props["endRule"]["enum"]:
      rules.add(value.getStr())
    for rule in [EndRuleFullTime, EndRuleMercy, EndRuleWipe, EndRuleWallClock,
                 EndRuleSimFault, EndRuleHostError]:
      check rule in rules

  test "every config key a variant or the fixture uses is in config_schema":
    ## This is the real constraint: the CLI validates each game_config against
    ## config_schema with additionalProperties false, injecting `tokens`.
    let props = game["config_schema"]["properties"]
    check game["config_schema"]["additionalProperties"].getBool() == false
    var required: seq[string]
    for value in game["config_schema"]["required"]:
      required.add(value.getStr())
    for key in ["tokens", "players"]:
      check key in required
    var configs = @[manifest["certification"]["game_config"]]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    for config in configs:
      for key in config.keys:
        check props.hasKey(key)

  test "every ARRAY property in config_schema declares minItems and maxItems":
    ## The tandem 0.1.0 scar: cert fails `manifest_invalid` otherwise.
    let props = game["config_schema"]["properties"]
    for key, prop in props:
      if prop{"type"}.getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "game.protocols carries BOTH player and global, in object form":
    ## The garble v0.1.0 scar: a bare string fails the platform validator and
    ## repo CI does not catch it.
    for key in ["player", "global"]:
      check game["protocols"].hasKey(key)
      check game["protocols"][key]["type"].getStr() == "text"
      check game["protocols"][key]["value"].getStr().len > 200

  test "game.docs has a non-empty text readme and all three pages":
    check game["docs"]["readme"]["type"].getStr() == "text"
    check game["docs"]["readme"]["value"].getStr().len > 200
    var ids: seq[string]
    for page in game["docs"]["pages"]:
      ids.add(page["id"].getStr())
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200
    check ids == @["rules", "protocol", "commanding"]

  test "the replay viewer is the STATIC bundle, never a pod":
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"

  test "nothing shipped declares or serves a /client/replay pod path":
    ## Checklist item 3: "the viewer contacts nothing but S3. No
    ## /client/replay pod path anywhere." The starter served the broadcast page
    ## at bitworld's replay routes and the protocol doc declared them as part
    ## of the contract; both are gone, so the manifest a certifier reads and
    ## the server it probes agree with the static bundle it declares.
    check "/client/replay" notin readFile(ProtocolPath)
    check "/client/replay" notin $manifest["game"]["protocols"]
    check "/client/replay" notin $manifest["game"]["docs"]
    ## And the server registers no replay page: the two bitworld replay-page
    ## routes, the league shell route and the embedded page they served are all
    ## gone. Comment lines are stripped first — the file explains the removal
    ## and that explanation must not read as evidence of the route.
    var server = ""
    for line in readFile("src/paintball/server.nim").splitLines():
      if line.strip().startsWith("#"):
        continue
      server.add(line & "\n")
    check "ReplayClientRoute" notin server
    check "CoworldReplayClientRoute" notin server
    check "EmbeddedBroadcastReplayHtml" notin server
    check "EmbeddedLeagueReplayerHtml" notin server
    check "/client/league" notin server
    check "/client/replay" notin server

  test "every variant settles inside 60% of episodeTimeoutSeconds":
    for variant in manifest["variants"]:
      let budget = variant["game_config"]["wallClockBudgetSeconds"].getInt()
      check budget <= EpisodeTimeoutSeconds * 6 div 10

  test "each variant's worst-case wall clock fits inside its own stop":
    ## The v1.1 timing amendment's arithmetic, recomputed per variant instead
    ## of asserted once in prose. A turn that blows BOTH deadlines costs
    ## attempt1Ms + retryMs; the spacing floor cannot add to that turn (it
    ## floors the START of consecutive batches, and a 9 s turn is already past
    ## the 5 s floor). Everything else is the note's cap column: the lobby
    ## join cap, wall-paced play, and the game-over/results/replay tail.
    let defaults = defaultGameConfig()
    check defaults.attempt1Ms + defaults.retryMs == 9000
    const
      LobbyCapSeconds = 100        ## 2400 lobby ticks at 24 Hz
      PlayCapSeconds = 180         ## 2 x 2160 ticks, wall-paced worst case
      TailSeconds = 20             ## game-over holds + results + replay write
    for variant in manifest["variants"]:
      let
        cfg = variant["game_config"]
        turnsPerGame = cfg["maxTicks"].getInt() div cfg["turnTicks"].getInt()
        turns = turnsPerGame * cfg["maxGames"].getInt()
        worstTurnMs = max(
          defaults.attempt1Ms + defaults.retryMs, cfg["turnSpacingMs"].getInt())
        worstSeconds = turns * worstTurnMs div 1000 +
          LobbyCapSeconds + PlayCapSeconds + TailSeconds
      check turns <= 40
      check worstTurnMs <= cfg["turnBudgetMs"].getInt()
      echo variant["id"].getStr(), ": ", turns, " turns, worst case ",
        worstSeconds, " s vs stop ",
        cfg["wallClockBudgetSeconds"].getInt(), " s"
      check worstSeconds <= cfg["wallClockBudgetSeconds"].getInt()
      check worstSeconds <= EpisodeTimeoutSeconds * 6 div 10

  test "the compose service and image agree with the manifest placeholder":
    ## Manifest image placeholders are DERIVED from compose service names
    ## (lantern 0.1.0), so a mismatch fails `coworld build` outright.
    let compose = readFile(ComposePath)
    check "  paintball:" in compose
    check "image: " & Image & ":latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    check game["runnable"]["image"].getStr() == Placeholder
    for player in manifest["player"]:
      check player["image"].getStr() == Placeholder

  test "game.name has no underscore and matches the secret namespace":
    ## The cooperative-hunting 2026-08-25 scar: the secret namespace must equal
    ## game.name exactly, and upload 400s otherwise after a green certify.
    let name = game["name"].getStr()
    check name == "paintball"
    check "_" notin name
    check game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & name & "/anthropic_api_key"
    check game["runnable"]["type"].getStr() == "game"
    check game["runnable"]["run"][0].getStr() == "/bin/paintball"

  test "the top-level upload contract fields are present":
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    check manifest["episode_timeout_minutes"].getInt() == 20

  test "the policy set is two LLM champions plus two scripted fillers":
    let policies = parseJson(readFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts, scripted = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/paintball-player"
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in
          ["holdline", "sprayer"]
    check prompts == 2
    check scripted == 2
    ## Champion #2 must be uploaded as daveey-1 or phase 50 409s.
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"

  test "the cert fixture plays longer than any viewer soak window":
    ## The ecos 2026-08-23 scar: a replay shorter than the soak reads as frozen.
    let cfg = manifest["certification"]["game_config"]
    let ticks = cfg["maxTicks"].getInt() * cfg["maxGames"].getInt()
    check ticks >= 1200                        ## 50 s of playback at 24 fps
    check cfg["turnSpacingMs"].getInt() == 0   ## no rate floor offline
