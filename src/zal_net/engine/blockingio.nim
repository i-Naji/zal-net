## The blocking socket calls, for code that runs on the blocking pool
## (`zal_net/rt/blocking`): `sockPoll` over `PollFd` entries with `PollIn`
## and `PollOut`, `sockSend` and `sockRecv`, and the `EAgain` and `EIntr`
## errno values they report.
from zal_net/private/os import sockPoll, PollFd, PollIn, PollOut, sockSend, sockRecv, EAgain, EIntr
export sockPoll, PollFd, PollIn, PollOut, sockSend, sockRecv, EAgain, EIntr
