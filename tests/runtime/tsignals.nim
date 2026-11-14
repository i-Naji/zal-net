## Signals arrive as events: SIGUSR1 and SIGHUP to this process are
## returned by waitSignal; a wait with nothing pending times out. On
## Windows a console Ctrl+C arrives as sigInt, and an unwatched event is
## left to the default handling.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/signals

when defined(windows):
  import zal_net/private/sys/sock

  proc main() {.passive.} =
    assert watchSignals({sigInt})
    assert waitSignal(100) == sigNone
    assert raiseConsoleCtrl(2)                       # Ctrl+C: watched, taken
    assert waitSignal(2000) == sigInt
    assert not raiseConsoleCtrl(15)                  # close: not watched
    assert waitSignal(100) == sigNone
    echo "PASS Ctrl+C delivered as sigInt; an unwatched event left alone; an idle wait times out"
    quit 0
else:
  proc kill(pid: cint; sig: cint): cint {.importc, header: "<signal.h>".}
  proc getpid(): cint {.importc, header: "<unistd.h>".}

  proc sender() {.passive.} =
    sleepMs(50)
    discard kill(getpid(), number(sigUsr1))
    sleepMs(20)
    discard kill(getpid(), number(sigHup))

  proc main() {.passive.} =
    assert watchSignals({sigUsr1, sigHup})
    spawnTask sender()
    assert waitSignal(2000) == sigUsr1
    assert waitSignal(2000) == sigHup
    assert waitSignal(100) == sigNone
    echo "PASS SIGUSR1 and SIGHUP delivered as events; an idle wait times out"
    quit 0

initRuntime()
spawnTask main()
drainRuntime()
