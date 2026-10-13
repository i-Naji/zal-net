## Detached OS threads for loops, the UDP engine and other long-lived workers.

import std/syncio
import zal_net/private/sharedmem

{.compile: "nn_thread.c".}

type Launch = object
  fn: proc (arg: nil pointer) {.nimcall.}
  arg: nil pointer

proc enter(raw: nil pointer) {.nimcall.} =
  # The allocator's per-thread region must exist before the first allocation
  # and outlive the thread's frees.
  let launch = cast[ptr Launch](raw)
  let fn = launch.fn
  let arg = launch.arg
  freeShared(raw)
  when declared(nimAllocThreadInit):
    nimAllocThreadInit()
  fn(arg)
  when declared(nimThreadTeardown):
    nimThreadTeardown()
  when declared(nimAllocThreadTeardown):
    nimAllocThreadTeardown()

proc launchOf(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): nil pointer =
  let memory = zeroedShared(sizeof(Launch))
  if memory == nil: return nil
  let launch = cast[ptr Launch](memory)
  launch.fn = fn
  launch.arg = arg
  result = memory

proc nnStartThread(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): cint {.importc: "nn_start_thread".}

proc startThread*(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer) =
  let launch = launchOf(fn, arg)
  if launch == nil: quit "zal-net: thread create failed"
  if nnStartThread(enter, launch) != 0:
    freeShared(launch)
    quit "zal-net: thread create failed"

{.compile: "nn_join.c".}
type ThreadHandle* = object
  raw: nil pointer

proc nnWorkerStart(fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): nil pointer {.importc: "nn_worker_start".}
proc nnWorkerJoin(raw: pointer): cint {.importc: "nn_worker_join".}

proc startJoinable*(handle: var ThreadHandle; fn: proc (arg: nil pointer) {.nimcall.}; arg: nil pointer): bool =
  if handle.raw != nil: return false
  let launch = launchOf(fn, arg)
  if launch == nil: return false
  handle.raw = nnWorkerStart(enter, launch)
  if handle.raw == nil: freeShared(launch)
  result = handle.raw != nil

proc joinThread*(handle: var ThreadHandle): bool =
  ## Never call from the worker being joined. Only after its completion signal.
  let raw = handle.raw
  if raw == nil: return true
  result = nnWorkerJoin(raw) != 0
  if result: handle.raw = nil
