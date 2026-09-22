## Worker count for the std backend. std/ioring starts the pool when it is
## imported, before any program code runs, so the count must be set by module
## initialisation that happens earlier: this module's (ZAL_WORKERS), or a
## caller's module that imports this one and calls `requestWorkers` before
## anything imports std/ioring. Needs a Nimony whose std/threadpool honours a
## preset `workerCount`; a stock pool picks its own count and `beInit` warns.

import std/threadpool
import zal_net/private/sys/env

var gRequested*: int  ## the count asked for, 0 = the pool's default

proc requestWorkers*(n: int) =
  if n > 0:
    gRequested = n
    workerCount = n

requestWorkers(workersFromEnv("ZAL_WORKERS"))
