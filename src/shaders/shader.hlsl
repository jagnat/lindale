
#ifdef VERTEX
#define UNIFORM_SPACE space1
#else
#define UNIFORM_SPACE space3
#endif

cbuffer UniformBuffer : register(b0, UNIFORM_SPACE) {
	float4x4 orthoMat;
	float2 dims;
	uint singleChannelTexture;
}

Texture2D tex : register(t0, space2);
SamplerState sampl : register(s0, space2);

#ifdef VULKAN
    #define LOCATION(n) [[vk::location(n)]]
#else
    #define LOCATION(n)
#endif

struct VSInput {
	LOCATION(0) float2 pos0 : TEXCOORD0;
	LOCATION(1) float2 pos1 : TEXCOORD1;
	LOCATION(2) float2 uv0 : TEXCOORD2;
	LOCATION(3) float2 uv1 : TEXCOORD3;
	LOCATION(4) float4 color : TEXCOORD4;
	LOCATION(5) float4 borderColor : TEXCOORD5;
	LOCATION(6) float4 params : TEXCOORD6; // (borderWidth, cornerRad, noTexture, padding)
	uint vertexId : SV_VertexID; // TL, BL, TR, BR
};

struct VSOutput {
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD0;
	float2 rectPos : RECTPOS;
	nointerpolation float2 halfRectSize: RECTSZ;
	nointerpolation float4 color : COLOR;
	nointerpolation float4 borderColor : BORDERCOLOR;
	nointerpolation float4 params : PARAMS;
};

float4 blerp(float4 c00, float4 c01, float4 c10, float4 c11, float2 uv) {
	return lerp(lerp(c00, c01, uv.y), lerp(c10, c11, uv.y), uv.x);
}

float rounded_rect_sdf(float2 input, float2 halfRectSize, float cornerRad)
{
	// float2 radSide = input.x > 0? cornerRad.zw : cornerRad.xy;
	// float rad = input.y > 0? radSide.y : radSide.x;
	float rad = cornerRad;
	float2 q = abs(input) - halfRectSize + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

float circle_sdf(float2 input, float rad) {
	return length(input) - rad;
}

VSOutput VSMain(VSInput input) {
	VSOutput output;

	// Determine position of this vertex from vertex id
	float2 posToPick = input.pos0;
	float2 uvToPick = input.uv0;
	float2 rectMult = float2(-1, -1);
	if (input.vertexId & 1)
	{
		posToPick.y = input.pos1.y;
		uvToPick.y = input.uv1.y;
		rectMult.y = 1;
	}
	if  ((input.vertexId >> 1) & 1) {
		posToPick.x = input.pos1.x;
		uvToPick.x = input.uv1.x;
		rectMult.x = 1;
	}

	output.pos = mul(orthoMat, float4(posToPick, 0.f, 1.f));
	output.uv = uvToPick;
	output.halfRectSize = (input.pos1 - input.pos0) / 2;
	output.rectPos = rectMult * output.halfRectSize;
	output.color = input.color;
	output.borderColor = input.borderColor;
	output.params = input.params;

	return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
	float4 outputColor = input.color;
	float borderWidth = input.params.x;
	float cornerRad = input.params.y;
	float noTexture = input.params.z;
	float4 sampleColor = float4(1, 1, 1, 1);
	if (noTexture < 1) {
		sampleColor = tex.Sample(sampl, input.uv);

		if (singleChannelTexture == 1) {
			outputColor = float4(input.color.rgb, input.color.a * sampleColor.r);
		} else {
			outputColor = input.color * sampleColor;
		}
	}
	// float sampleAlpha = dot(sampleColor, samplerAlphaChannel);
	// outputColor *= float4(sampleColor.rgb * (1.0 - abs(samplerAlphaChannel.r)) + samplerFillChannels.rgb, sampleAlpha);

	// SDF corners
	float outerSdf = rounded_rect_sdf(input.rectPos, input.halfRectSize, cornerRad);

	if (borderWidth > 0.0f) {
		float2 innerHalfSize = max(input.halfRectSize - borderWidth, 0.0f);
		float innerCornerRad = max(cornerRad - borderWidth, 0.0f);
		float innerSdf = rounded_rect_sdf(input.rectPos, innerHalfSize, innerCornerRad);

		float borderBlend = smoothstep(-0.5, 0.5, innerSdf);
		outputColor = lerp(outputColor, input.borderColor, borderBlend);
	}

	float mixFactor = smoothstep(-0.75f, 0.75f, outerSdf);
	outputColor.a *= 1.0f - mixFactor;

	return outputColor;
}