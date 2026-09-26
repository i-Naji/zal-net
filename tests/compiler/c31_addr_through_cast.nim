{.feature: "lenientnils".}
## `addr` of a field reached through a `cast[ptr T](...)` expression is rejected. Workaround: bind the cast to a local first (nimox-core users/session.nim's `sess` users, serve.nim).
import std/syncio

type O = object
  y: array[4, int]
var raw = default(array[8, uint64])
let p = addr cast[ptr O](addr raw[0]).y[0]
if p != nil: echo "ok"
