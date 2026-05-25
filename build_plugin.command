#!/bin/sh

# Resolve the plugin to build: first arg, else the default in src/bridge/plugin_id.odin.
PLUGIN="${1:-$(awk -F\" '/^ACTIVE_PLUGIN ::/ {print $2; exit}' src/bridge/plugin_id.odin)}"
if [ -z "$PLUGIN" ]; then
	echo "No plugin specified. Pass one as an argument or set it with set_plugin.command" >&2
	exit 1
fi

BUNDLE="out/$PLUGIN.vst3"
mkdir -p out/hot "$BUNDLE/Contents/MacOS"

# Build hotloaded dll
odin build src/lindale -define:HOT_DLL=true -define:ACTIVE_PLUGIN=$PLUGIN -debug -o:speed -no-entry-point -build-mode:dynamic -out:out/hot/${PLUGIN}Hot.dylib
codesign --force --sign - out/hot/${PLUGIN}Hot.dylib

# Build plugin dll
odin build src/vst_host -define:HOT_DLL=true -define:ACTIVE_PLUGIN=$PLUGIN -debug -o:speed -no-entry-point -extra-linker-flags:"-install_name @loader_path/$PLUGIN" -build-mode:dynamic -out:"$BUNDLE/Contents/MacOS/$PLUGIN.dylib"
mv "$BUNDLE/Contents/MacOS/$PLUGIN.dylib" "$BUNDLE/Contents/MacOS/$PLUGIN"

mkdir -p "$BUNDLE/Contents/MacOS/$PLUGIN.dSYM/Contents/Resources/DWARF"
cp "$BUNDLE/Contents/MacOS/$PLUGIN.dylib.dSYM/Contents/Resources/DWARF/$PLUGIN.dylib" "$BUNDLE/Contents/MacOS/$PLUGIN.dSYM/Contents/Resources/DWARF/$PLUGIN"
rm -rf "$BUNDLE/Contents/MacOS/$PLUGIN.dylib.dSYM"

# Generate the bundle Info.plist
cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>$PLUGIN</string>
	<key>CFBundleGetInfoString</key>
	<string>$PLUGIN 0.0.0</string>
	<key>CFBundleIdentifier</key>
	<string>quest.jagi.$PLUGIN.vst3</string>
	<key>CFBundleName</key>
	<string>$PLUGIN</string>
	<key>CFBundleVersion</key>
	<string>0.0.0</string>
</dict>
</plist>
EOF

# Strip Finder metadata a previous build's SetFile left behind — codesign
# refuses to sign a bundle carrying a com.apple.FinderInfo xattr.
xattr -cr "$BUNDLE"
codesign --deep --force --sign - "$BUNDLE/"

# Bundle bit so Finder shows the .vst3 as a package, not a plain folder.
SetFile -a B "$BUNDLE"

# Install symlinks into the system folders. -sfn replaces a stale or dangling
# link in place, so switching plugins or relocating out/ self-heals on rebuild
VST3_LINK="$HOME/Library/Audio/Plug-Ins/VST3/$PLUGIN.vst3"
ln -sfn "$(pwd)/$BUNDLE" "$VST3_LINK"
echo "Linked $VST3_LINK"

RUNTIME_DIR="$HOME/Library/Application Support/jagi/$PLUGIN"
mkdir -p "$RUNTIME_DIR"
ln -sfn "$(pwd)/out/hot" "$RUNTIME_DIR/hot"
echo "Linked $RUNTIME_DIR/hot"
