@echo off
rem SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
rem SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
rem
rem mcp\scripts\windows\build.bat: the Windows leg of the DuckDB MCP server.
rem VS 2022 cl.exe (found with vswhere), OpenSSL from vcpkg's x64-windows-static triplet, and a DuckDB
rem release's libduckdb-windows-amd64 (duckdb.h, duckdb.lib, duckdb.dll) for the C API.
rem
rem Usage: build.bat OUTDIR DUCKDB_DIR [probes]
rem   Builds OUTDIR\fractalsql-ext-mcp.exe and copies duckdb.dll next to it. With "probes" it also builds
rem   the standalone probes and duckdb_exec.exe (the SQL runner the test drivers use) into OUTDIR.
rem Not run by the author's Linux machine: first exercised by build_test.ps1 gates 35-43.

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set MCP_DIR=%SCRIPT_DIR%..\..
set REPO_DIR=%MCP_DIR%\..
set OUTDIR=%~1
set DUCKDB_DIR=%~2
set MODE=%~3
if "%OUTDIR%"=="" set OUTDIR=%MCP_DIR%\dist\windows-mcp
if "%DUCKDB_DIR%"=="" (
  echo FATAL: build.bat OUTDIR DUCKDB_DIR [probes] -- DUCKDB_DIR must hold duckdb.h, duckdb.lib and duckdb.dll 1>&2
  exit /b 1
)
if not exist "%DUCKDB_DIR%\duckdb.h" (echo FATAL: %DUCKDB_DIR%\duckdb.h not found 1>&2 & exit /b 1)
if not exist "%DUCKDB_DIR%\duckdb.lib" (echo FATAL: %DUCKDB_DIR%\duckdb.lib not found 1>&2 & exit /b 1)

set INCOMING_VCPKG_ROOT=%VCPKG_ROOT%
set VSPATH=
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
)
if "%VSPATH%"=="" set VSPATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
if not exist "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" (
  echo FATAL: no Visual Studio VC tools found 1>&2
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 (echo FATAL: vcvars64 failed 1>&2 & exit /b 1)
if not "%INCOMING_VCPKG_ROOT%"=="" set VCPKG_ROOT=%INCOMING_VCPKG_ROOT%

rem vcvars64 can overwrite VCPKG_ROOT with VS's bundled (empty) tree, so the caller's value is restored first.
set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  set CANDIDATE=%REPO_DIR%\..\vcpkg
  if exist "!CANDIDATE!\installed\x64-windows-static\include\openssl\evp.h" set OPENSSL_DIR=!CANDIDATE!\installed\x64-windows-static
)
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  echo FATAL: OpenSSL for MSVC not found: vcpkg install openssl:x64-windows-static, and set VCPKG_ROOT 1>&2
  exit /b 1
)
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set CFLAGS=/nologo /std:c++17 /utf-8 /EHsc /MT /O2 /W3 /D_CRT_SECURE_NO_WARNINGS /DNOMINMAX
set INCS=/I "%MCP_DIR%\vendor" /I "%MCP_DIR%\src" /I "%DUCKDB_DIR%" /I "%OPENSSL_DIR%\include"
set LIBS=/link /LIBPATH:"%DUCKDB_DIR%" /LIBPATH:"%OPENSSL_DIR%\lib" duckdb.lib libssl.lib libcrypto.lib ws2_32.lib advapi32.lib user32.lib crypt32.lib

cl.exe %CFLAGS% %INCS% "%MCP_DIR%\src\*.cpp" "%MCP_DIR%\src\adapters\*.cpp" /Fo"%OUTDIR%\\" /Fe"%OUTDIR%\fractalsql-ext-mcp.exe" %LIBS%
if errorlevel 1 (echo FATAL: mcp build failed 1>&2 & exit /b 1)
copy /y "%DUCKDB_DIR%\duckdb.dll" "%OUTDIR%\duckdb.dll" >nul
rem The server looks for its two drift locks beside the executable when no path is configured, so a
rem server started from this directory is checked against the locks this build was made with. The
rem Linux build lands the binary beside the locks by default; the Windows build puts it in a
rem separate output directory, so the locks are copied there.
for %%L in (.mcp-schema-lock .mcp-safety-annotations-lock) do (
  if exist "%MCP_DIR%\%%L" copy /y "%MCP_DIR%\%%L" "%OUTDIR%\%%L" >nul
)

if /i "%MODE%"=="probes" (
  set PDIR=%OUTDIR%\probes
  if not exist "!PDIR!" mkdir "!PDIR!"
  call :probe vectors_probe src\vectors.cpp src\errors.cpp
  if errorlevel 1 goto probe_failed
  call :probe concurrency_probe src\errors.cpp
  if errorlevel 1 goto probe_failed
  call :probe db_probe src\db.cpp src\errors.cpp src\logging.cpp
  if errorlevel 1 goto probe_failed
  call :probe sanitize_probe src\errors.cpp
  if errorlevel 1 goto probe_failed
  cl.exe %CFLAGS% %INCS% "%MCP_DIR%\tests\duckdb_exec.cpp" /Fo"!PDIR!\\" /Fe"%OUTDIR%\duckdb_exec.exe" %LIBS%
  if errorlevel 1 goto probe_failed
)
echo mcp build OK: %OUTDIR%
endlocal
exit /b 0

rem A failed build must leave this script with a NON-ZERO exit code. "exit /b N"
rem inside a parenthesised block does not carry its code out of the block on
rem cmd.exe -- the script stopped at the failure but still exited 0, so the
rem harness read a half-built output directory as a successful build and only
rem failed later, on the missing artefact. The failure jumps out of the block
rem first and exits at the top level, where the code does survive.
:probe_failed
echo FATAL: the MCP build did not finish 1>&2
exit /b 1

:probe
rem :probe NAME SRC... -- compiles tests\NAME.cpp with the given sources into OUTDIR\NAME.exe
set PNAME=%~1
set PSRCS=
:probe_next
shift
if "%~1"=="" goto probe_build
set PSRCS=%PSRCS% "%MCP_DIR%\%~1"
goto probe_next
:probe_build
cl.exe %CFLAGS% %INCS% "%MCP_DIR%\tests\%PNAME%.cpp" %PSRCS% /Fo"%PDIR%\\" /Fe"%OUTDIR%\%PNAME%.exe" %LIBS%
if errorlevel 1 (echo FATAL: %PNAME% failed to build 1>&2 & exit /b 1)
exit /b 0

