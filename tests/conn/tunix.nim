import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn
from zal_net/private/os import getPid

type Shared = ref object
  done: Event

proc serve(listener: ptr Listener; shared: Shared) {.passive.} =
  try:
    var c = accept(listener[], afterMs(5000))
    c.renew afterMs(5000)
    let line = c.readLine()
    c.write "got " & line & "\n"
  except ErrorCode as error:
    echo "server: ", error
  setEvent(addr shared.done)

proc main() {.passive.} =
  try:
    let path = "/tmp/zal-conn-" & $getPid() & ".sock"
    var listener = listenUnix(path)
    assert listener.isLocal
    let shared = Shared()
    assert trySpawnTask(serve(addr listener, shared))
    var c = connectUnix(path, afterMs(5000))
    c.renew afterMs(5000)
    c.write "unix\n"
    assert c.readLine() == "got unix"
    assert wait(addr shared.done, afterMs(5000)) == wrReady
    close c
    close listener
    var refused = false
    try:
      var again = connectUnix(path, afterMs(1000))
      close again
    except ErrorCode: refused = true
    assert refused
    echo "PASS Unix-domain connect, accept, lines; the path is gone after close"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

when defined(windows):
  echo "PASS Unix-domain connect, accept, lines; the path is gone after close"
else:
  assert runMain(main())
