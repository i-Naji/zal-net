import std/[assertions, syncio, atomics]
import zal_net/rt
import zal_net/rt/sync
import zal_net/serve

type App = ref object
  served: int       # atomic
  failures: int     # atomic
  ended: Event

proc echo(c: var Conn; app: App) {.passive, raises.} =
  c.renew afterMs(5000)
  let line = c.readLine()
  if line == "fail": raise ValueError
  c.write line & "\n"
  discard atomicFetchAdd(app.served, 1, moRelaxed)

proc report(app: App; error: ErrorCode) =
  discard atomicFetchAdd(app.failures, 1, moRelaxed)

proc run(listener: ptr Listener; app: App) {.passive.} =
  try:
    serve(listener[], echo, app, report)
  except ErrorCode as error:
    echo "serve: ", error
  setEvent(addr app.ended)

proc main() {.passive.} =
  try:
    let stop = newCancelToken()
    var listener = listen(0, "127.0.0.1", stop = stop)
    let app = App()
    assert trySpawnTask(run(addr listener, app))
    for i in 0 ..< 20:
      var c = connect("127.0.0.1", listener.port, afterMs(5000))
      c.renew afterMs(5000)
      if i == 7:
        c.write "fail\n"
        assert c.fill() == 0            # the server closed after the raise
      else:
        c.write "ping " & $i & "\n"
        assert c.readLine() == "ping " & $i
    cancel(stop)
    assert wait(addr app.ended, afterMs(5000)) == wrReady
    assert atomicLoad(app.served, moRelaxed) == 19
    assert atomicLoad(app.failures, moRelaxed) == 1
    close listener
    release(stop)
    echo "PASS serve: 19 handled, one handler failure reported, cancelled and drained"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
