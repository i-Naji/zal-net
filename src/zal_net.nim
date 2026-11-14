# zal-net: networking for Nimony programs. This import gives a program TCP
# and Unix-domain connections (`Conn`, `Listener`), UDP sockets (`UdpSocket`),
# `serve` with one task per connection, the runtime (`runMain`,
# `trySpawnTask`, `yieldNow`, `stopping`), cancellation tokens, events and
# channels, deadlines, socket addresses, signals and the log.
#
# An echo server and a client that talks to it:
#
#   proc echoConn(c: var Conn; app: App) {.passive, raises.} =
#     var buffer = default(array[4096, byte])
#     while true:
#       let n = c.read(buffer)
#       if n == 0: break
#       c.write buffer.toOpenArray(0, n - 1)
#
#   var listener = listen(7007, "127.0.0.1", stop = stop)
#   serve(listener, echoConn, app, report)      # returns after cancel(stop)
#
#   var c = connect("127.0.0.1", 7007, afterMs(2_000))
#   c.write "hello\n"
#   assert c.readLine() == "hello"
#
# `examples/application_echo.nim` is the whole server. Protocol libraries,
# such as a proxy or an HTTP server, import `zal_net/engine` for descriptors,
# the relay and the datagram engine.

import zal_net/rt
import zal_net/rt/[cancel, sync, time, signals]
import zal_net/[conn, serve, udp, log]
import zal_net/net/address
export rt, cancel, sync, time, signals, conn, serve, udp, log, address
