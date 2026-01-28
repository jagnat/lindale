dxc -spirv -T vs_6_0 -E VSMain -fspv-target-env=vulkan1.1 src/shaders/shader.hlsl -Fo src/shaders/vs.spv -DVERTEX
dxc -spirv -T ps_6_0 -E PSMain -fspv-target-env=vulkan1.1 src/shaders/shader.hlsl -Fo src/shaders/ps.spv
odin build src/lindale -define:HOT_DLL=true -debug -build-mode:dynamic -out:out/hot/LindaleHot.dll
