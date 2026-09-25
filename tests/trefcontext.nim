## Compiler regression: Ref -> pointer casts retain without a paired drop.
## The restricted borrowed-context helper must preserve the Ref count.
import std/[assertions, syncio]
import zal_net/unsafe/refcontext

var destroyed = 0
type OwnerObj = object
  value: int
type Owner = ref OwnerObj
type View = object
  context: pointer
proc `=destroy`(owner: var OwnerObj) = inc destroyed

proc context(owner: Owner): pointer =
  when defined(nnUnsafeContextRepro):
    let view = View(context: cast[pointer](owner))
    result = view.context
  else: result = borrowRefContext(owner)

proc decode(pointer: pointer): int =
  let held = cast[Owner](pointer)
  result = held.value

proc exercise() =
  let owner = Owner()
  owner.value = 42
  assert decode(context(owner)) == 42
  assert destroyed == 0

exercise()
assert destroyed == 1, "opaque context conversion leaked its managed owner"
echo "PASS borrowed managed context"
