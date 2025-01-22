
cbuffer UniformBuffer : register(b0, space1) {
	float4x4 projMat;
	float4 UColor : COLOR;
}

struct VSInput {
	[[vk::location(0)]]float2 pos1 : POSITION0;
	[[vk::location(1)]]float2 pos2 : POSITION1;
	[[vk::location(2)]]float4 color00 : COLOR0;
	[[vk::location(3)]]float4 color01 : COLOR1;
	[[vk::location(4)]]float4 color10 : COLOR2;
	[[vk::location(5)]]float4 color11 : COLOR3;
	[[vk::location(6)]]float4 cornerRads : CORNER;
	uint vertexId : SV_VertexID;
};

struct VSOutput {
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD0;
	nointerpolation float4 color00 : TEXCOORD1;
	nointerpolation float4 color01 : TEXCOORD2;
	nointerpolation float4 color10 : TEXCOORD3;
	nointerpolation float4 color11 : TEXCOORD4;
};

VSOutput VSMain(VSInput input) {
	VSOutput output;

	float2 posToPick = input.pos1;
	if (input.vertexId & 1)
	{
		posToPick.y = input.pos2.y;
	}
	if  ((input.vertexId >> 1) & 1) {
		posToPick.x = input.pos2.x;
	}
	output.pos = mul(projMat, float4(posToPick, 0.f, 1.f));

	// float4 colorAry[] = {input.Color00, input.Color01, input.Color10, input.Color11};
	output.color00 = input.color00;
	output.color01 = input.color01;
	output.color10 = input.color10;
	output.color11 = input.color11;

	output.uv = float2((input.vertexId >> 1) & 1,input.vertexId & 1);

	// float cornerRadAry[] = {input.cornerRads.x, input.cornerRads.z, input.cornerRads.y, input.cornerRads.w};

	return output;
}

float4 blerp(float4 c00, float4 c01, float4 c10, float4 c11, float2 uv) {
	return lerp(lerp(c00, c01, uv.y), lerp(c10, c11, uv.y), uv.x);
}

float4 PSMain(VSOutput input) : SV_TARGET {
	return blerp(input.color00, input.color01, input.color10, input.color11, input.uv);
}
