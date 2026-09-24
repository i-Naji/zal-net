## The relay: a connection as one pooled, raw block (`ConnObj`: plain data,
## no managed fields) holding both directions. Each direction is driven by
## ONE flat passive proc, `pump`. All parsing, sealing and opening happens in
## regular procs, and the pump suspends only through the inline readiness
## park (`parkReady`) when the kernel reports EAGAIN. Every transfer is a
## non-blocking system call made here.
##
## Framers: a direction's source and sink are plain (nil) or a framer, a
## small table of regular procs called once per batch of records. A framer
## declares its `Geometry`: the bytes before (`head`) and after (`tail`)
## each record's payload on the wire, the largest payload (`maxRecord`),
## and the room it needs before the first record (`headRoom`). It keeps its
## per-direction state (cipher context, parse state) in the Dir's
## `srcSt`/`dstSt` words, and per-connection data (keys) in `ConnObj.proto`.
##
## Buffer layout: a plain source's bytes are scattered by readv into record
## slots laid out for the sink framer's geometry (`layout`, cached in the
## Dir when the pumps start), so a batch is sealed in place and written at
## once. A framed source's records are decoded in place, so a
## framer-to-framer relay re-seals them without copying. A pair whose sink
## needs more head, tail or record size than the source's records leave is
## relaid out: each batch's payload is copied once into sink-shaped slots
## of a second block (`Dir.alt`, mapped when first needed), which holds the
## sink's state and is sealed and written instead. A first span longer
## than the sink's record (a handshake's leftover) goes the same way, once.
## No framer may need more than `HeadRoom` before the first record;
## `startPumps` refuses such geometries.
##
## Frameworks: `hooks` (`ConnHooks`) is called after every batch and once
## as the connection ends; `ext` holds the framework's per-connection data
## (a session), zeroed for each connection.
##
## Ownership: `refs` counts the running pumps. The last pump to finish
## runs the end hook, closes both descriptors, calls the framers' close
## hooks and returns the block to the pool. No lock is taken on the I/O
## path.
##
## Connection metadata and payloads are separate anonymous mappings. Payloads
## are acquired on first traffic, retained while referenced by buffered records
## or writes, and returned to their bounded pool after an idle grace. Pool
## capacity and live ownership are reported separately. No buffer borrow may
## survive its callback/batch. Idle metadata retains no payload mapping.

import std/syncio
import std/atomics
import std/locks
when defined(nnTraceRelay): import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/buffers
import zal_net/storage
import zal_net/private/sys/posix
import zal_net/private/sys/sock
import zal_net/net/sockaddr
import zal_net/raw/socket

# Includes preserve private fields and bind passive templates in one module.
include zal_net/private/relay/contracts
include zal_net/private/relay/ownership
include zal_net/private/relay/layout
include zal_net/private/relay/pump
