{.feature: "lenientnils".}
## `echo` of a `uint32` fails. Workaround: convert to `int`.
import std/syncio

let x = 5'u32
echo x
echo "ok"
