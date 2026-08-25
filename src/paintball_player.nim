## The paintball player container: a policy is just a prompt.
##
## This process is DELIBERATELY thin. It connects to its seat, sends ONE
## Sprite v1 chat message carrying its registration, and then only receives.
## Every decision happens inside the GAME server, because that is the only
## container the platform injects the `anthropic_api_key` coworld secret
## into, and because keeping the control layer server-side is what makes the
## recorded mask log reproducible with no network in the loop.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      holdline | sprayer         -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `holdline`. To field your own policy, reuse
## this image and set PLAYER_PROMPT:
##
##   coworld upload-policy <paintball-image> --name my-paintball \
##     --run /bin/paintball-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  bitworld/spriteprotocol,
  whisky

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500

proc registrationBlob(prompt, scripted, policy: string): string =
  ## The one registration message. `scripted` is JSON null when the seat is
  ## an LLM seat, so the server can tell "no baseline named" from "holdline
  ## named explicitly".
  var node = %*{
    "type": "register",
    "prompt": prompt,
    "policy": policy
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  blobFromSpriteChat($node)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every actuator mask), so the dead-reckoning hazard
  ## docs/PROTOCOL.md warns about cannot arise, and a fastMode server can
  ## advance the tick as soon as both seats have acknowledged the frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "holdline"
  echo "paintball player: kind=",
    (if prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "holdline"),
    " label=", label

  # The game bakes its supersampled board render caches BEFORE it opens the
  # listener (a viewer's first-message clock starts at connect, so nothing may
  # be accepted until every frame can be assembled instantly). The episode
  # runner starts the players at the same instant as the game, so the first
  # dial always lands on a closed port: RETRY, bounded, until the seat exists.
  var
    socket: WebSocket = nil
    everConnected = false
  for attempt in 0 ..< ConnectAttempts:
    try:
      socket = newWebSocket(url)
      everConnected = true
      break
    except CatchableError as error:
      if attempt == 0:
        echo "paintball player: game not listening yet (", error.msg,
          "); retrying"
      sleep(ConnectRetryMs)
  if not everConnected:
    quit("paintball player: game never accepted a connection", 1)
  echo "paintball player: connected"

  # From here the whole session is wrapped: whisky's receiveMessage RAISES on a
  # close frame or a truncated read (only a timeout returns none), and mummy's
  # send only QUEUES — so the game's own quit(0) can outrun the flushed frame.
  # A naive player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  try:
    socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
    var resent = false
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        continue                      ## a read timeout, not a closed socket
      if not resent:
        # Re-send once after the first received frame, in case the first send
        # raced the server's slot registration.
        resent = true
        socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
      socket.send(readyBlob(), BinaryMessage)
  except CatchableError as error:
    echo "paintball player: socket closed (", error.msg, "), exiting cleanly"
  quit(0)
