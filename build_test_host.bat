dxc -spirv -T vs_6_0 -E VSMain -fspv-target-env=vulkan1.1 src/shaders/shader.hlsl -Fo src/shaders/vs.spv -DVERTEX
dxc -spirv -T ps_6_0 -E PSMain -fspv-target-env=vulkan1.1 src/shaders/shader.hlsl -Fo src/shaders/ps.spv
odin run src/test_host -debug -out:Lindale.exe
