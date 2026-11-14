{.feature: "assumeSync".}
## The raw constructors conn.nim builds on: exact native refusal codes, DNS
## failures, Unix paths, busy and closed output owners, and shutdown.
import std/[assertions, syncio, envvars]
import zal_net/[rt, errors], zal_net/rt/[sync, cancel, blocking]
import zal_net/raw/[tcp, unix, socket], zal_net/net/address, zal_net/net/sockaddr
import zal_net/net/dns as resolver
import zal_net/private/os

proc main() {.passive.} =
  let tokenBaseline = liveCancelTokens()
  var listener = listenTcp(0, "127.0.0.1")
  assert listener.ok, "TCP listener setup"
  let destination = initSocketAddress(loopback4(), listener.port)
  var raw = default(TcpStream)
  raw.timeoutMs = 73
  let stopped = newCancelToken()
  cancel(stopped)
  assert connectInto(addr raw, destination, tok=stopped) == ECancelled, "cancelled raw TCP construction"
  assert not raw.isOpen and raw.timeoutMs == 73, "cancelled construction preserves timeout"
  assert connectInto(addr raw, destination, deadline=afterMs(0)) == IoTimedOut, "expired raw TCP construction"
  assert connectInto(addr raw, default(SocketAddress)) == InvalidInput, "invalid address rejection"
  assert connectInto(addr raw, "127.0.0.1\0ignored", listener.port) == InvalidInput
  assert connectInto(addr raw, destination, streamTimeoutMs=222) == 0, "raw TCP success"
  assert raw.isOpen and raw.timeoutMs == 222, "successful construction installs timeout"
  let original = nativeHandle(raw)
  assert connectInto(addr raw, destination) == ResourceBusy, "live owner rejection"
  assert connectInto(addr raw, "localhost", listener.port) == ResourceBusy
  assert raw.isOpen and nativeHandle(raw) == original, "live owner descriptor preserved"
  var peer = accept(listener, deadline=afterMs(2000))
  assert peer.isOpen, "accept connected raw TCP peer"
  var bytes = [31'u8]
  assert sendFrom(addr raw, bytes, afterMs(2000)) == 1, "raw TCP send"
  assert recvInto(addr peer, bytes, afterMs(2000)) == 1 and bytes[0] == 31, "raw TCP receive"
  close(addr raw)
  close(addr peer)

  # A bound, never-listening socket times out on Darwin. Close an actual
  # listener instead; these local sequential checks use its former port.
  var refusedListener = listenTcp(0, "127.0.0.1")
  assert refusedListener.ok, "refusal fixture listener"
  let refusedPort = refusedListener.port
  closeNow(refusedListener)
  let refused = initSocketAddress(loopback4(), refusedPort)
  const refusedCode = when defined(macosx): -61 else: -111
  # Windows retries loopback refusal for about two seconds before publishing
  # SO_ERROR. Allow the OS to finish, rather than asserting past our deadline.
  const failureCycles = when defined(windows): 4 else: 32
  for cycle in 0..<failureCycles:
    let addressFailure = connectInto(addr raw, refused, deadline=afterMs(5000))
    assert addressFailure == refusedCode, "address refusal code " & $addressFailure
    assert not raw.isOpen, "refused raw owner remains closed"
    let hostFailure = connectInto(addr raw, "localhost", refusedPort, deadline=afterMs(5000))
    assert hostFailure == refusedCode, "localhost refusal code " & $hostFailure
    assert not raw.isOpen, "refused hostname owner remains closed"

  var addrs = default(array[MaxAddrs, SockAddrBuf])
  addrs[0].len = 77
  let outp = resolver.resolveBuffer(addrs)
  assert resolver.resolveAsync("127.0.0.1", 0, SOCK_STREAM, 0.cint, outp, tok=stopped) == ECancelled, "numeric DNS cancellation"
  assert resolver.resolveAsync("127.0.0.1", 0, SOCK_STREAM, 0.cint, outp, deadline=afterMs(0)) == IoTimedOut, "numeric DNS deadline"
  assert resolver.resolveAsync("127.0.0.1\0ignored", 0, SOCK_STREAM, 0.cint, outp) == InvalidInput, "embedded NUL DNS rejection"
  assert addrs[0].len == 77, "rejected DNS preserves output"
  var hints = default(AddrInfo)
  hints.ai_family = -1
  hints.ai_socktype = SOCK_STREAM
  var native: AddrInfoList = nil
  let resolverCode = getaddrinfo("localhost", nil, addr hints, addr native)
  assert resolverCode != 0 and native == nil, "native invalid-family resolver fixture"
  let code = resolver.resolveAsync("localhost", 0, SOCK_STREAM, -1.cint, outp)
  assert code == DnsErrorBase - int(resolverCode), "preserve signed getaddrinfo code"
  assert addrs[0].len == 77, "failed DNS preserves output"
  assert resolver.describe(code).len > 0 and errors.describe(code).len > 0, "qualified resolver diagnostics"
  release(stopped)
  closeNow(listener)

  when defined(windows):
    let path = getEnv("TEMP") & "\\nn-connect-" & $getPid() & ".sock"
  else:
    let path = "/tmp/nn-connect-" & $getPid() & ".sock"
  var localListener = listenUnix(path)
  assert localListener.ok, "Unix listener setup"
  let listenerFd = nativeHandle(localListener)
  assert listenUnixInto(addr localListener, path) == ResourceBusy
  assert nativeHandle(localListener) == listenerFd and localListener.path == path
  var localRaw = default(UnixStream)
  assert acceptUnixInto(addr localRaw, addr localListener, deadline=afterMs(0)) == IoTimedOut
  assert not localRaw.isOpen and localRaw.timeoutMs == 0
  let stoppedAccept = newCancelToken()
  cancel(stoppedAccept)
  assert acceptUnixInto(addr localRaw, addr localListener, tok=stoppedAccept) == ECancelled
  release(stoppedAccept)
  assert nativeHandle(localListener) == listenerFd and not localRaw.isOpen
  assert connectUnixInto(addr localRaw, "") == InvalidInput
  assert connectUnixInto(addr localRaw, path & "\0suffix") == InvalidInput
  assert not localRaw.isOpen, "NUL path rejection preserves the output owner"
  assert connectUnixInto(addr localRaw, path, deadline=afterMs(0)) == IoTimedOut, "expired raw Unix construction"
  assert connectUnixInto(addr localRaw, path) == 0, "raw Unix success"
  let localFd = nativeHandle(localRaw)
  assert acceptUnixInto(addr localRaw, addr localListener) == ResourceBusy
  assert nativeHandle(localRaw) == localFd
  assert connectUnixInto(addr localRaw, path) == ResourceBusy, "live Unix owner rejection"
  assert nativeHandle(localRaw) == localFd, "live Unix descriptor preserved"
  var localPeer = accept(localListener, deadline=afterMs(2000))
  assert localPeer.isOpen, "accept raw Unix peer"
  close(addr localPeer)
  close(addr localRaw)
  closeNow(localListener)
  let localFailure = connectUnixInto(addr localRaw, path)
  assert localFailure < 0 and not localRaw.isOpen, "closed Unix path failure"

  stopBlockingPool()
  while not joinBlockingPool(): parkUntil(afterMs(1))
  let drainedBy = afterMs(2000)
  while liveCancelTokens() != tokenBaseline and monoNow() < drainedBy:
    parkUntil(afterMs(1))
  assert liveCancelTokens() == tokenBaseline, "constructor tokens drained"
  assert liveBlockingJobs() == 0, "constructor resolver jobs drained"
  requestStop()
  assert connectInto(addr raw, destination) == ResourceClosed, "raw shutdown rejection"
  echo "PASS raw TCP and Unix constructors: refusal codes, DNS failures, busy owners, shutdown"

assert runMain(main()), "calling-thread root entry"
