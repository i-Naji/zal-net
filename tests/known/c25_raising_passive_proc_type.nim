{.feature: "lenientnils".}
## A raising passive proc passed as a proc-typed value: the C function pointer type expects an int result where the proc writes an error-code tuple. Blocks startTaskR (manual, chapter 11).
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

type Fn = proc (x: int): int {.nimcall, passive, raises.}
proc body(x: int): int {.nimcall, passive, raises.} =
  yieldNow()
  if x < 0: raise ValueError
  result = x
proc call(f: Fn; x: int): int {.passive.} =
  result = 0
  try: result = f(x)
  except: result = -1
proc main() {.passive.} =
  if call(body, 3) == 3 and call(body, -1) == -1: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
