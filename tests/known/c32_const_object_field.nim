{.feature: "lenientnils".}
## A field of a `const` object is not a compile-time value (`when G.a > 1`). Workaround: name the field's value as its own const (Kage sip022/tcpcodec.nim `SipHeadRoom`).
import std/syncio

type G = object
  a, b: int
const g = G(a: 2, b: 3)
when g.a > 1:
  echo "ok"
