#!/bin/sh
odin build src -debug -no-entry-point -extra-linker-flags:"-install_name @loader_path/Lindale" -build-mode:dynamic -out:out/Lindale.vst3/Contents/MacOS/Lindale.dylib
mv out/Lindale.vst3/Contents/MacOS/Lindale.dylib out/Lindale.vst3/Contents/MacOS/Lindale