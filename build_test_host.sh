#!/bin/sh

# dxc -spirv -T vs_6_0 -E VSMain src/shaders/shader.hlsl -Fo src/shaders/vs.spv -DVERTEX
# dxc -spirv -T ps_6_0 -E PSMain src/shaders/shader.hlsl -Fo src/shaders/ps.spv
odin run src/test_host -debug -out:Lindale.exe