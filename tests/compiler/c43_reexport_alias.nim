## A package alias matching its re-exported module loses qualified type lookup.
## TLS keeps its implementation's module name distinct; c44 guards that form.
import std/[assertions, syncio]
import fixtures/aliasexport/package as tls
var config: nil tls.Config = nil
assert config == nil
echo "ok"
