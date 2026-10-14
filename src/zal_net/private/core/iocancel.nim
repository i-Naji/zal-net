## Readiness-only cancellation shared by both backends. The standard backend
## cannot cancel another lane's poll, so token-aware waits use bounded poll
## deadlines. Each poll completes before its frame/storage can be released.
## No socket is shut down: cancelling one wait preserves the owner's usability.
import zal_net/rt, zal_net/rt/cancel
import zal_net/errors
import zal_net/raw/io
import zal_net/private/runtime
import zal_net/private/core/parked

const CancelPollMs* = 10
const CancelPollMaxMs* = 200   ## an idle park backs off from CancelPollMs to this

type IoCancellation* = object
  ## Borrowed operation and owner-stop tokens. The I/O frame retains them;
  ## no child token or other storage is allocated for an operation.
  operation*, ownerStop*, peerStop*: nil CancelToken
  interrupts*: bool  ## closing the owner interrupts the socket (streams, not UDP)

proc ioCancellation*(operation: nil CancelToken;
                     ownerStop: nil CancelToken = nil; peerStop: nil CancelToken = nil;
                     interrupts = false): IoCancellation {.inline.} =
  IoCancellation(operation: operation, ownerStop: ownerStop, peerStop: peerStop, interrupts: interrupts)

proc retain*(tokens: IoCancellation) {.inline.} =
  retain(tokens.operation)
  retain(tokens.ownerStop)
  retain(tokens.peerStop)

proc release*(tokens: IoCancellation) {.inline.} =
  release(tokens.operation)
  release(tokens.ownerStop)
  release(tokens.peerStop)

proc cancelled*(tokens: IoCancellation): bool {.inline.} =
  cancelled(tokens.operation) or cancelled(tokens.ownerStop) or cancelled(tokens.peerStop)

proc pollDeadline*(deadline: Deadline; tokens: IoCancellation; ms = CancelPollMs): Deadline {.inline.} =
  if tokens.operation == nil and tokens.ownerStop == nil and tokens.peerStop == nil: deadline
  else: earlier(deadline, afterMs(ms))

template parkCancellable*(fd: cint; events: IoEvents; deadline: Deadline;
                          tokens: IoCancellation; outcome: var int) =
  block:
    var slice = CancelPollMs
    # Only the owner's stop token: close and runtime stop interrupt the socket.
    let owned = tokens.interrupts and tokens.operation == nil and tokens.peerStop == nil and
      tokens.ownerStop != nil and enterParked(fd)
    while true:
      if cancelled(tokens) or (owned and stopping()):
        outcome = ECancelled
        break
      if owned:
        parkPollOwned(fd, events, deadline, outcome)
      else:
        parkPoll(fd, events, pollDeadline(deadline, tokens, slice), outcome)
      if cancelled(tokens):
        outcome = ECancelled
        break
      if not owned and (tokens.operation != nil or tokens.ownerStop != nil or tokens.peerStop != nil) and
          outcome == IoTimedOut and monoNow() < deadline:
        slice = min(slice * 2, CancelPollMaxMs)
        continue
      break
    if owned: leaveParked(fd)

proc pollDeadline*(deadline: Deadline; tok: nil CancelToken; ms = CancelPollMs): Deadline {.inline.} =
  if tok == nil: deadline else: earlier(deadline, afterMs(ms))

template parkCancellable*(fd: cint; events: IoEvents; deadline: Deadline;
                          tok: nil CancelToken; outcome: var int) =
  ## Caller retains tok across the complete operation, including each park.
  block:
    var slice = CancelPollMs
    while true:
      if cancelled(tok):
        outcome = ECancelled
        break
      parkPoll(fd, events, pollDeadline(deadline, tok, slice), outcome)
      if cancelled(tok):
        outcome = ECancelled
        break
      if tok != nil and outcome == IoTimedOut and monoNow() < deadline:
        slice = min(slice * 2, CancelPollMaxMs)
        continue
      break

template parkAcceptCancellable*(fd: cint; deadline: Deadline;
                                tok: nil CancelToken; outcome: var int) =
  block:
    var slice = CancelPollMs
    while true:
      if cancelled(tok):
        outcome = ECancelled
        break
      # Keep the listener's poller classification. Raw owners permit one
      # pending accept per loop, as with the ordinary parkAccept path.
      beParkFd(fd, false, true, pollDeadline(deadline, tok, slice), outcome)
      if cancelled(tok):
        outcome = ECancelled
        break
      if tok != nil and outcome == IoTimedOut and monoNow() < deadline:
        slice = min(slice * 2, CancelPollMaxMs)
        continue
      break

template parkConnectOutcome*(fd: cint; deadline: Deadline;
                             tok: nil CancelToken; outcome: var int) =
  block:
    outcome = IoTimedOut
    var mask = 0
    var wakes = 0
    while wakes < 8:
      parkCancellable(fd, {evWrite}, deadline, tok, mask)
      if mask <= 0:
        outcome = if mask < 0: mask else: ResourceClosed
        break
      let state = connectResult(fd)
      if state != 0:
        outcome = if cancelled(tok): ECancelled elif state > 0: 0 else: state
        break
      wakes = wakes + 1
    # Too many stale wakes is a bounded failure, not a fabricated OS timeout.
    if wakes == 8: outcome = ResourceClosed

template parkConnectCancellable*(fd: cint; deadline: Deadline;
                                 tok: nil CancelToken; ok: var bool) =
  block:
    var code = 0
    parkConnectOutcome(fd, deadline, tok, code)
    ok = code == 0
