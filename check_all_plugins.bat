@echo off
rem Type-check every plugin branch in src\lindale\plugin_def.odin without
rem producing artifacts. Exits non-zero if any plugin fails to compile.

setlocal enabledelayedexpansion
cd /d "%~dp0"

set FAILED=
set FOUND=0
for /f tokens^=2^ delims^=^" %%a in ('findstr /c:"b.ACTIVE_PLUGIN ==" src\lindale\plugin_def.odin') do (
	set FOUND=1
	echo == %%a ==
	odin check src/lindale -no-entry-point -define:HOT_DLL=true -define:ACTIVE_PLUGIN=%%a
	if errorlevel 1 (
		set FAILED=!FAILED! %%a
	) else (
		echo    OK
	)
)

if "%FOUND%"=="0" (
	echo No plugins found in src\lindale\plugin_def.odin 1>&2
	exit /b 1
)

echo.
if defined FAILED (
	echo FAILED:!FAILED!
	exit /b 1
)
echo All plugins compile.
endlocal
