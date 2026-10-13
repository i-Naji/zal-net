## What a failed allocation does. Nimony's own allocator aborts with SIGABRT
## and no message. Under `-d:useLibc` or `-d:useMimalloc` a failed `seq` or
## `string` growth calls the OOM handler, whose default goes on with the
## missing bytes and fails later elsewhere.
##
## `initRuntime` installs `exitOnOutOfMemory`: it writes the failed size to
## stderr without allocating and exits with status 1. To go on instead, call
## `setOomHandler(continueAfterOutOfMem)` after `initRuntime`.

import zal_net/private/sys/sock

proc cExit(code: cint) {.importc: "exit", header: "<stdlib.h>".}

proc exitOnOutOfMemory*(size: int) {.nimcall.} =
  var msg {.noinit.}: array[80, char]
  const Head = "zal-net: out of memory ("
  const Tail = " bytes requested)\n"
  var n = 0
  for c in Head:
    msg[n] = c
    n = n + 1
  var digits {.noinit.}: array[20, char]
  var d = 0
  var v = if size > 0: size else: 0
  while true:
    digits[d] = char(ord('0') + v mod 10)
    d = d + 1
    v = v div 10
    if v == 0: break
  while d > 0:
    d = d - 1
    msg[n] = digits[d]
    n = n + 1
  for c in Tail:
    msg[n] = c
    n = n + 1
  discard fileWrite(2, addr msg[0], n)
  cExit(1)

proc installOomHandler*() =
  ## Make a failed allocation fatal (see the module doc). `initRuntime`
  ## calls it.
  setOomHandler(exitOnOutOfMemory)
