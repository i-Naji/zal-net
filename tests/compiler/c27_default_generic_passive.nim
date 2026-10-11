{.feature: "lenientnils".}
## `default(T)` for an unconstrained `T` inside a generic passive proc does not resolve. Workaround: write into `result.field` (typed Channel.recv in sync.nim).
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

proc g[T](x: T): T {.passive.} =
  var y = default(T)
  y = x
  result = y
proc main() {.passive.} =
  if g(3) == 3: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
