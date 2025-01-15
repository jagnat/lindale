dxc -spirv -T vs_6_0 -E VSMain -fspv-target-env=vulkan1.1 shader.hlsl -Fo vs.spv
dxc -spirv -T ps_6_0 -E PSMain -fspv-target-env=vulkan1.1 shader.hlsl -Fo ps.spv