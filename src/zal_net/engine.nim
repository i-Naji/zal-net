# The engine tier: one import for protocol libraries, such as a proxy or an
# HTTP server. The application tier (`zal_net/conn`, `zal_net/serve`,
# `zal_net/udp`) gives a program values that own their sockets. This tier
# gives a library the parts those values are made of: descriptors it reads
# and writes in its own frame, readiness parks on its own deadlines, and the
# two engines that carry bytes once a handshake is done.
#
# Runtime and tasks: `rt` (`runMain`, `trySpawnTask`, `tryStartConn`,
# `parkPoll`), cancellation tokens, events and waits, the blocking pool and
# signal handling.
# Fd operations and parking: reads, writes and accepts on a non-blocking
# descriptor (`fdRecvInline`, `fdSendInline`, `acceptNow`), socket options,
# batched datagram calls (`MmsgBatch`), and the blocking calls for the
# blocking pool (`engine/blockingio`).
# Listening, dialing and addresses: `tryListenTcp`, `tryListenUdp`,
# `dialEndpointInline`, endpoints, socket addresses, DNS, I/O failures, the
# TCP owners a library hands to an application, and UDP sockets.
# The relay engine: `Relay` blocks with one pump per direction, framers,
# handshake helpers and `acceptEach`.
# The datagram engine: one thread for every UDP listener, with listener
# codecs, legs and associations.
# Byte helpers and error codes: `buffers`, `bytes`, the SOCKS address codec,
# `errors` and the log.
#
# A SOCKS server, cut down from zal-socks:
#
#   proc serveConn(fd: cint; s: sink SocksServer) {.passive.} =
#     var h = Hs(fd: fd, fill: 0, deadline: afterMs(s.handshakeMs))
#     var k = 0
#     fdRecvInline(h.fd, 0, addr h.buf[h.fill], h.buf.len - h.fill, h.deadline, k, nil, s.stop)
#     # ... parse the request into `dest`, read again while it is short ...
#     var up: cint = -1
#     dialEndpointInline(dest, s.noDelay, s.dialMs, up, never, s.stop)
#     let c = newRelay(s.idleMs, s.maxRelays)
#     c.fd = fd; c.up = up
#     c.a.src = fd; c.a.dst = up; c.b.src = up; c.b.dst = fd
#     startPumps(c)
#
#   proc acceptLoop(fd: cint; s: sink SocksServer) {.passive.} =
#     acceptEach(fd):
#       if not tryStartConn(serveConn(accepted, s)): closeFd(accepted)

# Runtime and tasks
import zal_net/rt
import zal_net/rt/[cancel, sync, blocking, signals]
export rt, cancel, sync, blocking, signals

# Fd operations and parking
import zal_net/raw/[io, socket, fdops, mmsg]
import zal_net/engine/blockingio
export io, socket, fdops, mmsg, blockingio

# Listening, dialing and addresses. `zal_net/raw/tcp` stays a separate
# import: its `TcpStream`, `TcpListener` and `connect` clash with `zal_net`'s.
import zal_net/net/[endpoint, endpointdial, sockaddr, dns, address, failure, udp]
import zal_net/foundation/tcp as owners
export endpoint, endpointdial, sockaddr, dns, address, failure, udp, owners

# The relay engine
import zal_net/relay
export relay

# The datagram engine
import zal_net/datagram
export datagram

# Byte helpers and error codes
import zal_net/[buffers, bytes, errors, log]
import zal_net/codecs/socksaddr
export buffers, bytes, errors, log, socksaddr
