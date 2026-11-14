## Tickers keep their schedule, and report ticks missed by a task that
## fell behind.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/ticker

proc main() {.passive.} =
  var t = initTicker(50)
  let t0 = monoNow()
  var k = 0
  while k < 5:
    # A late wake (a loaded VM) reports the ticks it missed: count periods.
    let missed = waitTick(t)
    assert missed >= 0
    k = k + 1 + missed
  let ms = (int64(monoNow()) - int64(t0)) div 1_000_000
  # Windows VMs can have a coarse timer (a 1 ms Sleep takes 4-9 ms on the
  # test VM), and each tick may land that much late.
  assert ms >= 240 and ms < (when defined(windows): 700 else: 400), $ms
  sleepMs(180)                     # fall behind by three ticks or so
  let missed = waitTick(t)
  assert missed >= 2, $missed
  assert waitTick(t) == 0          # back on schedule
  echo "PASS 5 ticks of 50 ms in ", ms, " ms; ", missed, " missed ticks reported after a stall"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
