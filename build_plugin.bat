odin build src/lindale -define:HOT_DLL=true -debug -build-mode:dynamic -out:out/hot/LindaleHot.dll
odin build src/vst_host -define:HOT_DLL=true -debug -build-mode:dynamic -out:out\Lindale.vst3\Contents\x86_64-win\Lindale.vst3
