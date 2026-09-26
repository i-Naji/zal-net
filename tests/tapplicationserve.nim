## Handler value errors survive overlap and suspended finally. Serve drains
## the context and closes all accepted owners before it returns.
import std/[assertions, syncio, atomics, ticketlocks]
import zal_net/rt, zal_net/raw/io
import zal_net

type Context = ref object
  lock: TicketLock
  listener: nil TcpListener
  retained: nil TcpStream
  entered, exited, reported: int
  firstPaused: bool
  clientsDone: bool
  errors: set[ErrorCode]

proc report(ctx: Context; error: ErrorCode) =
  ctx.lock.acquire()
  inc ctx.reported
  ctx.errors.incl(error)
  ctx.lock.release()

proc handle(stream: TcpStream; ctx: Context) {.passive, raises.} =
  if atomicFetchAdd(ctx.entered, 1, moAcquireRelease) == 0:
    ctx.retained = stream
    try:
      raise TimeoutError
    finally:
      atomicStore(ctx.firstPaused, true, moRelease)
      sleepMs(30)
      discard atomicFetchAdd(ctx.exited, 1, moRelease)
  else:
    let listener = ctx.listener
    if listener != nil:
      listener.close()
    discard atomicFetchAdd(ctx.exited, 1, moRelease)
    raise PermissionDenied

proc clients(ctx: sink Context; port: uint16) {.passive.} =
  defer: atomicStore(ctx.clientsDone, true, moRelease)
  try:
    let first = connect("127.0.0.1", port, deadline=afterMs(5000))
    defer: first.close()
    while not atomicLoad(ctx.firstPaused, moAcquire):
      sleepMs(1)
    let second = connect("127.0.0.1", port, deadline=afterMs(5000))
    defer: second.close()
    var bytes = default(array[1, byte])
    assert first.read(bytes, deadline=afterMs(5000)) == 0
    assert second.read(bytes, deadline=afterMs(5000)) == 0
  except ErrorCode:
    assert false

proc main() {.passive.} =
  try:
    let ctx = Context()
    let listener = listen(0, "127.0.0.1")
    ctx.listener = listener
    defer: listener.close()
    assert trySpawnTask(clients(ctx, listener.port))
    serve(listener, handle, ctx, report)
    while not atomicLoad(ctx.clientsDone, moAcquire):
      sleepMs(1)
    assert ctx.entered == 2 and ctx.exited == 2 and ctx.reported == 2
    assert TimeoutError in ctx.errors and PermissionDenied in ctx.errors
    let retained = ctx.retained
    if retained != nil:
      var bytes = default(array[1, byte])
      try:
        discard retained.read(bytes)
        assert false
      except ErrorCode as error:
        assert error == DeadResource
      retained.close()
    echo "PASS application serve: context retention, error isolation and drain"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
