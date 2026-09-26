{.feature: "lenientnils".}
## Indexing a `ptr array` does not dereference it. Workaround: `p[][i]`, or wrap the array in an object.
import std/syncio

var a = [1, 2]
let p = addr a
if p[1] == 2: echo "ok"
