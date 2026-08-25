## The STATIC half of the viewer smoke: no browser, just the guarantees the
## chrome-provenance pin makes about the three client files.
##
## The dynamic half — does the bundle actually draw a frame — is
## tools/ci/viewer_smoke.mjs in the wasm-viewer job, which opens the built
## bundle in headless chromium.
import std/[os, strutils, unittest]

const
  ChromeCommonFingerprint = "d26e0d29ae78e8f6"
    ## The coworld-ctf original, pinned so an edit to the inherited chrome
    ## fails a test instead of silently drifting.
  Page = "client/replay_broadcast.html"
  Chrome = "client/chrome_common.js"
  Core = "client/broadcast_core.js"

proc read(path: string): string = readFile(path)

proc fingerprint(text: string): string =
  ## FNV-1a 64 over the whole file, rendered as 16 hex digits. Deliberately
  ## dependency-free: pinning the inherited chrome must not add a package to
  ## nimby.lock, and any content change moves this value.
  var hash = 14695981039346656037'u64
  for ch in text:
    hash = hash xor uint64(ord(ch))
    hash = hash * 1099511628211'u64
  toHex(hash, 16).toLowerAscii()

suite "broadcast chrome":
  let page = read(Page)
  let chrome = read(Chrome)
  let core = read(Core)

  test "the inherited transport, scorebug, feed and endcard survive":
    for id in ["\"stage\"", "\"board\"", "\"lockerroom\"", "\"scorebug\"",
               "\"bannerlane\"", "\"killfeed\"", "\"fpv\"", "\"povBadge\"",
               "\"mmwarn\"", "\"transport\"", "\"endcard\"", "\"lightpool\"",
               "\"grain\"", "\"scrub\"", "\"speedchips\"", "\"tick-clock\"",
               "\"momentum\"", "\"btn-play\"", "\"btn-skip\"",
               "\"btn-spoilers\"", "\"clock-time\"", "\"clock-caption\""]:
      check ("id=" & id) in page or ("$(" & id & ")") in page or
        ("$('" & id.strip(chars = {'"'}) & "')") in page

  test "#viewpanel, #minimap and #zoombar are ABSENT":
    ## The board is the fixed 1235x659 arena and relayout() always fits it
    ## whole inside the frame, so per the design pin the zoom bar and minimap
    ## are removed, not hidden.
    check "id=\"viewpanel\"" notin page
    check "id=\"minimap\"" notin page
    check "id=\"zoombar\"" notin page
    check "id=\"minimap-canvas\"" notin page
    check "attachMinimap" notin page

  test "relayout owns --hudscale, --topband and --band on :root":
    check "function relayout()" in page
    check "root.style.setProperty('--hudscale'" in page
    check "root.style.setProperty('--topband'" in page
    check "root.style.setProperty('--band'" in page
    check "clamp(0.5" in page or "Math.max(0.5, Math.min(1.6" in page
    check "stage.classList.toggle('tiny', boardW <= 620)" in page

  test "the endcard stops at the transport band and every seek dismisses it":
    check "bottom: var(--band, 0px)" in page
    check "$('endcard').classList.remove('on')" in page

  test "the 360px legibility rules are present":
    check ".plate-name {" in page
    check "flex: 1 1 auto" in page
    check "min-width: 3.2em" in page
    check "#stage.tiny .pb-tags" in page
    check "#stage.tiny .plate .lives-label" in page

  test "every beat kind the sim emits has CSS, and beats are BUTTONS":
    for kind in [".beat-marker.gamestart", ".beat-marker.hillflip.red",
                 ".beat-marker.hillflip.blue", ".beat-marker.tagout.red",
                 ".beat-marker.tagout.blue", ".beat-marker.gameover"]:
      check kind in page
    check "button.beat-marker" in page
    check "createElement('button')" in page
    check "aria-label" in page
    ## The steal/return/capture rules went with the objective they belonged to.
    check ".beat-marker.steal" notin page
    check ".beat-marker.capture" notin page

  test "the game block is APPENDED under its banner, never a rewrite":
    check "PAINTBALL additions to the inherited coworld-ctf chrome" in page
    let banner = page.find("PAINTBALL additions to the inherited")
    ## Everything the starter shipped comes BEFORE the banner: the appended
    ## block may add, never replace the page.
    check page.find("function relayout()") < banner
    check page.find("id=\"transport\"") < banner
    check page.find("window.ChromeCommon") < banner

  test "the game block defines no identifier the chrome alias block owns":
    ## The tandem 2026-08-23 hoisting trap: a game-block `function markBeat`
    ## is swallowed by the alias block's `var markBeat = C.markBeat`, leaving
    ## unlabelled div markers that never seek.
    let banner = page.find("PAINTBALL additions to the inherited")
    let appended = page[banner .. ^1]
    for alias in ["markBeat", "renderBeatMarkers", "ingestBeats", "setVerdict",
                  "renderClock", "renderTransport", "recordMomentum",
                  "renderMomentum", "ingestLeadSeries", "ingestLullSpans",
                  "renderLullSpans", "killMarkerTeam", "captureTeam",
                  "teamPerkGroups", "perkIconsHtml", "setHandicap"]:
      check ("function " & alias) notin appended
      check ("var " & alias) notin appended
    ## And the block's own beat builder is deliberately NOT called markBeat.
    check "function pbBeat(" in appended

  test "chrome_common.js is byte-identical to the coworld-ctf original":
    ## The chrome-provenance pin. Everything paintball adds lives in the
    ## appended game block; this file is inherited and not edited, not even
    ## reformatted.
    check fingerprint(chrome) == ChromeCommonFingerprint
    check "window.ChromeCommon = function (ctx)" in chrome
    check "markBeat" in chrome
    check "ingestBeats" in chrome
    check "setVerdict" in chrome

  test "broadcast_core.js differs only in the wire identifier":
    ## Byte-for-byte apart from window.CTF_WIRE -> window.PAINTBALL_WIRE.
    check "window.PAINTBALL_WIRE" in core
    check "window.CTF_WIRE" notin core
    ## Nothing else in the file was retargeted: the one line that reads the
    ## wire block is the only occurrence.
    var occurrences = 0
    for line in core.splitLines():
      if "PAINTBALL_WIRE" in line:
        inc occurrences
    check occurrences == 1

  test "no ctf_ / CTF_ identifier survives in client/, replay-viewer/ or src/":
    ## chrome_common.js is the ONE documented exception: the pin says it is
    ## inherited byte-for-byte, and it reads its wire block off the starter's
    ## global name. src/paintball/wire_constants.nim therefore publishes that
    ## name as a one-line alias, and those two places are the only survivors.
    let exempt = ["client/chrome_common.js", "src/paintball/wire_constants.nim"]
    for dir in ["client", "replay-viewer", "src"]:
      for path in walkDirRec(dir):
        if path.splitFile().ext notin [".js", ".nim", ".nims", ".html", ".cjs"]:
          continue
        if path.replace('\\', '/') in exempt:
          continue
        let body = readFile(path)
        check "ctf_" notin body
        check "CTF_" notin body
