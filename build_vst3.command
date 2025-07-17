#!/bin/sh

# Build hotloaded dll
odin build src/lindale -define:HOT_DLL=true -debug -no-entry-point -build-mode:dynamic -out:out/hot/LindaleHot.dylib
codesign --force --sign - out/hot/LindaleHot.dylib

# Build plugin dll
odin build src -define:HOT_DLL=true -debug -no-entry-point -extra-linker-flags:"-install_name @loader_path/Lindale" -build-mode:dynamic -out:out/Lindale.vst3/Contents/MacOS/Lindale.dylib
mv out/Lindale.vst3/Contents/MacOS/Lindale.dylib out/Lindale.vst3/Contents/MacOS/Lindale

mkdir -p out/Lindale.vst3/Contents/MacOS/Lindale.dSYM/Contents/Resources/DWARF
cp out/Lindale.vst3/Contents/MacOS/Lindale.dylib.dSYM/Contents/Resources/DWARF/Lindale.dylib out/Lindale.vst3/Contents/MacOS/Lindale.dSYM/Contents/Resources/DWARF/Lindale
rm -rf out/Lindale.vst3/Contents/MacOS/Lindale.dylib.dSYM

codesign --deep --force --sign - out/Lindale.vst3/
