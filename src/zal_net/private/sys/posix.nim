## Raw OS pieces both backends and the I/O helpers share: errno values,
## the descriptor limit, anonymous mappings. On Windows the errno values
## are what sys/win/nn_win.c reports (Linux numbering).

import std/oserrors
import zal_net/private/sys/sock

const
  EIntr* = 4
  EAgain* = when defined(macosx): 35 else: 11
  ENoBufs* = when defined(macosx): 55 else: 105
  ENoEntry* = 2
  EConnRefused* = when defined(macosx): 61 else: 111
  ENotSocket* = when defined(macosx): 38 else: 88

proc lastErr*(): int =
  result = cast[int](cast[int32](osLastError()))

proc makeNonblocking*(fd: cint): bool {.noinline.} = sockNonblock(fd)

when defined(windows):
  proc raiseFdLimit*(want = 1 shl 20): int = want
    ## Windows has no descriptor limit to raise.

  proc fdLimits*(soft, hard: var int): bool =
    soft = 1 shl 24
    hard = 1 shl 24
    result = true

  proc nnMapAnon(len: csize_t): nil pointer {.importc: "nn_map_anon".}
  proc nnUnmapAnon(p: nil pointer; len: csize_t) {.importc: "nn_unmap_anon".}

  proc mapAnon*(len: int): nil pointer = nnMapAnon(csize_t(len))
    ## Zeroed memory, committed as touched; nil on failure.

  proc unmapAnon*(p: nil pointer; len: int) = nnUnmapAnon(p, csize_t(len))

  proc ignoreSigpipe*() = discard
    ## Windows has no SIGPIPE: a send to a closed peer fails with an error.

when not defined(windows):
  proc cSignal(sig: cint; handler: nil pointer): nil pointer {.importc: "signal", header: "<signal.h>".}

  proc ignoreSigpipe*() =
    ## Make a write to a closed or shut-down socket fail with EPIPE instead
    ## of killing the process: `writev` and `splice` take no MSG_NOSIGNAL.
    ## Process-wide; `initRuntime` calls it.
    const SigPipe = 13.cint   # Linux, macOS and the BSDs
    discard cSignal(SigPipe, cast[pointer](1))   # SIG_IGN

when not defined(windows):
  type RLimit {.importc: "struct rlimit", header: "<sys/resource.h>".} = object
    rlim_cur: uint64
    rlim_max: uint64

  proc getrlimit(resource: cint; rlp: ptr RLimit): cint {.importc, header: "<sys/resource.h>".}
  proc setrlimit(resource: cint; rlp: ptr RLimit): cint {.importc, header: "<sys/resource.h>".}
  when defined(macosx):
    proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
                      newp: nil pointer; newlen: csize_t): cint {.importc, header: "<sys/sysctl.h>".}

  proc raiseFdLimit*(want = 1 shl 20): int =
    ## Raise the descriptor limit toward `want` and return the new soft
    ## limit. The soft limit rises to the hard limit; a privileged process
    ## (root, or CAP_SYS_RESOURCE on Linux) raises the hard limit too, as far
    ## as the kernel allows (fs.nr_open on Linux, kern.maxfilesperproc on
    ## macOS). launchd starts macOS processes with a soft limit of 256.
    const NoFile = when defined(macosx): 8.cint else: 7.cint
    var r = default(RLimit)
    if getrlimit(NoFile, addr r) != 0: return -1
    var target = uint64(want)
    when defined(macosx):
      var perProc: cint = 0
      var size = csize_t(sizeof(perProc))
      if sysctlbyname("kern.maxfilesperproc", addr perProc, addr size, nil, 0) == 0 and
          perProc > 0 and uint64(perProc) < target:
        target = uint64(perProc)
    # Above the hard limit: only a privileged process may; halve until the
    # kernel agrees (EPERM otherwise).
    var t = target
    while t > r.rlim_max and t > r.rlim_cur:
      var n = r
      n.rlim_cur = t
      n.rlim_max = t
      if setrlimit(NoFile, addr n) == 0: return int(t)
      t = t div 2
    # Up to the hard limit.
    if target > r.rlim_max: target = r.rlim_max
    while target > r.rlim_cur:
      var n = r
      n.rlim_cur = target
      if setrlimit(NoFile, addr n) == 0: return int(target)
      target = target div 2
    result = int(r.rlim_cur)

  proc fdLimits*(soft, hard: var int): bool =
    ## The current descriptor limits (hard may be very large: unlimited).
    const NoFile = when defined(macosx): 8.cint else: 7.cint
    var r = default(RLimit)
    result = getrlimit(NoFile, addr r) == 0
    soft = int(min(r.rlim_cur, uint64(high(int))))
    hard = int(min(r.rlim_max, uint64(high(int))))

  proc cMmap(a: nil pointer; len: csize_t; prot, flags, fd: cint; off: int): nil pointer {.importc: "mmap", header: "<sys/mman.h>".}
  proc cMunmap(a: pointer; len: csize_t): cint {.importc: "munmap", header: "<sys/mman.h>".}

  const
    ProtReadWrite = 3.cint
    MapPrivateAnon = when defined(macosx): 0x1002.cint else: 0x22.cint

  proc mapAnon*(len: int): nil pointer =
    ## Zeroed private memory whose pages become resident only when touched;
    ## nil on failure. For large buffers that are mostly left unused.
    result = cMmap(nil, csize_t(len), ProtReadWrite, MapPrivateAnon, -1.cint, 0)
    if cast[int](result) == -1: result = nil

  proc unmapAnon*(p: nil pointer; len: int) =
    if p != nil: discard cMunmap(p, csize_t(len))
