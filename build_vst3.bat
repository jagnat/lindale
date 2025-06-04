dxc -spirv -T vs_6_0 -E VSMain -fspv-target-env=vulkan1.1 src/shaders/shader.hlsl -Fo src/shaders/vs.spv -DVERTEX
dxc -spirv -T ps_6_0 -E PSMain -fspv-target-env=vulkan1.1 src/shaders/shader.hlsl -Fo src/shaders/ps.spv

odin build src/lindale -define:HOT_DLL=true -debug -no-entry-point -build-mode:dynamic -out:out/hot/LindaleHot.dll
odin build src -define:HOT_DLL=true -debug -no-entry-point -build-mode:dynamic -out:out\Lindale.vst3\Contents\x86_64-win\Lindale.vst3
