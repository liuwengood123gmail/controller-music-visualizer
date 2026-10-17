# Dot-source from build scripts: imports the MSVC x64 environment (link.exe, cl.exe, dumpbin, cmake, ninja)
# and the Swift / Java variables a shell opened before the installers ran would not see.
if (-not (Get-Command link.exe -ErrorAction SilentlyContinue) -or -not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "Visual Studio C++ build tools not found" }
    cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process") }
    }
}
if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT", "User") }
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine") }
if (-not (Get-Command swift.exe -ErrorAction SilentlyContinue)) {
    $env:Path = $env:Path + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
