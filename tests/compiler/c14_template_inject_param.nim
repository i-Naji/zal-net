{.feature: "lenientnils".}
## A template parameter cannot name a declaration it injects. Workaround: inject a fixed name (`accepted` in nimox-core's acceptEach).
import std/syncio

template decl(name: untyped) =
  let name {.inject.} = 3
decl(x)
if x == 3: echo "ok"
