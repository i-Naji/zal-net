## A blocked sink must retain the logger's storage until its write completes.
import std/[assertions, atomics, syncio]
import zal_net/[rt, log]
import zal_net/private/sys/[sock, threads]

var producerDone: int
proc publish(arg: nil pointer) {.nimcall.} =
  var i = 0
  while i < 50_000:
    logMsg(lvInfo, "concurrent producer")
    i = i + 1
  atomicStore(producerDone, 1, moRelease)

initRuntime()
assert not joinLogger()
when defined(windows):
  # The POSIX branch deliberately blocks a pipe; Windows covers join/rejection.
  assert initLogger(level = lvOff)
  stopLogger()
else:
  proc pipeRaw(fds: ptr cint): cint {.importc: "pipe", header: "<unistd.h>".}
  proc readRaw(fd: cint; buf: pointer; n: int): int {.importc: "read", header: "<unistd.h>".}
  var fds = default(array[2, cint])
  assert pipeRaw(addr fds[0]) == 0
  assert sockSetNonblock(fds[0], true)
  assert sockSetNonblock(fds[1], true)
  var bytes = default(array[4096, byte])
  while fileWrite(fds[1], addr bytes[0], bytes.len) > 0: discard
  var one = 0'u8
  while fileWrite(fds[1], addr one, 1) > 0: discard
  assert sockSetNonblock(fds[1], false)
  assert initLogger(fds[1], ringSlots = 16)
  logMsg(lvError, "held write")
  sleepUs(20_000)
  var worker: ThreadHandle
  assert startJoinable(worker, publish, nil)
  stopLogger()
  assert not joinLogger()
  assert not loggerStopped()
  assert not logEnabled(lvError)
  var waited = 0
  while not loggerStopped() and waited < 5000:
    while readRaw(fds[0], addr bytes[0], bytes.len) > 0: discard
    sleepUs(1000)
    waited = waited + 1
  assert loggerStopped()
  while atomicLoad(producerDone, moAcquire) == 0: sleepUs(1000)
  assert joinThread(worker)
  assert joinLogger()
  # Joining releases logger-owned storage, but fd remains borrowed.
  assert fileWrite(fds[1], addr one, 1) == 1
  discard sockClose(fds[0])
  discard sockClose(fds[1])
var finalWait = 0
while not loggerStopped() and finalWait < 5000:
  sleepUs(1000)
  finalWait = finalWait + 1
assert loggerStopped()
assert joinLogger()
stopLogger()
assert joinLogger()
assert not initLogger()
logMsg(lvError, "rejected after join")
flushLogger()
echo "PASS logger blocked write, concurrent publication, drain, join, no restart"
