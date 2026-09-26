## A template that `cast`s an expression built from its `untyped` parameter
## does not compile: "cannot `cast` between types untyped and ptr ...". The
## body is typed before the argument is substituted. Workaround: a generic
## proc (`proc ua[I](a: var array[I, byte]): ptr UncheckedArray[byte]`).
import std/syncio

template at(a: untyped): untyped =
  cast[ptr UncheckedArray[byte]](addr(a[0]))

var x: array[4, byte]
let p = at(x)
p[1] = 7
if x[1] == 7: echo "ok"
