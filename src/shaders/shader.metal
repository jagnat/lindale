#include <metal_stdlib>
using namespace metal;

struct UniformBuffer {
	float4x4 orthoMat;
	float4 samplerAlphaChannel;
	float4 samplerFillChannels;
	float2 dims;
};

struct VSInput {
	float2 pos0 [[attribute(0)]];
	float2 pos1 [[attribute(1)]];
	float2 uv0 [[attribute(2)]];
	float2 uv1 [[attribute(3)]];
	float4 color [[attribute(4)]];
	float3 params [[attribute(5)]]; // (cornerRad, noTexture, padding)
};

struct VSOutput {
	float4 pos [[position]];
	float2 uv;
	float2 rectPos;
	float2 halfRectSize [[flat]];
	float4 color [[flat]];
	float3 params [[flat]];
};

float4 blerp(float4 c00, float4 c01, float4 c10, float4 c11, float2 uv) {
	return mix(mix(c00, c01, uv.y), mix(c10, c11, uv.y), uv.x);
}

float rounded_rect_sdf(float2 input, float2 halfRectSize, float cornerRad) {
	float rad = cornerRad;
	float2 q = abs(input) - halfRectSize + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

float circle_sdf(float2 input, float rad) {
	return length(input) - rad;
}

vertex VSOutput VSMain(VSInput input [[stage_in]],
	constant UniformBuffer &uniformBuffer [[buffer(0)]],
	uint vertexId [[vertex_id]]) {
	VSOutput output;

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

	output.pos = uniformBuffer.orthoMat * float4(posToPick, 0.0, 1.0);
	output.uv = uvToPick;
	output.halfRectSize = (input.pos1 - input.pos0) / 2.0;
	output.rectPos = rectMult * output.halfRectSize;
	output.color = input.color;
	output.params = input.params;

	return output;
}

fragment float4 PSMain(VSOutput input [[stage_in]], constant UniformBuffer &uniformBuffer [[buffer(0)]], texture2d<float> tex [[texture(0)]], sampler sampl [[sampler(0)]]) {
	float4 outputColor = input.color;
	float4 sampleColor = tex.sample(sampl, input.uv);
	float sampleAlpha = dot(sampleColor, uniformBuffer.samplerAlphaChannel);
	outputColor *= float4(sampleColor.rgb * (1.0 - abs(uniformBuffer.samplerAlphaChannel.r)) + uniformBuffer.samplerFillChannels.rgb, sampleAlpha);

	// SDF corners
	float sdf = rounded_rect_sdf(input.rectPos, input.halfRectSize, input.params.x);
	float mixFactor = smoothstep(-0.75, 0.75, sdf);
	outputColor.a *= 1.0 - mixFactor;

	return outputColor;
}
