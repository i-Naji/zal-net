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
