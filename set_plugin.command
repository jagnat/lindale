#!/bin/sh

# Sets the active build target by rewriting src/bridge/plugin_id.odin, which
# is the source-of-truth read by both the build scripts and the LSP.
if [ -z "$1" ]; then
	echo "Usage: set_plugin.command <plugin>" >&2
	exit 1
fi

cat > src/bridge/plugin_id.odin <<EOF
package bridge

// Selects which plugin's vtable + state types are compiled in. The default
// here is the source-of-truth. The set_plugin script rewrites this file.
// Override one-off with -define:ACTIVE_PLUGIN=<name>.
ACTIVE_PLUGIN :: #config(ACTIVE_PLUGIN, "$1")
EOF
echo "Active plugin set to '$1'"
