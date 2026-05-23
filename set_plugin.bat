@echo off
rem Sets the active build target by rewriting src\bridge\plugin_id.odin, which
rem is the source-of-truth read by both the build scripts and the LSP.
if "%~1"=="" (
	echo Usage: set_plugin.bat ^<plugin^>
	exit /b 1
)

>src\bridge\plugin_id.odin (
	echo package bridge
	echo.
	echo // Selects which plugin's vtable + state types are compiled in. The default
	echo // here is the source-of-truth. The set_plugin script rewrites this file.
	echo // Override one-off with -define:ACTIVE_PLUGIN=^<name^>.
	echo ACTIVE_PLUGIN :: #config^(ACTIVE_PLUGIN, "%~1"^)
)
echo Active plugin set to '%~1'
