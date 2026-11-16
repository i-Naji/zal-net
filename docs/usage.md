# Build and ownership

Nimony is required; standard Nim only bootstraps the compiler.
Build an isolated checkout with `scripts/nimony-setup.sh build/toolchain`.

```sh
NIMONY=build/toolchain/bin/nimony scripts/test.sh
NIMONY=build/toolchain/bin/nimony SUITE=full scripts/test.sh
```

`scripts/test.sh` builds `tools/tester.nim` and runs it. Tests live in
`tests/<category>/t*.nim`, as in Nimony's own suite, and a file next to a test
changes how it is judged: `tname.output` is what it must print, `tname.msgs`
means the compiler must reject it with those messages, `tname.args` adds
compiler flags, `tname.os` names the systems it runs on. Each test has 180
seconds per run. `tests/known` holds compiler repros; they report what the
compiler does today and never fail the run.

`TESTS="tests/relay tests/conn/techo.nim"` picks categories or files,
`SUITE=stress` loops the shutdown and engine cases, `WORKERS="1 4"` runs every
program at both worker counts. `build/test/tester --overwrite <tests>` records
new goldens. Windows uses `scripts/test.ps1` with the same choices;
`-Flags -d:nimIoringWsaPoll` selects its fallback.
Tests and compiler caches stay in ignored `build/` directories.

## Two imports

`import zal_net` is for programs: `Conn` and `Listener` for TCP and
Unix-domain streams, `UdpSocket`, `serve`, the runtime, cancellation tokens,
events and channels, deadlines, socket addresses, signals and the log.
`import zal_net/engine` is for protocol libraries such as a proxy or an HTTP
server: reads and writes on a descriptor in the caller's frame, readiness
parks, listening and dialing by descriptor, endpoints, the relay and the
datagram engine. The two import together without clashes. `zal_net/raw/*`
holds the rest: raw TCP, Unix and UDP owners, datagram batches, IP, ICMP and
TUN/TAP. [Protocol libraries on the engine tier](engine.md) shows how a
library uses the second import.

## Ownership

A `Conn` and a `UdpSocket` own their descriptor. They cannot be copied,
moving one moves the descriptor, and each closes when it goes out of scope.
`close` closes earlier and can be called twice. A `Listener` has no
destructor: its owner calls `close`, which also removes a Unix socket's file.
One task uses a value at a time, which is why no operation takes a lock.
Another task reaches a connection through its token.

Every failure raises an `ErrorCode`. `fill` and `read` answer the bytes that
arrived, and 0 means the peer finished. `TimeoutError` means the deadline came
first and `AbortedOperation` that a token was cancelled. A write sends all of
its bytes or raises; it does not say how many went out before the raise.

`peek` returns a view into the connection's buffer. Finish with it before the
next `fill`, `read` or `consume`. `scratch` lends staging bytes for a frame
that `flush` then writes in one call.

## Deadlines and cancellation

`renew` sets a standing deadline on a `Conn` or a `UdpSocket`. Each operation
ends at the earlier of it and its own, so a call can tighten it and cannot
widen it. `never` clears it. `connect` starts with none: its deadline bounds
the setup only.

Each `Conn` has its own token, a child of the `stop` token it was made with.
Cancelling the connection's token shuts the socket down: its parked
operations raise `AbortedOperation` and the peer reads the end. Cancelling the
parent ends every child; cancelling a child leaves the parent and its
siblings alone. A `Listener`'s `stop` token ends `accept` and leaves the
accepted connections running. `endConnectionsWith` names a token that ends
them. A `UdpSocket`'s token ends its waits for good; a parked wait notices
within about 200 ms, and the descriptor stays open until `close`.

`serve` runs one task per accepted connection. It closes each connection when
its handler returns or raises, passes a raised error to `onError`, and keeps
serving. It returns once the listener's token is cancelled and every handler
has finished. The context is one `ref` shared by every handler, so guard what
they change.

## Runtime

The process runner drains tasks and joins blocking/logging/signal services
before shutting down the standard pool.
`echo` is not synchronized between workers; handlers log through `zal_net/log`.
The runtime cannot restart. Library close never shuts down the pool.
Set `ZAL_WORKERS` before startup to configure the standard pool. Without it
the pool gets one worker per CPU the process may run on, capped on Linux by
the CPU quota of its cgroups (`docker --cpus`, a Kubernetes CPU limit). std's
own default keeps a CPU back for a main thread that zal leaves idle.
The standard pool runs up to `-d:trampolineSteps` (default 64) steps of a resumed
chain inline before it polls again. On a 10-core Mac the default gives an HTTP
hello server 13% more requests per second at 100 and 1000 connections, while a
32-connection echo at 4 workers takes 25% longer with a 70% lower p99;
`-d:trampolineSteps=0` reverses both. Pick it per application.
`runtimeWorkers()` reports the count.
`ZAL_TASKS` caps admitted tasks (default: the descriptor limit, at least 8192).
A single worker delays datagram-engine readiness under heavy association churn; use two or more.
I/O uses nonblocking native calls and public standard readiness/timer operations.
Cancellation returns after the pending standard operation releases its storage.

Linux offloads and raw-network/TUN tests need native capabilities and permissions.
Platform errors and unavailable checks are kept explicit.
`tests/contracts` checks that the compiler rejects invalid borrows and managed
channel payloads.

`zal_net/raw/udp`'s `sendBatch` returns `BatchResult(sent, error)`: a failure
can follow a sent prefix. To retry the remainder, advance `first` by `sent` and
reduce the requested packet count by the same amount. The caller keeps the
`MmsgBatch` alive and unchanged until the operation completes. An empty packet
still sends a datagram; a zero-entry batch performs no I/O.

## Moving from the old API

`zal_net` used to export reference-counted owners with shared admission
(`OwnerLife`), retained transports and borrow admission. Those are gone from
`zal_net`, from `zal_net/engine` and from these docs. Code written against
them changes as follows.

| Old | New |
| --- | --- |
| `TcpStream` (`net/tcp`), `TcpConnRef` (`foundation/tcp`) | `Conn` |
| `TcpListener` (`net/tcp`), `TcpListenerRef` (`foundation/tcplistener`) | `Listener` |
| `connect(host, port, deadline = d)` | `connect(host, port, d)` |
| `stream.read(buf, deadline = d)`, `stream.write(buf, deadline = d)` | `c.read(buf, d)`, `c.write(buf, d)` on a `var Conn` |
| `stream.close()`, `retire(owner)`, `closeNow(owner)` | `close c`, or the end of the scope |
| `halfClose(owner)` | `shutdownWrite(c)` |
| `deadline(stream)`, `renew(stream, d)` | `renew(c, d)` |
| `lastReadFailure`, `lastWriteFailure`, `IoResult`, `IoFailure` | the raised `ErrorCode` |
| a `cancel` token per call | the connection's token, `cancelToken(c)` |
| `serve(listener, handler, ctx, onError)` with `handler(stream: TcpStream; ctx)` | `serve(listener, handler, ctx, onError)` with `handler(c: var Conn; ctx)`; cancel the listener's `stop` token to end it |
| `zal_net/raw/serve` and `ContextHandler` | `serve` |
| `net/unix`: `listen(path)`, `connect(path)`, `UnixStream`, `UnixConnRef` | `listenUnix(path)`, `connectUnix(path)`, `Conn` |
| `net/udp`: `bindUdp`, `openUdp`, `connectUdp`, `UdpSocket`; `UdpSocketRef` (`foundation/udp`) | `openUdp(port, host)` and `connect` for a default peer; `UdpSocket` |
| `recvDatagram`, `sendDatagram`, UDP `read` and `write` | `recvFrom`, `sendTo`, `recv`, `send` |
| `DatagramInfo`, multicast, broadcast and batches on the UDP owner | `zal_net/raw/udp` on `nativeHandle(u)` |
| `BufReader` (`zal_net/reader`): `readLine`, `readUntil`, `readExactly` | `Conn`: `readLine`, `fill`, `peek`, `consume` |
| `withTcp`, `withUnix`, `withUdp`, `withListener` (`net/scoped`) | the end of the value's scope |
| `OwnerLife`, `beginBorrow`, `drainClose` (`ownership`) | none: one task uses a `Conn` at a time |
| `Transport`, `retainTransport`, `ownTransport`, `tcpTransport`, `unsafeBorrowStream` over an owner | a layer (a context, a `StreamOps` table and a release proc) put on a `Conn` with `install`, as zal-tls's `secure` does |
| `ByteStream`, `DuplexStream` (`zal_net/streamconcepts`) | the same concepts in `zal_net/net/stream` |
| the datagram engine's `Listener` | `DatagramListener` |
| `zal_net/foundation/readiness` | the datagram engine's own, in `private/datagram` |
| `TcpConnRef` and the old UDP sockets from `zal_net/engine` | a descriptor, or `initConn(fd, deadline)` to hand it to a program |

`net/tcp`, `net/tcpview`, `net/transport`, `foundation/tcp`,
`foundation/tcplistener`, `ownership` and `io` went last, once zal-tls had
moved to `Conn`.
