## Configure the standard pool before importing std/ioring.
import std/threadpool
import zal_net/private/sys/env

let requestedWorkers* = workersFromEnv("ZAL_WORKERS")
if requestedWorkers > 0:
  initPool(requestedWorkers)
