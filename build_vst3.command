#!/bin/sh
odin build src/hotloaded -define:HOT_DLL=true -debug -no-entry-point -build-mode:dynamic -out:out/hot/LindaleHot.dylib
codesign --force --sign - out/hot/LindaleHot.dylib

odin build src -debug -no-entry-point -extra-linker-flags:"-install_name @loader_path/Lindale" -build-mode:dynamic -out:out/Lindale.vst3/Contents/MacOS/Lindale.dylib
mv out/Lindale.vst3/Contents/MacOS/Lindale.dylib out/Lindale.vst3/Contents/MacOS/Lindale
codesign --deep --force --sign - out/Lindale.vst3/
