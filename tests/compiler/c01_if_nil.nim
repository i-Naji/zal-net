{.feature: "lenientnils".}
## An `if` expression that yields `nil` crashes the backend ("isTrivial nilt"). Workaround: assign in statements (`dataPtr` in net/fdops.nim).
import std/syncio

proc pick(b: bool; p: pointer): pointer =
  result = if b: p else: nil
var x = 1
if pick(true, addr x) == addr x and pick(false, addr x) == nil: echo "ok"
