package platform_specific

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:strconv"
import "core:strings"

import gl "vendor:OpenGL"
import "vendor:x11/xlib"

import "../bridge"

// GLX isn't bound in vendor:x11
foreign import glx "system:GL"

GLXContext :: distinct rawptr
GLXFBConfig :: distinct rawptr

@(default_calling_convention="c")
foreign glx {
	glXChooseFBConfig :: proc(display: ^xlib.Display, screen: i32, attribs: [^]i32, count: ^i32) -> [^]GLXFBConfig ---
	glXGetVisualFromFBConfig :: proc(display: ^xlib.Display, config: GLXFBConfig) -> ^xlib.XVisualInfo ---
	glXMakeCurrent :: proc(display: ^xlib.Display, drawable: xlib.XID, ctx: GLXContext) -> b32 ---
	glXSwapBuffers :: proc(display: ^xlib.Display, drawable: xlib.XID) ---
	glXDestroyContext :: proc(display: ^xlib.Display, ctx: GLXContext) ---
	glXGetProcAddressARB :: proc(name: cstring) -> rawptr ---
}

GLXCreateContextAttribsARBProc :: #type proc "c" (display: ^xlib.Display, config: GLXFBConfig, share: GLXContext, direct: b32, attribs: [^]i32) -> GLXContext

GLX_DOUBLEBUFFER :: 5
GLX_RED_SIZE :: 8
GLX_GREEN_SIZE :: 9
GLX_BLUE_SIZE :: 10
GLX_X_VISUAL_TYPE :: 0x22
GLX_TRUE_COLOR :: 0x8002
GLX_DRAWABLE_TYPE :: 0x8010
GLX_RENDER_TYPE :: 0x8011
GLX_X_RENDERABLE :: 0x8012
GLX_WINDOW_BIT :: 0x1
GLX_RGBA_BIT :: 0x1
GLX_CONTEXT_MAJOR_VERSION_ARB :: 0x2091
GLX_CONTEXT_MINOR_VERSION_ARB :: 0x2092
GLX_CONTEXT_PROFILE_MASK_ARB :: 0x9126
GLX_CONTEXT_CORE_PROFILE_BIT_ARB :: 0x1

DOUBLE_CLICK_MS :: 400

shader_source := #load("shader.glsl", string)

// GL entry points are process-global and context-independent under GLX
@(private="file")
gl_loaded: bool

TextureSlot :: struct {
	texture: u32,
	width: u32,
	height: u32,
	format: bridge.PixelFormat,
	in_use: bool,
}

GLRenderer :: struct {
	display: ^xlib.Display, // own connection, never the host's
	window: xlib.Window, // our child window
	parent_window: xlib.Window, // DAW's parent window
	colormap: xlib.Colormap,
	gl_context: GLXContext,

	program: u32,
	vao: u32,

	instance_buffer: u32,
	instance_capacity: u32,

	uniform_buffer: u32,
	uniforms: bridge.UniformBuffer,

	textures: [bridge.MAX_TEXTURES]TextureSlot,

	// logical = points for UI, physical = actual pixels
	logical_width: i32,
	logical_height: i32,
	scale_factor: f32,
	physical_width: i32,
	physical_height: i32,

	white_texture: bridge.TextureHandle,

	mouse: ^bridge.MouseState,
	last_click_time: xlib.Time,
	last_click_button: bridge.MouseButton,
	on_repaint: proc "c" (rawptr),
	on_repaint_data: rawptr,
	ctx: runtime.Context,
}

// Renderer lifecycle

// X11 has no per-window DPI
// Xft.dpi is what toolkits read, unset means 96
@(private="file")
get_scale_factor :: proc(display: ^xlib.Display) -> f32 {
	resources := string(xlib.ResourceManagerString(display))
	for line in strings.split_lines_iterator(&resources) {
		if !strings.has_prefix(line, "Xft.dpi:") do continue
		dpi, ok := strconv.parse_f32(strings.trim_space(line[len("Xft.dpi:"):]))
		if ok && dpi > 0 do return dpi / 96.0
	}
	return 1
}

@(private="file")
set_proc_address :: proc(p: rawptr, name: cstring) {
	(^rawptr)(p)^ = glXGetProcAddressARB(name)
}

renderer_create :: proc(parent: rawptr, width, height: i32) -> bridge.Renderer {
	if parent == nil do return nil

	display := xlib.OpenDisplay(nil)
	if display == nil {
		log.error("Failed to open X display")
		return nil
	}

	renderer := new(GLRenderer)
	renderer.display = display
	renderer.parent_window = xlib.Window(uintptr(parent))
	renderer.ctx = context

	renderer.scale_factor = get_scale_factor(display)
	renderer.logical_width = width
	renderer.logical_height = height
	renderer.physical_width = i32(f32(width) * renderer.scale_factor)
	renderer.physical_height = i32(f32(height) * renderer.scale_factor)

	fb_attribs := []i32{
		GLX_X_RENDERABLE, 1,
		GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
		GLX_RENDER_TYPE, GLX_RGBA_BIT,
		GLX_X_VISUAL_TYPE, GLX_TRUE_COLOR,
		GLX_RED_SIZE, 8,
		GLX_GREEN_SIZE, 8,
		GLX_BLUE_SIZE, 8,
		GLX_DOUBLEBUFFER, 1,
		0,
	}
	config_count: i32
	configs := glXChooseFBConfig(display, xlib.DefaultScreen(display), raw_data(fb_attribs), &config_count)
	if configs == nil {
		log.error("No suitable GLX framebuffer config")
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}
	defer xlib.Free(configs)

	// Skip 32-bit ARGB visuals, a compositor would blend our antialiased edges with whatever is behind the window
	config: GLXFBConfig
	visual_info: ^xlib.XVisualInfo
	for i in 0..<config_count {
		vi := glXGetVisualFromFBConfig(display, configs[i])
		if vi == nil do continue
		if vi.depth == 24 {
			config = configs[i]
			visual_info = vi
			break
		}
		xlib.Free(vi)
	}
	if visual_info == nil {
		log.error("No 24-bit GLX visual")
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}
	defer xlib.Free(visual_info)

	renderer.colormap = xlib.CreateColormap(display, renderer.parent_window, visual_info.visual, .AllocNone)
	window_attribs := xlib.XSetWindowAttributes{
		colormap = renderer.colormap,
		border_pixel = 0,
		event_mask = {.ButtonPress, .ButtonRelease, .PointerMotion},
	}
	renderer.window = xlib.CreateWindow(
		display,
		renderer.parent_window,
		0, 0,
		u32(renderer.physical_width), u32(renderer.physical_height),
		0,
		visual_info.depth,
		.InputOutput,
		visual_info.visual,
		{.CWColormap, .CWBorderPixel, .CWEventMask},
		&window_attribs,
	)
	if renderer.window == 0 {
		log.error("Failed to create child window")
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}
	xlib.MapWindow(display, renderer.window)
	xlib.Flush(display)

	log.infof("Created child window: %x, parent: %x, size: %dx%d", renderer.window, renderer.parent_window, renderer.physical_width, renderer.physical_height)

	create_context_attribs := cast(GLXCreateContextAttribsARBProc)glXGetProcAddressARB("glXCreateContextAttribsARB")
	if create_context_attribs == nil {
		log.error("glXCreateContextAttribsARB unavailable")
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}
	context_attribs := []i32{
		GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
		GLX_CONTEXT_MINOR_VERSION_ARB, 3,
		GLX_CONTEXT_PROFILE_MASK_ARB, GLX_CONTEXT_CORE_PROFILE_BIT_ARB,
		0,
	}
	renderer.gl_context = create_context_attribs(display, config, nil, true, raw_data(context_attribs))
	if renderer.gl_context == nil {
		log.error("Failed to create GL 3.3 core context")
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	make_current(renderer)
	if !gl_loaded {
		gl.load_up_to(3, 3, set_proc_address)
		gl_loaded = true
	}

	if !create_pipeline(renderer) {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	white_pixel := []u8{255, 255, 255, 255}
	renderer.white_texture = create_texture_internal(renderer, 1, 1, .RGBA8)
	upload_texture_internal(renderer, renderer.white_texture, white_pixel)

	resize_internal(renderer, width, height, renderer.scale_factor)

	return bridge.Renderer(renderer)
}

renderer_destroy :: proc(r: bridge.Renderer) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return

	if renderer.gl_context != nil {
		make_current(renderer)

		for &slot in renderer.textures {
			if slot.in_use do gl.DeleteTextures(1, &slot.texture)
		}

		if renderer.uniform_buffer != 0 do gl.DeleteBuffers(1, &renderer.uniform_buffer)
		if renderer.instance_buffer != 0 do gl.DeleteBuffers(1, &renderer.instance_buffer)
		if renderer.vao != 0 do gl.DeleteVertexArrays(1, &renderer.vao)
		if renderer.program != 0 do gl.DeleteProgram(renderer.program)

		glXMakeCurrent(renderer.display, 0, nil)
		glXDestroyContext(renderer.display, renderer.gl_context)
	}

	if renderer.window != 0 do xlib.DestroyWindow(renderer.display, renderer.window)
	if renderer.colormap != 0 do xlib.FreeColormap(renderer.display, renderer.colormap)
	xlib.CloseDisplay(renderer.display)

	free(renderer)
}

@(private="file")
make_current :: proc(renderer: ^GLRenderer) {
	glXMakeCurrent(renderer.display, renderer.window, renderer.gl_context)
}

renderer_set_mouse_state :: proc(r: bridge.Renderer, mouse: ^bridge.MouseState) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return
	renderer.mouse = mouse
}

// Stored but not called yet, input is drained in renderer_begin_frame
renderer_set_repaint_callback :: proc(r: bridge.Renderer, callback: proc "c" (rawptr), data: rawptr) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return
	renderer.on_repaint = callback
	renderer.on_repaint_data = data
}

@(private="file")
get_mouse_pos :: #force_inline proc "contextless" (renderer: ^GLRenderer, x, y: i32) -> bridge.Vec2f {
	scale := renderer.scale_factor
	return {f32(x) / scale, f32(y) / scale}
}

@(private="file")
x_button_to_mouse :: proc "contextless" (button: xlib.MouseButton) -> (bridge.MouseButton, bool) {
	switch i32(button) {
	case 1: return .Left, true
	case 2: return .Middle, true
	case 3: return .Right, true
	}
	return {}, false
}

@(private="file")
process_events :: proc(renderer: ^GLRenderer) {
	for xlib.Pending(renderer.display) > 0 {
		event: xlib.XEvent
		xlib.NextEvent(renderer.display, &event)
		if renderer.mouse == nil do continue

		#partial switch event.type {
		case .MotionNotify:
			renderer.mouse.pos = get_mouse_pos(renderer, event.xmotion.x, event.xmotion.y)

		case .ButtonPress:
			ev := &event.xbutton
			renderer.mouse.pos = get_mouse_pos(renderer, ev.x, ev.y)
			switch i32(ev.button) {
			case 4: renderer.mouse.scroll_delta.y += 1
			case 5: renderer.mouse.scroll_delta.y -= 1
			case 6: renderer.mouse.scroll_delta.x -= 1
			case 7: renderer.mouse.scroll_delta.x += 1
			}
			button, ok := x_button_to_mouse(ev.button)
			if !ok do continue
			renderer.mouse.down += {button}
			renderer.mouse.pressed += {button}
			if button == renderer.last_click_button && ev.time - renderer.last_click_time < DOUBLE_CLICK_MS {
				renderer.mouse.double_clicked += {button}
				renderer.last_click_time = 0
			} else {
				renderer.last_click_button = button
				renderer.last_click_time = ev.time
			}

		case .ButtonRelease:
			ev := &event.xbutton
			button, ok := x_button_to_mouse(ev.button)
			if !ok do continue
			renderer.mouse.pos = get_mouse_pos(renderer, ev.x, ev.y)
			renderer.mouse.down -= {button}
			renderer.mouse.released += {button}
		}
	}
}

renderer_resize :: proc(r: bridge.Renderer, width, height: i32) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return

	physical_width := i32(f32(width) * renderer.scale_factor)
	physical_height := i32(f32(height) * renderer.scale_factor)
	xlib.ResizeWindow(renderer.display, renderer.window, u32(physical_width), u32(physical_height))
	xlib.Flush(renderer.display)

	resize_internal(renderer, width, height, renderer.scale_factor)
}

@(private="file")
resize_internal :: proc(renderer: ^GLRenderer, logical_width, logical_height: i32, scale_factor: f32) {
	renderer.logical_width = logical_width
	renderer.logical_height = logical_height
	renderer.scale_factor = scale_factor
	renderer.physical_width = i32(f32(logical_width) * scale_factor)
	renderer.physical_height = i32(f32(logical_height) * scale_factor)

	renderer.uniforms.proj_matrix = linalg.matrix_ortho3d_f32(0, f32(logical_width), f32(logical_height), 0, -1, 1)
	renderer.uniforms.dims = {f32(logical_width), f32(logical_height)}
}

renderer_get_size :: proc(r: bridge.Renderer) -> bridge.RendererSize {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return {}
	return bridge.RendererSize{
		logical_width = renderer.logical_width,
		logical_height = renderer.logical_height,
		scale_factor = renderer.scale_factor,
		physical_width = renderer.physical_width,
		physical_height = renderer.physical_height,
	}
}

// Texture management

renderer_create_texture :: proc(r: bridge.Renderer, width, height: u32, format: bridge.PixelFormat) -> bridge.TextureHandle {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return bridge.INVALID_TEXTURE
	make_current(renderer)
	return create_texture_internal(renderer, width, height, format)
}

@(private="file")
create_texture_internal :: proc(renderer: ^GLRenderer, width, height: u32, format: bridge.PixelFormat) -> bridge.TextureHandle {
	slot: u32 = 0
	for i in 1..<u32(bridge.MAX_TEXTURES) {
		if !renderer.textures[i].in_use {
			slot = i
			break
		}
	}
	if slot == 0 do return bridge.INVALID_TEXTURE

	internal_format: i32
	pixel_format: u32
	switch format {
	case .RGBA8:
		internal_format = gl.RGBA8
		pixel_format = gl.RGBA
	case .R8:
		internal_format = gl.R8
		pixel_format = gl.RED
	}

	texture: u32
	gl.GenTextures(1, &texture)
	gl.BindTexture(gl.TEXTURE_2D, texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, internal_format, i32(width), i32(height), 0, pixel_format, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)

	renderer.textures[slot] = TextureSlot{
		texture = texture,
		width = width,
		height = height,
		format = format,
		in_use = true,
	}

	return bridge.TextureHandle(slot)
}

renderer_destroy_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return
	if handle == bridge.INVALID_TEXTURE do return
	if u32(handle) >= bridge.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if slot.in_use {
		make_current(renderer)
		gl.DeleteTextures(1, &slot.texture)
		slot^ = {}
	}
}

renderer_upload_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle, pixels: []u8) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return
	make_current(renderer)
	upload_texture_internal(renderer, handle, pixels)
}

@(private="file")
upload_texture_internal :: proc(renderer: ^GLRenderer, handle: bridge.TextureHandle, pixels: []u8) {
	if handle == bridge.INVALID_TEXTURE do return
	if u32(handle) >= bridge.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if !slot.in_use || slot.texture == 0 do return

	pixel_format: u32 = slot.format == .RGBA8 ? gl.RGBA : gl.RED

	// R8 rows aren't 4-byte aligned
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.BindTexture(gl.TEXTURE_2D, slot.texture)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, i32(slot.width), i32(slot.height), pixel_format, gl.UNSIGNED_BYTE, raw_data(pixels))
}

renderer_get_white_texture :: proc(r: bridge.Renderer) -> bridge.TextureHandle {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return bridge.INVALID_TEXTURE
	return renderer.white_texture
}

// Frame rendering

renderer_begin_frame :: proc(r: bridge.Renderer) -> bool {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return false

	process_events(renderer)

	// Detect parent window resize, matching macOS pattern of auto-detecting in the render path
	parent_attribs: xlib.XWindowAttributes
	xlib.GetWindowAttributes(renderer.display, renderer.parent_window, &parent_attribs)
	parent_width := parent_attribs.width
	parent_height := parent_attribs.height
	if parent_width > 0 && parent_height > 0 {
		if parent_width != renderer.physical_width || parent_height != renderer.physical_height {
			xlib.ResizeWindow(renderer.display, renderer.window, u32(parent_width), u32(parent_height))
			xlib.Flush(renderer.display)

			scale_factor := renderer.scale_factor
			logical_width := i32(f32(parent_width) / scale_factor)
			logical_height := i32(f32(parent_height) / scale_factor)
			resize_internal(renderer, logical_width, logical_height, scale_factor)
		}
	}

	make_current(renderer)
	return true
}

renderer_end_frame :: proc(r: bridge.Renderer) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return

	glXSwapBuffers(renderer.display, renderer.window)
}

renderer_upload_instances :: proc(r: bridge.Renderer, instances: []bridge.DrawInstance) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return
	if len(instances) == 0 do return
	if u32(len(instances)) > renderer.instance_capacity {
		assert(false, "draw instance count exceeded MAX_INSTANCES")
		return
	}

	// Respecifying the whole store orphans last frame's buffer instead of stalling on it
	gl.BindBuffer(gl.ARRAY_BUFFER, renderer.instance_buffer)
	gl.BufferData(gl.ARRAY_BUFFER, len(instances) * size_of(bridge.DrawInstance), raw_data(instances), gl.STREAM_DRAW)
}

renderer_begin_pass :: proc(r: bridge.Renderer, clear_color: bridge.ColorF32) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return

	// physical pixels
	gl.Viewport(0, 0, renderer.physical_width, renderer.physical_height)

	// Scissor also clips the clear
	gl.Disable(gl.SCISSOR_TEST)
	gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.Enable(gl.SCISSOR_TEST)

	gl.UseProgram(renderer.program)
	gl.BindVertexArray(renderer.vao)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, renderer.uniform_buffer)

	gl.Enable(gl.BLEND)
}

renderer_end_pass :: proc(r: bridge.Renderer) {
	// Nothing needed for immediate context
}

renderer_draw :: proc(r: bridge.Renderer, cmd: bridge.DrawCommand) {
	renderer := cast(^GLRenderer)r
	if renderer == nil do return
	if cmd.instance_count == 0 do return

	if cmd.scissor.w > 0 && cmd.scissor.h > 0 {
		// GL scissor origin is bottom-left
		bottom := cmd.scissor.y + cmd.scissor.h
		gl.Scissor(cmd.scissor.x, renderer.physical_height - bottom, cmd.scissor.w, cmd.scissor.h)
	} else {
		gl.Scissor(0, 0, renderer.physical_width, renderer.physical_height)
	}

	switch cmd.blend {
	case .Normal:
		gl.BlendEquation(gl.FUNC_ADD)
		gl.BlendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	case .Additive:
		gl.BlendEquation(gl.FUNC_ADD)
		gl.BlendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE)
	case .Multiply:
		gl.BlendEquation(gl.FUNC_ADD)
		gl.BlendFuncSeparate(gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	case .Max:
		// Factors are ignored for MAX
		gl.BlendEquation(gl.MAX)
	}

	renderer.uniforms.single_channel_texture = cmd.single_channel_texture ? 1 : 0
	gl.BindBuffer(gl.UNIFORM_BUFFER, renderer.uniform_buffer)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(bridge.UniformBuffer), &renderer.uniforms)

	texture_handle := cmd.texture
	if texture_handle == bridge.INVALID_TEXTURE {
		texture_handle = renderer.white_texture
	}

	if u32(texture_handle) < bridge.MAX_TEXTURES {
		slot := &renderer.textures[texture_handle]
		if slot.in_use {
			gl.ActiveTexture(gl.TEXTURE0)
			gl.BindTexture(gl.TEXTURE_2D, slot.texture)
		}
	}

	// GL 3.3 has no base instance, so point the attributes at this batch instead
	gl.BindBuffer(gl.ARRAY_BUFFER, renderer.instance_buffer)
	point_instance_attribs(uintptr(cmd.instance_offset) * size_of(bridge.DrawInstance))

	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(cmd.instance_count))
}

// Pipeline creation

@(private="file")
InstanceAttribKind :: enum {
	Float,
	Normalized, // u8 -> 0..1
	Integer,
}

@(private="file")
InstanceAttrib :: struct {
	components: i32,
	type: u32,
	kind: InstanceAttribKind,
	offset: uintptr,
}

@(private="file")
instance_attribs := [?]InstanceAttrib{
	{2, gl.FLOAT, .Float, offset_of(bridge.DrawInstance, pos0)},
	{2, gl.FLOAT, .Float, offset_of(bridge.DrawInstance, pos1)},
	{2, gl.FLOAT, .Float, offset_of(bridge.DrawInstance, uv0)},
	{2, gl.FLOAT, .Float, offset_of(bridge.DrawInstance, uv1)},
	{4, gl.UNSIGNED_BYTE, .Normalized, offset_of(bridge.DrawInstance, color)},
	{4, gl.UNSIGNED_BYTE, .Normalized, offset_of(bridge.DrawInstance, border_color)},
	{2, gl.FLOAT, .Float, offset_of(bridge.DrawInstance, border_width)}, // border_width, shape_param
	{2, gl.FLOAT, .Float, offset_of(bridge.DrawInstance, extra0)}, // extra0, extra1
	{4, gl.UNSIGNED_BYTE, .Integer, offset_of(bridge.DrawInstance, mode)}, // mode, flags, 2 spare bytes
}

@(private="file")
point_instance_attribs :: proc(base_offset: uintptr) {
	stride := i32(size_of(bridge.DrawInstance))
	for attrib, i in instance_attribs {
		switch attrib.kind {
		case .Integer:
			gl.VertexAttribIPointer(u32(i), attrib.components, attrib.type, stride, base_offset + attrib.offset)
		case .Normalized:
			gl.VertexAttribPointer(u32(i), attrib.components, attrib.type, true, stride, base_offset + attrib.offset)
		case .Float:
			gl.VertexAttribPointer(u32(i), attrib.components, attrib.type, false, stride, base_offset + attrib.offset)
		}
	}
}

@(private="file")
compile_shader :: proc(stage: u32, define: string) -> (shader: u32, ok: bool) {
	sources := [2]cstring{fmt.ctprintf("#version 330 core\n#define %s 1\n", define), cstring(raw_data(shader_source))}
	lengths := [2]i32{-1, i32(len(shader_source))}

	shader = gl.CreateShader(stage)
	gl.ShaderSource(shader, 2, &sources[0], &lengths[0])
	gl.CompileShader(shader)

	status: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		info: [4096]u8
		info_len: i32
		gl.GetShaderInfoLog(shader, len(info), &info_len, &info[0])
		log.errorf("%s shader compile error: %s", define, string(info[:info_len]))
		gl.DeleteShader(shader)
		return 0, false
	}
	return shader, true
}

@(private="file")
create_pipeline :: proc(renderer: ^GLRenderer) -> bool {
	vs := compile_shader(gl.VERTEX_SHADER, "VERTEX") or_return
	defer gl.DeleteShader(vs)
	fs := compile_shader(gl.FRAGMENT_SHADER, "FRAGMENT") or_return
	defer gl.DeleteShader(fs)

	renderer.program = gl.CreateProgram()
	gl.AttachShader(renderer.program, vs)
	gl.AttachShader(renderer.program, fs)
	gl.LinkProgram(renderer.program)

	status: i32
	gl.GetProgramiv(renderer.program, gl.LINK_STATUS, &status)
	if status == 0 {
		info: [4096]u8
		info_len: i32
		gl.GetProgramInfoLog(renderer.program, len(info), &info_len, &info[0])
		log.errorf("Shader link error: %s", string(info[:info_len]))
		return false
	}

	gl.UniformBlockBinding(renderer.program, gl.GetUniformBlockIndex(renderer.program, "UniformBuffer"), 0)
	gl.UseProgram(renderer.program)
	gl.Uniform1i(gl.GetUniformLocation(renderer.program, "tex"), 0)

	gl.GenVertexArrays(1, &renderer.vao)
	gl.BindVertexArray(renderer.vao)

	gl.GenBuffers(1, &renderer.instance_buffer)
	gl.BindBuffer(gl.ARRAY_BUFFER, renderer.instance_buffer)
	renderer.instance_capacity = bridge.MAX_INSTANCES
	for _, i in instance_attribs {
		gl.EnableVertexAttribArray(u32(i))
		gl.VertexAttribDivisor(u32(i), 1)
	}
	point_instance_attribs(0)

	gl.GenBuffers(1, &renderer.uniform_buffer)
	gl.BindBuffer(gl.UNIFORM_BUFFER, renderer.uniform_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(bridge.UniformBuffer), nil, gl.DYNAMIC_DRAW)

	return true
}
