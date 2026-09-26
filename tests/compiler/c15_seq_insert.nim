{.feature: "lenientnils".}
## stdlib: `seq` has no `insert`. Workaround: a helper (`insertAt` in tfuzz).
import std/syncio

var s = @[1, 3]
s.insert(2, 1)
if s.len == 3 and s[1] == 2: echo "ok"
