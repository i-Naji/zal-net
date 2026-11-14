## Guard for a regular raising constructor returning a managed ref across
## modules, including a nullable-result check inside the constructor. This
## reduced case passes; larger constructor integrations require separate tests.
## flags: --path:src
import std/[assertions, syncio]
import zal_net/rt
import fixtures/raisingowner

proc exercise() {.passive, raises.} =
  let owner = makeOwner(3)
  assert owner.value == 3
  discard makeOwner(-1)
  assert false

proc main() {.passive.} =
  try:
    exercise()
  except ErrorCode as error:
    assert error == ValueError
  echo "ok"

assert runMain(main())
