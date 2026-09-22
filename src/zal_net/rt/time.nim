## Public standard deadlines and readiness events.
import std/ioring
export ioring.Deadline, ioring.never, ioring.monoNow, ioring.after, ioring.afterMs,
  ioring.earlier, ioring.millisUntil, ioring.IoEvent, ioring.IoEvents,
  ioring.evRead, ioring.evWrite, ioring.ECancelled, ioring.`==`, ioring.`<`, ioring.`<=`
const
  IoTimedOut* = -110  ## park result when the deadline passed (std/ioring's value)

proc limit*(timeoutMs: int; deadline: Deadline): Deadline {.inline.} =
  ## One operation's fixed deadline, capped by its owner's idle limit.
  ## A nonpositive idle limit imposes no additional timeout.
  if timeoutMs <= 0: deadline else: earlier(deadline, afterMs(timeoutMs))
