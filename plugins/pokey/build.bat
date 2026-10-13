@echo off
setlocal
cd /d "%~dp0"

if not exist lindale_collection.txt echo ./lindale> lindale_collection.txt
set /p LINDALE=<lindale_collection.txt

odin run . -collection:lindale="%LINDALE%/src" -- %*

