## Intrusive lock-free MPSC mailbox: any thread pushes, one consumer takes
## everything at once. Push reports whether the mailbox was empty, so a
## producer wakes the consumer only for the first item of a batch.

import std/atomics

type
  MailNode* = object
    next*: nil ptr MailNode
  Mailbox* = object
    head: int        # atomic: ptr MailNode, newest first

proc push*(m: var Mailbox; n: ptr MailNode): bool =
  ## Returns true when the mailbox was empty.
  var old = atomicLoad(m.head, moAcquire)
  while true:
    n.next = cast[nil ptr MailNode](old)
    if atomicCompareExchange(m.head, old, cast[int](n), moAcquireRelease, moAcquire): break
  result = old == 0

proc takeAll*(m: var Mailbox): nil ptr MailNode =
  ## Everything pushed so far, oldest first, linked through `next`.
  var expected = atomicLoad(m.head, moAcquire)
  while true:
    if expected == 0: return nil
    if atomicCompareExchange(m.head, expected, 0, moAcquireRelease, moAcquire): break
  var n = cast[nil ptr MailNode](expected)
  var fifo: nil ptr MailNode = nil
  while n != nil:
    let next = n.next
    n.next = fifo
    fifo = n
    n = next
  result = fifo
