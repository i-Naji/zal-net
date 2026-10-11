{.feature: "lenientnils".}
## A statement followed by `return` inside a `when` branch of a generic passive proc crashes nimsem ("index -1 not in 0 .. n"). Workaround: `if`/`else` assigning `result` (`direction` in net/stream.nim).
## flags: --path:src
import std/syncio
import zal_net/rt
import zal_net/raw/io

type
  Src = concept
    proc get(s: Self; d: int): int {.passive.}
  Thing = object
    v: int
  Other = object
    v: int

proc get(t: Thing; d: int): int {.passive.} = t.v + d
proc get(t: Other; d: int): int {.passive.} = t.v - d
proc helper(x: int): int {.passive.} = x * 10
proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

proc dir[A: Src; B: Src](a: A; b: B; flag: bool): int {.passive.} =
  when (A is Thing or A is Other) and (B is Thing or B is Other):
    var p = default(array[2, cint])
    if flag and p[0] == 0:
      result = helper(a.v)
      discard cClose(-1)
      return
  result = get(a, 1) + get(b, 1)

proc main() {.passive.} =
  if dir(Thing(v: 1), Other(v: 2), true) == 10 and dir(Thing(v: 1), Other(v: 2), false) == 3: echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
