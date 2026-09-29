# Build and ownership

Nimony is required; standard Nim only bootstraps the compiler.
Build an isolated checkout with `scripts/nimony-setup.sh build/toolchain`.

```sh
NIMONY=build/toolchain/bin/nimony scripts/test.sh
NIMONY=build/toolchain/bin/nimony SUITE=full scripts/test.sh
```

`SUITE=stress` and `SUITE=platform` select slower or platform-specific checks.
Windows uses `scripts/test.ps1`; `-Flags -d:nimIoringWsaPoll` selects its fallback.
Tests and compiler caches stay in ignored `build/` directories.

Handles retain one resource state. Aliases share ownership. One reader and one
writer may coexist; a full write keeps admission across partial sends.
Close rejects new work, cancels pending waits and drains borrowers before
releasing the descriptor. A close deadline ends the wait, not cleanup.
Destructors perform only quiescent, nonblocking cleanup.

Use retained transports for composition. Unsafe borrowed views cannot close or
transfer owners. A rejected transfer preserves the source; admitted transfer
invalidates its aliases and makes the destination responsible for cleanup.
Low-level I/O reports bytes and failure separately. Do not replay partial writes.

The process runner drains tasks before shutting down the standard pool.
The runtime cannot restart. Library close never shuts down the pool.
Set `ZAL_WORKERS` before startup to configure the standard pool.
The default comes from its CPU count/affinity; `runtimeWorkers()` reports it.
I/O uses nonblocking native calls and public standard readiness/timer operations.
Cancellation returns after the pending standard operation releases its storage.

Linux offloads and raw-network/TUN tests need native capabilities and permissions.
Platform errors and unavailable checks are kept explicit.
