{.feature: "assumeSync".}
import std/[assertions, syncio]
import zal_net/ownership
import zal_net/rt/time

const Iterations = 1_000_000
var life = default(OwnerLife)
initOwnerLife(life)
for run in 0..<5:
  let started = monoNow()
  for i in 0..<Iterations:
    assert beginBorrow(life, false) == 0
    endBorrow(life, false)
  echo "operations=", Iterations, " elapsed_ns=", int64(monoNow()) - int64(started)
