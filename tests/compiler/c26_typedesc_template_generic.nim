{.feature: "lenientnils".}
## A template taking a `typedesc`, called inside a generic proc, fails with "BUG: unhandled type: typekind". Workaround: inline the `when`.
import std/syncio

template isInt(T: typedesc): bool = T is int
proc g[T](x: T): int =
  when isInt(T): result = 1
  else: result = 2
if g(1) == 1 and g(2.5) == 2: echo "ok"
