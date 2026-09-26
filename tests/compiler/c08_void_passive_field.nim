{.feature: "lenientnils".}
## Calling a `void` passive proc through a proc-typed object field generates C with one argument too many. Workaround: give the proc type a result (`TaskFn` returns int).
## flags: --path:src -d:nnLoops
import std/syncio
import zal_net/rt
import zal_net/raw/io

type Obj = object
  f: proc (x: int) {.nimcall, passive.}
var gHit = 0
proc body(x: int) {.passive.} = gHit = x
proc main() {.passive.} =
  let o = Obj(f: body)
  o.f(5)
  if gHit == 5: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
