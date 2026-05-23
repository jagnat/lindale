@echo off
setlocal

rem Resolve the plugin to build: first arg, else the default in src\bridge\plugin_id.odin.
set PLUGIN=%1
if "%PLUGIN%"=="" for /f tokens^=2^ delims^=^" %%a in ('findstr /b "ACTIVE_PLUGIN ::" src\bridge\plugin_id.odin') do set PLUGIN=%%a
if "%PLUGIN%"=="" (
	echo No plugin specified. Pass one as an argument or set it with set_plugin.bat
	exit /b 1
)

set BUNDLE=out\%PLUGIN%.vst3
if not exist out\hot mkdir out\hot
if not exist "%BUNDLE%\Contents\x86_64-win" mkdir "%BUNDLE%\Contents\x86_64-win"

odin build src/lindale -define:HOT_DLL=true -define:ACTIVE_PLUGIN=%PLUGIN% -debug -build-mode:dynamic -out:out/hot/%PLUGIN%Hot.dll
odin build src/vst_host -define:HOT_DLL=true -define:ACTIVE_PLUGIN=%PLUGIN% -debug -build-mode:dynamic -out:%BUNDLE%\Contents\x86_64-win\%PLUGIN%.vst3

rem Install junctions into the system folders. rmdir drops a stale junction
rem first (it never follows into the target) so switching plugins self-heals.
rem Junctions (mklink /J) need no admin, unlike symbolic links (mklink /D).
set VST3_DIR=%LOCALAPPDATA%\Programs\Common\VST3
if not exist "%VST3_DIR%" mkdir "%VST3_DIR%"
rmdir "%VST3_DIR%\%PLUGIN%.vst3" 2>nul
mklink /J "%VST3_DIR%\%PLUGIN%.vst3" "%CD%\%BUNDLE%"

set RUNTIME_DIR=%APPDATA%\jagi\%PLUGIN%
if not exist "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%"
rmdir "%RUNTIME_DIR%\hot" 2>nul
mklink /J "%RUNTIME_DIR%\hot" "%CD%\out\hot"

endlocal
