{.feature: "assumeSync".}
import zal_net/unsafe/streamview
## Public custom-transport cancellation and all dial/resolver entry points.
import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io, zal_net/rt/[sync, cancel, waits]
import zal_net/raw/tcp, zal_net/net/[address, transport, dns, dial, endpoint, endpointdial, sockaddr]
import zal_net/net/resolve as resolver

proc tcpContext(ctx: pointer): TcpStreamPtr {.inline.} = cast[TcpStreamPtr](ctx)
proc readTcp(ctx: pointer; buf: pointer; count: int; until: Deadline;
              tok: nil CancelToken): int {.nimcall, passive.} =
  result = recvInto(tcpContext(ctx), buf, count, until, tok)
proc writeTcp(ctx: pointer; buf: pointer; count: int; until: Deadline;
               tok: nil CancelToken): int {.nimcall, passive.} =
  result = sendFrom(tcpContext(ctx), buf, count, until, tok)
proc endTcp(ctx: pointer) {.nimcall.} = shutdownWrite(tcpContext(ctx))
proc interruptTcp(ctx: pointer) {.nimcall.} = interrupt(tcpContext(ctx))
proc closeTcp(ctx: pointer): int {.nimcall, passive.} =
  close(tcpContext(ctx))
  result = 0

var operations = StreamOps(recv: readTcp, send: writeTcp, shutdownWrite: endTcp,
                           interrupt: interruptTcp)

proc cancelSoon(tok: CancelToken; done: ptr Event) {.passive.} =
  sleepMs(20)
  cancel(tok)
  release(tok)
  setEvent(done)

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  var listener = listenTcp(0, "127.0.0.1")
  assert listener.ok, "transport cancellation check 32"
  var client = connect("127.0.0.1", listener.port)
  var server = accept(listener, deadline = afterMs(2000))
  assert client.isOpen and server.isOpen, "transport cancellation check 35"
  let view = unsafeBorrowStream(addr server, addr operations)
  var bytes = default(array[4, byte])
  var empty = default(array[0, byte])
  for iteration in 0..<10:
    let tok = newCancelToken()
    var done = default(Event)
    retain(tok)
    assert trySpawnTask(cancelSoon(tok, addr done)), "transport cancellation check 43"
    assert recvInto(view, bytes, afterMs(2000), tok) == ECancelled, "transport cancellation check 44"
    assert wait(addr done, afterMs(2000)) == wrReady, "transport cancellation check 45"
    release(tok)
    var payload = [byte(iteration)]
    assert sendFrom(addr client, payload) == 1, "transport cancellation check 48"
    assert recvInto(view, bytes, afterMs(2000)) == 1 and bytes[0] == payload[0], "transport cancellation check 49"
  let tok = newCancelToken()
  var done = default(Event)
  retain(tok)
  assert trySpawnTask(cancelSoon(tok, addr done)), "transport cancellation check 53"
  var outcome = 0
  let waitDeadline = afterMs(2000)
  while true:
    parkIo(nativeHandle(server), {evRead}, waitDeadline, outcome, tok)
    if outcome <= 0: break
    # Windows may report stale readiness after the preceding receive. Retry
    # the syscall as adapters do; a hint is not cancellation acknowledgement.
    var scratch = 0'u8
    assert readSome(nativeHandle(server), addr scratch, 1) == IoAgain,
      "unexpected data or EOF during readiness cancellation probe"
    yieldNow()
  assert outcome == ECancelled and server.isOpen, "transport cancellation check 56: outcome " & $outcome
  assert wait(addr done, afterMs(2000)) == wrReady, "transport cancellation check 57"
  release(tok)

  let stopped = newCancelToken()
  cancel(stopped)
  assert recvInto(view, empty, tok = stopped) == 0, "transport cancellation check 62"
  assert sendFrom(view, empty, tok = stopped) == 0, "transport cancellation check 63"
  assert sendFrom(view, bytes, tok = stopped) == ECancelled, "transport cancellation check 64"
  assert recvInto(view, bytes, tok = stopped) == ECancelled, "transport cancellation check 65"
  var addrs = default(array[MaxAddrs, SockAddrBuf])
  assert resolveAsync("127.0.0.1", listener.port, SOCK_STREAM, 0.cint,
                      resolveBuffer(addrs), tok = stopped) == ECancelled, "transport cancellation check 67"
  assert resolver.resolve4("127.0.0.1", listener.port, tok = stopped).len == 0, "transport cancellation check 69"
  assert resolver.resolve6("::1", listener.port, tok = stopped).len == 0, "transport cancellation check 70"
  assert dialHost("localhost", listener.port, tok = stopped) == -1, "transport cancellation check 71"
  assert dialTcp("127.0.0.1", listener.port, tok = stopped) == -1, "transport cancellation check 72"
  var destination = default(Endpoint)
  assert setIp(destination, [127'u8, 0, 0, 1], listener.port), "transport cancellation check 74"
  assert dialEndpoint(destination, tok = stopped) == -1, "transport cancellation check 75"
  var fd = -1.cint
  dialEndpointInline(destination, true, 2000, fd, tok = stopped)
  assert fd == -1, "transport cancellation check 78"
  release(stopped)
  close(addr client)
  close(addr server)
  closeNow(listener)
  assert liveCancelTokens() == baseline, "transport cancellation check 83"
  echo "PASS custom-transport wait cancellation/reuse and dial/resolver forwarding"

assert runMain(main()), "transport cancellation check 86"
