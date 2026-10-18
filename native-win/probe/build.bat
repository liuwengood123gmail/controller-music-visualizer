@echo off
setlocal
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSDIR=%%i
if not defined VSDIR (
    echo [ERROR] Visual Studio C++ build tools not found.
    exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

cd /d "%~dp0"
if not exist ..\bin mkdir ..\bin
if not exist ..\obj mkdir ..\obj
cl /nologo /W4 /EHsc /O2 /utf-8 /Fo..\obj\ probe.cpp /Fe..\bin\probe.exe || exit /b 1
echo [OK] ..\bin\probe.exe
