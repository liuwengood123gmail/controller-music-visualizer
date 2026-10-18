# Builds cvwin.dll (CMake + Ninja, release) into native-win/out/x64 next to ControllerCAPI.dll.
# Run build-swift.ps1 first (it produces ControllerCAPI.lib). Usage:
#   powershell -ExecutionPolicy Bypass -File native-win\scripts\build-native.ps1
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\env.ps1"
$root = Resolve-Path "$PSScriptRoot\.."
$build = Join-Path $root "build"

cmake -S $root -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
cmake --build $build
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
Write-Host "[OK] $root\out\x64\cvwin.dll"
