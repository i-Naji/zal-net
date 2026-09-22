## Tickers: periodic waits that do not drift. Each tick is due one period
## after the previous one was due, not after the task woke; a task that
## falls behind learns how many ticks it missed and catches up at once.
##
## ```nim
## var t = initTicker(1000)
## while true:
##   let missed = waitTick(t)     # parks until the next second
##   flushCounters()
## ```

import zal_net/rt

type
  Ticker* = object
    periodNs*: int64
    next*: int64                  ## when the next tick is due (monotonic ns)

proc initTicker*(periodMs: int): Ticker =
  let p = max(1'i64, int64(periodMs) * 1_000_000)
  result = Ticker(periodNs: p, next: int64(monoNow()) + p)

proc waitTickImpl*(t: ptr Ticker): int {.passive.} =
  ## Park until the next tick; the ticks missed since the last one (0 when
  ## on time).
  let now = int64(monoNow())
  result = 0
  if now < t.next:
    parkUntil(Deadline(t.next))
  else:
    result = int((now - t.next) div t.periodNs)
  t.next = t.next + int64(result + 1) * t.periodNs

template waitTick*(t: var Ticker): int =
  ## Park until the next tick; the ticks missed since the last one.
  waitTickImpl(addr t)

proc reset*(t: var Ticker) =
  ## The next tick one period from now.
  t.next = int64(monoNow()) + t.periodNs
