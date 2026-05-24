#!/bin/sh
# Type-check every plugin branch in src/lindale/plugin_def.odin without
# producing artifacts. Exits non-zero if any plugin fails to compile.

cd "$(dirname "$0")"

PLUGINS=$(awk -F\" '/b\.ACTIVE_PLUGIN == / {print $2}' src/lindale/plugin_def.odin)
if [ -z "$PLUGINS" ]; then
	echo "No plugins found in src/lindale/plugin_def.odin" >&2
	exit 1
fi

FAILED=""
for PLUGIN in $PLUGINS; do
	printf '== %s ==\n' "$PLUGIN"
	if odin check src/lindale -no-entry-point -define:HOT_DLL=true -define:ACTIVE_PLUGIN=$PLUGIN; then
		printf '   OK\n'
	else
		FAILED="$FAILED $PLUGIN"
	fi
done

echo
if [ -n "$FAILED" ]; then
	echo "FAILED:$FAILED"
	exit 1
fi
echo "All plugins compile."
