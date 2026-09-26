{.feature: "lenientnils".}
## An `or` of integer constants is an `int`, not a literal: it does not convert to a `cint` parameter. Workaround: `cint(0x1 or 0x100)`.
import std/syncio

proc f(x: cint): cint = x
if f(0x1 or 0x100) == 0x101: echo "ok"
