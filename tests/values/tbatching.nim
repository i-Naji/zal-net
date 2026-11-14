import std/[assertions, syncio]
import zal_net/net/batching

var budget = initReceiveBudget(64)
assert target(budget) == 4
for expected in [8, 16, 32, 64, 64]:
  observe(budget, target(budget))
  assert target(budget) == expected
for cycle in 0..<7: observe(budget, 1)
assert target(budget) == 64
observe(budget, 1)
assert target(budget) == 32
observe(budget, -1)
observe(budget, 0)
observe(budget, 33)
assert target(budget) == 32
for cycle in 0..<64: observe(budget, 1)
assert target(budget) >= 1 and target(budget) <= 4
var small = initReceiveBudget(1)
for cycle in 0..<64:
  observe(small, 1)
  assert target(small) == 1
var odd = initReceiveBudget(7)
assert target(odd) == 4
observe(odd, 4)
assert target(odd) == 7
var huge = initReceiveBudget(high(int))
for cycle in 0..<128: observe(huge, target(huge))
assert target(huge) == high(int), "growth cannot overflow"
assert target(initReceiveBudget(0)) == 0
assert target(initReceiveBudget(-1)) == 0
# Independent budgets cannot change each other's syscall bound.
assert target(budget) != target(small)
echo "PASS adaptive bounded receive policy, saturation, sparse hysteresis and independent limits"
