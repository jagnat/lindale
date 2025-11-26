
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct vs_in {
	float4 position [[attribute(0)]];
	float4 color [[attribute(1)]];
};
struct vs_out {
	float4 position [[position]];
	float4 color [[user(usr0)]];
};
vertex vs_out vs_shader(vs_in in [[stage_in]]) {
	vs_out out;
	out.position = in.position;
	out.color = in.color;
	return out;
}

struct fs_in {
  float4 color [[user(usr0)]];
};

fragment float4 ps_shader(fs_in in [[stage_in]]) {
  return in.color;
}
