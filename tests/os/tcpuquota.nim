# The pool's default worker count is capped by the cgroup CPU quota: a
# `cpu.max` line in whole CPUs, rounded up, and 0 when it sets no limit.
import std/assertions
import zal_net/private/os

assert parseCpuMax("max 100000") == 0
assert parseCpuMax("150000 100000") == 2
assert parseCpuMax("50000 100000") == 1
assert parseCpuMax("200000 100000") == 2
assert parseCpuMax("100000") == 0
assert parseCpuMax("") == 0
assert cpuQuota() >= 0
