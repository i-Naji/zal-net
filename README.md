# zal-net

Networking for Nimony: TCP, UDP, Unix sockets, cancellation and task scopes.
Protocol libraries use the public streams and retained transport adapters.
Raw IP, ICMP, TUN/TAP, batching and relay/datagram engines are explicit imports.

```nim
import std/syncio
import zal_net

proc main() {.passive.} =
  try:
    let stream = connect("127.0.0.1", 7007, deadline=afterMs(2000))
    defer: stream.close()
    var bytes = [104'u8, 105]
    stream.write(bytes)
    discard stream.read(bytes)
  except ErrorCode as error:
    echo error

discard runMain(main())
```

Uses `std/ioring` and `std/threadpool`. Build with the Nimony revision in
`ci/nimony.ref` and `--mm:atomicArc`. `-d:useMimalloc` is optional.
See [build and ownership](docs/usage.md). MIT license.
