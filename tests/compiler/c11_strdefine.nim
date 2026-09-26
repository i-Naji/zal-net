{.feature: "lenientnils".}
## `{.strdefine.}` is not supported. Workaround: the environment, or a module initialised earlier (backend/stdpre.nim).
import std/syncio

const name {.strdefine.} = "default"
if name == "default": echo "ok"
