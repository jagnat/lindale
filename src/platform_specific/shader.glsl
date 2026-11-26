// GLSL port of shader.hlsl
// The renderer prepends #version and a VERTEX or FRAGMENT define

layout(std140) uniform UniformBuffer {
	mat4 orthoMat;
	vec2 dims;
	uint singleChannelTexture;
};

uniform sampler2D tex;

#ifdef VERTEX
#define VARYING out
#else
#define VARYING in
#endif

VARYING vec2 uv;
VARYING vec2 rectPos;
flat VARYING vec2 halfRectSize;
flat VARYING vec4 color;
flat VARYING vec4 borderColor;
flat VARYING vec3 params; // (borderWidth, shapeParam, noTexture)
flat VARYING uint mode;
VARYING vec2 worldPos;
flat VARYING vec2 instanceUv0;
flat VARYING vec2 instanceUv1;
flat VARYING vec2 extras; // (extra0, extra1)

#ifdef VERTEX

layout(location = 0) in vec2 inPos0;
layout(location = 1) in vec2 inPos1;
layout(location = 2) in vec2 inUv0;
layout(location = 3) in vec2 inUv1;
layout(location = 4) in vec4 inColor;
layout(location = 5) in vec4 inBorderColor;
layout(location = 6) in vec3 inParams;
layout(location = 7) in uint inMode;
layout(location = 8) in vec2 inExtras;

void main() {
	vec2 posToPick = inPos0;
	vec2 uvToPick = inUv0;
	vec2 rectMult = vec2(-1.0, -1.0);
	if ((gl_VertexID & 1) != 0) {
		posToPick.y = inPos1.y;
		uvToPick.y = inUv1.y;
		rectMult.y = 1.0;
	}
	if (((gl_VertexID >> 1) & 1) != 0) {
		posToPick.x = inPos1.x;
		uvToPick.x = inUv1.x;
		rectMult.x = 1.0;
	}

	gl_Position = orthoMat * vec4(posToPick, 0.0, 1.0);
	uv = uvToPick;
	halfRectSize = (inPos1 - inPos0) / 2.0;
	rectPos = rectMult * halfRectSize;
	color = inColor;
	borderColor = inBorderColor;
	params = inParams;
	mode = inMode;
	worldPos = posToPick;
	instanceUv0 = inUv0;
	instanceUv1 = inUv1;
	extras = inExtras;
}

#else

layout(location = 0) out vec4 fragColor;

float rounded_rect_sdf(vec2 p, vec2 halfSize, float cornerRad) {
	vec2 q = abs(p) - halfSize + cornerRad;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - cornerRad;
}

float edge_coverage(float sdf, float px) {
	return clamp(0.5 - sdf / px, 0.0, 1.0);
}

void main() {
	// SDF units per physical pixel, must precede branches
	float px = length(fwidth(worldPos)) / sqrt(2.0);
	float borderWidth = params.x;
	float shapeParam = params.y;
	float noTexture = params.z;

	if (mode == 1u) {
		// Pill (capsule) SDF
		vec2 p0 = instanceUv0;
		vec2 p1 = instanceUv1;
		vec2 pa = worldPos - p0;
		vec2 ba = p1 - p0;
		float baLen2 = max(dot(ba, ba), 1e-6);
		float h = clamp(dot(pa, ba) / baLen2, 0.0, 1.0);
		float d = length(pa - ba * h);
		float outerSdf = d - shapeParam * 0.5;

		vec4 outputColor = color;
		if (borderWidth > 0.0) {
			float innerSdf = d - max(shapeParam * 0.5 - borderWidth, 0.0);
			float borderBlend = 1.0 - edge_coverage(innerSdf, px);
			outputColor = mix(outputColor, borderColor, borderBlend);
		}
		outputColor.a *= edge_coverage(outerSdf, px);
		fragColor = outputColor;
		return;
	}

	if (mode == 2u) {
		// Arc SDF (Inigo Quilez arc formula)
		vec2 center = instanceUv0;
		float startAngle = instanceUv1.x;
		float endAngle = instanceUv1.y;
		float radius = extras.x;

		vec2 p = worldPos - center;
		float midAngle = (startAngle + endAngle) * 0.5;
		float halfSpan = (endAngle - startAngle) * 0.5;

		// Rotate so midAngle direction maps to IQ +Y. With Y-down screen space
		// this gives 0 = East, increasing CW.
		float cosM = sin(midAngle);
		float sinM = cos(midAngle);
		vec2 pr = vec2(p.x * cosM - p.y * sinM, p.x * sinM + p.y * cosM);
		pr.x = abs(pr.x);

		vec2 sc = vec2(sin(halfSpan), cos(halfSpan));
		float d;
		if (sc.y * pr.x > sc.x * pr.y) {
			d = length(pr - sc * radius);
		} else {
			d = abs(length(p) - radius);
		}
		float outerSdf = d - shapeParam * 0.5;

		vec4 outputColor = color;
		if (borderWidth > 0.0) {
			float innerSdf = d - max(shapeParam * 0.5 - borderWidth, 0.0);
			float borderBlend = 1.0 - edge_coverage(innerSdf, px);
			outputColor = mix(outputColor, borderColor, borderBlend);
		}
		outputColor.a *= edge_coverage(outerSdf, px);
		fragColor = outputColor;
		return;
	}

	// mode == 0: Rect SDF
	vec4 outputColor = color;
	float cornerRad = shapeParam;

	if (noTexture < 1.0) {
		vec4 sampleColor = texture(tex, uv);

		if (singleChannelTexture == 1u) {
			outputColor = vec4(color.rgb, color.a * sampleColor.r);
		} else {
			outputColor = color * sampleColor;
		}
	}

	float outerSdf = rounded_rect_sdf(rectPos, halfRectSize, cornerRad);

	if (borderWidth > 0.0) {
		vec2 innerHalfSize = max(halfRectSize - borderWidth, 0.0);
		float innerCornerRad = max(cornerRad - borderWidth, 0.0);
		float innerSdf = rounded_rect_sdf(rectPos, innerHalfSize, innerCornerRad);

		float borderBlend = 1.0 - edge_coverage(innerSdf, px);
		outputColor = mix(outputColor, borderColor, borderBlend);
	}

	outputColor.a *= edge_coverage(outerSdf, px);

	fragColor = outputColor;
}

#endif
