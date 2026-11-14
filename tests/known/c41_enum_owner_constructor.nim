## A same-module managed owner can be returned by an ErrorCode-raising
## passive constructor. c42 also guards a reduced cross-module constructor.
## flags: --path:src
import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io

type Owner = ref object
  value: int

proc make(value: int): Owner {.raises.} =
  if value < 0: raise ValueError
  result = Owner(value: value)

proc connect(value: int): Owner {.passive, raises.} =
  sleepMs(1)
  result = make(value)

proc main() {.passive.} =
  try:
    let owner = connect(3)
    assert owner.value == 3
    discard connect(-1)
    assert false
  except ErrorCode as error:
    assert error == ValueError
  echo "ok"

assert runMain(main())
