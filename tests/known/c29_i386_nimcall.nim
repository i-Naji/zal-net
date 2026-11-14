{.feature: "lenientnils".}
## 32-bit Windows: `nimcall` proc pointers are `fastcall` but the procs are not; the C does not compile (in Nimony's system module). Blocks 32-bit Windows.
## flags: --cpu:i386 --bits:32 --cc:i686-w64-mingw32-clang
## requires: i686-w64-mingw32-clang
import std/syncio

echo "ok"
