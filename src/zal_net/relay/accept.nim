## The accept loop, once: drain pending connections per readiness event,
## yield every AcceptBurst accepts so a flood cannot monopolize a loop, back
## off 50 ms when out of descriptors or memory, and end on AcceptClosed
## (`stopAccepting` or `closeListener`).

import zal_net/rt
import zal_net/raw/io

template acceptEach*(listenFd: cint; body: untyped) =
  ## Run `body` for every accepted descriptor, bound to the injected
  ## `accepted` (a non-blocking cint). Use inside a passive proc, one per
  ## loop via `spawnAll`. (Nimony injects only fixed names, so the name is
  ## not a parameter.)
  block:
    var aeRes = 0
    var aeBurst = 0
    while true:
      let aeFd = acceptNow(listenFd)
      if aeFd >= 0:
        let accepted {.inject.} = cint(aeFd)
        body
        aeBurst = aeBurst + 1
        if aeBurst >= AcceptBurst:
          aeBurst = 0
          yieldNow()
      elif aeFd == AcceptAgain:
        aeBurst = 0
        parkAccept(listenFd, aeRes)
      elif aeFd == AcceptBusy:
        parkUntil(afterMs(50))
      elif aeFd == AcceptClosed:
        break
