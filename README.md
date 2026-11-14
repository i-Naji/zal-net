# zal-net

Networking for Nimony: TCP, Unix-domain and UDP sockets, a server loop with
one task per connection, cancellation tokens and the runtime they run on.
Protocol libraries import `zal_net/engine` for descriptors, the relay and the
datagram engine. Raw IP, ICMP, TUN/TAP and datagram batches are separate
imports.

```nim
import std/syncio
import zal_net

proc main() {.passive.} =
  try:
    var c = connect("127.0.0.1", 7007, afterMs(2000))
    c.write "hi\n"
    echo c.readLine(afterMs(2000))
  except ErrorCode as error:
    echo error

discard runMain(main())
```

Uses `std/ioring` and `std/threadpool`. Build with the Nimony revision in
`ci/nimony.ref` and `--mm:atomicArc`. `-d:useMimalloc` is optional.
See [build and ownership](docs/usage.md). MIT license.
