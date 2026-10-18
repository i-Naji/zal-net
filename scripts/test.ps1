param(
  [ValidateSet("fast", "full", "stress", "platform")]
  [string]$Suite = "fast",
  [string[]]$Workers = @("1"),
  [string[]]$Tests = @(),
  [string]$Nimony = "nimony",
  [string]$Flags = "",
  [switch]$Release,
  [string]$BuildDir = "build/test",
  [int]$TimeoutSec = 120,
  [string]$Arch = "",                # x64: build x86_64 binaries (run under emulation on ARM64)
  [string]$Wintun = ""
)
$ErrorActionPreference = "Continue"
$Workers = @($Workers | ForEach-Object { $_.Split(",") } | Where-Object { $_ })
$Tests = @($Tests | ForEach-Object { $_.Split(",") } | Where-Object { $_ })
if ($Tests.Count -eq 0 -and $Suite -ne "full") {
  switch ($Suite) {
    "fast" { $Tests = @("tcontinuations", "tcompletiondrain", "treadyio", "townership", "ttcpref", "tunixref", "tapplicationtcp", "tapplicationunix", "tapplicationudp", "tudpdeadline", "tapplicationserve", "treaderresults", "ttransport", "ttransportcancel", "tservicedrain") }
    "stress" { $Tests = @("tshutdown", "truntimedrain", "tstdhandoff", "tenginereadiness", "tenginecapacity", "tenginestop", "tengines", "tdatagram") }
    "platform" { $Tests = @("tinterfaces", "tip", "ticmp", "ttun", "turingclose") }
  }
}
$selectedOnly = $Tests.Count -gt 0
Set-Location (Join-Path $PSScriptRoot "..")
if ($Tests.Count -eq 0) {
  $Tests = Get-ChildItem tests -Filter "t*.nim" | ForEach-Object { $_.BaseName }
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$BuildDir = (Resolve-Path $BuildDir).Path
$fail = 0
foreach ($be in @("runtime")) {
  $dir = Join-Path $BuildDir $be
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  if ($Wintun) { Copy-Item -Force $Wintun (Join-Path $dir "wintun.dll") }
  $args0 = @("c", "--ff", "--path:src")
  $args0 += "--mm:atomicArc", "-d:useMimalloc"
  if ($Flags) { $args0 += $Flags.Split(" ") }
  if ($Release) { $args0 += "-d:release" }
  if ($Arch -eq "x64") { $args0 += "--cpu:amd64", "--cc:x86_64-w64-mingw32-clang" }
  $sources = @($Tests | ForEach-Object { "tests\$_.nim" })
  if (-not $selectedOnly) {
    $sources += @(Get-ChildItem examples -Recurse -Filter "*.nim" | ForEach-Object { $_.FullName.Substring((Get-Location).Path.Length + 1) })
  }
  foreach ($src in $sources) {
    $name = [IO.Path]::GetFileNameWithoutExtension($src)
    $exe = Join-Path $dir "$name.exe"
    $log = Join-Path $dir "$name.log"
    $previousLocalAppData = $env:LOCALAPPDATA
    try {
      $env:LOCALAPPDATA = "$BuildDir\$be\c-cache-$name"
      New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
      & $Nimony @args0 "--nimcache:$dir\cache-$name" "-o:$exe" $src *> $log
      $compileExit = $LASTEXITCODE
    } finally {
      $env:LOCALAPPDATA = $previousLocalAppData
    }
    if ($compileExit -ne 0) {
      "FAIL build $be $name (see $log)"
      Get-Content $log -Tail 40
      $fail = 1
      continue
    }
    if ($src.StartsWith("examples")) { "ok   build $be $name"; continue }
    foreach ($w in $Workers) {
      # One worker delays the datagram engine's readiness under churn.
      if ($name -eq "tdatagram" -and [int]$w -lt 2) { $w = "2" }
      $env:ZAL_WORKERS = "$w"
      $out = Join-Path $dir "$name.w$w.out"
      $p = Start-Process -FilePath $exe -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
      $null = $p.Handle          # without it ExitCode stays empty
      if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill()
        $p.WaitForExit()
        "FAIL $be $name workers=$w (timeout, see $out)"
        $fail = 1
        Get-Content $out, "$out.err"
      } elseif ($p.ExitCode -ne 0) {
        "FAIL $be $name workers=$w (rc=$($p.ExitCode), see $out)"
        $fail = 1
        Get-Content $out, "$out.err"
      } else {
        "ok   $be $name workers=$w"
      }
    }
  }
}
exit $fail
