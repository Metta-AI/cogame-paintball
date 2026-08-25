## The worst-case renderer fixture's frame — built by the SIM, so the browser
## half tests what the game really draws.
##
## Checklist item 15 asks a repo whose viewer draws model-authored text for a
## fixture that hands the real renderer "a frame built to hurt". Here that
## frame is: every cog on the board shouting the FULL shout cap
## (ShoutMaxChars runes of the widest glyph) in the same tick, standing on the
## worst positions the arena has — the top row, where the bubble grows off the
## frame if nothing clamps it, and the two top corners.
##
## Paintball's bubbles are rasterised into sprites in Nim, so a browser
## `fillText` hook counts zero of them (`viewer_smoke.mjs` says so itself:
## "total: 0 means the check covered nothing"). This tool therefore writes what
## a browser CAN check:
##
##   text_fixture_shout.bin   the real Sprite v1 board packet for that frame
##   text_fixture_quiet.bin   the identical frame with nothing shouting
##   text_fixture.json        the strings, the shout cap, the board size, and
##                            each bubble's expected map-space rect, straight
##                            out of the draw pass's own geometry
##
## `replay-viewer/text_fixture.html` renders both packets through the real
## `broadcast_core.js` at several canvas sizes and proves, per bubble, that the
## rect is inside the frame AND that the frame really changed inside it — a
## bubble clipped to a sliver fails on pixels, not on eyesight.
##
##   nim c -r --path:src tools/record_text_fixture.nim <out-dir>

import
  std/[json, os, strutils],
  paintball/[sim, global]

const
  FullCap = "WWWWWWWWWW"   ## ShoutMaxChars of the widest printable glyph.
  ConfigJson = """{
    "seed": 679961, "num_agents": 2, "minPlayers": 2, "cogsPerTeam": 4,
    "maxTicks": 600, "maxGames": 1, "regimes": ["resident"], "lives": 12,
    "hitPoints": 3, "sprayDamage": 1, "respawnTicks": 48, "mapPath": "arena",
    "loadout": "paintball", "floorPaint": true, "paintBuff": true,
    "hill": true, "turnTicks": 108, "turnSpacingMs": 0, "startWaitTicks": 0,
    "gameOverTicks": 4, "lobbyJoinTimeoutTicks": 0, "fastMode": true,
    "showPlayerLabels": false, "tokens": ["t0", "t1"],
    "players": [{"name": "Red Command"}, {"name": "Blue Command"}],
    "slots": [{"team": "red"}, {"team": "blue"}]
  }"""

proc newFixtureSim(): SimServer =
  var config = defaultGameConfig()
  config.update(ConfigJson)
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("Red Command", 0, "t0")
  discard result.addPlayer("Blue Command", 1, "t1")
  for order in 2 ..< result.totalCogs():
    discard result.addPlayer(
      toUpperAscii(teamText(result.teamForSlot(order))) & "-" &
      IdentityNames[result.slotIdentityIndex(order)],
      order, "", trusted = true)
  result.startGame()

proc placeWorstCase(sim: var SimServer) =
  ## The positions that hurt: the top row and the two top corners, spread so
  ## every bubble is visible rather than stacked into one pile.
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
    spots = [
      (0, 0), (w div 4, 0), (w div 2, 0), (3 * w div 4, 0), (w - 1, 0),
      (0, h div 2), (w - 1, h div 2), (w div 2, h - 1)
    ]
  for cogIndex in 0 ..< sim.players.len:
    let spot = spots[cogIndex mod spots.len]
    sim.placePlayer(cogIndex, spot[0], spot[1])
    sim.players[cogIndex].alive = true

proc boardPacket(sim: var SimServer): seq[uint8] =
  ## One full board frame for a fresh spectator — the same call the live server
  ## and the wasm viewer make, with an empty viewer state so the packet is
  ## self-contained (every sprite definition and object placement included).
  ## initGlobalViewerState, not a zeroed object: the zero value has
  ## selectedJoinOrder 0, which the builder reads as "this viewer has a POV
  ## selected" and answers with a player stream instead of the board.
  var
    state = initGlobalViewerState()
    nextState = initGlobalViewerState()
  sim.buildSpriteProtocolUpdates(state, nextState)

when isMainModule:
  let outDir =
    if paramCount() >= 1: paramStr(1) else: "replay-viewer/dist"
  createDir(outDir)

  ## The quiet frame first: identical board, nothing shouting.
  var quiet = newFixtureSim()
  quiet.placeWorstCase()
  let quietPacket = quiet.boardPacket()

  ## Then the same frame with every cog at the cap.
  var loud = newFixtureSim()
  loud.placeWorstCase()
  var rects = newJArray()
  var says = newJArray()
  for cogIndex in 0 ..< loud.players.len:
    ## Through the server's own shout path, so the fixture cannot carry a
    ## string the game would have refused or shortened.
    loud.players[cogIndex].lastShoutTick = -1
    if not loud.applyShout(cogIndex, FullCap):
      quit("record_text_fixture: the sim refused a full-cap shout for cog " &
        $cogIndex)
    let rect = loud.shoutBubbleRectFor(cogIndex, FullCap)
    rects.add(%*{
      "cog": cogIndex,
      "alias": loud.cogAlias(cogIndex),
      "x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h
    })
    var said = ""
    for shout in loud.recentShouts:
      if shout.address == loud.players[cogIndex].address:
        said = shout.text
    says.add(%said)
  let loudPacket = loud.boardPacket()

  writeFile(outDir / "text_fixture_quiet.bin", cast[string](quietPacket))
  writeFile(outDir / "text_fixture_shout.bin", cast[string](loudPacket))
  writeFile(outDir / "text_fixture.json", (%*{
    "cap": ShoutMaxChars,
    "text": FullCap,
    "map": {"w": loud.gameMap.width, "h": loud.gameMap.height},
    "boardScale": boardRenderScaleFor(loud.gameMap.width, loud.gameMap.height),
    "reservedBandPx": loud.shoutBubbleMaxHeight(),
    "says": says,
    "bubbles": rects
  }).pretty & "\n")
  echo "record_text_fixture: ", loud.players.len, " full-cap bubbles, ",
    loudPacket.len, " packet bytes (quiet ", quietPacket.len, "), board ",
    loud.gameMap.width, "x", loud.gameMap.height, " -> ", outDir
