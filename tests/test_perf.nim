## Release-only: a full 2 x 2160-tick episode with mask compilation and paint
## rasterisation has to finish comfortably inside the wall-clock budget the
## engine promises, or the 690 s stop would fire on a healthy episode.
import std/[monotimes, times, unittest]
import helpers

suite "performance":
  test "2 x 2160 ticks of sim, control and paint complete under 120 s":
    let started = getMonoTime()
    var sim = newPaintballSim(paintballConfigJson(
      maxTicks = 2160, maxGames = 1, regimes = @["resident"]))
    var ctl = initControlState(sim)
    sim.scriptedEpisode(ctl, [blHoldline, blSprayer], 2160)
    var second = newPaintballSim(paintballConfigJson(
      maxTicks = 2160, maxGames = 1, regimes = @["visitor"]))
    var ctl2 = initControlState(second)
    second.scriptedEpisode(ctl2, [blHoldline, blSprayer], 2160)
    let elapsed = (getMonoTime() - started).inSeconds
    echo "episode wall time: ", elapsed, "s"
    check elapsed < 120
    check sim.paintCount[Red] + sim.paintCount[Blue] > 0
