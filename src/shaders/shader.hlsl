struct VSInput
{
	[[vk::location(0)]]float3 Position : POSITION;
	[[vk::location(1)]]float4 Color : COLOR;
};

struct VSOutput
{
	float4 Position : SV_POSITION;
	float4 Color : COLOR;
};

VSOutput VSMain(VSInput input)
{
	VSOutput output;
	output.Color = input.Color;
	output.Position = float4(input.Position, 1.f);
	return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
	return input.Color;
}