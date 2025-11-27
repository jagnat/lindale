package lindale

import "base:runtime"
import "core:slice"
import "core:fmt"
import "core:math/linalg"

import sg "shared:sokol/gfx"

import plat "../platform_data"

SokolRenderState :: struct {
	passAction: sg.Pass_Action,
	pip: sg.Pipeline,
	bind: sg.Bindings,

	initialized: bool,
	ctx: runtime.Context
}

VertexUniforms :: struct {
	projMatrix: linalg.Matrix4x4f32
}

PixelUniforms :: struct {

}

rs_sokol_log_proc :: proc "c" (
		tag: cstring,
		log_level: u32,
		log_item: u32,
		message: cstring,
		line_nr: u32,
		filename:cstring,
		userData: rawptr) {
	plug: ^Plugin = cast(^Plugin)userData
	context = plug.sokolRender.ctx
	fmt.printfln("[SOKOL] tag: %s log_level: %d log_item: %d msg: %s line_no: %d filename: %s",
		tag, log_level, log_item, message, line_nr, filename)
}

@(private)
range_from_slice :: proc "contextless" (a: $T/[]$E) -> sg.Range {
		return sg.Range {&a[0], uint(slice.size(a)) }
}

rs_init :: proc(plug: ^Plugin) {
	if plug.sokolRender.initialized do return

	plug.sokolRender.ctx = context

	desc: sg.Desc
	desc.logger = sg.Logger{
		func = rs_sokol_log_proc,
		user_data = rawptr(plug),
	}
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

	vertices: []RectInstance = {
		RectInstance{pos0 = {10, 10}, pos1 = {200, 200}, uv0 = {0, 0}, uv1 = {1, 1}, color = {255, 255, 255, 255}, borderColor = {220, 200, 200, 255}, borderWidth = 3, cornerRad = 10,},
		RectInstance{pos0 = {600, 600}, pos1 = {700, 700}, color = {100, 255, 0, 255}, cornerRad = 20,},
	}
	bd := sg.Buffer_Desc{data = sg.Range{&vertices[0], uint(slice.size(vertices))}}
	plug.sokolRender.bind.vertex_buffers[0] = sg.make_buffer(bd)

	pixels := []u32 {
		0xFFFFFFFF, 0xFF00AA00, 0xFFFFFFFF, 0xFF00AA00,
		0xFF00AA00, 0xFFFFFFFF, 0xFF00AA00, 0xFFFFFFFF,
		0xFFFFFFFF, 0xFF00AA00, 0xFFFFFFFF, 0xFF00AA00,
		0xFF00AA00, 0xFFFFFFFF, 0xFF00AA00, 0xFFFFFFFF,
	}
	img_desc := sg.Image_Desc {
		width = 4,
		height = 4,
	}
	img_desc.data.mip_levels[0] = range_from_slice(pixels)

	plug.sokolRender.bind.views[0] = sg.make_view(sg.View_Desc {
		texture = sg.Texture_View_Desc {
			image = sg.make_image(img_desc)
		}
	})

	plug.sokolRender.bind.samplers[0] = sg.make_sampler(sg.Sampler_Desc {
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
	})

	shaderBits : cstring = #load("../shaders/shader2.metal")

	sd := sg.Shader_Desc {
		vertex_func = sg.Shader_Function {
			source = shaderBits,
			entry = "vs_shader",
		},
		fragment_func = sg.Shader_Function {
			source = shaderBits,
			entry = "ps_shader"
		},
	}
	sd.uniform_blocks[0] = sg.Shader_Uniform_Block {
		stage = .VERTEX,
		size = size_of(VertexUniforms),
	}
	sd.views[0].texture = sg.Shader_Texture_View {
		stage = .FRAGMENT,
		hlsl_register_t_n = 0,
		msl_texture_n = 0,
	}
	sd.samplers[0] = sg.Shader_Sampler {
		stage = .FRAGMENT,
		hlsl_register_s_n = 0,
		msl_sampler_n = 0,
	}
	sd.texture_sampler_pairs[0] = sg.Shader_Texture_Sampler_Pair {
		stage = .FRAGMENT,
		view_slot = 0,
		sampler_slot = 0,
	}
	shd := sg.make_shader(sd)
	attrs: [16]sg.Vertex_Attr_State = {}
	attrs[0] = sg.Vertex_Attr_State {offset = 0 * size_of(f32), format = .FLOAT2}
	attrs[1] = sg.Vertex_Attr_State {offset = 2 * size_of(f32), format = .FLOAT2}
	attrs[2] = sg.Vertex_Attr_State {offset = 4 * size_of(f32), format = .FLOAT2}
	attrs[3] = sg.Vertex_Attr_State {offset = 6 * size_of(f32), format = .FLOAT2}
	attrs[4] = sg.Vertex_Attr_State {offset = 8 * size_of(f32), format = .UBYTE4N}
	attrs[5] = sg.Vertex_Attr_State {offset = 9 * size_of(f32), format = .UBYTE4N}
	attrs[6] = sg.Vertex_Attr_State {offset = 10 * size_of(f32), format = .FLOAT4}

	pd := sg.Pipeline_Desc {
		shader = shd,
		layout = sg.Vertex_Layout_State {
			attrs = attrs
		},
		primitive_type = .TRIANGLE_STRIP,
	}
	pd.layout.buffers[0] = sg.Vertex_Buffer_Layout_State{
		step_func = .PER_INSTANCE
	}
	pd.colors[0] = sg.Color_Target_State {
		blend = sg.Blend_State {
			enabled = true,
			src_factor_rgb = .SRC_ALPHA,
			dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
			op_rgb = .ADD,
			src_factor_alpha = .ONE,
			dst_factor_alpha = .ZERO,
			op_alpha = .ADD,
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
	plug.sokolRender.passAction.colors[0] = sg.Color_Attachment_Action{
		load_action = .CLEAR,
		store_action = .DEFAULT,
		clear_value = sg.Color{0.141, 0.137, 0.106, 1}
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
	uniforms := VertexUniforms {
		projMatrix = linalg.matrix_ortho3d_f32(0, f32(plug.platformData.width), f32(plug.platformData.height), 0, -1, 1)
	}
	sg.begin_pass(pass)
	sg.apply_pipeline(plug.sokolRender.pip)
	sg.apply_bindings(plug.sokolRender.bind)
	sg.apply_uniforms(0, sg.Range{&uniforms, size_of(uniforms)})
	sg.draw(0, 4, 2)
	sg.end_pass()
	sg.commit()
}
