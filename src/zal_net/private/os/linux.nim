## Linux: errno values, flag values and the calls only Linux has.

import std/syncio
import zal_net/private/os/common
export common

{.compile: "../sys/nn_linux.c".}       # fallbacks for old kernels (NN_LINUX_COMPAT=1 forces them)

const
  EAgain* = 11
  ENoBufs* = 105
  EConnRefused* = 111
  ENotSocket* = 88
  ONonblock = 2048.cint
  SockCloexec = 0x80000.cint   # SOCK_CLOEXEC, ORed into socket()'s type
  NoFile = 7.cint              # RLIMIT_NOFILE
  MapPrivateAnon = 0x22.cint

proc fdCeiling(): uint64 {.inline.} = high(uint64)
  ## The kernel's own ceiling (fs.nr_open) shows up as EPERM from setrlimit.

include zal_net/private/os/posixcommon

proc sockAbort*(fd: cint): bool =
  ## Disconnect a connected TCP socket now, waking whatever waits on it:
  ## with SO_LINGER 0 set, connecting to AF_UNSPEC resets it. False when the
  ## kernel refuses (a kTLS socket).
  var sa = default(array[16, byte])          # sa_family 0: AF_UNSPEC
  result = sockConnect(fd, addr sa[0], cuint(sa.len)) == 0
  # The reset alone polls as error and hang-up, which epoll readers miss.
  if result: discard sockShutdown(fd, 2)

proc parseCpuMax*(line: string): int =
  ## A cgroup v2 `cpu.max` line ("QUOTA PERIOD", or "max PERIOD" for no
  ## limit) in whole CPUs, rounded up; 0 when it sets no limit.
  result = 0
  var i = 0
  var quota = 0'i64
  var digits = 0
  while i < line.len and line[i] in {'0'..'9'}:
    quota = quota * 10 + int64(ord(line[i]) - ord('0'))
    inc i
    inc digits
  if digits == 0 or i >= line.len or line[i] != ' ': return
  inc i
  var period = 0'i64
  while i < line.len and line[i] in {'0'..'9'}:
    period = period * 10 + int64(ord(line[i]) - ord('0'))
    inc i
  if quota > 0 and period > 0:
    result = int((quota + period - 1) div period)

proc firstLine(path: string): string =
  result = ""
  var f: File
  if open(f, path):
    discard readLine(f, result)
    close(f)

proc cgroupPath(): string =
  ## This process's cgroup v2 path ("0::/path" in /proc/self/cgroup), or "".
  result = ""
  var f: File
  if open(f, "/proc/self/cgroup"):
    var line = ""
    while readLine(f, line):
      if line.len >= 3 and line[0] == '0' and line[1] == ':' and line[2] == ':':
        for i in 3 ..< line.len: result.add line[i]
        break
    close(f)

proc cpuQuota*(): int =
  ## The CPU time this process's cgroups allow, in whole CPUs rounded up, or
  ## 0 when none limits it. A container gets this from `docker --cpus` or a
  ## Kubernetes CPU limit without a narrower affinity mask, so a pool sized
  ## from the mask alone would run far more workers than it has CPU time for.
  ## Every ancestor's limit applies, so the smallest one wins.
  result = 0
  var path = cgroupPath()
  while true:
    let limit = parseCpuMax(firstLine("/sys/fs/cgroup" & path & "/cpu.max"))
    if limit > 0 and (result == 0 or limit < result): result = limit
    if path.len == 0: break
    var cut = path.len - 1
    while cut > 0 and path[cut] != '/': dec cut
    path.setLen cut
