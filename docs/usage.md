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

`TESTS="tests/relay tests/app/treadyio.nim"` picks categories or files,
`SUITE=stress` loops the shutdown and engine cases, `WORKERS="1 4"` runs every
program at both worker counts. `build/test/tester --overwrite <tests>` records
new goldens. Windows uses `scripts/test.ps1` with the same choices;
`-Flags -d:nimIoringWsaPoll` selects its fallback.
Tests and compiler caches stay in ignored `build/` directories.

Handles retain one resource state. Aliases share ownership. One reader and one
writer may coexist; a full write keeps admission across partial sends.
Close rejects new work, cancels pending waits and drains borrowers before
releasing the descriptor. A close deadline ends the wait, not cleanup.
Destructors perform only quiescent, nonblocking cleanup.
`renew` sets a standing deadline on a TCP or Unix stream; each read and write
ends at the earlier of it and its own. `never` clears it.

Use retained transports for composition. Unsafe borrowed views cannot close or
transfer owners. A rejected transfer preserves the source; admitted transfer
invalidates its aliases and makes the destination responsible for cleanup.
Low-level I/O reports bytes and failure separately. Do not replay partial writes.

The process runner drains tasks and joins blocking/logging/signal services
before shutting down the standard pool.
`echo` is not synchronized between workers; handlers log through `zal_net/log`.
The runtime cannot restart. Library close never shuts down the pool.
Set `ZAL_WORKERS` before startup to configure the standard pool.
The standard pool runs up to `-d:trampolineSteps` (default 64) steps of a resumed
chain inline before it polls again. On a 10-core Mac the default gives an HTTP
hello server 13% more requests per second at 100 and 1000 connections, while a
32-connection echo at 4 workers takes 25% longer with a 70% lower p99;
`-d:trampolineSteps=0` reverses both. Pick it per application.
The default comes from its CPU count/affinity; `runtimeWorkers()` reports it.
`ZAL_TASKS` caps admitted tasks (default: the descriptor limit, at least 8192).
A single worker delays datagram-engine readiness under heavy association churn; use two or more.
I/O uses nonblocking native calls and public standard readiness/timer operations.
Cancellation returns after the pending standard operation releases its storage.
A token, or closing a UDP socket, cancels an idle parked wait within about 200 ms;
closing a stream is immediate.

Linux offloads and raw-network/TUN tests need native capabilities and permissions.
Platform errors and unavailable checks are kept explicit.

`peek(reader)` returns a checked borrowed slice. End its scope before calling
`fill(reader)` or `consume(reader, count)`. Pointer overloads are for low-level
callers that manage this lifetime themselves. `readExactly(reader, buffer)`
returns `IoResult`, including bytes received before EOF or failure.
`tests/contracts` checks that the compiler rejects invalid borrows and managed
channel payloads.

`retainTransport(owner)` builds a transport from the owner's `recvInto`,
`sendFrom`, `halfClose`, `interrupt`, `retire`, `dispose` and `canTransfer`
procedures. Read and write accept a pointer, count, deadline and cancellation
token. Close, dispose and transfer checks return an integer error code.
The adapter and its retained owner slot share one allocation.

`ownTransport(owner, operations, control)` takes a `sink owned` reference
when a constructor wants to hand off its concrete owner. Build this in an
ordinary procedure, then pass the returned shared transport to passive code.
The current compiler cannot lower an owned reference local in a passive frame.
Transfer still checks for pending I/O and invalidates existing adapter aliases.

UDP `sendBatch` returns `BatchResult(sent, error)`: a failure can follow a sent
prefix. To retry the remainder, advance `first` by `sent` and reduce the requested
packet count by the same amount. The caller keeps the `MmsgBatch` alive and
unchanged until the operation completes. An empty packet still sends a datagram;
a zero-entry batch performs no I/O.
