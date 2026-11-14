## Reference exception payload is thread-local: interleaved suspending finally crashes on the pin.
## flags: --path:src
import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io

type
  NetworkError = ref object of Exception
    code: int
  Context = ref object
    firstPaused: bool
    firstDone: bool
    secondDone: bool
    firstCode: int
    secondCode: int

proc first(context: Context) {.passive, raises: NetworkError.} =
  try:
    raise NetworkError(msg: "first", code: 123)
  finally:
    context.firstPaused = true
    sleepMs(10)

proc second(context: Context) {.passive, raises: NetworkError.} =
  sleepMs(1)
  raise NetworkError(msg: "second", code: 456)

template startHandled(body: untyped; context: Context; isFirst: bool): bool {.untyped.} =
  block:
    proc dispatch(held: Context; firstRun: bool) {.passive.} =
      try:
        body(held)
      except NetworkError as error:
        if firstRun: held.firstCode = error.code
        else: held.secondCode = error.code
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
  assert context.firstCode == 123 and context.secondCode == 456
  echo "ok"

assert runMain(main())
