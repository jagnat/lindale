cbuffer UniformBuffer : register(b0) {
	float4x4 orthoMat;
	float2 dims;
	uint singleChannelTexture;
}

// Matches bridge.DrawFlag
static const uint DRAW_FLAG_TEXTURED = 1u;

Texture2D tex : register(t0);
SamplerState sampl : register(s0);

struct VSInput {
	float2 pos0 : TEXCOORD0;
	float2 pos1 : TEXCOORD1;
	float2 uv0 : TEXCOORD2;
	float2 uv1 : TEXCOORD3;
	float4 color : TEXCOORD4;
	float4 borderColor : TEXCOORD5;
	float2 params : TEXCOORD6; // (borderWidth, shapeParam)
	float2 extras : TEXCOORD7; // (extra0, extra1)
	uint4 modeFlags : TEXCOORD8; // (mode, flags, spare, spare)
	uint vertexId : SV_VertexID;
};

struct VSOutput {
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD0;
	float2 rectPos : TEXCOORD1;
	nointerpolation float2 halfRectSize : TEXCOORD2;
	nointerpolation float4 color : TEXCOORD3;
	nointerpolation float4 borderColor : TEXCOORD4;
	nointerpolation float2 params : TEXCOORD5;
	nointerpolation uint2 modeFlags : TEXCOORD6;
	float2 worldPos : TEXCOORD7;
	nointerpolation float2 instanceUv0 : TEXCOORD8;
	nointerpolation float2 instanceUv1 : TEXCOORD9;
	nointerpolation float2 extras : TEXCOORD10;
};

float rounded_rect_sdf(float2 input, float2 halfRectSize, float cornerRad) {
	float rad = cornerRad;
	float2 q = abs(input) - halfRectSize + rad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

float edge_coverage(float sdf, float px) {
	return saturate(0.5 - sdf / px);
}

float4 premultiply(float4 c) {
	return float4(c.rgb * c.a, c.a);
}

// Interleaved gradient noise under 1 LSB, breaks up 8-bit banding
float4 dither(float4 c, float2 fragCoord) {
	float n = frac(52.9829189 * frac(dot(fragCoord, float2(0.06711056, 0.00583715))));
	c.rgb += (n - 0.5) / 255.0;
	return c;
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
	output.modeFlags = input.modeFlags.xy;
	output.worldPos = posToPick;
	output.instanceUv0 = input.uv0;
	output.instanceUv1 = input.uv1;
	output.extras = input.extras;

	return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
	// SDF units per physical pixel, must precede branches
	float px = length(fwidth(input.worldPos)) / sqrt(2.0);
	uint mode = input.modeFlags.x;
	uint flags = input.modeFlags.y;
	float borderWidth = input.params.x;
	float shapeParam = input.params.y;
	float4 fillColor = premultiply(input.color);
	float4 borderColor = premultiply(input.borderColor);

	if (mode == 1u) {
		// Pill (capsule) SDF
		float2 p0 = input.instanceUv0;
		float2 p1 = input.instanceUv1;
		float2 pa = input.worldPos - p0;
		float2 ba = p1 - p0;
		float baLen2 = max(dot(ba, ba), 1e-6);
		float h = saturate(dot(pa, ba) / baLen2);
		float d = length(pa - ba * h);
		float outerSdf = d - shapeParam * 0.5;

		float4 outputColor = fillColor;
		if (borderWidth > 0.0) {
			float innerSdf = d - max(shapeParam * 0.5 - borderWidth, 0.0);
			float borderBlend = 1.0 - edge_coverage(innerSdf, px);
			outputColor = lerp(outputColor, borderColor, borderBlend);
		}
		outputColor *= edge_coverage(outerSdf, px);
		return dither(outputColor, input.pos.xy);
	}

	if (mode == 2u) {
		// Arc SDF (Inigo Quilez arc formula)
		float2 center = input.instanceUv0;
		float startAngle = input.instanceUv1.x;
		float endAngle = input.instanceUv1.y;
		float radius = input.extras.x;

		float2 p = input.worldPos - center;
		float midAngle = (startAngle + endAngle) * 0.5;
		float halfSpan = (endAngle - startAngle) * 0.5;

		// Rotate so midAngle direction maps to IQ +Y. With Y-down screen space
		// this gives 0 = East, increasing CW.
		float cosM = sin(midAngle);
		float sinM = cos(midAngle);
		float2 pr = float2(p.x * cosM - p.y * sinM, p.x * sinM + p.y * cosM);
		pr.x = abs(pr.x);

		float2 sc = float2(sin(halfSpan), cos(halfSpan));
		float d;
		if (sc.y * pr.x > sc.x * pr.y) {
			d = length(pr - sc * radius);
		} else {
			d = abs(length(p) - radius);
		}
		float outerSdf = d - shapeParam * 0.5;

		float4 outputColor = fillColor;
		if (borderWidth > 0.0) {
			float innerSdf = d - max(shapeParam * 0.5 - borderWidth, 0.0);
			float borderBlend = 1.0 - edge_coverage(innerSdf, px);
			outputColor = lerp(outputColor, borderColor, borderBlend);
		}
		outputColor *= edge_coverage(outerSdf, px);
		return dither(outputColor, input.pos.xy);
	}

	// mode == 0: Rect SDF
	float4 outputColor = fillColor;
	float cornerRad = shapeParam;

	if ((flags & DRAW_FLAG_TEXTURED) != 0u) {
		float4 sampleColor = tex.Sample(sampl, input.uv);

		if (singleChannelTexture == 1) {
			outputColor = fillColor * sampleColor.r;
		} else {
			outputColor = fillColor * sampleColor;
		}
	}

	float outerSdf = rounded_rect_sdf(input.rectPos, input.halfRectSize, cornerRad);

	if (borderWidth > 0.0) {
		float2 innerHalfSize = max(input.halfRectSize - borderWidth, 0.0);
		float innerCornerRad = max(cornerRad - borderWidth, 0.0);
		float innerSdf = rounded_rect_sdf(input.rectPos, innerHalfSize, innerCornerRad);

		float borderBlend = 1.0 - edge_coverage(innerSdf, px);
		outputColor = lerp(outputColor, borderColor, borderBlend);
	}

	outputColor *= edge_coverage(outerSdf, px);

	return dither(outputColor, input.pos.xy);
}
