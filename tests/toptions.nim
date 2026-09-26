## Common options as methods: buffers granted; keepalive with its timers;
## a TTL set on the sender arrives in the receiver's metadata; linger 0
## resets the peer; reusePort lets two UDP sockets and two TCP listeners
## share a port, and without it the second bind is refused.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/tcp
import zal_net/raw/udp
import zal_net/net/options
import zal_net/raw/advanced

proc main() {.passive.} =
  var buf = default(array[64, byte])
  let msg = [byte 1, 2, 3, 4]

  var r = bindUdp(0, "127.0.0.1", timeoutMs = 2000)
  assert r.ok and enableInfo(r)
  # 128 KiB: stock Linux caps a request at twice net.core.rmem_max and
  # wmem_max (212992 today, 131071 on old kernels).
  assert setRecvBuffer(r, 128 shl 10) and recvBuffer(r) >= 128 shl 10
  assert setSendBuffer(r, 128 shl 10) and sendBuffer(r) >= 128 shl 10
  var s = bindUdp(0, "127.0.0.1")
  assert setTtl(s, 7) and ttl(s) == 7
  assert setTos(s, 0x20)
  var info = default(DatagramInfo)
  assert sendTo(s, msg, localAddress(r)) == 4
  assert recvFrom(r, buf, info) == 4 and info.ttl == 7, $info.ttl
  echo "PASS buffers granted; TTL 7 set on the sender, seen by the receiver (tos ", info.tos, ")"

  # reusePort: two sockets on one port; without it, refused. Windows has
  # no such option: there a second bind is always refused.
  let port = port(localAddress(r))
  assert not bindUdp(port, "127.0.0.1").ok
  var l1 = listenTcp(0, "127.0.0.1", reusePort = true)
  assert l1.ok
  when defined(windows):
    assert not listenTcp(port(l1), "127.0.0.1", reusePort = true).ok
    echo "PASS a second bind to a port is refused (no reusePort on Windows)"
  else:
    var a = bindUdp(0, "127.0.0.1", reusePort = true)
    assert a.ok
    var b = bindUdp(port(localAddress(a)), "127.0.0.1", reusePort = true)
    assert b.ok
    close(a)
    close(b)
    var l2 = listenTcp(port(l1), "127.0.0.1", reusePort = true)
    assert l2.ok
    closeNow(l2)
    echo "PASS reusePort: UDP sockets and TCP listeners share a port"

  # Keepalive and linger on a TCP connection.
  var c = connect(initSocketAddress(loopback4(), port(l1)))
  assert c.isOpen
  var srv = accept(l1)
  assert srv.isOpen
  assert setKeepAlive(c, idleSec = 30, intervalSec = 5, count = 3)
  assert setKeepAlive(c, false)
  assert setKeepAlive(c, idleSec = 30, intervalSec = 5, count = 3)
  assert setUserTimeout(c, 5000)
  assert setLinger(srv, 0)
  close(addr srv)                                  # a reset, not a FIN
  let n = recv(addr c, buf)
  assert n < 0, $n
  close(addr c)
  closeNow(l1)
  echo "PASS keepalive with timers; linger 0 reset the peer (", n, ")"
  close(r)
  close(s)
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
