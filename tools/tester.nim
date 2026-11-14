# The zal test runner. It follows the conventions of Nimony's own suite
# (`tests/nimony/<category>/` run by `hastur`), with the three things a
# networking suite needs on top: a time limit per test, a worker matrix and
# per-OS tests.
#
#   tester --nimony:build/toolchain/bin/nimony --workers:1,4
#   tester tests/relay                     one category
#   tester tests/relay/tsplice.nim         one test
#   tester --suite:fast                    the names listed in tests/fast.suite
#   tester --overwrite tests/values        record what the tests print now
#
# A test is `tests/<category>/t*.nim`. Files next to it change how it is
# judged, all optional:
#
#   tname.output   what the program must print, compared after stripping
#   tname.msgs     the compiler must FAIL, and its output must contain every
#                  line of this file
#   tname.args     extra compiler flags for this test
#   tname.os       the systems it runs on (linux macos windows bsd), one line
#   tname.workers  the fewest workers it can run with; smaller entries of
#                  the matrix are raised to it
#
# A directory can hold `tester.mode` with one word: `compile` (build only,
# as for examples), `known` (compiler repros: never fails the run, reports
# what happened) or `skip`.
#
# `tests/tester.args` holds the flags every test of the repository gets.
# `$NAME` in it is replaced from the environment, and a line starting with
# `linux:`, `macos:`, `windows:` or `bsd:` applies on that system only.
#
# A program runs once per entry of `--workers` with `ZAL_WORKERS` set. It
# passes when it exits 0 within the time limit and its output matches the
# `.output` file if there is one. A test without `.output` may print
# anything; that keeps timing lines out of the goldens.

import std/[syncio, os, osproc, strutils, envvars, cmdline, dirs, paths, files, streams, algorithm]

const
  DefaultTimeoutS = 180   ## no test in the suites runs longer than a minute
  KnownTimeoutS = 20      ## a compiler repro that runs longer has hung
  ErrorKeyword = "Error:"

type
  Mode = enum
    mRun, mCompile, mKnown, mSkip
  Options = object
    nimony: string
    buildDir: string
    workers: seq[string]
    timeoutS: int
    overwrite: bool
    keep: bool          ## keep each test's nimcache after it passed
    suite: string
    flags: seq[string]  ## from --flag, after tests/tester.args
    targets: seq[string]
  Counters = object
    passed, failed, skipped, known: int

const HostOs =
  when defined(windows): "windows"
  elif defined(linux): "linux"
  elif defined(macosx): "macos"
  else: "bsd"

const ExeExt = when defined(windows): ".exe" else: ""

proc readText(file: string): string =
  result = ""
  try:
    result = readFile(file)
  except:
    result = ""

proc expandEnv(s: string): string =
  ## `$NAME` and `${NAME}` from the environment. An unset name expands to "".
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '$' and i + 1 < s.len:
      var j = i + 1
      let braced = s[j] == '{'
      if braced: inc j
      let start = j
      while j < s.len and (s[j] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}): inc j
      result.add getEnv(s.substr(start, j - 1))
      if braced and j < s.len and s[j] == '}': inc j
      i = j
    else:
      result.add s[i]
      inc i

proc argsFrom(file: string): seq[string] =
  ## One flag per line. Blank lines and `#` comments are skipped.
  result = @[]
  for raw in readText(file).splitLines():
    var line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    var applies = true
    for os in ["linux", "macos", "windows", "bsd"]:
      if line.startsWith(os & ":"):
        applies = os == HostOs
        line = line.substr(os.len + 1).strip()
        break
    if applies and line.len > 0: result.add expandEnv(line)

proc modeOf(dir: string): Mode =
  result = mRun
  let word = readText(dir / "tester.mode").strip()
  case word
  of "compile": result = mCompile
  of "known": result = mKnown
  of "skip": result = mSkip
  else: discard

proc runsHere(test: string): bool =
  let spec = readText(test.changeFileExt(".os")).strip()
  if spec.len == 0: return true
  result = false
  for word in spec.splitWhitespace():
    if word == HostOs: result = true

proc collect(target: string; into: var seq[string]) =
  ## Every `t*.nim` under a directory, or the file itself.
  if fileExists(target):
    into.add target
    return
  var found: seq[string] = @[]
  try:
    for entry in walkDirRec(path(target)):
      let file = $entry
      let name = extractFilename(file)
      if name.endsWith(".nim") and (name.startsWith("t") or modeOf(parentDir(file)) != mRun):
        found.add file
  except:
    echo "cannot read ", target
  found.sort()
  for file in found: into.add file

proc quoteAll(args: openArray[string]): string =
  result = ""
  for a in args:
    if result.len > 0: result.add ' '
    result.add quoteShell(a)

proc compile(o: Options; test, exe, cache: string; common: seq[string]): (string, int) =
  var args = @[o.nimony, "c", "--ff"]
  for a in common: args.add a
  for a in o.flags: args.add a
  for a in argsFrom(test.changeFileExt(".args")): args.add a
  args.add "--nimcache:" & cache
  args.add "-o:" & exe
  args.add test
  # One C object cache for the run. The standard library's own cache lives
  # in the toolchain and is shared anyway.
  result = ("", 1)
  try:
    putEnv(when defined(windows): "LOCALAPPDATA" else: "XDG_CACHE_HOME", o.buildDir / "c-cache")
    result = execCmdEx(quoteAll(args))
  except:
    result = ("cannot start " & o.nimony, 1)

proc run(exe, workers: string; timeoutS: int): (string, int, bool) =
  ## Output, exit code and whether the time limit ended it.
  result = ("", 1, false)
  try:
    putEnv("ZAL_WORKERS", workers)
    let p = startProcess(exe, options = {poStdErrToStdOut})
    let code = waitForExit(p, timeoutS * 1000)
    let text = outputStream(p).readAll()
    close(p)
    # waitForExit kills at the limit; a killed child reports a signal exit.
    result = (text, code, code > 128 or code < 0)
  except:
    result = ("cannot start " & exe, 1, false)

proc show(text: string; limit = 60) =
  let lines = text.strip().splitLines()
  let first = max(0, lines.len - limit)
  for i in first ..< lines.len: echo "    ", lines[i]

proc missingLines(spec, text: string): seq[string] =
  result = @[]
  for raw in spec.splitLines():
    let line = raw.strip()
    if line.len > 0 and not text.contains(line): result.add line

proc testOne(o: Options; c: var Counters; test: string; common: seq[string]) =
  let dir = parentDir(test)
  let mode = modeOf(dir)
  let name = extractFilename(test).changeFileExt("")
  let label = extractFilename(dir) / name
  if mode == mSkip or not runsHere(test):
    inc c.skipped
    echo "skip ", label
    return
  let work = o.buildDir / extractFilename(dir)
  try: createDir(path(work))
  except: discard
  let exe = work / name & ExeExt
  let cache = work / "cache-" & name
  let (compilerOutput, compilerExit) = compile(o, test, exe, cache, common)
  let msgsFile = test.changeFileExt(".msgs")
  var ok = true
  var ran = false

  if mode == mKnown:
    # A compiler repro. What it does today is the golden; a change is news,
    # reported and never a failure of the libraries.
    var verdict = if compilerExit != 0: "rejected" else: "compiles"
    if compilerExit == 0:
      let (_, code, timedOut) = run(exe, "1", min(o.timeoutS, KnownTimeoutS))
      verdict = if timedOut: "hangs" elif code == 0: "passes" else: "fails at run time"
    let was = readText(test.changeFileExt(".output")).strip()
    if o.overwrite:
      try: writeFile(test.changeFileExt(".output"), verdict & "\n")
      except: discard
    inc c.known
    if was.len > 0 and was != verdict: echo "CHANGED ", label, ": was '", was, "', now '", verdict, "'"
    else: echo "known ", label, ": ", verdict
    return

  if fileExists(msgsFile):
    let spec = readText(msgsFile)
    if compilerExit == 0:
      ok = false
      echo "FAIL ", label, ": compiled, but must be rejected"
    else:
      let missing = missingLines(spec, compilerOutput)
      if missing.len > 0:
        if o.overwrite:
          var kept = ""
          for line in compilerOutput.splitLines():
            if line.contains(ErrorKeyword):
              # Keep the message, drop the path and position in front of it.
              let at = line.find(ErrorKeyword)
              kept.add line.substr(at).strip() & "\n"
          try: writeFile(msgsFile, kept)
          except: discard
        ok = false
        echo "FAIL ", label, ": rejected without the expected message"
        for line in missing: echo "    expected: ", line
        show compilerOutput, 20
    if ok: echo "ok   ", label, " (rejected)"
  elif compilerExit != 0:
    ok = false
    echo "FAIL ", label, ": does not compile"
    show compilerOutput, 40
  elif mode == mCompile:
    echo "ok   ", label, " (builds)"
  else:
    ran = true
    let outputFile = test.changeFileExt(".output")
    let hasGolden = fileExists(outputFile)
    let golden = readText(outputFile).strip()
    let fewest = readText(test.changeFileExt(".workers")).strip()
    var done: seq[string] = @[]
    for entry in o.workers:
      var w = entry
      try:
        if fewest.len > 0 and parseInt(w) < parseInt(fewest): w = fewest
      except: discard
      if w in done: continue
      done.add w
      let (text, code, timedOut) = run(exe, w, o.timeoutS)
      if timedOut:
        ok = false
        echo "FAIL ", label, " workers=", w, ": no result after ", o.timeoutS, " s"
        show text
      elif code != 0:
        ok = false
        echo "FAIL ", label, " workers=", w, ": exit code ", code
        show text
      elif hasGolden and text.strip() != golden:
        if o.overwrite:
          try: writeFile(outputFile, text)
          except: discard
        ok = false
        echo "FAIL ", label, " workers=", w, ": output differs from ", extractFilename(outputFile)
        echo "  expected:"
        show golden, 20
        echo "  printed:"
        show text, 20
      else:
        if o.overwrite and not hasGolden and text.strip().len > 0 and w == o.workers[0]:
          try: writeFile(outputFile, text)
          except: discard
        echo "ok   ", label, " workers=", w
  if ok:
    inc c.passed
    if not o.keep:
      try: removeDir(path(cache))
      except: discard
      if ran:
        try: removeFile(path(exe))
        except: discard
  else:
    inc c.failed

proc usage() {.noreturn.} =
  echo "tester [--nimony:PATH] [--build:DIR] [--workers:1,4] [--timeout:SECONDS]"
  echo "       [--suite:NAME] [--flag:COMPILERFLAG]... [--overwrite] [--keep] [tests...]"
  quit 2

proc main() =
  var o = Options(nimony: getEnv("NIMONY", "nimony"), buildDir: getEnv("BUILD_DIR", "build/test"),
                  workers: @[], timeoutS: DefaultTimeoutS, overwrite: false, keep: false,
                  suite: "", flags: @[], targets: @[])
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg.startsWith("--"):
      let colon = arg.find(':')
      let key = if colon < 0: arg.substr(2) else: arg.substr(2, colon - 1)
      let value = if colon < 0: "" else: arg.substr(colon + 1)
      case key
      of "nimony": o.nimony = value
      of "build": o.buildDir = value
      of "workers":
        for w in value.split({',', ' '}):
          if w.len > 0: o.workers.add w
      of "timeout":
        try: o.timeoutS = parseInt(value)
        except: usage()
      of "suite": o.suite = value
      of "flag": o.flags.add value
      of "overwrite": o.overwrite = true
      of "keep": o.keep = true
      else: usage()
    else:
      o.targets.add arg
  if o.workers.len == 0:
    for w in getEnv("WORKERS", "1").split({',', ' '}):
      if w.len > 0: o.workers.add w
  try:
    o.buildDir = $absolutePath(path(o.buildDir))
    createDir(path(o.buildDir))
  except:
    quit "cannot create " & o.buildDir

  var tests: seq[string] = @[]
  if o.suite.len > 0:
    for name in argsFrom("tests" / o.suite & ".suite"): collect("tests" / name & ".nim", tests)
    if tests.len == 0: quit "tests/" & o.suite & ".suite names no test"
  if o.targets.len == 0 and o.suite.len == 0: o.targets.add "tests"
  for target in o.targets: collect(target, tests)

  let common = argsFrom("tests" / "tester.args")
  var c = Counters(passed: 0, failed: 0, skipped: 0, known: 0)
  for test in tests:
    testOne(o, c, test, common)
    flushFile(stdout)   # a lane that tails the log sees each verdict as it lands
  echo c.passed, " passed, ", c.failed, " failed, ", c.skipped, " skipped",
    (if c.known > 0: ", " & $c.known & " known compiler cases" else: "")
  quit(if c.failed == 0: 0 else: 1)

main()
