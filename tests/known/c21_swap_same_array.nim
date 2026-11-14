{.feature: "lenientnils".}
## `swap(a[i], a[j])` on one array is rejected ("mutable argument aliases"). Workaround: swap through a temporary.
import std/syncio

var a = [1, 2]
swap(a[0], a[1])
if a[0] == 2 and a[1] == 1: echo "ok"
