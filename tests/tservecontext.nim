## Context retention and handler connection cleanup use only the friendly API.
import std/[assertions, syncio, atomics]
import zal_net/[rt, errors], zal_net/rt/sync
import zal_net/foundation/tcp, zal_net/foundation/tcplistener, zal_net/raw/serve

var completed = 0

type Context = ref object
  listener: TcpListenerRef
  entered, done: Event
  count: int
  seen: nil TcpConnRef
  served: int

proc echoConn(conn: TcpConnRef; ctx: Context) {.passive.} =
  discard atomicFetchAdd(ctx.count, 1, moAcquireRelease)
  ctx.seen = conn
  var bytes = default(array[8, byte])
  let got = recvInto(conn, bytes, afterMs(2000))
  assert got == 1 and bytes[0] == 91
  assert sendFrom(conn, bytes.toOpenArray(0, got - 1), afterMs(2000)) == got
  assert close(ctx.listener) == 0
  setEvent(addr ctx.done)
  # serve's dispatcher closes the connection after this handler returns.

proc burstHandler(conn: TcpConnRef; ctx: Context) {.passive.} =
  let previous = atomicFetchAdd(ctx.count, 1, moAcquireRelease)
  if previous == 0: assert close(ctx.listener) == 0

proc runBurstService(ctx: sink Context) {.passive.} =
  let code = serve(ctx.listener, burstHandler, ctx)
  atomicStore(ctx.served, code, moRelease)

proc runService(ctx: sink Context) {.passive.} =
  setEvent(addr ctx.entered)
  let code = serve(ctx.listener, echoConn, ctx)
  atomicStore(ctx.served, code, moRelease)
  discard atomicFetchAdd(completed, 1, moRelease)

proc main() {.passive.} =
  let opened = listenTcpRef(0, "127.0.0.1")
  assert opened.code == 0
  let listener = opened.value
  if listener != nil:
    let ctx = Context(listener: listener)
    assert trySpawnTask(runService(ctx))
    assert wait(addr ctx.entered, afterMs(2000)) == wrReady
    let connected = connectTcpConn("127.0.0.1", listener.port, deadline=afterMs(2000))
    let client = connected.value
    if client != nil:
      var bytes = [91'u8]
      assert sendFrom(client, bytes, afterMs(2000)) == 1
      assert recvInto(client, bytes, afterMs(2000)) == 1 and bytes[0] == 91
      assert wait(addr ctx.done, afterMs(2000)) == wrReady
      while atomicLoad(ctx.served, moAcquire) == 0: yieldNow()
      assert atomicLoad(ctx.served, moAcquire) == ResourceClosed and atomicLoad(ctx.count, moAcquire) == 1
      # Let the handler's dispatcher finish its ordinary close transition.
      yieldNow()
      let retained = ctx.seen
      if retained != nil:
        let until = afterMs(2000)
        while state(retained) != ownerClosed and monoNow() < until: yieldNow()
        assert state(retained) == ownerClosed
      else: assert false, "handler received connection"
      assert close(client) == 0 and close(listener) == 0
    else: assert false, "friendly client construction"
  else: assert false, "friendly listener construction"
  for cycle in 0..<32:
    var port: uint16 = 0
    let previous = atomicLoad(completed, moAcquire)
    block:
      let created = listenTcpRef(0, "127.0.0.1")
      let listener = created.value
      if listener != nil:
        port = listener.port
        let context = Context(listener: listener)
        assert trySpawnTask(runService(context))
      else: assert false, "queued context setup"
    # The serving task now holds the only context/listener references.
    let connected = connectTcpConn("127.0.0.1", port, deadline=afterMs(2000))
    let client = connected.value
    if client != nil:
      var bytes = [91'u8]
      assert sendFrom(client, bytes, afterMs(2000)) == 1
      assert recvInto(client, bytes, afterMs(2000)) == 1 and bytes[0] == 91
      assert close(client) == 0
    else: assert false, "queued context connection"
    let until = afterMs(2000)
    while atomicLoad(completed, moAcquire) == previous and monoNow() < until: parkUntil(afterMs(1))
    assert atomicLoad(completed, moAcquire) == previous + 1
    yieldNow()
  # Pre-fill a readable backlog. Without a bounded accept burst, the server
  # admits every queued client before its first handler can close admission.
  let created = listenTcpRef(0, "127.0.0.1")
  let burstListener = created.value
  if burstListener != nil:
    let context = Context(listener: burstListener)
    var clients = default(array[65, nil TcpConnRef])
    for i in 0..<clients.len:
      let connected = connectTcpConn("127.0.0.1", burstListener.port, deadline=afterMs(2000))
      assert connected.code == 0
      clients[i] = connected.value
    assert trySpawnTask(runBurstService(context))
    let until = afterMs(2000)
    while atomicLoad(context.served, moAcquire) == 0 and monoNow() < until:
      parkUntil(afterMs(1))
    assert atomicLoad(context.served, moAcquire) == ResourceClosed
    let admitted = atomicLoad(context.count, moAcquire)
    assert admitted >= 1 and admitted <= 64, "bounded admission yields to handlers"
    for i in 0..<clients.len:
      let client = clients[i]
      if client != nil: assert close(client) == 0
    assert close(burstListener) == 0
  else: assert false, "burst service setup"
  echo "PASS contextual serving, retained context and dispatcher-owned connection"

assert runMain(main())
