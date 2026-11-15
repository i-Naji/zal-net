## Sockets are closed on exec: a listener, an accepted connection, a dialled
## one and a UDP socket, so a program this one starts cannot keep them.
import std/[assertions, syncio]
import zal_net
import zal_net/engine

proc cFcntl(fd, cmd: cint): cint {.importc: "fcntl", header: "<fcntl.h>", varargs.}
const FGetFd = 1.cint

proc closesOnExec(fd: cint): bool = (cFcntl(fd, FGetFd) and 1) != 0

proc main() {.passive.} =
  try:
    var listener = listen(0, "127.0.0.1")
    let lr = tryListenTcp(0, 16, "127.0.0.1", true)
    assert lr.ok and closesOnExec(lr.fd)
    closeFd(lr.fd)
    var c = connect("127.0.0.1", listener.port, afterMs(2000))
    var a = accept(listener, afterMs(2000))
    assert closesOnExec(c.nativeHandle) and closesOnExec(a.nativeHandle)
    var u = openUdp(0, "127.0.0.1")
    assert closesOnExec(u.nativeHandle)
    close u
    close a
    close c
    close listener
    echo "PASS close on exec: listener, accepted, dialled, UDP"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
