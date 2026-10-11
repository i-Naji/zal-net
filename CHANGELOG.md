# Changelog

## Unreleased

- Initial standard-runtime package.
- Use Nimony `0a48dbd4` and configure the standard pool through ZAL_WORKERS.
- Use Nimony `d5fc40e3` for delayed argument ownership and iterator cleanup.
- Join process-owned services before standard-pool shutdown.
- Use Nimony `aa01546a` for the platform I/O update.
- Drain queued datagram replies before idle expiry.
- Use Nimony `d5396682` for closure layout and readiness retry fixes.
