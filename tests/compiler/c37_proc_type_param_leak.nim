## Calling a proc-typed field declared in another module lets that proc
## type's parameter names shadow same-named locals of the caller in the
## call's arguments: `data` below is taken as the proc type's `data: ptr
## int`, not the `var seq[int]` parameter ("expected: seq but got: ptr").
## A proc earlier in the same module with a parameter of that name hides
## the bug. Workaround: name locals differently from the parameters of
## proc types they call (zal-tls: `pub`, `certs`).
import std/syncio
import c37/hook

proc use(h: Hook; data: var seq[int]): int =
  let f = h.fn
  if f != nil: result = f(addr data[0])
  else: result = 0

var s = @[42]
if use(Hook(fn: first), s) == 42: echo "ok"
