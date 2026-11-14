## DNS on the blocking pool: a lookup given up at its deadline or by a
## cancel (the pool finishes and frees it), and inbox delivery.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/sync
import zal_net/rt/blocking
import zal_net/errors
import zal_net/net/sockaddr
import zal_net/net/dns

proc main() {.passive.} =
  var addrs = default(array[MaxAddrs, SockAddrBuf])
  let outp = cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0])
  # An expired deadline rejects before numeric/cache or job submission.
  let early = resolveAsync("localhost", 80, SOCK_STREAM, 0.cint, outp, afterMs(0))
  assert early == IoTimedOut
  # Pre-cancellation rejects before numeric/cache or job submission.
  let tok = newCancelToken()
  cancel(tok)
  let late = resolveAsync("localhost", 81, SOCK_DGRAM, 0.cint, outp, never, tok)
  assert late == ECancelled
  release(tok)
  # A normal lookup, then a cache hit.
  assert resolveAsync("localhost", 82, SOCK_STREAM, 0.cint, outp) >= 1
  echo "PASS deadline, cancel and a normal lookup"

  var inbox = default(JobInbox)
  assert initJobInbox(inbox)
  let r = submitResolve("localhost", 53, SOCK_DGRAM, 0.cint, addr inbox, 7, 9)
  assert r != nil
  var res = 0
  parkPoll(inboxFd(inbox), {evRead}, afterMs(5000), res)
  assert res > 0
  let j = takeCompleted(inbox)
  if j == nil: quit "tdns: nothing delivered"
  assert j == (addr r.job)
  assert j.tag == 7 and j.tag2 == 9 and nextJob(j) == nil
  assert resolveResult(r, outp) >= 1
  releaseJob(j)            # the delivered reference
  releaseJob(addr r.job)   # the submitter's
  echo "PASS submitResolve inbox"
  sleepMs(200)   # let the given-up lookups finish under the sanitizer
  closeJobInbox(inbox)
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
