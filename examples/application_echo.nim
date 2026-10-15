## nimony c --path:src examples/application_echo.nim
import std/syncio
import zal_net
import zal_net/log

type Context = ref object
  connections: int

proc report(ctx: Context; error: ErrorCode) = logWarn("connection: " & $error)

proc echoClient(stream: TcpStream; ctx: Context) {.passive, raises.} =
  inc ctx.connections
  var bytes = default(array[16_384, byte])
  while true:
    let count = stream.read(bytes)
    if count == 0:
      break
    stream.write(bytes.toOpenArray(0, count - 1))

proc main(ctx: sink Context) {.passive.} =
  try:
    discard initLogger()
    let server = listen(7007)
    defer: server.close()
    echo "echo on :7007"
    flushFile(stdout)
    serve(server, echoClient, ctx, report)
  except ErrorCode as error:
    echo "server: ", error

discard runMain(main(Context()))
