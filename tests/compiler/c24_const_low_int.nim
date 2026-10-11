{.feature: "lenientnils".}
## `const X = low(int)` used by a passive proc crashes nimsem with a RangeDefect (found writing startTaskR). Workaround: another sentinel.
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

const Failed = low(int)
var gCode = 0
proc body() {.passive.} =
  yieldNow()
  gCode = Failed
proc main() {.passive.} =
  body()
  if gCode == Failed: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
