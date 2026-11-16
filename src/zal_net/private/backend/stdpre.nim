## Configure the standard pool before importing std/ioring.
import std/[threadpool, cpuinfo]
import zal_net/private/os
import zal_net/private/sys/env

proc defaultWorkers(): int =
  ## One worker per CPU the process may run on, but no more than its CPU
  ## quota pays for. The pool's own default keeps a CPU back for the main
  ## thread, which in a zal program only waits for the runtime to stop: on
  ## two CPUs that halves the workers.
  result = max(1, countProcessors())
  let quota = cpuQuota()
  if quota > 0 and quota < result: result = quota

let requestedWorkers* = workersFromEnv("ZAL_WORKERS")
initPool(if requestedWorkers > 0: requestedWorkers else: defaultWorkers())
