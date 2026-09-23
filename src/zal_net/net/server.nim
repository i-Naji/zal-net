## Contextual serving with joined handlers. A handler borrows its accepted stream;
## the dispatcher retains and closes it, reports failures, and acknowledges
## completion. Closing the listener stops acceptance; serve drains handlers.
## Error handlers are regular nonraising procedures. With the standard pool,
## callbacks may overlap on different workers; synchronize shared context state.
import zal_net/rt
import std/ticketlocks
import zal_net/rt/sync
import zal_net/net/tcp
import zal_net/net/failure
import zal_net/foundation/tcplistener as listeners
from zal_net/errors import InvalidInput, ResourceClosed

const HandlerBurst = 32  ## Bound accept work before yielding to queued handlers.

type
  Handler*[C] = proc (stream: TcpStream; context: C) {.nimcall, passive, raises.}
  ErrorHandler*[C] = proc (context: C; error: ErrorCode) {.nimcall.}
  Serving = ref object
    lock: TicketLock
    active: int
    idle: Event

proc newServing(): Serving = Serving()

proc started(service: Serving) =
  service.lock.acquire()
  if service.active == 0:
    clearEvent(addr service.idle)
  inc service.active
  service.lock.release()

proc finished(service: Serving) =
  service.lock.acquire()
  dec service.active
  if service.active == 0:
    setEvent(addr service.idle)
  service.lock.release()

proc pending(service: Serving): bool =
  service.lock.acquire()
  result = service.active != 0
  service.lock.release()
proc idleEvent(service: Serving): ptr Event {.inline.} = addr service.idle

proc raiseFailure(error: ErrorCode) {.raises.} = raise error

template serve*[C](listener: TcpListener; handler: Handler[C]; context: C;
                   onError: ErrorHandler[C]) =
  ## The context must be a retained ref with synchronized mutable state. Handler errors are isolated and
  ## reported; an acceptance error is raised only after admitted handlers drain.
  ## A closed listener ends serving normally. Returning handlers relinquish
  ## their stream, including any retained aliases; it is closed by dispatch.
  block:
    when not (C is ref):
      {.error: "serve context must be a ref object".}
    let server = listener
    let held = context
    let service = newServing()
    # The pin erases the passive ABI for generic callback values (see Group).
    # Bind the typed handler at this concrete expansion; never store it in a
    # proc table. Sink parameters retain all three owners until dispatch ends.
    proc dispatch(stream: sink TcpStream; kept: sink C; state: sink Serving) {.passive.} =
      defer: finished(state)
      var errorCode = Success
      try:
        handler(stream, kept)
      except ErrorCode as error:
        errorCode = error
      try:
        stream.close()
      except ErrorCode as error:
        if errorCode == Success:
          errorCode = error
      if errorCode != Success:
        onError(kept, errorCode)
    var failure = Success
    var burst = 0
    try:
      while true:
        let stream = server.accept()
        started(service)
        if not trySpawnTask(dispatch(stream, held, service)):
          finished(service)
          stream.close()
          failIo(ResourceClosed)
        inc burst
        if burst == HandlerBurst:
          yieldNow()
          burst = 0
    except ErrorCode as error:
      if error != DeadResource:
        failure = error
    finally:
      while pending(service):
        discard wait(idleEvent(service), never)
        if pending(service):
          yieldNow()
    if failure != Success:
      raiseFailure(failure)
