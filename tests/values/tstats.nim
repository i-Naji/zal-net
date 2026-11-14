{.feature: "assumeSync".}
## Sharded counters from loops and raw threads, a per-user counter set, and
## the async logger: level filtering, and a flood that must not block.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/stats
import zal_net/log
import zal_net/private/sys/threads
import zal_net/private/sys/posix

when defined(windows):
  import std/envvars
  proc cOpen(path: cstring; flags, mode: cint): cint {.importc: "_open", header: "<io.h>".}
else:
  proc pipeRaw(fds: ptr cint): cint {.importc: "pipe", header: "<unistd.h>".}
  proc cRead(fd: cint; buf: pointer; n: int): int {.importc: "read", header: "<unistd.h>".}

var gCounter: nil ShardedCounter   # made in main, sized by the runtime
var gUsers: nil CounterSet
var gThreadsDone: int   # atomic

proc rawCounter(arg: nil pointer) {.nimcall.} =
  let c = gCounter
  let u = gUsers
  if c == nil or u == nil: return
  var i = 0
  while i < 100_000:
    inc(c)
    inc(u, 1, 2)
    i = i + 1
  discard atomicFetchAdd(gThreadsDone, 1, moRelease)

proc count(n: int) =
  let c = gCounter
  if c == nil: return
  var i = 0
  while i < n:
    inc(c)
    i = i + 1

proc loopCounter() {.passive.} =
  # The counting is a regular proc: a passive loop that rarely suspends
  # recurses once per iteration (manual, chapter 6).
  var k = 0
  while k < 10:
    count(10_000)
    yieldNow()
    k = k + 1

when not defined(windows):
  proc readAvailable(fd: cint; into: var string) =
    var buf = default(array[4096, char])
    while true:
      let n = cRead(fd, addr buf[0], buf.len)
      if n <= 0: break
      var i = 0
      while i < n:
        into.add buf[i]
        i = i + 1

proc slurp(path: string): string =
  ## A regular proc: readFile raises, and a raising call in a passive proc
  ## generates C that does not compile.
  result = ""
  try: result = readFile(path)
  except: discard

proc contains(s, sub: string): bool =
  result = false
  if sub.len == 0 or sub.len > s.len: return
  var i = 0
  while i + sub.len <= s.len:
    var j = 0
    while j < sub.len and s[i + j] == sub[j]: j = j + 1
    if j == sub.len: return true
    i = i + 1

proc floodLogger() =
  # This loop never suspends. Keep it out of the passive frame: Nimony's
  # passive-loop recursion adds unrelated stack/allocation overhead.
  var i = 0
  while i < 20_000:
    logInfo("flood line number " & $i)
    i = i + 1

proc main() {.passive.} =
  let counter = newShardedCounter()
  let users = newCounterSet(3)
  gCounter = counter
  gUsers = users
  var mark = 0'i64
  startThread(rawCounter, nil)
  startThread(rawCounter, nil)
  spawnTask loopCounter()
  spawnTask loopCounter()
  while atomicLoad(gThreadsDone, moAcquire) < 2 or total(counter) < 400_000: sleepMs(5)
  assert total(counter) == 400_000
  assert takeDelta(counter, mark) == 400_000
  inc(counter, 5)
  assert takeDelta(counter, mark) == 5
  assert total(users, 1) == 400_000 and total(users, 0) == 0 and total(users, 2) == 0
  echo "PASS sharded counters"

  when defined(windows):
    # The logger writes to a C-runtime descriptor: a file here. (No flood
    # test: a file never blocks the writer.)
    var path = getEnv("TEMP") & "\\nn-tstats.log"
    let fd = cOpen(path.toCString, cint(0x0001 or 0x0100 or 0x0200 or 0x8000), cint(0x0180)) # WRONLY|CREAT|TRUNC|BINARY
    assert fd >= 0
    assert initLogger(fd, lvInfo, ringSlots = 64)
    logInfo("hello " & $42)
    logDebug("not shown")
    flushLogger()
    let text = slurp(path)
    assert contains(text, "INFO hello 42\n")
    assert not contains(text, "not shown")
    assert text.len > 24 and text[4] == '-' and text[10] == 'T' and text[23] == 'Z'
    echo "PASS logger output"
  else:
    var fds = default(array[2, cint])
    assert pipeRaw(addr fds[0]) == 0
    assert makeNonblocking(fds[0])
    assert initLogger(fds[1], lvInfo, ringSlots = 64)
    logInfo("hello " & $42)
    logDebug("not shown")
    flushLogger()
    var text = ""
    readAvailable(fds[0], text)
    assert contains(text, "INFO hello 42\n")
    assert not contains(text, "not shown")
    assert text.len > 24 and text[4] == '-' and text[10] == 'T' and text[23] == 'Z'
    echo "PASS logger output"

    # Nobody reads the pipe: the logger thread blocks in write, the ring
    # fills, and logging keeps returning at once, dropping and counting.
    let t0 = monoNow()
    floodLogger()
    let spent = int64(monoNow()) - int64(t0)
    # Completion before any reader starts proves enqueue does not wait on
    # the blocked sink. Report duration without a machine-dependent deadline.
    text = ""
    var rounds = 0
    while not contains(text, "dropped") and rounds < 200:
      readAvailable(fds[0], text)
      sleepMs(10)
      rounds = rounds + 1
    assert contains(text, "log: dropped "), "no drop summary after draining the logger"
    echo "PASS logger never blocks a loop (20000 lines in ", spent div 1_000_000, " ms)"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
