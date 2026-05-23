#!/bin/sh

# Resolve the plugin to build: first arg, else the default in src/bridge/plugin_id.odin.
PLUGIN="${1:-$(awk -F\" '/^ACTIVE_PLUGIN ::/ {print $2; exit}' src/bridge/plugin_id.odin)}"
if [ -z "$PLUGIN" ]; then
	echo "No plugin specified. Pass one as an argument or set it with set_plugin.command" >&2
	exit 1
fi

mkdir -p out/hot

# Build hotloaded dll
odin build src/lindale -define:HOT_DLL=true -define:ACTIVE_PLUGIN=$PLUGIN -debug -no-entry-point -build-mode:dynamic -out:out/hot/${PLUGIN}Hot.dylib
codesign --force --sign - out/hot/${PLUGIN}Hot.dylib
