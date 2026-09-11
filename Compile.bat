@echo off
echo Building FoxArchiverShell.dll...

REM Find Visual Studio installation
set VSWhere="%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist %VSWhere% set VSWhere="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"

REM Find the latest Visual Studio installation
for /f "usebackq tokens=*" %%i in (`%VSWhere% -latest -property installationPath`) do set VS_PATH=%%i

if not defined VS_PATH (
    echo ERROR: Visual Studio not found!
    pause
    exit /b 1
)

echo Found Visual Studio at: %VS_PATH%

REM Set up the build environment
call "%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat" x64

if errorlevel 1 (
    echo ERROR: Failed to set up Visual Studio environment!
    pause
    exit /b 1
)

REM Build the DLL
echo.
echo Compiling FoxArchiverShell.cpp...
cl /nologo /O2 /MT /W4 /EHsc /D "_WIN64" /D "WIN32" /D "_WINDOWS" /D "NDEBUG" /D "_USING_V110_SDK71_" ^
   /I "%VS_PATH%\VC\include" ^
   /I "%ProgramFiles(x86)%\Windows Kits\10\Include\10.0.22000.0\ucrt" ^
   /I "%ProgramFiles(x86)%\Windows Kits\10\Include\10.0.22000.0\shared" ^
   /I "%ProgramFiles(x86)%\Windows Kits\10\Include\10.0.22000.0\um" ^
   /I "%ProgramFiles(x86)%\Windows Kits\10\Include\10.0.22000.0\winrt" ^
   FoxArchiverShell.cpp ^
   /link /DLL /OUT:FoxArchiverShell.dll ^
   /DEF:FoxArchiverShell.def ^
   /LIBPATH:"%ProgramFiles(x86)%\Windows Kits\10\Lib\10.0.22000.0\ucrt\x64" ^
   /LIBPATH:"%ProgramFiles(x86)%\Windows Kits\10\Lib\10.0.22000.0\um\x64" ^
   /LIBPATH:"%VS_PATH%\VC\lib\x64" ^
   shell32.lib shlwapi.lib ole32.lib user32.lib advapi32.lib ^
   /NODEFAULTLIB:libucrtd.lib ^
   /NODEFAULTLIB:msvcrtd.lib ^
   /NODEFAULTLIB:libcmtd.lib

if errorlevel 1 (
    echo.
    echo ERROR: Build failed!
    pause
    exit /b 1
)

echo.
echo Build successful!
echo Output: FoxArchiverShell.dll
echo.
echo To register the DLL, run as Administrator:
echo   regsvr32 FoxArchiverShell.dll
echo.
pause