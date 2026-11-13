{.feature: "lenientnils".}
## `for x in SomeEnum` was unsupported; the workaround was a loop over the ordinals.
## 4ba90a78: fixed, kept as a guard.
import std/syncio

type E = enum ea, eb, ec
var n = 0
for x in E: n = n + 1
if n == 3: echo "ok"
