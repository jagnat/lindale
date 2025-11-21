package lindale

import "core:slice"

import sg "shared:sokol/gfx"

import plat "../platform_data"

SokolRenderState :: struct {
	passAction: sg.Pass_Action,
	pip: sg.Pipeline,
	bind: sg.Bindings,
}

rs_init :: proc(plug: ^Plugin) {
	desc: sg.Desc
	env := sg.Environment {}
	when ODIN_OS == .Windows {

	} else when ODIN_OS == .Darwin {
		desc.environment = sg.Environment {
			defaults = sg.Environment_Defaults {
				sample_count = 1, // no multisample
				color_format = .BGRA8,
				depth_format = .NONE,
			},
			metal = sg.Metal_Environment {
				device = plug.platformData.graphicsDevice
			}
		}
	} else when ODIN_OS == .Linux {
		#assert(false, "Linux support not done yet")
	}
	sg.setup(desc)

	vertices: []f32 = {
		// positions         colors
		-0.5,  0.5, 0.5,     1.0, 0.0, 0.0, 1.0,
		 0.5,  0.5, 0.5,     0.0, 1.0, 0.0, 1.0,
		 0.5, -0.5, 0.5,     0.0, 0.0, 1.0, 1.0,
		-0.5, -0.5, 0.5,     1.0, 1.0, 0.0, 1.0,
	}
	bd := sg.Buffer_Desc{data = sg.Range{&vertices[0], uint(slice.size(vertices))}}
	plug.sokolRender.bind.vertex_buffers[0] = sg.make_buffer(bd)

// 	Shader_Desc :: struct {
//     _ : u32,
//     vertex_func : Shader_Function,
//     fragment_func : Shader_Function,
//     compute_func : Shader_Function,
//     attrs : [16]Shader_Vertex_Attr,
//     uniform_blocks : [8]Shader_Uniform_Block,
//     views : [32]Shader_View,
//     samplers : [12]Shader_Sampler,
//     texture_sampler_pairs : [32]Shader_Texture_Sampler_Pair,
//     mtl_threads_per_threadgroup : Mtl_Shader_Threads_Per_Threadgroup,
//     label : cstring,
//     _ : u32,
// }

	sd := sg.Shader_Desc {
		vertex_func = sg.Shader_Function {
			source = 
			`#include <metal_stdlib>
			using namespace metal;
			struct vs_in {
			  float4 position [[attribute(0)]];
			  float4 color [[attribute(1)]];
			};
			struct vs_out {
			  float4 position [[position]];
			  float4 color [[user(usr0)]];
			};
			vertex vs_out _main(vs_in in [[stage_in]]) {
			  vs_out out;
			  out.position = in.position;
			  out.color = in.color;
			  return out;
			}`
		},
		fragment_func = sg.Shader_Function {
			source = 
			`#include <metal_stdlib>
			#include <simd/simd.h>
			using namespace metal;
			struct fs_in {
			  float4 color [[user(usr0)]];
			};
			fragment float4 _main(fs_in in [[stage_in]]) {
			  return in.color;
			};`
		}
	}
	shd := sg.make_shader(sd)
	attrs: [16]sg.Vertex_Attr_State = {}
	attrs[0] = sg.Vertex_Attr_State {
		offset = 0,
		format = .FLOAT3,
	}
	attrs[1] = sg.Vertex_Attr_State {
		offset = 12,
		format = .FLOAT4
	}

	pd := sg.Pipeline_Desc {
		shader = shd,
		layout = sg.Vertex_Layout_State {
			attrs = attrs
		}
	}
	plug.sokolRender.pip = sg.make_pipeline(pd)
}

rs_frame :: proc(plug: ^Plugin) {
	ms : sg.Metal_Swapchain
	ds : sg.D3d11_Swapchain
	gs : sg.Gl_Swapchain
	when ODIN_OS == .Darwin {
		ms.current_drawable = plug.platformData.swapchain.swapchainArg0
		ms.depth_stencil_texture = plug.platformData.swapchain.swapchainArg1
		ms.msaa_color_texture = plug.platformData.swapchain.swapchainArg2
	}
	pass := sg.Pass {
		action = plug.sokolRender.passAction,
		swapchain = sg.Swapchain {
			width = i32(plug.platformData.width),
			height = i32(plug.platformData.height),
			sample_count = 1,
			color_format = .BGRA8,
			depth_format = .NONE,
			metal = ms,
			d3d11 = ds,
			gl = gs,
		},
	}
	sg.begin_pass(pass)
	sg.apply_pipeline(plug.sokolRender.pip)
	sg.apply_bindings(plug.sokolRender.bind)
	sg.draw(0, 3, 1)
	sg.end_pass()
	sg.commit()
}

// static void frame(void) {
//     sg_begin_pass(&(sg_pass){ .action = state.pass_action, .swapchain = osx_swapchain() });
//     sg_apply_pipeline(state.pip);
//     sg_apply_bindings(&state.bind);
//     sg_draw(0, 3, 1);
//     sg_end_pass();
//     sg_commit();
// }

// sg_swapchain osx_swapchain(void) {
//     return (sg_swapchain) {
//         .width = (int) [mtk_view drawableSize].width,
//         .height = (int) [mtk_view drawableSize].height,
//         .sample_count = sample_count,
//         .color_format = SG_PIXELFORMAT_BGRA8,
//         .depth_format = depth_format,
//         .metal = {
//             .current_drawable = (__bridge const void*) [mtk_view currentDrawable],
//             .depth_stencil_texture = (__bridge const void*) [mtk_view depthStencilTexture],
//             .msaa_color_texture = (__bridge const void*) [mtk_view multisampleColorTexture],
//         }
//     };
// }