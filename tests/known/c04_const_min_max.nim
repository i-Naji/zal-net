{.feature: "lenientnils".}
## `min`/`max` in a `const` expression do not evaluate. Workaround: a `when` expression.
import std/syncio

const A = min(3, 5)
const B = max(3, 5)
when A == 3 and B == 5: echo "ok"
