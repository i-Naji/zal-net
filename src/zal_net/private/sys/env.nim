## Worker counts from the environment, usable before the runtime starts.

import std/envvars
import std/syncio

proc workersFromEnv*(name: string): int =
  ## A positive worker count from environment variable `name`, or 0 when it
  ## is unset. Quits on a malformed value.
  let value = getEnv(name)
  if value.len == 0: return 0
  var n = 0
  for c in value:
    if c < '0' or c > '9': quit name & " must be 1..256"
    n = n * 10 + ord(c) - ord('0')
    if n > 256: quit name & " must be 1..256"
  if n < 1: quit name & " must be 1..256"
  result = n
