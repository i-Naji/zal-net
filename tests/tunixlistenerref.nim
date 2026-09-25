## Explicit raw-listener transfer preserves path and descriptor on rejection.
import std/[assertions, envvars, syncio]
import zal_net/rt, zal_net/errors
import zal_net/raw/unix
import zal_net/foundation/unixlistener
from zal_net/private/sys/sock import getPid

proc main() {.passive.} =
  when defined(windows):
    let path = getEnv("TEMP") & "\\nn-unix-listener-ref-" & $getPid() & ".sock"
  else:
    let path = "/tmp/nn-unix-listener-ref-" & $getPid() & ".sock"
  var listener = listenUnix(path)
  assert listener.ok
  let descriptor = nativeHandle(listener)
  let transfer = takeUnixListenerRef(listener)
  assert transfer.code == 0 and not listener.ok and listener.path == ""
  let owner = transfer.value
  if owner == nil:
    assert false
  else:
    assert nativeHandle(owner) == descriptor and owner.path == path
    let repeated = takeUnixListenerRef(listener)
    assert repeated.code == ResourceClosed and repeated.value == nil
    assert nativeHandle(owner) == descriptor and owner.path == path
    assert close(owner, afterMs(2000)) == 0
    assert close(owner) == 0
    var file: File
    assert not open(file, path)
  var remaining = listenUnix(path)
  assert remaining.ok
  let remainingFd = nativeHandle(remaining)
  requestStop()
  let rejected = takeUnixListenerRef(remaining)
  assert rejected.code == ResourceClosed and rejected.value == nil
  assert remaining.ok and nativeHandle(remaining) == remainingFd and remaining.path == path
  closeNow(remaining)
  echo "PASS Unix listener transfer, repeated close and shutdown rejection"

assert runMain(main())
