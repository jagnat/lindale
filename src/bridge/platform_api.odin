package bridge

import "core:math/linalg"
import "core:mem"

BUILD_ID :: #config(BUILD_ID, "a8e15a84")

// Common types shared between platform layer and lindale
Vec2f :: linalg.Vector2f32
Vec4f :: linalg.Vector4f32
Mat4f :: linalg.Matrix4x4f32

RectI32 :: struct {
	x, y, w, h: i32,
}

RectF32 :: struct {
	x, y, w, h: f32,
}

ColorU8 :: struct {
	r, g, b, a: u8,
}

ColorF32 :: [4]f32

KeyModifierSet :: bit_set[KeyModifiers]
KeyModifiers :: enum {
	Shift,
	Ctrl,
	Alt,
}

MouseButton :: enum { Left, Right, Middle }

MouseState :: struct {
	pos: Vec2f,
	down: bit_set[MouseButton],
	pressed: bit_set[MouseButton],
	released: bit_set[MouseButton],
	double_clicked: bit_set[MouseButton],
	scroll_delta: Vec2f,
	modifiers: KeyModifierSet,
}

ShaderMode :: enum u32 {
	Rect = 0,
	Pill = 1,
	Arc  = 2,
}

// Instance data for SDF draw primitives.
// pos0/pos1 are always the AABB for the vertex shader quad.
// uv0/uv1 and extras are reinterpreted per mode.
// Must match vertex shader input format.
DrawInstance :: struct #packed {
	pos0: [2]f32, // AABB top-left
	pos1: [2]f32, // AABB bottom-right
	uv0: [2]f32, // Rect: tex UV0. Pill: p0. Arc: center.
	uv1: [2]f32, // Rect: tex UV1. Pill: p1. Arc: {startAngle, endAngle} rads.
	color: ColorU8,
	border_color: ColorU8,
	border_width: f32,
	shape_param: f32, // Rect: corner_rad. Pill/Arc: thickness.
	no_texture: f32,
	mode: ShaderMode,
	extra0: f32, // Arc: radius.
	extra1: f32,
}
#assert(size_of(DrawInstance) == 64)

// Uniform data passed to shader
UniformBuffer :: struct {
	proj_matrix: Mat4f,
	dims: Vec2f,
	single_channel_texture: u32,
	_pad: u32,
}

// Opaque handle to a GPU texture
TextureHandle :: distinct u32
INVALID_TEXTURE :: TextureHandle(0)

// Texture format for creation
PixelFormat :: enum {
	RGBA8,       // 4 bytes per pixel
	R8,          // 1 byte per pixel (fonts, masks)
}

// Draw command for a batch of instances
DrawCommand :: struct {
	instance_offset: u32,  // Offset into instance buffer
	instance_count: u32,   // Number of instances to draw
	texture: TextureHandle,
	single_channel_texture: bool,
	scissor: RectI32,     // {0,0,0,0} means no scissor
}

// Maximum instances per frame (256MB / 64 bytes)
MAX_INSTANCES :: 256 * 1024 * 1024 / size_of(DrawInstance)
MAX_TEXTURES :: 64

// Renderer handle - platform specific implementation
Renderer :: distinct rawptr

// Renderer size info - logical coordinates for UI, physical for actual rendering
RendererSize :: struct {
	logical_width: i32,   // Width in points (use this for UI layout)
	logical_height: i32,  // Height in points (use this for UI layout)
	scale_factor: f32,    // DPI scale (1.0 = standard, 2.0 = retina)
	physical_width: i32,  // Actual drawable pixels
	physical_height: i32, // Actual drawable pixels
}

// Host-provided resources passed to the hot-loaded plugin.
// Allocated and owned by the static VST layer, survives hot-reloads.
HostContext :: struct {
	params: ^ParamValues,
	platform: ^PlatformApi,
	host_api: ^HostApi,
	renderer: Renderer,
	font_atlas: TextureHandle,

	persistent_allocator: mem.Allocator,
	session_allocator: mem.Allocator,
	frame_allocator: mem.Allocator,
	generation: u64,
}

// Platform vtable
PlatformApi :: struct {
	create_texture:    proc(r: Renderer, width, height: u32, format: PixelFormat) -> TextureHandle,
	destroy_texture:   proc(r: Renderer, handle: TextureHandle),
	upload_texture:    proc(r: Renderer, handle: TextureHandle, pixels: []u8),
	get_white_texture: proc(r: Renderer) -> TextureHandle,
	get_size:          proc(r: Renderer) -> RendererSize,
	begin_frame:       proc(r: Renderer) -> bool,
	end_frame:         proc(r: Renderer),
	upload_instances:  proc(r: Renderer, instances: []DrawInstance),
	begin_pass:        proc(r: Renderer, clear_color: ColorF32),
	end_pass:          proc(r: Renderer),
	draw:              proc(r: Renderer, cmd: DrawCommand),
}
