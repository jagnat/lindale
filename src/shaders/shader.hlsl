cbuffer UniformBuffer : register(b0) {
	float4x4 orthoMat;
	float2 dims;
	uint singleChannelTexture;
}

Texture2D tex : register(t0);
SamplerState sampl : register(s0);

struct VSInput {
	float2 pos0 : TEXCOORD0;
	float2 pos1 : TEXCOORD1;
	float2 uv0 : TEXCOORD2;
	float2 uv1 : TEXCOORD3;
	float4 color : TEXCOORD4;
	float4 borderColor : TEXCOORD5;
	float4 params : TEXCOORD6; // (borderWidth, cornerRad, noTexture, padding)
	uint vertexId : SV_VertexID;
};

struct VSOutput {
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD0;
	float2 rectPos : TEXCOORD1;
	nointerpolation float2 halfRectSize: TEXCOORD2;
	nointerpolation float4 color : TEXCOORD3;
	nointerpolation float4 borderColor : TEXCOORD4;
	nointerpolation float4 params : TEXCOORD5;
};

float rounded_rect_sdf(float2 input, float2 halfRectSize, float cornerRad) {
	float rad = cornerRad;
	float2 q = abs(input) - halfRectSize + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

VSOutput VSMain(VSInput input) {
	VSOutput output;

	float2 posToPick = input.pos0;
	float2 uvToPick = input.uv0;
	float2 rectMult = float2(-1, -1);
	if (input.vertexId & 1) {
		posToPick.y = input.pos1.y;
		uvToPick.y = input.uv1.y;
		rectMult.y = 1;
	}
	if ((input.vertexId >> 1) & 1) {
		posToPick.x = input.pos1.x;
		uvToPick.x = input.uv1.x;
		rectMult.x = 1;
	}

	output.pos = mul(orthoMat, float4(posToPick, 0.0, 1.0));
	output.uv = uvToPick;
	output.halfRectSize = (input.pos1 - input.pos0) / 2.0;
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

	if (noTexture < 1.0) {
		float4 sampleColor = tex.Sample(sampl, input.uv);

		if (singleChannelTexture == 1) {
			outputColor = float4(input.color.rgb, input.color.a * sampleColor.r);
		} else {
			outputColor = input.color * sampleColor;
		}
	}

	float outerSdf = rounded_rect_sdf(input.rectPos, input.halfRectSize, cornerRad);

	if (borderWidth > 0.0) {
		float2 innerHalfSize = max(input.halfRectSize - borderWidth, 0.0);
		float innerCornerRad = max(cornerRad - borderWidth, 0.0);
		float innerSdf = rounded_rect_sdf(input.rectPos, innerHalfSize, innerCornerRad);

		float borderBlend = smoothstep(-0.5, 0.5, innerSdf);
		outputColor = lerp(outputColor, input.borderColor, borderBlend);
	}

	float mixFactor = smoothstep(-0.75, 0.75, outerSdf);
	outputColor.a *= 1.0 - mixFactor;

	return outputColor;
}
