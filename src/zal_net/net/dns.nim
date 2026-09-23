## Name resolution off the I/O threads: getaddrinfo runs as a job on the
## blocking pool, a 60-second cache is shared by all loops, and numeric hosts
## never reach the resolver. `resolveAsync` parks a passive caller;
## `submitResolve` delivers to a `JobInbox` for threads with their own
## poller. The resolver writes only into its job, never into a caller's
## frame, so a caller may give up (deadline, cancel) at any time.

import std/locks
import std/atomics
import zal_net/rt
import zal_net/rt/sync
import zal_net/rt/blocking
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/errors
import zal_net/private/sys/resolvererror

type ResolveAddrsPtr* = ptr UncheckedArray[SockAddrBuf]

proc describe*(code: int): string =
  ## Resolver-specific diagnostics; all other codes use net's fixed ranges.
  if code != DnsErrorBase and code > DnsErrorBase - DnsErrorRadius and
      code < DnsErrorBase + DnsErrorRadius:
    result = "getaddrinfo: " & fromCString(gai_strerror(cint(DnsErrorBase - code)))
  else:
    result = errors.describe(code)

proc resolveBuffer*(addrs: var array[MaxAddrs, SockAddrBuf]): ResolveAddrsPtr {.inline.} =
  ## Borrow the fixed-capacity, aligned output of resolveAsync. The array
  ## must remain address-stable until the resolving operation returns.
  cast[ResolveAddrsPtr](addr addrs[0])

proc validHost(host: openArray[char]): bool =
  if host.len == 0 or host.len > 255: return false
  for ch in host:
    if ch == '\0': return false
  result = true

proc resolveC(host: cstring; port: uint16; sockType, family: cint;
              outp: var array[MaxAddrs, SockAddrBuf]): int =
  ## Blocking getaddrinfo into plain storage; no Nim allocation, so the
  ## resolver threads never touch the Nim heap.
  result = 0
  var hints {.noinit.}: AddrInfo
  zeroMem(addr hints, sizeof(hints))
  hints.ai_socktype = sockType
  hints.ai_family = family
  # IPv6 sockets reach IPv4 through mapped addresses: ask for both kinds.
  if family == AF_INET6: hints.ai_flags = AI_V4MAPPED or AI_ALL
  var res: AddrInfoList = nil
  let code = getaddrinfo(host, nil, addr hints, addr res)
  if code != 0: return resolverFailure(code)
  if res == nil: return DnsNoAddresses
  var next: AddrInfoList = res
  while result < MaxAddrs:
    let ai = next
    if ai == nil: break
    next = ai.ai_next
    let n = int(ai.ai_addrlen)
    let sa = ai.ai_addr
    if sa != nil and n > 0 and n <= sizeof(SockaddrStorage):
      zeroMem(addr outp[result].ss, sizeof(SockaddrStorage))
      copyMem(addr outp[result].ss, sa, n)
      outp[result].len = cuint(n)
      setPort(outp[result], port)
      result = result + 1
  freeaddrinfo(res)
  if result == 0: result = DnsNoAddresses

proc resolve*(host: string; port: uint16; sockType, family: cint;
              outp: var array[MaxAddrs, SockAddrBuf]): int =
  ## Up to MaxAddrs addresses for `host`, blocking the calling thread for
  ## names. I/O paths use `resolveAsync` or a `ResolveInbox` instead.
  if not validHost(host): return InvalidInput
  if parseNumeric(host, port, family, outp[0]): return 1
  var node = host
  result = resolveC(node.toCString, port, sockType, family, outp)

# ----------------------------------------------------------------- resolver

type
  ResolveJob* = object
    ## A lookup on the blocking pool. `job` must stay the first field.
    job*: Job
    host: array[256, char]
    hostLen: int
    port: uint16
    sockType, family: cint
    n: int
    addrs: array[MaxAddrs, SockAddrBuf]

proc runResolve(j: ptr Job) {.nimcall.} =
  let r = cast[ptr ResolveJob](j)
  r.n = resolveC(cast[cstring](addr r.host[0]), r.port, r.sockType, r.family, r.addrs)

proc newResolveJob(host: openArray[char]; port: uint16; sockType, family: cint): nil ptr ResolveJob =
  ## nil for an empty, oversized or NUL-containing name.
  result = nil
  if not validHost(host): return
  let r = cast[ptr ResolveJob](newJob(sizeof(ResolveJob), runResolve))
  var i = 0
  while i < host.len:
    r.host[i] = host[i]
    i = i + 1
  r.host[host.len] = '\0'
  r.hostLen = host.len
  r.port = port
  r.sockType = sockType
  r.family = family
  result = r

const
  DnsSlots = 128                          # power of two
  DnsProbe = 8
  DnsTtlNs = 60'i64 * 1_000_000_000

type
  DnsEntry = object
    ## Addresses are stored with the port of the lookup that filled the
    ## entry; `cacheLookup` rewrites it.
    expires: int64                        # monotonic ns; 0 = empty
    sockType, family: cint
    hostLen: int
    n: int
    host: array[256, char]
    addrs: array[MaxAddrs, SockAddrBuf]

var dnsCacheLock: Lock
var dnsCache: array[DnsSlots, DnsEntry]
initLock(dnsCacheLock)

proc lowerAscii(c: char): char {.inline.} =
  if c >= 'A' and c <= 'Z': char(ord(c) + 32) else: c

proc hostSlot(host: openArray[char]): int =
  var h = 2166136261'u32                  # FNV-1a over the lowercased name
  for c in host:
    h = (h xor uint32(ord(lowerAscii(c)))) * 16777619'u32
  result = int(h and uint32(DnsSlots - 1))

proc sameHost(e: ptr DnsEntry; host: openArray[char]; sockType, family: cint): bool =
  if e.hostLen != host.len or e.sockType != sockType or e.family != family: return false
  var i = 0
  while i < host.len:
    if lowerAscii(e.host[i]) != lowerAscii(host[i]): return false
    i = i + 1
  result = true

proc cacheLookup(host: openArray[char]; port: uint16; sockType, family: cint;
                 outp: ptr UncheckedArray[SockAddrBuf]): int =
  result = 0
  if host.len == 0 or host.len > 255: return 0
  let now = int64(monoNow())
  let s = hostSlot(host)
  acquire(dnsCacheLock)
  var i = 0
  while i < DnsProbe:
    let e = addr dnsCache[(s + i) and (DnsSlots - 1)]
    if e.expires > now and sameHost(e, host, sockType, family):
      var k = 0
      while k < e.n:
        outp[k] = e.addrs[k]
        setPort(outp[k], port)
        k = k + 1
      result = e.n
      break
    i = i + 1
  release(dnsCacheLock)

proc cacheStore(req: ptr ResolveJob) =
  ## Replaces the same name, else the first free or oldest slot in the
  ## probe window. Failed lookups are not cached.
  if req.n <= 0: return
  let hostLen = req.hostLen
  let now = int64(monoNow())
  let s = hostSlot(req.host.toOpenArray(0, hostLen - 1))
  acquire(dnsCacheLock)
  var victim = addr dnsCache[s]
  var i = 0
  while i < DnsProbe:
    let e = addr dnsCache[(s + i) and (DnsSlots - 1)]
    if sameHost(e, req.host.toOpenArray(0, hostLen - 1), req.sockType, req.family):
      victim = e
      break
    if e.expires < victim.expires: victim = e
    i = i + 1
  victim.expires = now + DnsTtlNs
  victim.sockType = req.sockType
  victim.family = req.family
  victim.hostLen = hostLen
  copyMem(addr victim.host[0], addr req.host[0], hostLen)
  victim.n = req.n
  var k = 0
  while k < req.n:
    victim.addrs[k] = req.addrs[k]
    k = k + 1
  release(dnsCacheLock)

proc forgetHost*(host: string; sockType, family: cint) =
  ## Drop a cached name, e.g. after none of its addresses accepted a dial.
  if host.len == 0 or host.len > 255: return
  let s = hostSlot(host.toOpenArray(0, host.len - 1))
  acquire(dnsCacheLock)
  var i = 0
  while i < DnsProbe:
    let e = addr dnsCache[(s + i) and (DnsSlots - 1)]
    if sameHost(e, host.toOpenArray(0, host.len - 1), sockType, family): e.expires = 0
    i = i + 1
  release(dnsCacheLock)

proc resolveAsync*(host: string; port: uint16; sockType, family: cint;
                   outp: ptr UncheckedArray[SockAddrBuf]; deadline = never;
                   tok: nil CancelToken = nil): int {.passive.} =
  ## Up to MaxAddrs addresses for `host`; negative failure/cancellation/timeout.
  ## Failure leaves the caller's output unchanged. Numeric hosts resolve inline and
  ## cached names from the cache; others run on the blocking pool while
  ## this passive proc stays parked.
  result = 0
  retain(tok)
  defer: release(tok)
  if cancelled(tok): return ECancelled
  if stopping(): return ResourceClosed
  if monoNow() >= deadline: return IoTimedOut
  if not validHost(host): return InvalidInput
  var sa = default(SockAddrBuf)
  if parseNumeric(host, port, family, sa):
    outp[0] = sa
    return 1
  let cached = cacheLookup(host.toOpenArray(0, host.len - 1), port, sockType, family, outp)
  if cached > 0: return cached
  let r = newResolveJob(host.toOpenArray(0, host.len - 1), port, sockType, family)
  if r == nil: return InvalidInput
  result = ResourceClosed
  if spawnBlocking(addr r.job):
    let outcome = awaitJob(addr r.job, deadline, tok)
    if outcome == wrReady:
      cacheStore(r)
      var i = 0
      while i < r.n:
        outp[i] = r.addrs[i]
        i = i + 1
      result = r.n
    elif outcome == wrCancelled:
      result = ECancelled
    elif outcome == wrTimedOut:
      result = IoTimedOut
  releaseJob(addr r.job)

proc submitResolve*(host: openArray[char]; port: uint16; sockType, family: cint;
                    inbox: ptr JobInbox; tag, tag2: uint64): nil ptr ResolveJob =
  ## Resolve on the blocking pool and deliver the finished job to `inbox`.
  ## Returns the job, with the caller's reference, or nil when it could not
  ## be queued. The inbox consumer releases the delivered job once, and the
  ## caller releases its own reference when it stops referring to it.
  let r = newResolveJob(host, port, sockType, family)
  if r == nil: return nil
  r.job.tag = tag
  r.job.tag2 = tag2
  if not spawnBlocking(addr r.job, inbox):
    releaseJob(addr r.job)
    return nil
  result = r

proc resolveResult*(r: ptr ResolveJob; outp: ptr UncheckedArray[SockAddrBuf]): int =
  ## Delivered addresses (also cached), or a negative resolver failure.
  if r.n > 0: cacheStore(r)
  var i = 0
  while i < r.n:
    outp[i] = r.addrs[i]
    i = i + 1
  result = r.n
