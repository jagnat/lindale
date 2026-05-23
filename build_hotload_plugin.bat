@echo off
setlocal

rem Resolve the plugin to build: first arg, else the default in src\bridge\plugin_id.odin.
set PLUGIN=%1
if "%PLUGIN%"=="" for /f tokens^=2^ delims^=^" %%a in ('findstr /b "ACTIVE_PLUGIN ::" src\bridge\plugin_id.odin') do set PLUGIN=%%a
if "%PLUGIN%"=="" (
	echo No plugin specified. Pass one as an argument or set it with set_plugin.bat
	exit /b 1
)

if not exist out\hot mkdir out\hot
odin build src/lindale -define:HOT_DLL=true -define:ACTIVE_PLUGIN=%PLUGIN% -debug -build-mode:dynamic -out:out/hot/%PLUGIN%Hot.dll

endlocal
