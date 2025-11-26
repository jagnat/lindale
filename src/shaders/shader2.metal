
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct VSInput {
	float2 pos0 [[attribute(0)]];
	float2 pos1 [[attribute(1)]];
	float2 uv0 [[attribute(2)]];
	float2 uv1 [[attribute(3)]];
	float4 color [[attribute(4)]];
	float4 borderColor [[attribute(5)]];
	float4 params [[attribute(6)]]; // (borderWidth, cornerRad, noTexture, padding)
};

struct VSOutput {
	float4 position [[position]];
	float4 color [[user(usr0)]];
};

vertex VSOutput vs_shader(VSInput input [[stage_in]], uint vertexId [[vertex_id]]) {
	VSOutput out;

	float2 posToPick = input.pos0;
	float2 uvToPick = input.uv0;
	float2 rectMult = float2(-1, -1);
	if (vertexId & 1) {
		posToPick.y = input.pos1.y;
		uvToPick.y = input.uv1.y;
		rectMult.y = 1;
	}
	if ((vertexId >> 1) & 1) {
		posToPick.x = input.pos1.x;
		uvToPick.x = input.uv1.x;
		rectMult.x = 1;
	}

	out.position = float4(posToPick, 0, 1);
	out.color = input.color;
	return out;
}

fragment float4 ps_shader(VSOutput in [[stage_in]]) {
  return in.color;
}
