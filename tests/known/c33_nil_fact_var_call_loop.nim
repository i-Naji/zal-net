## A nil fact about an immutable parameter, established before a loop, is lost inside the loop after a call with a `var` argument ("cannot prove expression is not nil: a"). Workaround: bind the narrowed value to a not-nil local (`let a: ptr int64 = activity`, rt.nim `touchIo`).
import std/syncio
import std/atomics

proc bump(activity: nil ptr int64) =
  if activity == nil: return
  var previous = atomicLoad(activity[], moRelaxed)
  while previous < 10:
    if atomicCompareExchange(activity[], previous, 10, moRelaxed, moRelaxed): break

var x = 1'i64
bump(addr x)
if x == 10: echo "ok"
