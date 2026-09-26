## The blocking pool: results, abandoned jobs, cancellation, inbox delivery.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/sync
import zal_net/rt/blocking

proc usleep(us: cuint): cint {.importc, header: "<unistd.h>".}

type SleepJob = object
  job: Job          # first field
  ms: int
  answer: int

proc runSleep(j: ptr Job) {.nimcall.} =
  let s = cast[ptr SleepJob](j)
  discard usleep(cuint(s.ms * 1000))
  s.answer = s.ms * 2

proc sleepJob(ms: int): ptr SleepJob =
  result = cast[ptr SleepJob](newJob(sizeof(SleepJob), runSleep))
  result.ms = ms

proc runsNothing(j: ptr Job) {.nimcall.} = discard   # delivered with postJob, never run

proc main() {.passive.} =
  let a = sleepJob(20)
  assert spawnBlocking(addr a.job)
  assert awaitJob(addr a.job, afterMs(5000)) == wrReady
  assert a.answer == 40
  releaseJob(addr a.job)
  echo "PASS result"

  # Timed out: abandoned; the pool frees it when it finishes.
  let b = sleepJob(200)
  assert spawnBlocking(addr b.job)
  assert awaitJob(addr b.job, afterMs(20)) == wrTimedOut
  releaseJob(addr b.job)
  echo "PASS abandoned on timeout"

  let tok = newCancelToken()
  let c = sleepJob(200)
  assert spawnBlocking(addr c.job)
  cancel(tok)
  assert awaitJob(addr c.job, afterMs(5000), tok) == wrCancelled
  releaseJob(addr c.job)
  release(tok)
  echo "PASS cancelled"

  # Inbox delivery, collected by a loop parked on the inbox descriptor.
  var inbox = default(JobInbox)
  assert initJobInbox(inbox)
  var k = 0
  while k < 3:
    let j = sleepJob(5 + k)
    j.job.tag = uint64(k)
    assert spawnBlocking(addr j.job, addr inbox)
    releaseJob(addr j.job)   # the inbox consumer gets the pool's reference
    k = k + 1
  var got = 0
  var sum = 0
  var res = 0
  while got < 3:
    parkPoll(inboxFd(inbox), {evRead}, afterMs(5000), res)
    assert res > 0
    var j = takeCompleted(inbox)
    while j != nil:
      let next = nextJob(j)
      sum = sum + cast[ptr SleepJob](j).answer
      got = got + 1
      releaseJob(j)
      j = next
  assert sum == 10 + 12 + 14
  echo "PASS inbox"

  # Messages posted straight to the inbox, from a loop and not run.
  var posted = 0
  k = 0
  while k < 5:
    let m = cast[ptr SleepJob](newJob(sizeof(SleepJob), runsNothing))
    m.job.tag = uint64(100 + k)
    assert postJob(addr inbox, addr m.job)
    releaseJob(addr m.job)
    k = k + 1
  var tags = 0
  while posted < 5:
    parkPoll(inboxFd(inbox), {evRead}, afterMs(2000), res)
    assert res > 0
    var j = takeCompleted(inbox)
    while j != nil:
      let next = nextJob(j)
      tags = tags + int(j.tag)
      posted = posted + 1
      releaseJob(j)
      j = next
  assert tags == 100 + 101 + 102 + 103 + 104
  echo "PASS posted messages arrive in order, each once"
  closeJobInbox(inbox)
  closeJobInbox(inbox)
  sleepMs(250)   # let the abandoned jobs finish under the sanitizer
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
