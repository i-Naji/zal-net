{.feature: "lenientnils".}
## `for x in SomeEnum` is unsupported. Workaround: loop over the ordinals.
import std/syncio

type E = enum ea, eb, ec
var n = 0
for x in E: n = n + 1
if n == 3: echo "ok"
