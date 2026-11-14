{.feature: "lenientnils".}
## `addr` of a field reached through a call result is rejected. Workaround: bind the pointer first.
import std/syncio

type O = object
  y: array[4, int]
var g = O()
proc f(): ptr O = addr g
let p = addr f().y[0]
if p != nil: echo "ok"
