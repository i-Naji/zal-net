{.feature: "lenientnils".}
## A failed `assert` does not print its message. Workaround: tests/*: build a copy whose asserts print their line (build/winspike/mkdbg.py).
## expect: the-assert-message
import std/syncio

import std/assertions
assert 1 == 2, "the-assert-message"
