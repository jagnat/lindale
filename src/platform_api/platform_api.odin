package platform_api

import "core:math/linalg"

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

// Instance data for SDF rounded rectangles.
// Must match vertex shader input format
// Total size: 56 bytes
RectInstance :: struct #packed {
	pos0: [2]f32,         // Top left corner
	pos1: [2]f32,         // Bottom right corner
	uv0: [2]f32,          // Top left UV
	uv1: [2]f32,          // Bottom right UV
	color: ColorU8,       // Fill color
	borderColor: ColorU8, // Border color
	borderWidth: f32,     // Border thickness in pixels
	cornerRad: f32,       // Corner radius in pixels
	noTexture: f32,       // 1.0 = solid color, 0.0 = use texture
	_pad: f32,            // Padding to align to 56 bytes
}
#assert(size_of(RectInstance) == 56)

// Uniform data passed to shader
UniformBuffer :: struct {
	projMatrix: Mat4f,
	dims: Vec2f,
	singleChannelTexture: u32,
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
	instanceOffset: u32,  // Offset into instance buffer
	instanceCount: u32,   // Number of instances to draw
	texture: TextureHandle,
	singleChannelTexture: bool,
	scissor: RectI32,     // {0,0,0,0} means no scissor
}

// Maximum instances per frame (1MB / 56 bytes)
MAX_INSTANCES :: 1024 * 1024 / size_of(RectInstance)
MAX_TEXTURES :: 64

// Renderer handle - platform specific implementation
Renderer :: distinct rawptr

// Renderer size info - logical coordinates for UI, physical for actual rendering
RendererSize :: struct {
	logicalWidth: i32,   // Width in points (use this for UI layout)
	logicalHeight: i32,  // Height in points (use this for UI layout)
	scaleFactor: f32,    // DPI scale (1.0 = standard, 2.0 = retina)
	physicalWidth: i32,  // Actual drawable pixels
	physicalHeight: i32, // Actual drawable pixels
}

// Platform vtable for hot-loaded code
PlatformApi :: struct {
	create_texture:    proc(r: Renderer, width, height: u32, format: PixelFormat) -> TextureHandle,
	destroy_texture:   proc(r: Renderer, handle: TextureHandle),
	upload_texture:    proc(r: Renderer, handle: TextureHandle, pixels: []u8),
	get_white_texture: proc(r: Renderer) -> TextureHandle,
	get_size:          proc(r: Renderer) -> RendererSize,
	begin_frame:       proc(r: Renderer) -> bool,
	end_frame:         proc(r: Renderer),
	upload_instances:  proc(r: Renderer, instances: []RectInstance),
	begin_pass:        proc(r: Renderer, clearColor: ColorF32),
	end_pass:          proc(r: Renderer),
	draw:              proc(r: Renderer, cmd: DrawCommand),
}
