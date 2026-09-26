## `var nil ptr T` does not parse as a parameter type ("undeclared identifier: 'ptr'"). Workaround: an alias (`PendBytes = nil ptr UncheckedArray[byte]` in datagram/engine.nim, `UserRef` in Kage's eih.nim).
import std/syncio

proc clear(p: var nil ptr int): bool =
  p = nil
  result = p == nil

var x = 1
var q: nil ptr int = addr x
if clear(q): echo "ok"
