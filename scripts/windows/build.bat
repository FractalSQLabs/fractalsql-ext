@echo off
REM scripts\windows\build.bat -- the pure-C DuckDB extension on Windows x64, both bands.
REM
REM   scripts\windows\build.bat            builds both bands into dist\windows_amd64\
REM   scripts\windows\build.bat clean
REM
REM Run from an "x64 Native Tools Command Prompt for VS" (cl on PATH), or let
REM the script locate vcvars64.bat through vswhere. C mode (/TC, /std:c11),
REM static CRT (/MT) so the extension has no Visual C++ Redistributable dependency
REM (the separate reasoning plugin DLL does; see docs/reasoning-setup.md).
REM No DuckDB source is compiled or linked; see
REM ~/github/duckdb-purec-ext-port.txt.
REM
REM NOT YET RUN WITH MSVC. What has been checked without it: every source compiles for Windows with
REM MinGW-w64 (warnings-clean), and a MinGW link of the vendored core showed that the core needs FSQL_STATIC
REM (it is a static archive) and bcrypt.lib (BCryptGenRandom); everything else it imports is kernel32.
REM What only MSVC can confirm: the first real cl/link run, and that the DLL then loads in a DuckDB CLI.
REM
REM FSQL_SANITIZE=address|undefined builds the INSTRUMENTED extension the
REM -Asan/-Ubsan harness cells drive, into dist\windows-asan\ /
REM dist\windows-ubsan\, next to the instrumented CLI that hosts it:
REM
REM   address    MSVC cl.exe /fsanitize=address. /MD (not /MT) so the DLL
REM               imports clang_rt.asan_dynamic-x86_64.dll -- the SAME
REM               runtime the instrumented CLI in that directory uses.
REM               Two ASan runtimes in one process would be two shadow
REM               maps and two interceptors.
REM   undefined  clang-cl -fsanitize=undefined. MSVC has no undefined-
REM               behaviour sanitizer at all, so the cell switches the
REM               compiler driver. /MD because LLVM's prebuilt
REM               clang_rt.ubsan_standalone-x86_64.lib expects the dynamic
REM               CRT's import thunks.
REM
REM A sanitizer cell builds the stable band only: the instrumented CLI is
REM the 2.0 line, and the LTS band is pinned to 1.4.5, which has no
REM instrumented host here.
setlocal enabledelayedexpansion
cd /d "%~dp0..\.."

if /i "%~1"=="clean" ( rmdir /s /q dist\windows_amd64 2>nul & exit /b 0 )

set "SANMODE="
if not "%FSQL_SANITIZE%"=="" (
  REM both spellings: the harness calls the cell "asan"/"ubsan", the
  REM sanitizer itself is called address/undefined.
  if /i "%FSQL_SANITIZE%"=="address" set "SANMODE=address"
  if /i "%FSQL_SANITIZE%"=="asan" set "SANMODE=address"
  if /i "%FSQL_SANITIZE%"=="undefined" set "SANMODE=undefined"
  if /i "%FSQL_SANITIZE%"=="ubsan" set "SANMODE=undefined"
  if not defined SANMODE (
    echo scripts\windows\build.bat: FSQL_SANITIZE must be address or undefined, got "%FSQL_SANITIZE%"
    exit /b 2
  )
)

REM The MSVC toolchain: headers, libs and cl.exe itself. clang-cl needs the
REM same INCLUDE/LIB, so this runs for every mode.
where cl >nul 2>nul
if errorlevel 1 (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" ( echo scripts\windows\build.bat: cl not on PATH and vswhere not found & exit /b 2 )
  for /f "usebackq delims=" %%I in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%I"
  if not defined VSROOT ( echo scripts\windows\build.bat: no Visual Studio with the C++ tools found & exit /b 2 )
  call "!VSROOT!\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 2
)

REM The UBSan cell's compiler driver: VS's bundled LLVM, or a standalone one.
if "%SANMODE%"=="undefined" (
  where clang-cl >nul 2>nul
  if errorlevel 1 (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    set "VSROOT="
    if exist "!VSWHERE!" for /f "usebackq delims=" %%I in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Llvm.x86.x64 -property installationPath`) do set "VSROOT=%%I"
    if defined VSROOT if exist "!VSROOT!\VC\Tools\Llvm\x64\bin\clang-cl.exe" set "PATH=!VSROOT!\VC\Tools\Llvm\x64\bin;!PATH!"
  )
  where clang-cl >nul 2>nul
  if errorlevel 1 (
    if exist "C:\Program Files\LLVM\bin\clang-cl.exe" set "PATH=C:\Program Files\LLVM\bin;!PATH!"
  )
  where clang-cl >nul 2>nul
  if errorlevel 1 ( echo scripts\windows\build.bat: clang-cl not found (needs the VS "C++ Clang tools for Windows" component, or a standalone LLVM) & exit /b 2 )
)

REM The extension: every translation unit under src\, linked with the vendored static core.
if not defined SRC set "SRC=src\fractalsql_ext.c src\fsql_duck.c src\fsql_buf.c src\fsql_vector.c src\fsql_index.c src\fsql_sovereign.c src\fsql_enterprise.c src\fsql_reasoning.c src\fsql_config.c src\fsql_ledger.c src\fsql_parse.c src\fsql_t2s.c src\fsql_vectorizer.c src\fsql_feature_store.c src\fsql_agents.c src\fsql_domain_agents.c"
if not defined CORE_LIB set "CORE_LIB=include\windows-x86_64\fractalsql-community-sovereign-c.lib"
if not defined EXTVER set "EXTVER=v2.0.2"
if not defined L_VERSION set "L_VERSION=v1.4.5"
set "PLATFORM=windows_amd64"
set "OUT=dist\%PLATFORM%"
set "CC=cl"
set "LINKFLAGS=/INCREMENTAL:NO"
if "%SANMODE%"=="address" set "OUT=dist\windows-asan"
if "%SANMODE%"=="undefined" ( set "OUT=dist\windows-ubsan" & set "CC=clang-cl" )
if not "%SANMODE%"=="" set "LINKFLAGS=/INCREMENTAL:NO /DEBUG"
if not exist "%OUT%" mkdir "%OUT%"

set "CFLAGS=/nologo /O2 /MT /W3 /TC /std:c11 /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS /wd4141 /DFSQL_STATIC /fp:precise /Qvec- /Isrc /Iinclude"
REM The sanitizer cells keep the release build's /MT: the vendored core is a
REM /MT archive, so a /MD extension would put two heaps in one DLL (and
REM LNK4098 with it). MSVC's /fsanitize=address imports the DYNAMIC ASan
REM runtime under /MT too, so the cell still shares the instrumented
REM CLI's runtime, and ASan's own malloc/free definitions interpose over
REM the static CRT's -- the extension's heap is still ASan's to check.
if "%SANMODE%"=="address" set "CFLAGS=/nologo /O2 /MT /W3 /TC /std:c11 /fsanitize=address /Zi /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS /wd4141 /DFSQL_STATIC /fp:precise /Qvec- /Isrc /Iinclude"
if "%SANMODE%"=="undefined" set "CFLAGS=/nologo /O2 /MT /W3 /TC /std:c11 -fsanitize=undefined /Zi /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS /wd4141 /DFSQL_STATIC /fp:precise /Qvec- /Isrc /Iinclude"
REM The IVF index. MSVC has no weak externs, so the index TU is compiled against the core's IVF
REM entry points directly -- the vendored Windows core carries them. FSQL_IVF=0 turns that off (an
REM older core archive): the index surface is still registered and reports that this build of the
REM core does not carry the index.
if "%FSQL_IVF%"=="" set "FSQL_IVF=1"
if "%FSQL_IVF%"=="1" set "CFLAGS=%CFLAGS% /DFSQL_HAVE_IVF"
set "S_FILE=%OUT%\fractalsql.capi.%PLATFORM%.duckdb_extension"
set "L_FILE=%OUT%\fractalsql.%L_VERSION%.%PLATFORM%.duckdb_extension"

echo == band S: stable, v1.5.6 header (C_STRUCT)
%CC% %CFLAGS% /Ivendor\duckdb-v1.5.6 %SRC% /LD /Fe:"%S_FILE%" /Fo:"%OUT%\\" /link %LINKFLAGS% /EXPORT:fractalsql_init_c_api "%CORE_LIB%" bcrypt.lib || exit /b 1
python -I scripts\append_metadata.py --extension "%S_FILE%" --platform %PLATFORM% --duckdb-version v1.5.6 --extension-version %EXTVER% --abi-type C_STRUCT || exit /b 1

REM The instrumented CLI imports clang_rt.asan_dynamic-x86_64.dll, and so
REM does the extension that imports it: the runtime has to sit next to
REM both, or the cell's CLI will not start.
if "%SANMODE%"=="address" call :stage_asan_runtime "%OUT%"

if "%SANMODE%"=="" goto bands

echo built the %SANMODE%-instrumented band S into %OUT%
goto done

:bands
echo == band L: LTS %L_VERSION% header - C_STRUCT_UNSTABLE
%CC% %CFLAGS% /Ivendor\duckdb-%L_VERSION% /DFSQL_BAND_L_VER=\"%L_VERSION%\" /FIfsql_band_l.h %SRC% /LD /Fe:"%L_FILE%" /Fo:"%OUT%\\" /link %LINKFLAGS% /EXPORT:fractalsql_init_c_api "%CORE_LIB%" bcrypt.lib || exit /b 1
python -I scripts\append_metadata.py --extension "%L_FILE%" --platform %PLATFORM% --duckdb-version %L_VERSION% --extension-version %EXTVER% --abi-type C_STRUCT_UNSTABLE || exit /b 1
echo built both bands into %OUT%

:done
del /q "%OUT%\*.obj" "%OUT%\*.exp" "%OUT%\*.lib" 2>nul
endlocal
exit /b 0

REM Copy the ASan runtime next to the cell's artifacts if it is not
REM there already. It lives in the MSVC tools directory, which vcvars
REM puts on PATH.
:stage_asan_runtime
if exist "%~1\clang_rt.asan_dynamic-x86_64.dll" exit /b 0
for /f "usebackq delims=" %%I in (`where clang_rt.asan_dynamic-x86_64.dll 2^>nul`) do (
  copy /y "%%I" "%~1\" >nul
  echo staged the ASan runtime: %%I
  exit /b 0
)
echo scripts\windows\build.bat: clang_rt.asan_dynamic-x86_64.dll not found on PATH -- the instrumented CLI needs it next to it
exit /b 0
