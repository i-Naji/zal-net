## Worker and task counts from the environment, usable before the runtime starts.

import std/envvars
import std/syncio

const MaxWorkers* = 256
const MaxTasks* = 1 shl 24

proc countFromEnv(name: string; limit: int; range: string): int =
  let value = getEnv(name)
  if value.len == 0: return 0
  var n = 0
  for c in value:
    if c < '0' or c > '9': quit name & " must be " & range
    n = n * 10 + ord(c) - ord('0')
    if n > limit: quit name & " must be " & range
  if n < 1: quit name & " must be " & range
  result = n

proc workersFromEnv*(name: string): int =
  ## A positive worker count from environment variable `name`, or 0 when it
  ## is unset. Quits on a malformed value.
  countFromEnv(name, MaxWorkers, "1..256")

proc tasksFromEnv*(name: string): int =
  ## `workersFromEnv` for the admitted task limit.
  countFromEnv(name, MaxTasks, "1..16777216")
