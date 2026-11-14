{.feature: "lenientnils".}
## `addr` of a field reached through a pointer-to-pointer is rejected. Workaround: walk with plain pointers.
import std/syncio

type Node = object
  next: ptr Node
  v: int
var a = Node(next: nil, v: 1)
var pa = addr a
var pp = addr pa
let q = addr pp[].next
if q != nil: echo "ok"
