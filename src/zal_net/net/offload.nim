## Typed blocking offload; worker input/results are plain byte-copy values.
## Timeout/cancellation abandons the result, not the running OS call. The
## worker retains storage until it finishes. Borrowed pointer targets must
## remain alive through that eventual completion; prefer self-contained values.
import zal_net/rt/[blocking, sync, cancel], zal_net/[rt, errors, plain]

type
  OffloadFn*[A, R] = proc (argument: A): R {.nimcall.}
  OffloadResult*[R] = object
    value*: R
    code*: int
  Work[A, R] = object
    job: Job                        ## base header is always first
    fn: OffloadFn[A, R]
    argument: A
    value: R

proc run[A, R](job: ptr Job) {.nimcall.} =
  let work = cast[ptr Work[A, R]](job)
  work.value = work.fn(work.argument)

proc newWork[A, R](fn: OffloadFn[A, R]; argument: A): ptr Work[A, R] =
  requirePlainData(A)
  requirePlainData(R)
  let callback: JobFn = run[A, R]
  result = cast[ptr Work[A, R]](newJob(sizeof(Work[A, R]), callback))
  result.fn = fn
  result.argument = argument

proc rawJob[A, R](work: ptr Work[A, R]): JobPtr {.inline.} = addr work.job
proc value[A, R](work: ptr Work[A, R]): R {.inline.} = work.value

template offload*[A, R](fn: OffloadFn[A, R]; argument: A; deadline: Deadline = never;
                       tok: nil CancelToken = nil): OffloadResult[R] =
  block:
    requirePlainData(A)
    requirePlainData(R)
    var outcome = default(OffloadResult[R])
    let cancel = tok
    let until = deadline
    if stopping() or blockingPoolClosing(): outcome.code = ResourceClosed
    elif cancelled(cancel): outcome.code = ECancelled
    elif monoNow() >= until: outcome.code = IoTimedOut
    else:
      let work = newWork[A, R](fn, argument)
      let job = rawJob(work)
      if not spawnBlocking(job):
        outcome.code = (if blockingPoolClosing(): ResourceClosed else: ResourceBusy)
      else:
        let ready = awaitJob(job, until, cancel)
        if ready == wrReady: outcome.value = value(work)
        elif ready == wrTimedOut: outcome.code = IoTimedOut
        else: outcome.code = ECancelled
      releaseJob(job)
    outcome
