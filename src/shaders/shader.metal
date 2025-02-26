#include <metal_stdlib>
using namespace metal;

struct UniformBuffer {
    float4x4 orthoMat;
    float2 dims;
};

struct VSInput {
    float2 pos1 [[attribute(0)]];
    float2 pos2 [[attribute(1)]];
    float4 color00 [[attribute(2)]];
    float4 color01 [[attribute(3)]];
    float4 color10 [[attribute(4)]];
    float4 color11 [[attribute(5)]];
    float4 cornerRads [[attribute(6)]];
};

struct VSOutput {
    float4 pos [[position]];
    float2 uv;
    float2 rectPos;
    float2 halfRectSize [[flat]];
    float4 color00 [[flat]];
    float4 color01 [[flat]];
    float4 color10 [[flat]];
    float4 color11 [[flat]];
    float4 cornerRads [[flat]];
};

float4 blerp(float4 c00, float4 c01, float4 c10, float4 c11, float2 uv) {
    return mix(mix(c00, c01, uv.y), mix(c10, c11, uv.y), uv.x);
}

float rounded_rect_sdf(float2 input, float2 halfRectSize, float4 cornerRad) {
    float2 radSide = input.x > 0 ? cornerRad.zw : cornerRad.xy;
    float rad = input.y > 0 ? radSide.y : radSide.x;
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

    float2 posToPick = input.pos1;
    float2 rectMult = float2(-1, -1);
    if (vertexId & 1) {
        posToPick.y = input.pos2.y;
        rectMult.y = 1;
    }
    if ((vertexId >> 1) & 1) {
        posToPick.x = input.pos2.x;
        rectMult.x = 1;
    }

    output.pos = uniformBuffer.orthoMat * float4(posToPick, 0.0, 1.0);
    output.uv = float2((vertexId >> 1) & 1, vertexId & 1);
    output.halfRectSize = (input.pos2 - input.pos1) / 2.0;
    output.rectPos = rectMult * output.halfRectSize;
    output.color00 = input.color00;
    output.color01 = input.color01;
    output.color10 = input.color10;
    output.color11 = input.color11;
    output.cornerRads = input.cornerRads;

    return output;
}

fragment float4 PSMain(VSOutput input [[stage_in]], texture2d<float> tex [[texture(0)]], sampler sampl [[sampler(0)]]) {
    // texture sample
    float4 outputColor = tex.sample(sampl, input.uv);

    // interpolated vertex color
    outputColor *= blerp(input.color00, input.color01, input.color10, input.color11, input.uv);

    // SDF corners
    float sdf = rounded_rect_sdf(input.rectPos, input.halfRectSize, input.cornerRads);
    float mixFactor = smoothstep(-0.75, 0.75, sdf);
    outputColor.a *= 1.0 - mixFactor;

    return outputColor;
}
