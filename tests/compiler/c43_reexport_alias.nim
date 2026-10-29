## A package alias matching its re-exported module loses qualified type lookup.
## TLS keeps its implementation's module name distinct; c44 guards that form.
## 0da5a6b7: a selective re-export no longer binds the module name (#2796), a whole-module one still does; this form still fails.
import std/[assertions, syncio]
import fixtures/aliasexport/package as tls
var config: nil tls.Config = nil
assert config == nil
echo "ok"
