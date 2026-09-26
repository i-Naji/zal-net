{.feature: "lenientnils".}
## `addr` of a string element is rejected. Workaround: `cast[pointer](s.toCString)`.
import std/syncio

var s = "abc"
let p = addr s[1]
if p[] == 'b': echo "ok"
