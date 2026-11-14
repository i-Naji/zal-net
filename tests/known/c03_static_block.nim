{.feature: "lenientnils".}
## `static:` blocks are unsupported. Workaround: `when cond: {.error.}`.
import std/syncio

static:
  discard 1
echo "ok"
