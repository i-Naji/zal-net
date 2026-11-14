## A parenthesized `(block: ...)` as an `if` branch, holding a `for` loop
## that moves a temporary into a sink parameter (`s.add $y`), crashes the
## compiler: "finalir.nim(654, 3) `n.stmtKind in {StmtsS, ScopeS}` TagLit
## [AssertionDefect]". `echo $y` there, or the same block as an indented
## `block:` statement, compiles. Workaround: write the branch as indented
## statements (met while debugging zal-tls's ECH decoder).
import std/syncio

proc f(xs: seq[int]; x: int): int =
  var s = ""
  if x < 0: (block:
    for y in xs: s.add $y
    return -1)
  result = x

if f(@[1, 2], 1) == 1 and f(@[1, 2], -1) == -1: echo "ok"
