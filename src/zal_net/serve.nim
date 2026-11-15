# Serving: accept on a listener and run one handler task per connection,
# until the listener's token is cancelled, then wait for the handlers.
#
#   proc echo(c: var Conn; app: App) {.passive, raises.} =
#     var buffer = default(array[4096, byte])
#     while true:
#       let n = c.read(buffer)
#       if n == 0: break
#       c.write buffer.toOpenArray(0, n - 1)
#
#   let stop = newCancelToken()
#   var listener = listen(8080, stop = stop)
#   serve(listener, echo, app, report)     # returns after cancel(stop)
#
# The handler borrows its connection. `serve` owns it, closes it when the
# handler returns or raises, and passes a raised error to `onError`. A
# handler's failure never ends the server; a failed accept does, after the
# handlers already running have finished.
#
# Handlers run on whichever worker picks them up, so several run at once.
# The context is one `ref` shared by all of them: guard what they change.

import std/ticketlocks
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn
import zal_net/net/failure
from zal_net/errors import ResourceClosed

export conn

const AcceptBurst = 32
  ## Connections accepted before the accept loop yields. A burst of arrivals
  ## otherwise keeps the loop running while the handlers it spawned wait.

type
  Handler*[C] = proc (c: var Conn; context: C) {.nimcall, passive, raises.}
  ErrorHandler*[C] = proc (context: C; error: ErrorCode) {.nimcall.}

  Serving* = ref object
    ## How many handlers run, and an event that is set while none does.
    lock: TicketLock
    active: int
    idle: Event

proc newServing*(): Serving = Serving()

proc started*(s: Serving) =
  s.lock.acquire()
  if s.active == 0: clearEvent(addr s.idle)
  inc s.active
  s.lock.release()

proc finished*(s: Serving) =
  s.lock.acquire()
  dec s.active
  if s.active == 0: setEvent(addr s.idle)
  s.lock.release()

proc pending*(s: Serving): bool =
  s.lock.acquire()
  result = s.active != 0
  s.lock.release()

proc idleEvent*(s: Serving): ptr Event {.inline.} = addr s.idle

proc raiseAgain*(error: ErrorCode) {.raises.} = raise error

template serve*[C: ref](listener: var Listener; handler: Handler[C]; context: C;
                        onError: ErrorHandler[C]) =
  ## Accept and dispatch until the listener's token is cancelled or the
  ## runtime stops; both end it normally. Any other accept failure is raised,
  ## after the running handlers have finished.
  block:
    let held = context
    let service = newServing()
    # The handler is bound here, at the concrete expansion, and not stored in
    # a table: a generic procedure value loses its passive calling convention.
    proc dispatch(accepted: sink Conn; kept: sink C; state: sink Serving) {.passive.} =
      defer: finished(state)
      var c = accepted
      try:
        handler(c, kept)
      except ErrorCode as error:
        onError(kept, error)
      close c
    var failure = Success
    var burst = 0
    try:
      while true:
        var c = accept(listener)
        started(service)
        if not trySpawnTask(dispatch(c, held, service)):
          # The task limit is reached: this connection is dropped, and
          # accepting goes on once running handlers have finished some.
          finished(service)
          parkUntil(afterMs(50))
        inc burst
        if burst == AcceptBurst:
          yieldNow()
          burst = 0
    except ErrorCode as error:
      if error != AbortedOperation and error != DeadResource: failure = error
    finally:
      while pending(service):
        discard wait(idleEvent(service), never)
        if pending(service): yieldNow()
    if failure != Success: raiseAgain(failure)
