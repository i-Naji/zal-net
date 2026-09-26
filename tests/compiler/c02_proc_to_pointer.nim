{.feature: "lenientnils".}
## `cast[pointer]` of a proc is rejected. Workaround: an importc struct with a proc-typed field.
import std/syncio

proc f() = discard
let p = cast[pointer](f)
if p != nil: echo "ok"
