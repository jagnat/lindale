#!/bin/sh
odin build src/hotloaded -define:HOT_DLL=true -debug -no-entry-point -build-mode:dynamic -out:out/hot/LindaleHot.dylib
codesign --force --sign - out/hot/LindaleHot.dylib
