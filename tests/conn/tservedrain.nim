## serve and its handlers: an error raised before a parked `finally`, another
## from the handler that stopped the server, both reported; serve returns
## after both handlers and their connections are done. A backlog of 65
## connections is accepted in bursts that let a handler stop the server.
import std/[assertions, syncio, atomics, ticketlocks]
import zal_net/rt
import zal_net/rt/sync
import zal_net/serve

type App = ref object
  lock: TicketLock
  stop: CancelToken
  entered, exited, reported: int   # atomic, except `reported`: under lock
  firstPaused: bool                # atomic
  errors: set[ErrorCode]
  clientsDone: Event

proc report(app: App; error: ErrorCode) =
  app.lock.acquire()
  inc app.reported
  app.errors.incl error
  app.lock.release()

proc handle(c: var Conn; app: App) {.passive, raises.} =
  if atomicFetchAdd(app.entered, 1, moAcquireRelease) == 0:
    try:
      raise TimeoutError
    finally:
      atomicStore(app.firstPaused, true, moRelease)
      parkUntil(afterMs(30))
      discard atomicFetchAdd(app.exited, 1, moRelease)
  else:
    cancel(app.stop)
    discard atomicFetchAdd(app.exited, 1, moRelease)
    raise PermissionDenied

proc clients(app: App; port: uint16) {.passive.} =
  try:
    var first = connect("127.0.0.1", port, afterMs(5000))
    while not atomicLoad(app.firstPaused, moAcquire): parkUntil(afterMs(1))
    var second = connect("127.0.0.1", port, afterMs(5000))
    var bytes = default(array[1, byte])
    assert first.read(bytes, afterMs(5000)) == 0, "serve closed the first connection"
    assert second.read(bytes, afterMs(5000)) == 0, "serve closed the second connection"
  except ErrorCode:
    assert false
  setEvent(addr app.clientsDone)

proc stopFirst(c: var Conn; app: App) {.passive, raises.} =
  if atomicFetchAdd(app.entered, 1, moAcquireRelease) == 0: cancel(app.stop)

proc drained() {.passive, raises.} =
  let app = App(stop: newCancelToken())
  var listener = listen(0, "127.0.0.1", stop = app.stop)
  assert trySpawnTask(clients(app, listener.port))
  serve(listener, handle, app, report)
  assert atomicLoad(app.entered, moAcquire) == 2
  assert atomicLoad(app.exited, moAcquire) == 2, "serve waited for both handlers"
  assert app.reported == 2 and TimeoutError in app.errors and PermissionDenied in app.errors
  assert wait(addr app.clientsDone, afterMs(5000)) == wrReady
  close listener
  release(app.stop)

proc bursts() {.passive, raises.} =
  # A full backlog: the accept loop yields after a burst, so the first
  # handler gets to stop it long before the queue is empty.
  let app = App(stop: newCancelToken())
  var listener = listen(0, "127.0.0.1", stop = app.stop)
  var waiting: seq[Conn] = @[]
  for i in 0 ..< 65:
    waiting.add connect("127.0.0.1", listener.port, afterMs(2000))
  serve(listener, stopFirst, app, report)
  let admitted = atomicLoad(app.entered, moAcquire)
  assert admitted >= 1 and admitted <= 64, "bounded accept bursts, admitted " & $admitted
  close listener
  release(app.stop)

proc main() {.passive.} =
  try:
    drained()
    bursts()
    echo "PASS handler errors reported across a parked finally, serve drained, accept bursts bounded"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
