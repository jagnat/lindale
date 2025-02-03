
cbuffer UniformBuffer : register(b0, space1) {
	float4x4 projMat;
	float2 dims;
}

struct VSInput {
	[[vk::location(0)]]float2 pos1 : POSITION0;
	[[vk::location(1)]]float2 pos2 : POSITION1;
	[[vk::location(2)]]float4 color00 : COLOR0;
	[[vk::location(3)]]float4 color01 : COLOR1;
	[[vk::location(4)]]float4 color10 : COLOR2;
	[[vk::location(5)]]float4 color11 : COLOR3;
	[[vk::location(6)]]float4 cornerRads : CORNER;
	uint vertexId : SV_VertexID; // TL, BL, TR, BR
};

struct VSOutput {
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD0;
	float2 rectPos : RECTPOS;
	nointerpolation float2 halfRectSize: RECTSZ;
	nointerpolation float4 color00 : TEXCOORD1;
	nointerpolation float4 color01 : TEXCOORD2;
	nointerpolation float4 color10 : TEXCOORD3;
	nointerpolation float4 color11 : TEXCOORD4;
	nointerpolation float4 cornerRads : CORNER;
};

float4 blerp(float4 c00, float4 c01, float4 c10, float4 c11, float2 uv) {
	return lerp(lerp(c00, c01, uv.y), lerp(c10, c11, uv.y), uv.x);
}

float rounded_rect_sdf(float2 input, float2 halfRectSize, float4 cornerRad)
{
	float2 radSide = input.x > 0? cornerRad.zw : cornerRad.xy;
	float rad = input.y > 0? radSide.y : radSide.x;
	float2 q = abs(input) - halfRectSize + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

float circle_sdf(float2 input, float rad) {
	return length(input) - rad;
}

VSOutput VSMain(VSInput input) {
	VSOutput output;

	float2 posToPick = input.pos1;
	float2 rectMult = float2(-1, -1);
	if (input.vertexId & 1)
	{
		posToPick.y = input.pos2.y;
		rectMult.y = 1;
	}
	if  ((input.vertexId >> 1) & 1) {
		posToPick.x = input.pos2.x;
		rectMult.x = 1;
	}

	output.pos = mul(projMat, float4(posToPick, 0.f, 1.f));
	output.uv = float2((input.vertexId >> 1) & 1,input.vertexId & 1);
	output.halfRectSize = (input.pos2 - input.pos1) / 2;
	output.rectPos = rectMult * output.halfRectSize;
	output.color00 = input.color00;
	output.color01 = input.color01;
	output.color10 = input.color10;
	output.color11 = input.color11;
	output.cornerRads = input.cornerRads;

	return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
	float4 outputColor = blerp(input.color00, input.color01, input.color10, input.color11, input.uv);
	float sdf = rounded_rect_sdf(input.rectPos, input.halfRectSize, input.cornerRads);
	float mixFactor = smoothstep(-0.5, 0.5, sdf);

	outputColor.a *= 1 - mixFactor;
	return outputColor;
}