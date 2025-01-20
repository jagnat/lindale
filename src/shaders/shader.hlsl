
cbuffer UniformBuffer : register(b0, space1) {
	float4x4 projMat;
	float4 UColor : COLOR;
}

struct VSInput {
	[[vk::location(0)]]float3 Position : POSITION;
	[[vk::location(1)]]float4 Color : COLOR;
};

struct VSOutput {
	float4 Position : SV_POSITION;
	float4 Color : COLOR;
};

VSOutput VSMain(VSInput input) {
	VSOutput output;
	output.Color = UColor;
	output.Position = mul(projMat, float4(input.Position, 1.f));
	return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
	return input.Color;
}