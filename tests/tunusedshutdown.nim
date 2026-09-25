## Closing unused services must release their wakes without starting workers.
import std/[assertions, syncio]
import zal_net/rt/[blocking, signals], zal_net/log
stopBlockingPool()
assert blockingPoolStopped()
assert joinBlockingPool()
assert joinBlockingPool()
stopLogger()
assert loggerStopped()
assert joinLogger()
assert not initLogger()
stopSignals()
assert joinSignals()
assert joinSignals()
assert not watchSignals({sigInt})
echo "PASS unused worker, logger and signal shutdown"
