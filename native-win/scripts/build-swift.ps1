# Builds ControllerCAPI.dll (release) and copies it plus every Swift runtime DLL it
# needs (recursively, per dumpbin /dependents) into native-win/out/x64.
# Usage: powershell -ExecutionPolicy Bypass -File native-win\scripts\build-swift.ps1 [-Configuration debug]
param([ValidateSet("release", "debug")][string]$Configuration = "release")
$ErrorActionPreference = "Stop"
$repo = Resolve-Path "$PSScriptRoot\..\.."
$out = Join-Path $repo "native-win\out\x64"

# Import the MSVC x64 environment (Swift on Windows needs link.exe, dumpbin needs it too).
if (-not (Get-Command link.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "Visual Studio C++ build tools not found" }
    cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process") }
    }
}
# A shell opened before the Swift installer ran does not see its user-level variables.
if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT", "User") }
if (-not (Get-Command swift.exe -ErrorAction SilentlyContinue)) {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:Path
}

Push-Location $repo
try {
    swift build -c $Configuration --product ControllerCAPI
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
} finally { Pop-Location }

$cfgDir = if ($Configuration -eq "release") { "Release" } else { "Debug" }
$products = Join-Path $repo ".build\out\Products\$cfgDir-windows-x86_64"
if (-not (Test-Path "$products\ControllerCAPI.dll")) {
    # Older SwiftPM layout
    $products = Join-Path $repo ".build\x86_64-unknown-windows-msvc\$Configuration"
}
$runtime = Split-Path (Get-Command swiftCore.dll -ErrorAction Stop).Source

New-Item -ItemType Directory -Force $out | Out-Null
Get-ChildItem $out -Filter *.dll | Remove-Item
Copy-Item "$products\ControllerCAPI.dll" $out
foreach ($ext in "lib", "pdb") {
    if (Test-Path "$products\ControllerCAPI.$ext") { Copy-Item "$products\ControllerCAPI.$ext" $out }
}

# Breadth-first walk of dependencies that live in the Swift runtime directory;
# system / VC runtime DLLs are left to the OS (VC++ redistributable).
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue("$out\ControllerCAPI.dll")
$seen = @{}
while ($queue.Count -gt 0) {
    $dll = $queue.Dequeue()
    $deps = dumpbin /nologo /dependents $dll | Where-Object { $_ -match '^\s+(\S+\.dll)\s*$' } | ForEach-Object { $Matches[1] }
    foreach ($d in $deps) {
        $key = $d.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $src = Join-Path $runtime $d
        if (Test-Path $src) {
            Copy-Item $src $out
            $queue.Enqueue((Join-Path $out $d))
        }
    }
}

$files = Get-ChildItem $out -Filter *.dll
$mb = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "Copied $($files.Count) DLLs ($mb MB) to $out"
$files | ForEach-Object { Write-Host "  $($_.Name)" }
