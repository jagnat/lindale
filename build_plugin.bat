dxc -T vs_6_0 -E VSMain src/shaders/shader.hlsl -Fo src/shaders/vs.dxil -DVERTEX
dxc -T ps_6_0 -E PSMain src/shaders/shader.hlsl -Fo src/shaders/ps.dxil

odin build src/lindale -define:HOT_DLL=true -debug -build-mode:dynamic -out:out/hot/LindaleHot.dll
odin build src -define:HOT_DLL=true -debug -build-mode:dynamic -out:out\Lindale.vst3\Contents\x86_64-win\Lindale.vst3
