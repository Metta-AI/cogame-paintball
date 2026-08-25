## Every drawn string fits its frame — the shout-bubble half, asserted on the
## real geometry rather than by eye.
##
## A canvas accepts a draw at a negative coordinate without complaint, so a
## bubble anchored where there is no room is invisible to the load signal, to
## the soak and to a screenshot (cogchemists, 2026-08-24: four speech bubbles
## drawn upward from cogs standing at the top of the arena, four sentences
## rendered as four white slivers, everything green).
##
## Paintball's bubbles are rasterised into sprites in Nim and blitted into a
## map-sized layer canvas, so `viewer_smoke.mjs`'s `fillText` hook cannot see
## them (canvas_text total is structurally 0). This file is the gate that can:
## it asks the DRAW PASS's own geometry where every worst-case bubble lands and
## asserts the rect is inside the board. The browser half — the real renderer,
## a frame built to hurt, several canvas sizes — is
## `replay-viewer/text_fixture.html`, driven by `viewer_smoke.mjs
## --strict-text-bounds` in its own ci.yml step.
import std/[unicode, unittest]
import paintball/global
import helpers

const
  ## The worst string the server can ever hand the bubble builder: the shout
  ## cap in the widest printable glyphs. sanitizeShout keeps all of them.
  FullCap = "WWWWWWWWWW"

suite "shout bubbles fit the frame":
  test "the cap is what the fixture thinks it is":
    check FullCap.runeLen == ShoutMaxChars
    check sanitizeShout(FullCap) == FullCap
    ## And a longer say is cut to the cap, so no bubble can ever be wider than
    ## the one this file measures.
    check sanitizeShout(FullCap & FullCap).runeLen == ShoutMaxChars

  test "a full-cap bubble on EVERY cog at once lands inside the board":
    ## Worst positions first: the top edge (the cogchemists case), then the
    ## four corners and the side walls. Every cog shouts the full cap at the
    ## same time, which is also the frame the browser fixture renders.
    var sim = newPaintballSim()
    let
      w = sim.gameMap.width
      h = sim.gameMap.height
      band = sim.shoutBubbleMaxHeight()
    check band > 0
    var worst = h
    for spot in [(0, 0), (w div 2, 0), (w - 1, 0), (0, h - 1), (w div 2, h - 1),
                 (w - 1, h - 1), (0, h div 2), (w - 1, h div 2),
                 (w div 2, h div 2)]:
      for cogIndex in 0 ..< sim.players.len:
        sim.placePlayer(cogIndex, spot[0], spot[1])
      for cogIndex in 0 ..< sim.players.len:
        let rect = sim.shoutBubbleRectFor(cogIndex, FullCap)
        ## The whole rect, not just its anchor, is inside the board — which is
        ## the frame every spectator client fits whole into the viewport.
        check rect.x >= 0
        check rect.y >= 0
        check rect.x + rect.w <= w
        check rect.y + rect.h <= h
        check rect.h <= band          ## the reserved band really is the cap
        worst = min(worst, rect.y)
    echo "worst-case bubble top y = ", worst, " (reserved band ", band,
      " px, board ", w, "x", h, ")"

  test "a bubble that cannot fit above the cog flips below it, not off-frame":
    ## The clamp is not allowed to be a silent squash: a cog on the top row
    ## must get a bubble whose whole height is on screen, below its tail.
    var sim = newPaintballSim()
    sim.placePlayer(0, sim.gameMap.width div 2, 0)
    let
      anchor = sim.players[0].shoutAnchor()
      rect = sim.shoutBubbleRectFor(0, FullCap)
    check anchor.tailTipY - rect.h < 0        ## it genuinely does not fit above
    check rect.y >= 0
    check rect.y + rect.h <= sim.gameMap.height
    check rect.y > anchor.tailTipY - rect.h   ## it moved rather than clipped

  test "the placement is a pure clamp, so it never moves a bubble that fits":
    ## A bubble with room above the cog is placed exactly where the design
    ## puts it: centred on the shouter, its base at the tail tip.
    var sim = newPaintballSim()
    sim.placePlayer(0, sim.gameMap.width div 2, sim.gameMap.height div 2)
    let
      anchor = sim.players[0].shoutAnchor()
      rect = sim.shoutBubbleRectFor(0, FullCap)
    check rect.x == anchor.x - rect.w div 2
    check rect.y == anchor.tailTipY - rect.h

  test "every say the scripted baselines emit fits, at every board position":
    ## The strings CI's own replay actually carries. They are shorter than the
    ## cap, so they must fit wherever the cap fits — asserted rather than
    ## assumed, because a shorter string with a different placement rule is
    ## exactly how a regression would hide.
    var sim = newPaintballSim()
    for say in ["hold", "paint", "watch", "on it", FullCap]:
      for spot in [(0, 0), (sim.gameMap.width - 1, 0),
                   (sim.gameMap.width div 2, 0)]:
        for cogIndex in 0 ..< sim.players.len:
          sim.placePlayer(cogIndex, spot[0], spot[1])
          let rect = sim.shoutBubbleRectFor(cogIndex, say)
          check rect.x >= 0 and rect.y >= 0
          check rect.x + rect.w <= sim.gameMap.width
          check rect.y + rect.h <= sim.gameMap.height
