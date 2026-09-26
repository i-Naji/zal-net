{.feature: "lenientnils".}
## A `while` loop in a passive proc that rarely reaches its suspension point recurses once per iteration: enough iterations overflow the stack (seen on the std backend's pool threads; a static musl build's 128 KiB thread stacks crashed tstats). Workaround: do the work between suspensions in a regular proc (`count` in tstats.nim).
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

proc main() {.passive.} =
  var i = 0
  while i < 5_000_000:
    i = i + 1
    if i mod 1_000_000 == 0: yieldNow()
  echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
