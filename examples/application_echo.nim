## nimony c --path:src examples/application_echo.nim
## An echo server on port 7007, one task per connection.
import std/syncio
import zal_net

type App = ref object

proc echoConn(c: var Conn; app: App) {.passive, raises.} =
  var buffer = default(array[16_384, byte])
  while true:
    let n = c.read(buffer)
    if n == 0: break
    c.write buffer.toOpenArray(0, n - 1)

proc report(app: App; error: ErrorCode) = logWarn("connection: " & $error)

proc main() {.passive.} =
  try:
    discard initLogger()
    var listener = listen(7007)
    echo "echo on :", listener.port
    flushFile(stdout)
    serve(listener, echoConn, App(), report)
  except ErrorCode as error:
    echo "server: ", error

discard runMain(main())
