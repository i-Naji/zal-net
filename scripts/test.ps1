# Builds tools/tester.nim and hands over to it; see that file for the rules.
param(
  [string]$Suite = "fast",
  [string[]]$Workers = @("1"),
  [string[]]$Tests = @(),
  [string]$Nimony = "nimony",
  [string]$Flags = "",
  [switch]$Release,
  [string]$BuildDir = "build/test",
  [int]$TimeoutSec = 180,
  [string]$Arch = "",                # x64: build x86_64 binaries (run under emulation on ARM64)
  [string]$Wintun = ""
)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$BuildDir = (Resolve-Path $BuildDir).Path
$tester = Join-Path $BuildDir "tester.exe"
$env:LOCALAPPDATA = Join-Path $BuildDir "c-cache"
& $Nimony c --ff "--nimcache:$BuildDir\cache-tester" "-o:$tester" tools/tester.nim *> (Join-Path $BuildDir "tester.log")
if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $BuildDir "tester.log"); exit 1 }
# Windows loads wintun.dll from the program's directory; the TUN test lives in tests/os.
if ($Wintun) {
  New-Item -ItemType Directory -Force -Path (Join-Path $BuildDir "os") | Out-Null
  Copy-Item -Force $Wintun (Join-Path $BuildDir "os\wintun.dll")
}
$list = @($Workers | ForEach-Object { $_.Split(",") } | Where-Object { $_ }) -join ","
$a = @("--nimony:$Nimony", "--build:$BuildDir", "--workers:$list", "--timeout:$TimeoutSec")
if ($Flags) { $Flags.Split(" ") | Where-Object { $_ } | ForEach-Object { $a += "--flag:$_" } }
if ($Release) { $a += "--flag:-d:release" }
if ($Arch -eq "x64") { $a += "--flag:--cpu:amd64", "--flag:--cc:x86_64-w64-mingw32-clang" }
$Tests = @($Tests | ForEach-Object { $_.Split(",") } | Where-Object { $_ })
if ($Tests.Count -gt 0) { $a += $Tests }
elseif ($Suite -eq "full") { $a += "tests", "examples" }
else { $a += "--suite:$Suite" }
& $tester @a
exit $LASTEXITCODE
