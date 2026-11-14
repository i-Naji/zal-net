{.feature: "lenientnils".}
## Suspending inside a `for` loop in a passive proc (reported by hashi). Workaround: `while` loops.
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

proc main() {.passive.} =
  var total = 0
  for i in 0 ..< 3:
    yieldNow()
    total = total + i
  if total == 3: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
