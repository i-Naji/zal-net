{.feature: "lenientnils".}
## A guard, fixed upstream (Nimony's tests/nimony/valgrind/tpassive_openarray.nim): an `openArray` parameter of a passive proc lost its pointer (the length survived) across a suspension. zal-net's passive procs still take `pointer` + length; this repro must stay FIXED before that rule is relaxed.
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

proc total(xs: openArray[int]): int {.passive.} =
  result = 0
  sleepMs(1)                       # a real suspension: the frame is resumed later
  for x in xs: result = result + x

proc main() {.passive.} =
  let data = @[1, 2, 3, 4, 5]
  if total(data) == 15 and total(data.toOpenArray(1, 3)) == 9: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
