## A `=copy` hook marked `{.error.}` does not forbid copies (the manual, "=copy hook": "any assignment ... is a compile-time error"). Workaround: document "do not copy" on types that own C resources (zal-tls `KxKey`, `Aead`, `HpkeCtx`, which keep the hook for when it works).
## Still reproduces on 0da5a6b7.
import std/syncio

type K = object
  p: nil pointer

proc `=copy`(dst: var K; src: K) {.error.}

proc probe() =
  var a = default(K)
  when compiles((var c = a; c.p)): echo "copies"
  else: echo "ok"

probe()
