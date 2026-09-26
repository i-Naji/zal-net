{.feature: "lenientnils".}
## An `openArray` cannot be bound to a `let`. Workaround: pass `x.toOpenArray(a, b)` directly.
import std/syncio

proc sum(a: openArray[int]): int =
  result = 0
  for x in a: result = result + x
let arr = [1, 2, 3]
let v = arr.toOpenArray(0, 1)
if sum(v) == 3: echo "ok"
