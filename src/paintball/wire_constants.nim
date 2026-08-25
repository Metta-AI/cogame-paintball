## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with (playback speeds, fps, the chrome sprite id, shot
## FX tuning). Historically each HTML client re-typed these as literals and
## nothing enforced agreement — a retuned PlaybackSpeeds would silently
## desync every client. This module renders them ONCE, from the same Nim
## consts the engine runs on; server.nim splices the block into every served
## client page, and tools/gen_wire_constants.nim emits it for the static
## wasm bundle. Clients read `window.PAINTBALL_WIRE` and keep their old literals
## only as fallbacks for raw file:// opens of the un-spliced sources.

import std/strutils
import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.PAINTBALL_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:" & $ShotFxTicks &
  ",shotTrailFalloff:" & $TrailFalloff &
  "};" &
  ## chrome_common.js is inherited BYTE-FOR-BYTE from coworld-ctf (the design
  ## note's chrome-provenance pin, asserted by a sha256 in tests/test_viewer.nim),
  ## and that file reads its wire block off the starter's global name. Rather
  ## than edit a file the pin says must not change, the generated block also
  ## publishes the legacy alias. This one line is the ONLY place the starter's
  ## wire global survives in paintball's own source.
  "window.CTF_WIRE=window.PAINTBALL_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder both client HTML files carry where the block belongs
  ## (before any script that reads window.PAINTBALL_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
