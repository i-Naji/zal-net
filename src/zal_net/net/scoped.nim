## Optional scoped owners. The body runs in the caller's passive frame;
## every exit drains close on the owning loop. Destructors never perform this
## blocking drain. Choose an explicit close deadline when bounded waiting matters.
import zal_net/foundation/tcp, zal_net/foundation/unix, zal_net/foundation/udp, zal_net/foundation/tcplistener

template withTcp*(owner: TcpConnRef; body: untyped) =
  block:
    let held = owner
    defer: discard close(held)
    body

template withUnix*(owner: UnixConnRef; body: untyped) =
  block:
    let held = owner
    defer: discard close(held)
    body

template withUdp*(owner: UdpSocketRef; body: untyped) =
  block:
    let held = owner
    defer: discard close(held)
    body

template withListener*(owner: TcpListenerRef; body: untyped) =
  block:
    let held = owner
    defer: discard close(held)
    body
