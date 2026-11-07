# Changelog

## Unreleased

- Initial standard-runtime package.
- Use Nimony `0a48dbd4` and configure the standard pool through ZAL_WORKERS.
- Use Nimony `d5fc40e3` for delayed argument ownership and iterator cleanup.
- Join process-owned services before standard-pool shutdown.
- Use Nimony `aa01546a` for the platform I/O update.
- Drain queued datagram replies before idle expiry.
- Use Nimony `d5396682` for closure layout and readiness retry fixes.
- Resume passive calls in bounded batches on the standard pool.
- Drain queued resumptions before pool shutdown.
- Use Nimony `2593bf85` for symbol lookup and raises fixes.
- Return an error from relay when its state cannot be allocated.
- Run the allocator's thread hooks on library-started threads.
- Build without -d:useMimalloc; the native allocator is supported.
- Back off cancellation and readiness polling for idle connections.
- Park owned sockets on their real deadline: idle connections no longer poll.
- Admit tasks up to ZAL_TASKS or the descriptor limit instead of 8192.
- Park Event, Notify and channel waits on their real deadline; stop wakes them at once.
- Back off idle datagram-engine polls to a second; retired sockets are woken at once.
- Wake relay pumps at once when the other side fails on the Linux epoll backend.
- Notice a rejected kTLS record while a relay reader is parked on the epoll backend.
- Back off a writer stalled behind a half-closed peer on io_uring instead of retrying every millisecond.
- Use Nimony `112365da`.
- Add a standing deadline to TCP and Unix streams (`deadline`, `renew`).
- Use Nimony `c923e3c9`: a call now also finds the routines of its argument's module.
- Owners close with `retire` and half-close with `halfClose`, and datagram owners use `recvDatagram` and `sendDatagram`; `close`, `shutdownWrite`, `recvFrom` and `sendTo` are the raising forms in net/tcp, net/unix and net/udp.
- net/tcp, net/unix and net/udp re-export the owners' `port`, `path`, `localAddress`, `remoteAddress`, `lastReadFailure`, `lastWriteFailure`, `deadline` and `renew`.
- Use Nimony `0da5a6b7`: a type with a written `=destroy` also defines `=wasMoved`.
- `IoTimedOut` comes from std/ioring; docs/usage.md describes the pool's `-d:trampolineSteps` trade-off.
- Use Nimony `941d128a`: `supportsCopyMem` folds at compile time.
- Plain-data checks use `supportsCopyMem`: a type with a destructor is rejected, a non-closure proc is plain.
- Use Nimony `288097b1`: deadline checks go through `expired`, which rt/time re-exports.
- Use Nimony `ee549766`: `readLine` returns -12 when the line cannot be stored.
- `runtimeWorkers` and the stats shards keep the pool size after the runtime has finished.
