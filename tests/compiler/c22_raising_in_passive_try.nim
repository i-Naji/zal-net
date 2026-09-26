{.feature: "lenientnils".}
## A raising call returning a string (`readFile`) in a `try` inside a passive proc generates C that does not compile. Workaround: wrap it in a regular proc (`slurp` in tstats.nim).
## flags: --path:src -d:nnLoops
import std/syncio
import zal_net/rt
import zal_net/raw/io

proc main() {.passive.} =
  var s = ""
  try: s = readFile("/nonexistent/nimony-repro")
  except: s = "caught"
  if s == "caught": echo "ok"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
