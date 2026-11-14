# Protocol libraries on the engine tier

This guide is for code between a program and its sockets: a proxy, a tunnel,
TLS, an HTTP server. The examples come from zal-socks, zal-ss and zal-tls. A
program that only opens connections needs [build and ownership](usage.md).

## Imports, and handing a connection back

`import zal_net/engine` gives a library descriptors and what works on them:
reads and writes that park in the caller's frame, listening and dialing,
endpoints, DNS, the relay, the datagram engine, `ServiceLife` and error
codes. It does not export `Conn`; a library that hands connections to
programs also imports `zal_net` (or `zal_net/conn`, as zal-socks' `client.nim`
does). `zal_net/raw/tcp` stays apart: its `connect` clashes with `zal_net`'s.

A handshake run on a raw descriptor ends with `initConn(fd, never, stop)`, as
zal-socks' `streamVia` does. The `Conn` takes the connected, non-blocking
socket and closes it at the end of its scope. Its token is a child of `stop`,
so cancelling `stop` ends the connection and cancelling the connection leaves
`stop` alone. `nativeHandle(c)` lends the descriptor back to engine code while
the `Conn` keeps owning it.

### A layer on a `Conn`

A protocol that keeps changing the bytes after its handshake, such as TLS,
goes on the `Conn` as a layer, and the program keeps calling `read` and
`write`. A layer is a context pointer, a `StreamOps` table and a
`LayerRelease` proc. In the table, `recv` and `send` are non-raising
`{.nimcall, passive.}` procs that return a byte count or a negative code,
`shutdownWrite` ends the sending side and `interrupt` wakes parked operations.
`releaseDescriptor(c)` hands the descriptor to the layer and `install` puts
the layer in place; from then on `fill`, `read`, `write` and `flush` go
through the table, and the release proc closes the descriptor. The `Conn`
keeps the number for `nativeHandle` and for its token, which still shuts the
socket down when cancelled. A layer that counts the bytes it reads keeps a
`ptr Counted` (`fd`, `received`, `sent`) as its context; `countedSend` is
`countedRecv` over `fdSendInline`, and the other two call `fdShutdown`:

```nim
proc countedRecv(ctx: pointer; buf: pointer; count: int; until: Deadline;
                 tok: nil CancelToken): int {.nimcall, passive.} =
  let s = cast[CountedPtr](ctx)
  fdRecvInline(s.fd, 0, buf, count, until, result, nil, tok)
  if result > 0: s.received += result

proc countedRelease(ctx: pointer) {.nimcall.} =
  let s = cast[CountedPtr](ctx)
  closeFd(s.fd)
  dealloc(s)

let countedOps = StreamOps(recv: countedRecv, send: countedSend,
                           shutdownWrite: countedShutdown, interrupt: countedInterrupt)

proc count*(c: var Conn) =
  ## Count `c`'s bytes from here on. Call it before the first read.
  let s = cast[CountedPtr](alloc0(sizeof(Counted)))
  s.fd = releaseDescriptor(c)
  install(c, s, unsafeAddr countedOps, countedRelease)
```

`install` asserts that nothing is buffered yet, since those bytes were read
below the layer, and that there is no layer. `takeLayer` hands the current
layer to a new one, which reads and writes through it and calls its release
proc from its own; zal-tls's `trySecure` runs TLS inside another layer this
way. The release is a proc because Nimony 4ba90a78 does not run a derived
object's destructor through a base `ref`, and `recv` and `send` return codes
because the compiler rejects a raising passive proc-typed value
(`tests/known/c25`). `layerOps(c) == unsafeAddr countedOps` recognises the
layer, as zal-tls's `isSecure` does. `Conn` never calls `interrupt`; a
`StreamView` over the layer does. `zal-tls/src/zal_tls/secure.nim` is the
whole example: a context from `alloc0` with a holder count, so a close_notify
still going out outlives the `Conn`.

## Descriptor operations and where a wait parks

`readSome`, `writeSome` and `acceptNow` make one non-blocking system call
and return `IoAgain` (`AcceptAgain`) when the kernel would block. A wait
suspends the passive proc that runs it. These templates park in the caller's
frame:

| Template | Waits for |
| --- | --- |
| `fdRecvInline`, `fdSendInline` | one read or write of at most `chunk` bytes (64 KiB) |
| `parkPoll`, `parkReady` | readiness against a fixed deadline; against an idle one that traffic moves |
| `parkAccept`, `acceptEach` | a pending connection; a loop over them, bound to `accepted` |
| `parkUntil`, `yieldNow` | a deadline; the loop's other tasks |
| `dialEndpointInline` | resolution and connection under one budget |
| `fillTo`, `sendAll` | a relay direction filled to a length; a buffer sent |

`fdRecv`, `fdSend`, `fdReadExactly`, `fdWriteAll`, `waitRead`, `waitWrite` and
`dialEndpoint` are passive procs that do the same, with a frame per call.

A wait that runs per read or per write stays in the caller's frame. A passive
proc gets its own frame, and with several workers the runtime hands a chain
back to the pool after two steps, so a frame per read is a trip through the
pool per read. On a loopback echo with four workers the proc form took 880 ms
against 330 ms for 20,000 round trips (the header of `zal_net/conn.nim`). A
larger step limit fixed the echo and halved the rate of some runs at 1000
connections, so it stays at two. A wait of your own is a template with `var`
results, one loop and no passive proc under it:

```nim
template recvExactly(fd: cint; p: pointer; n: int; dl: Deadline; stop: nil CancelToken;
                     ok: var bool) =
  ## `n` bytes into `p`, parking in the caller's frame.
  block:
    let total = n
    var got = 0
    ok = true
    while got < total:
      var k = 0
      fdRecvInline(fd, 0, cast[pointer](cast[uint](p) + uint(got)), total - got, dl, k, nil, stop)
      if k <= 0:
        ok = false
        break
      got += k
```

A step that runs once per connection can be a passive proc, as `refuse` is in
`zal_socks/inbound`. The SOCKS5 handshake there and the Shadowsocks request
in zal-ss's `connection.nim` are read with templates.

The templates take a deadline and up to three tokens. The operation token,
`tok`, is checked between polls of 10 ms that grow to 200 ms. A token passed
as `ownerCancel` belongs to the socket's owner: after `adoptFd(token, fd)`,
cancelling it shuts the socket down, which wakes the wait, so outside Windows
it parks once on its real deadline (WSAPoll does not reliably report a local
shutdown). `Conn` and `zal_socks/inbound` pass their token this way. Call
`releaseFd(token, fd)` before closing an adopted descriptor. `timeoutMs` is an
idle limit per operation, 0 for none. Each inline read or write is charged to
a budget per thread, and after 1 MiB or 256 calls the task yields
(`ioCheckpoint`), so a fast peer cannot keep a worker.

## A handshake, then the relay

A `Relay` from `newRelay` is a `ptr` to a pooled block that carries bytes
between `r.fd`, the accepted side, and `r.up`, with one pump per direction:
`a` from `fd` to `up`, `b` back. Each direction has a source, a sink and an
optional framer on each. `newRelay(timeoutMs, maxConns, payloadIdleMs)`
returns nil at the block limit, out of memory or once the runtime stops, and
the caller keeps its sockets. Until the pumps start, `closeRelay(r)` closes
both descriptors with a FIN, so the peer reads a reply already sent, and
`failRelay(r, why)` resets the accepted side and closes the other.
`startPumps(r)` starts `b` as a task and runs `a` in the caller's frame chain,
so it returns when the relay is over; the last pump runs the end hook, closes
both descriptors and returns the block. `r.hooks` points to a `RelayHooks`
with that hook, `onEnd(r)`, where `r.endReason`, `r.upBytes` and
`r.downBytes` tell how it went, and `onBatch(r, d, bytes)`, called after each
batch.

A handshake can read into the relay's own buffer: `fillTo(r, d, want,
deadline, res, ok)` reads until `want` bytes sit after `d.off`; it takes no
token, so only its deadline or a shut-down socket ends it. With a framer
on the source, the bytes past the handshake stay there and the framer opens
them first, as in zal-ss's `receiveRequest`. A plain source starts from spans
instead: `ensurePayload(d)`, copy the bytes to `bufAt(d, HeadRoom)`, set
`d.spans[0]`, `d.nspans` and `d.bytes`. `passEarly` in `zal_socks/inbound` is
that copy.

A framer is a `FramerObj` of regular procs called once per batch:

- `geometry`: the bytes before (`head`) and after (`tail`) each payload, the
  largest payload (`maxRecord`, at most 65535), and the room before the first
  (`headRoom`). `head` and `headRoom` stay within `HeadRoom`, 128 bytes.
- `open(r, d)` decodes the whole records in `d.buf[d.off ..< d.fill]` in place
  into `d.spans`: the span count, 0 for more bytes, `InFail` or `InEof`.
- `seal(r, d)` frames `d.spans` in place into one region `d.wOff ..< d.wEnd`.
- `atBoundary(d)` says whether the stream may end where the transport ended
  with no partial record; TLS says yes only after close_notify.
- `closeSource` and `closeSink` free the framer's state. `sourceEnded`,
  `finish` (a closing record into `d.pre`), `readFailed` and `writePrefix` may
  be nil; kTLS uses the last two.

A plain source is read into slots shaped by the sink's geometry, so a batch
is sealed where it lies, and a framed source's records are opened in place,
so a framer-to-framer relay re-seals without a copy. On Linux a plain-to-plain
direction with no batch hook moves to splice(2). State is plain data in the
block, zeroed for each connection: `sourceState[T](d)` and `sinkState[T](d)`
hold 128 bytes per direction, `protocolState[T](r)` 128 and
`extensionState[T](r)` 768 per connection.

A server whose clients name an IPv4 destination in their first seven bytes (a
SOCKS address), then send records with a two-byte length (`LenHead`), as do
the replies. Its `lenOpen` walks the window from `d.off`, adds a span for
each whole record and moves `d.off` past it:

```nim
proc lenSeal(r: Relay; d: DirectionPtr): bool =
  ## A head in front of every span, then the records moved into one region.
  var i = 0
  while i < d.nspans:
    let n = d.spans[i].len
    let start = d.spans[i].off - LenHead
    if start < 0: return false
    d.buf[start] = byte(n shr 8)
    d.buf[start + 1] = byte(n and 0xff)
    if i == 0:
      d.wOff = start
      d.wEnd = start
    elif start != d.wEnd:
      if start < d.wEnd: return false
      moveMem(bufAt(d, d.wEnd), bufAt(d, start), LenHead + n)
    d.wEnd += LenHead + n
    i += 1
  result = true

proc anywhere(d: DirectionPtr): bool = true
proc nothing(d: DirectionPtr) = discard

let lengthFramer = FramerObj(
  geometry: Geometry(head: LenHead, tail: 0, maxRecord: 65535, headRoom: 0),
  open: lenOpen, atBoundary: anywhere, seal: lenSeal,
  closeSource: nothing, closeSink: nothing)

proc serveClient(fd: cint; stop: nil CancelToken) {.passive.} =
  ## The client's first 7 bytes name an IPv4 destination (a SOCKS address);
  ## records of the length framer follow, both ways.
  let r = newRelay(60_000)
  if r == nil:
    closeFd(fd)
    return
  r.fd = fd
  r.a.src = fd
  r.a.srcFramer = unsafeAddr lengthFramer
  var res = 0
  var ok = false
  fillTo(r, addr r.a, 7, afterMs(10_000), res, ok)
  var v = default(SocksAddrView)
  var dest = default(Endpoint)
  ok = ok and viewSocksAddr(buf(addr r.a), r.a.off, r.a.fill, v) and v.kind == epIp4 and
       toEndpoint(buf(addr r.a), v, dest)
  if not ok:
    failRelay(r, "address")
    return
  r.a.off += v.used          # the records after it stay buffered for the pump
  var up: cint = -1
  dialEndpointInline(dest, true, 10_000, up, never, stop)
  if up < 0:
    failRelay(r, "dial")
    return
  r.up = up
  r.a.dst = up
  r.b.src = up
  r.b.dst = fd
  r.b.dstFramer = unsafeAddr lengthFramer
  startPumps(r)
```

zal-tls's `raw/framer.nim` (TLS records, KeyUpdate through the prefix,
close_notify from `finish`, kTLS) and zal-ss's `framer.nim` are full framers.

## The datagram engine

One engine carries every UDP listener of a service, as one task on the pool.
A listener is a UDP socket and a `ListenerCodec`. The codec's `open` decodes a
client's datagram in place, finds or makes its association and names the
destination and payload; the engine sends the payload on, direct unless a
hook routes it, and `sealReply` frames the answer. The engine calls codec
procs one at a time, and they must not park. A codec whose datagrams start
with a SOCKS address:

```nim
proc openAddressed(e: ptr DatagramEngine; ib: int; p: BytesPtr; n: int;
                   peer: ptr SockaddrStorage; peerLen: cuint; now: int64;
                   pkt: var Packet): bool =
  ## A client's datagram: a SOCKS address, then the payload for it.
  var v = default(SocksAddrView)
  if not viewSocksAddr(p, 0, n, v): return false
  let id = peerKey(peer, peerLen)
  var slot = lookupAssoc(e, ib, id)
  if slot < 0: slot = claimAssoc(e, ib, id, now)
  if slot < 0: return false
  setPeer(assocAt(e, slot), peer, peerLen)
  pkt.slot = slot
  pkt.dst = endpointView(p, v)
  pkt.pay = bytesPtr(addr p[v.used])
  pkt.payLen = n - v.used
  result = true

proc sealAddressed(e: ptr DatagramEngine; slot: int; src: EndpointView;
                   pay: BytesPtr; payLen: int; outp: BytesPtr; cap: int; now: int64): int =
  ## A reply for the client: the sender's SOCKS address, then the payload.
  let head = encodeSocksAddr(src, outp, cap)
  if head == 0 or payLen > cap - head: return 0
  if payLen > 0: copyMem(addr outp[head], pay, payLen)
  result = head + payLen

let addressed = ListenerCodec(open: openAddressed, sealReply: sealAddressed,
                              replyOverhead: MaxSocksAddr)
```

`setPeer` records where replies go; `Packet.dst` may borrow the datagram for
this dispatch; `replyOverhead` is the most `sealReply` adds. A listener's
codec state lives in `listenerState[T]` (64 bytes), set up by `bindListener`
and released by `unbindListener`; an association's in `associationState[T]`
(256 bytes), released by `freeAssoc`.

Other tasks talk to the engine with messages: `addListener`, `removeListener`,
`stopEngine`, and `newEngineMsg(MsgCall)` with a `call` proc run on the
engine. The sender waits for `engineMsgDone`, reads `ok` and releases it:

```nim
proc waitDone(m: ptr EngineMsg): bool {.passive.} =
  while not engineMsgDone(m): sleepMs(1)
  result = m.ok
  releaseEngineMsg(m)
```

A service makes its engine with `newDatagramEngine` and `startEngine`, serves
a socket from `tryListenUdp` with `waitDone(addListener(e, 0, u.fd, unsafeAddr
addressed))`, and at the end posts `stopEngine`, waits for `engineStopped` and
calls `freeEngine` until it returns true, as zal-socks' `serve` does.

`addListener` owns the socket from the call on. zal-socks makes one listener
per UDP ASSOCIATE (`holdUdp` in `zal_socks/inbound`), so it raises
`listenerLimit` to its handshake limit. `EngineHooks` let a framework route:
`route` picks a `LegChoice` per destination, a framed leg (`LegKind`) sends
through a server in its own framing, and `alive`, `onBytes` and `onEnd`
follow owned associations. zal-ss's `private/forward.nim` routes the local
proxy's datagrams to one Shadowsocks leg set by a `MsgCall`, and zal-socks'
`udpLeg` runs UDP ASSOCIATE on the blocking pool (`legSetup`).

## A service with several accept loops

A server runs one accept loop per worker on one listener and a handler per
connection. Stopping it means refusing new work, waking every wait, and
waiting for the last handler to leave, in that order. `ServiceLife`
(`zal_net/engine/service.nim`) keeps the order.

| Call | Where | What it does |
| --- | --- | --- |
| `initLife` | constructor | a new stop token; the caller sets `listener` |
| `beginServe` | `serve` | false for a second `serve` and for one after `stop` |
| `enterAcceptor`, `leaveAcceptor` | each accept loop | the last to leave gets true and sets `done` |
| `readyToAccept` | `serve` | the loops are counted; a waiting `stop` may go on |
| `borrow(limit)`, `unborrow` | each connection | a place among `limit` handshakes; none once closing |
| `closeAdmission` | `stop` | cancels `stop`, closes the listener once its loops saw it, closes `udpListener` |
| `waitQuiet(deadline)` | `serve` | until `done` is set and no place is held |

Destroying a `ServiceLife` closes a listener that was never served. A
`Forwarder` relays every connection to one address. It is a `ref` holding
`target`, `maxPending` and `life`, with a `tryListenTcp` descriptor in
`life.listener` and `closeAdmission` as its `stop`. Its handler, `forward`,
adopts the socket into `life.stop`, dials, and starts a relay as in the
previous section:

```nim
proc acceptLoop(fd: cint; f: sink Forwarder) {.passive.} =
  acceptEach(fd):
    if not borrow(f.life, f.maxPending):
      closeFd(accepted)
    elif not tryStartConn(forward(accepted, f)):
      unborrow(f.life)
      closeFd(accepted)
  if leaveAcceptor(f.life): setEvent(addr f.life.done)

proc serve(f: Forwarder) {.passive, raises.} =
  if f.life.listener < 0 or not beginServe(f.life): raise BadOperation
  let fd = f.life.listener
  enterAcceptor(f.life)
  var i = 1
  while i < runtimeWorkers():
    enterAcceptor(f.life)
    if not trySpawnTask(acceptLoop(fd, f)): discard leaveAcceptor(f.life)
    i += 1
  readyToAccept(f.life)
  acceptLoop(fd, f)
  discard waitQuiet(f.life, never)
```

A place is borrowed before `tryStartConn`, which runs the handler on the
accepting worker until it first waits and returns false once shutdown has
begun, leaving the descriptor with the caller. `forward` gives its place back
before `startPumps`, which returns only when the relay ends: `stop` waits for
handshakes, and running relays finish on their own. `acceptEach` ends when
`closeAdmission` closes the listener. zal-socks' `proxy.nim` has this shape
with SOCKS5 on top and stops its datagram engine after `waitQuiet`.

## Outbound connections as a policy

A proxy learns a destination and connects to it. Where that connection
leaves from is a policy the embedding program picks, so a server holds a
`Dialer` and asks it:

```nim
var direct = DirectDialer(noDelay: true, timeoutMs: 10_000, device: "eth1", mark: 0)
server.useDialer dialer(addr direct)

let d = dialer(addr direct)
let got = dialStream(d, destination, deadline, stop)
if got.fd < 0: refuse(got.code)
```

`DirectDialer` connects from this machine: it resolves names, tries each
address within one budget, and can bind the socket to an interface or set a
Linux routing mark before the SYN. A `Dialer` is a context pointer and a
passive proc, so a library whose protocol reaches destinations through a
server of its own offers a dialer too, built on another dialer that reaches
that server. That is how outbounds chain. `tests/server/tdialer.nim` in
zal-socks shows a dialer written by hand.

A zeroed `Dialer` is unset (`isSet` is false). zal-socks and zal-ss connect
with `dialEndpointInline` in that case, which saves one passive frame per
connection. A dial is never on the per-read path.

## Errors

Engine-tier operations return codes and do not raise:

| Code | Meaning |
| --- | --- |
| above 0 | bytes moved |
| 0 | end of stream, or a zero-length operation |
| -1 to -99,999 | `-errno`; the Windows shim reports Linux numbers |
| `IoTimedOut` (-110), `ECancelled` (-125) | the deadline passed; a token was cancelled |
| `NetErrorBase - 1` to `- 13` | `StreamEof`, `TooLong`, `IoAgain`, `AcceptClosed` and the rest of `zal_net/errors` |
| -120,001 to -179,999 | a `getaddrinfo` failure, `DnsErrorBase` minus its code |
| -200,000 to -299,999 | a layer on a `Conn`: `LayerErrorBase`, `LayerErrorSpan` |

`describe(code)` builds a diagnostic, allocating only then. `zal_net/engine`
exports two, `errors.describe` and `dns.describe` (which adds the resolver's
text), so call it qualified: `dns.describe(code)`.

The application tier raises Nimony's `ErrorCode`, a value, so a raise
allocates nothing. `checkIo(code)` raises for a negative code and `failIo`
for any, through `errorKind`: `IoTimedOut` becomes `TimeoutError`,
`ECancelled` `AbortedOperation`, `StreamEof` `EndOfStreamError`, a DNS code
`NameNotFound`, an errno its POSIX error (a table on Windows), a layer code
`ProtocolError`, anything else `IOError`. A library that offers both forms
writes the one that returns a code, then a wrapper that passes it to
`checkIo`, as zal-tls's `trySecure` and `secure` do.

`Conn` raises `ProtocolError` for a layer's codes, from `LayerErrorBase`
(-200,000) down to `LayerErrorBase - LayerErrorSpan + 1`, so a program
catches one error for every layer, and the layer's own `describe` gives the
detail. TLS uses the first 2000 (`TlsErrorBase` is -200,000, its alerts start
at -201,000). Nothing hands out the rest, so a new layer picks a block no
other layer in the program uses:

```nim
const
  FrameBase = LayerErrorBase - 10_000   ## past the codes TLS uses
  BadFrame = FrameBase - 1              ## a record that does not parse
  FrameTooLong = FrameBase - 2

proc describeFrame(code: int): string =
  case code
  of BadFrame: "bad frame"
  of FrameTooLong: "frame too long"
  else: dns.describe(code)
```
