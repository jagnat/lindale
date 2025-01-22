
cbuffer UniformBuffer : register(b0, space1) {
	float4x4 projMat;
	float4 UColor : COLOR;
}

struct VSInput {
	[[vk::location(0)]]float2 Pos1 : POSITION0;
	[[vk::location(1)]]float2 Pos2 : POSITION1;
	[[vk::location(2)]]float4 Color : COLOR;
	uint vertexId : SV_VertexID;
};

struct VSOutput {
	float4 Position : SV_POSITION;
	float4 Color : COLOR;
};

VSOutput VSMain(VSInput input) {
	VSOutput output;
	output.Color = UColor;
	float2 posToPick = input.Pos1;
	if (input.vertexId & 1)
	{
		posToPick.y = input.Pos2.y;
	}
	if  ((input.vertexId >> 1) & 1) {
		posToPick.x = input.Pos2.x;
	}
	output.Position = mul(projMat, float4(posToPick, 0.f, 1.f));
	return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
	return input.Color;
}