## Enum ErrorCode survives interleaved raised failures and suspended finally cleanup.
## flags: --path:src
import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io

type
  Context = ref object
    firstPaused: bool
    firstDone: bool
    secondDone: bool
    firstCode: int
    secondCode: int

proc first(context: Context) {.passive, raises.} =
  try:
    raise TimeoutError
  finally:
    context.firstPaused = true
    sleepMs(10)

proc second(context: Context) {.passive, raises.} =
  sleepMs(1)
  raise PermissionDenied

template startHandled(body: untyped; context: Context; isFirst: bool): bool {.untyped.} =
  block:
    proc dispatch(held: Context; firstRun: bool) {.passive.} =
      try:
        body(held)
      except ErrorCode as error:
        if firstRun: held.firstCode = ord(error)
        else: held.secondCode = ord(error)
      finally:
        if firstRun: held.firstDone = true
        else: held.secondDone = true
    trySpawnTask(dispatch(context, isFirst))

proc main() {.passive.} =
  let context = Context()
  assert startHandled(first, context, true)
  while not context.firstPaused: sleepMs(1)
  assert startHandled(second, context, false)
  while not context.firstDone or not context.secondDone: sleepMs(1)
  echo "codes ", context.firstCode, " ", context.secondCode
  assert context.firstCode == ord(TimeoutError) and context.secondCode == ord(PermissionDenied)
  echo "ok"

assert runMain(main())
