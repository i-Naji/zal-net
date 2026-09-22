## Optional token-aware descriptor waits for transport adapters. Cancellation
## ends this wait without closing or shutting down the descriptor. The buffer
## and descriptor owner must remain alive until the wait completes.
import zal_net/rt, zal_net/rt/cancel
import zal_net/private/core/iocancel

export Deadline, IoEvents, CancelToken

template parkIo*(fd: cint; events: IoEvents; deadline: Deadline;
                 outcome: var int; tok: nil CancelToken = nil) =
  ## Flat in the enclosing passive frame. Both backends use bounded poll
  ## deadlines for cancellation: about 10 ms plus scheduling delay. The last
  ## poll completes before the retained token is released. Nil keeps the
  ## ordinary readiness wait. Only one wait per descriptor/direction/loop.
  ## Positive readiness is a hint: retry the syscall and park again after
  ## IoAgain. In particular, a stale readiness hint can precede cancellation.
  block:
    let waitToken = tok
    retain(waitToken)
    parkCancellable(fd, events, deadline, waitToken, outcome)
    release(waitToken)
