## EventCount: how a thread that is not an event loop sleeps until notified.
## Protocol: `let t = prepareWait(ec)`; recheck the condition; then either
## `cancelWait(ec)` or `commitWait(ec, t)`. A notify between the recheck and
## the sleep is not lost. Never call `commitWait` on a loop thread.

import std/syncio

{.compile: "../sys/nn_ec.c".}

type EventCount* = distinct pointer

proc nnEcNew(): nil pointer {.importc: "nn_ec_new".}
proc nnEcPrepare(p: pointer): cuint {.importc: "nn_ec_prepare".}
proc nnEcCancel(p: pointer) {.importc: "nn_ec_cancel".}
proc nnEcCommit(p: pointer; ticket: cuint; timeoutMs: cint) {.importc: "nn_ec_commit".}
proc nnEcNotifyOne(p: pointer) {.importc: "nn_ec_notify_one".}
proc nnEcNotifyAll(p: pointer) {.importc: "nn_ec_notify_all".}

proc newEventCount*(): EventCount =
  let p = nnEcNew()
  if p == nil: quit "zal-net: out of memory (event count)"
  result = EventCount(p)
proc prepareWait*(ec: EventCount): uint32 = uint32(nnEcPrepare(pointer(ec)))
proc cancelWait*(ec: EventCount) = nnEcCancel(pointer(ec))
proc commitWait*(ec: EventCount; ticket: uint32; timeoutMs = -1) =
  nnEcCommit(pointer(ec), cuint(ticket), cint(timeoutMs))
proc notifyOne*(ec: EventCount) = nnEcNotifyOne(pointer(ec))
proc notifyAll*(ec: EventCount) = nnEcNotifyAll(pointer(ec))

proc nnEcFree(p: pointer) {.importc: "nn_ec_free".}
proc freeEventCount*(ec: EventCount) =
  ## Exactly once, after every waiter and notifier has joined.
  nnEcFree(pointer(ec))
