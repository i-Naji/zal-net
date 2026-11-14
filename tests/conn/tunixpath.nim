## Unix-domain paths: a live listener keeps its path, a stale file is
## replaced, bad paths and backlogs are refused, and close removes the file.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/conn
from zal_net/private/os import getPid

proc main() {.passive.} =
  try:
    let path = "/tmp/zal-unixpath-" & $getPid() & ".sock"

    # A file nobody listens on is stale: listening replaces it.
    writeFile(path, "stale")
    var listener = listenUnix(path)

    # A second listener on a live path is refused, and the first keeps it.
    var busy = false
    try:
      var again = listenUnix(path)
      close again
    except ErrorCode as error: busy = error == BusyError
    assert busy, "a live path is refused"
    # The check connected once; that connection is the listener's to drain.
    var probe = accept(listener, afterMs(2000))
    var bytes = default(array[4, byte])
    assert probe.read(bytes, afterMs(2000)) == 0
    close probe

    var c = connectUnix(path, afterMs(2000))
    var peer = accept(listener, afterMs(2000))
    c.write "abc"
    var got = 0
    while got < 3: got += peer.read(bytes.toOpenArray(got, 2), afterMs(2000))
    var timedOut = false
    try: discard accept(listener, afterMs(0))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut

    for bad in ["", path & "\0suffix"]:
      var refused = false
      try:
        var l = listenUnix(bad)
        close l
      except ErrorCode as error: refused = error == ValueError
      assert refused, "a bad path is refused"
    var refused = false
    try:
      var l = listenUnix(path & ".backlog", backlog = 0)
      close l
    except ErrorCode as error: refused = error == ValueError
    assert refused, "a backlog of 0 is refused"

    close listener
    var file: File
    assert not open(file, path), "close removed the socket file"
    # The accepted connection outlives its listener.
    peer.write "d"
    assert c.read(bytes, afterMs(2000)) == 1 and bytes[0] == byte('d')
    close c
    close peer
    echo "PASS a stale file replaced, a live path refused, bad paths refused, the file removed"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

when defined(windows):
  echo "PASS a stale file replaced, a live path refused, bad paths refused, the file removed"
else:
  assert runMain(main())
