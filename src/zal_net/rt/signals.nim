{.feature: "assumeSync".}
# Shared state uses pool/lifecycle locks, atomics and publication barriers.
## Signals as events a task waits for, instead of handlers that run in
## signal context. `watchSignals` routes the chosen signals to a wake
## channel (the handler only writes one byte, async-signal-safe);
## `waitSignal` parks on it. On Windows the console's events stand in:
## Ctrl+C and Ctrl+Break as `sigInt`, closing the console, logoff and
## shutdown as `sigTerm` (the system still ends the process a few seconds
## after those); other signals are never delivered there. One task should wait. Watching `sigInt` or `sigTerm` replaces the
## default stop (which shuts listeners down and exits): the program then
## decides, for instance `stopAccepting()`, a drain, `requestStop()`.
##
## ```nim
## watchSignals({sigHup, sigTerm})
## while true:
##   case waitSignal()
##   of sigHup: reload()
##   of sigTerm: drainAndStop(); break
##   else: discard
## ```

import std/atomics
import std/ticketlocks
import zal_net/rt
import zal_net/private/services
import zal_net/raw/io
import zal_net/private/sys/sock
import zal_net/raw/socket

type
  Signal* = enum
    sigNone, sigHup, sigInt, sigQuit, sigUsr1, sigUsr2, sigTerm, sigWinch, sigChld

when not defined(windows):
  type SigAct {.importc: "struct sigaction", header: "<signal.h>".} = object
    sa_handler: nil proc (sig: cint) {.noconv.}   # SIG_DFL is 0

  proc sigaction(sig: cint; act: pointer; old: nil pointer): cint {.importc, header: "<signal.h>".}
  {.compile: "../private/sys/nn_signal.c".}
  proc signalPost(fd, sig: cint): cint {.importc: "nn_signal_post".}
  var previous: array[Signal, SigAct]
  var installed: set[Signal]

proc number*(s: Signal): cint =
  ## The platform's number for `s` (0 for sigNone).
  case s
  of sigNone: 0.cint
  of sigHup: 1.cint
  of sigInt: 2.cint
  of sigQuit: 3.cint
  of sigUsr1: (when defined(linux): 10.cint else: 30.cint)
  of sigUsr2: (when defined(linux): 12.cint else: 31.cint)
  of sigTerm: 15.cint
  of sigWinch: 28.cint
  of sigChld: (when defined(linux): 17.cint else: 20.cint)

var gRd: cint = -1
var gWr: cint = -1
var gReady: int          # atomic: 0 unused, 1 active, 2 closing, 3 released
var gUsers: int          # signal handlers and passive waits retaining the wake
var gLifecycle: TicketLock
var gWatched: int        # atomic: bit per signal number < 64 (Windows)

proc post(sig: cint): bool =
  # Retain before checking active state. A late handler may run after restoration
  # of the previous action, but must never write to a recycled descriptor.
  discard atomicFetchAdd(gUsers, 1, moSequentiallyConsistent)
  result = atomicLoad(gReady, moSequentiallyConsistent) == 1
  if result:
    when defined(windows):
      var b = byte(sig and 0xff)
      discard sockWrite(gWr, addr b, 1)
    else:
      discard signalPost(gWr, sig) # preserves the interrupted thread's errno
  discard atomicFetchSub(gUsers, 1, moSequentiallyConsistent)

when defined(windows):
  proc onConsole(sig: cint): cint {.noconv.} =
    if (atomicLoad(gWatched, moAcquire) and (1 shl int(sig))) == 0: return 0
    result = cint(ord(post(sig)))
else:
  proc onSignal(sig: cint) {.noconv.} = discard post(sig)

proc watchSignals*(sigs: set[Signal]): bool =
  ## Add watched signals. Shutdown is final; registrations after stop fail.
  ## On registration failure existing watches remain owned until stopSignals.
  acquire(gLifecycle)
  let state = atomicLoad(gReady, moSequentiallyConsistent)
  if state >= 2:
    release(gLifecycle)
    return false
  if state == 0:
    var r: cint = -1
    var w: cint = -1
    if not wakePair(r, w):
      release(gLifecycle)
      return false
    gRd = r
    gWr = w
    when defined(windows):
      if not onConsoleCtrl(onConsole):
        wakeClose(r, w)
        gRd = -1
        gWr = -1
        release(gLifecycle)
        return false
    atomicStore(gReady, 1, moSequentiallyConsistent)
  result = true
  when defined(windows):
    for s in sigs:
      if s == sigInt or s == sigTerm:
        discard atomicFetchOr(gWatched, 1 shl int(number(s)), moAcquireRelease)
  else:
    var sa = default(SigAct)
    sa.sa_handler = onSignal
    for s in sigs:
      if s != sigNone and s notin installed:
        if sigaction(number(s), addr sa, addr previous[s]) == 0:
          installed.incl s
        else:
          result = false
  release(gLifecycle)

proc stopSignals*() =
  ## Restore previous POSIX actions; wake waitSignal so it returns sigNone.
  ## Call from ordinary code, not a signal handler. No new waits are admitted.
  acquire(gLifecycle)
  let state = atomicLoad(gReady, moSequentiallyConsistent)
  if state == 0:
    atomicStore(gReady, 3, moSequentiallyConsistent)
  elif state == 1:
    atomicStore(gReady, 2, moSequentiallyConsistent)
    when defined(windows):
      atomicStore(gWatched, 0, moRelease)
    else:
      for s in installed: discard sigaction(number(s), addr previous[s], nil)
      installed = {}
    wakeSignal(gWr)
  release(gLifecycle)

proc joinSignals*(): bool =
  ## After stopSignals: false while a handler or wait still borrows the wake.
  ## Retry from an active task before stopping the runtime, or after its drain.
  acquire(gLifecycle)
  let state = atomicLoad(gReady, moSequentiallyConsistent)
  result = state == 3
  if state == 2 and atomicLoad(gUsers, moSequentiallyConsistent) == 0:
    wakeClose(gRd, gWr)
    gRd = -1
    gWr = -1
    atomicStore(gReady, 3, moSequentiallyConsistent)
    result = true
  release(gLifecycle)

proc fromNumber(n: int): Signal =
  result = sigNone
  var i = ord(sigHup)
  while i <= ord(high(Signal)):
    if int(number(Signal(i))) == n: return Signal(i)
    i = i + 1

proc waitSignal*(timeoutMs = -1): Signal {.passive.} =
  ## The next watched signal to arrive; sigNone after `timeoutMs` (-1:
  ## wait for ever) or when nothing is watched.
  result = sigNone
  discard atomicFetchAdd(gUsers, 1, moSequentiallyConsistent)
  if atomicLoad(gReady, moSequentiallyConsistent) == 1:
    let deadline = if timeoutMs < 0: never else: afterMs(timeoutMs)
    var res = 0
    while atomicLoad(gReady, moSequentiallyConsistent) == 1:
      var b = 0'u8
      if sockRead(gRd, addr b, 1) == 1:
        if atomicLoad(gReady, moSequentiallyConsistent) == 1:
          result = fromNumber(int(b))
        break
      parkPoll(gRd, {evRead}, deadline, res)
      if res <= 0: break
  discard atomicFetchSub(gUsers, 1, moSequentiallyConsistent)

if not registerProcessService(stopSignals, joinSignals):
  atomicStore(gReady, 3, moRelease)
