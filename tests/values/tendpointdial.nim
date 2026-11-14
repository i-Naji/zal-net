import zal_net/net/endpointdial
## Dialing an Endpoint: an IP, a name through the resolver, and a refused port.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/private/core/waitq
import zal_net/raw/socket
import zal_net/net/endpoint

proc main() {.passive.} =
  let l = tryListenTcp(0, bindAddr = "127.0.0.1")
  assert l.ok
  let port = localPort(l.fd)
  var d = default(Endpoint)
  assert parseHostPort("127.0.0.1:" & $port, d)
  let a = dialEndpoint(d)
  assert a >= 0
  closeFd(a)
  assert parseHost("localhost", port, d) and d.kind == epName
  var c = dialEndpoint(d)
  if c < 0:
    # localhost may resolve to ::1 first; the listener is IPv4 only.
    assert parseHost("127.0.0.1", port, d)
    c = dialEndpoint(d)
  assert c >= 0
  closeFd(c)
  echo "PASS dial an IP and a name"
  assert closeListener(l.fd, acceptors = 0) == wrReady
  assert parseHostPort("127.0.0.1:" & $port, d)
  assert dialEndpoint(d, timeoutMs = 2000) < 0
  echo "PASS refused"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
