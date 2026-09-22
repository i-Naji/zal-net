## Detached OS threads for loops, the UDP engine and other long-lived workers.

import std/syncio

{.compile: "nn_thread.c".}

proc nnStartThread(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): cint {.importc: "nn_start_thread".}

proc startThread*(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer) =
  if nnStartThread(fn, arg) != 0: quit "zal-net: thread create failed"

{.compile: "nn_join.c".}
type ThreadHandle* = object
  raw: nil pointer

proc nnWorkerStart(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): nil pointer {.importc: "nn_worker_start".}
proc nnWorkerJoin(raw: pointer): cint {.importc: "nn_worker_join".}

proc startJoinable*(handle: var ThreadHandle; fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): bool =
  if handle.raw != nil: return false
  handle.raw = nnWorkerStart(fn, arg)
  result = handle.raw != nil

proc joinThread*(handle: var ThreadHandle): bool =
  ## Never call from the worker being joined. Only after its completion signal.
  let raw = handle.raw
  if raw == nil: return true
  result = nnWorkerJoin(raw) != 0
  if result: handle.raw = nil
