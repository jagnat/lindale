package platform_specific

import "base:runtime"
import "core:log"
import "core:math/linalg"

import F "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

import "base:intrinsics"

import "../bridge"

foreign import ObjCRuntime "system:objc"

ObjCSuper :: struct {
	receiver:    ^intrinsics.objc_object,
	super_class: ^intrinsics.objc_class,
}

foreign ObjCRuntime {
	objc_msgSendSuper2 :: proc "c" (super: rawptr, op: ^intrinsics.objc_selector, #c_vararg args: ..any) -> ^intrinsics.objc_object ---
}

// Minimal binding for NSTrackingArea (not in Odin's vendor libs)
@(objc_class="NSTrackingArea")
NSTrackingArea :: struct { using _: intrinsics.objc_object }

shader_source := #load("../shaders/shader.metal")

TextureSlot :: struct {
	texture: ^MTL.Texture,
	width: u32,
	height: u32,
	format: bridge.PixelFormat,
	in_use: bool,
}

// Metal renderer state - coupled with the view
MetalRenderer :: struct {
	view: ^LindaleMetalView,
	layer: ^CA.MetalLayer,
	device: ^MTL.Device,
	command_queue: ^MTL.CommandQueue,
	pipeline: ^MTL.RenderPipelineState,

	// One large buffer for all instances
	instance_buffer: ^MTL.Buffer,
	instance_capacity: u32,

	uniform_buffer: ^MTL.Buffer,
	uniforms: bridge.UniformBuffer,

	textures: [bridge.MAX_TEXTURES]TextureSlot,
	next_texture_slot: u32,
	sampler: ^MTL.SamplerState,

	// Current frame state
	command_buffer: ^MTL.CommandBuffer,
	render_encoder: ^MTL.RenderCommandEncoder,
	current_drawable: ^CA.MetalDrawable,

	// logical = points for UI, physical = actual pixels
	logical_width: i32,
	logical_height: i32,
	scale_factor: f32,
	physical_width: i32,
	physical_height: i32,

	// For solid color rendering
	white_texture: bridge.TextureHandle,
}

// Obj-C class names are a process-global namespace. Suffix with random ID
// when registering the class, a duplicate registration crashes the host
METAL_VIEW_CLASS :: "LindaleMetalView_" + string(bridge.BUILD_ID)

// NSView subclass with CAMetalLayer
@(objc_implement,
	objc_class            = METAL_VIEW_CLASS,
	objc_superclass       = F.View,
	objc_ivar             = LindaleMetalViewVar,
	objc_context_provider = lindale_metal_view_get_context,
)
LindaleMetalView :: struct {
	using _: F.View,
}

LindaleMetalViewVar :: struct {
	ctx: runtime.Context,
	mouse: ^bridge.MouseState,
	on_repaint: proc "c" (rawptr),
	on_repaint_data: rawptr,
}

lindale_metal_view_get_context :: proc "c" (self: ^LindaleMetalViewVar) -> runtime.Context {
	return self.ctx
}

@(objc_type=LindaleMetalView, objc_name="initWithFrameAndContext")
lindale_metal_view_init_with_frame_and_context :: proc "c" (self: ^LindaleMetalView, frame: F.Rect, ctx: runtime.Context) -> ^LindaleMetalView {
	intrinsics.objc_send(nil, self, "initWithFrame:", frame)
	self.ctx = ctx
	self.mouse = nil
	self.on_repaint = nil
	self.on_repaint_data = nil
	return self
}

@(objc_type=LindaleMetalView, objc_implement)
LindaleMetalView_acceptsFirstResponder :: proc (self: ^LindaleMetalView) -> F.BOOL {
	return true
}

@(objc_type=LindaleMetalView, objc_implement)
LindaleMetalView_wantsUpdateLayer :: proc (self: ^LindaleMetalView) -> F.BOOL {
	return true
}

@(objc_type=LindaleMetalView, objc_implement)
LindaleMetalView_isFlipped :: proc (self: ^LindaleMetalView) -> F.BOOL {
	return true
}

@(private)
view_get_mouse_pos :: proc(view: ^LindaleMetalView, event: ^F.Event) -> bridge.Vec2f {
	if event == nil do return view.mouse != nil ? view.mouse.pos : {}
	loc := intrinsics.objc_send(F.Point, event, "locationInWindow")
	pt := intrinsics.objc_send(F.Point, view, "convertPoint:fromView:", loc, rawptr(nil))
	return {f32(pt.x), f32(pt.y)}
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="mouseDown:")
LindaleMetalView_mouseDown :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	self.mouse.pos = view_get_mouse_pos(self, event)
	self.mouse.down += {.Left}
	self.mouse.pressed += {.Left}
	if event->clickCount() >= 2 do self.mouse.double_clicked += {.Left}
	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="mouseUp:")
LindaleMetalView_mouseUp :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	self.mouse.pos = view_get_mouse_pos(self, event)
	self.mouse.down -= {.Left}
	self.mouse.released += {.Left}
	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="mouseDragged:")
LindaleMetalView_mouseDragged :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	self.mouse.pos = view_get_mouse_pos(self, event)
	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="mouseMoved:")
LindaleMetalView_mouseMoved :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	self.mouse.pos = view_get_mouse_pos(self, event)
	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="rightMouseDown:")
LindaleMetalView_rightMouseDown :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	self.mouse.pos = view_get_mouse_pos(self, event)
	self.mouse.down += {.Right}
	self.mouse.pressed += {.Right}
	if event->clickCount() >= 2 do self.mouse.double_clicked += {.Right}
	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="rightMouseUp:")
LindaleMetalView_rightMouseUp :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	self.mouse.pos = view_get_mouse_pos(self, event)
	self.mouse.down -= {.Right}
	self.mouse.released += {.Right}
	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="scrollWheel:")
LindaleMetalView_scrollWheel :: proc (self: ^LindaleMetalView, event: ^F.Event) {
	if self.mouse == nil do return
	dx := intrinsics.objc_send(F.Float, event, "scrollingDeltaX")
	dy := intrinsics.objc_send(F.Float, event, "scrollingDeltaY")
	self.mouse.scroll_delta.x += f32(dx)
	self.mouse.scroll_delta.y += f32(dy)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="setFrameSize:")
LindaleMetalView_setFrameSize :: proc (self: ^LindaleMetalView, new_size: F.Size) {
	cls := intrinsics.objc_send(^intrinsics.objc_class, self, "class")
	sup := ObjCSuper{auto_cast self, cls}
	sel := intrinsics.objc_find_selector("setFrameSize:")
	objc_msgSendSuper2(&sup, sel, new_size)

	// Keep the drawable in lock-step with the view; otherwise the
	// logical bounds and drawable pixels disagree for a frame
	// during live resize, and the UI appears to warp
	layer := cast(^CA.MetalLayer)self->layer()
	if layer != nil {
		scale: F.Float = 1.0
		window := intrinsics.objc_send(^F.Window, self, "window")
		if window != nil {
			scale = intrinsics.objc_send(F.Float, window, "backingScaleFactor")
		}
		layer->setDrawableSize(F.Size{new_size.width * scale, new_size.height * scale})
	}

	if self.on_repaint != nil do self.on_repaint(self.on_repaint_data)
}

@(objc_type=LindaleMetalView, objc_implement, objc_selector="updateTrackingAreas")
LindaleMetalView_updateTrackingAreas :: proc (self: ^LindaleMetalView) {
	// Remove old tracking areas
	areas := intrinsics.objc_send(^F.Array, self, "trackingAreas")
	count := intrinsics.objc_send(F.UInteger, areas, "count")
	for i in 0..<count {
		area := intrinsics.objc_send(rawptr, areas, "objectAtIndex:", i)
		intrinsics.objc_send(nil, self, "removeTrackingArea:", area)
	}

	bounds := intrinsics.objc_send(F.Rect, self, "bounds")
	// NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways
	options := F.UInteger(0x01 | 0x02 | 0x20)
	area := intrinsics.objc_send(^NSTrackingArea, NSTrackingArea, "alloc")
	tracking_area := intrinsics.objc_send(^NSTrackingArea, area,
		"initWithRect:options:owner:userInfo:", bounds, options, self, rawptr(nil))
	intrinsics.objc_send(nil, self, "addTrackingArea:", tracking_area)
}

@(objc_type=LindaleMetalView, objc_implement=false, objc_is_class_method=true)
LindaleMetalView_alloc :: proc "c" () -> ^LindaleMetalView {
	return intrinsics.objc_send(^LindaleMetalView, LindaleMetalView, "alloc")
}

@(objc_type=LindaleMetalView, objc_implement)
LindaleMetalView_makeBackingLayer :: proc(self: ^LindaleMetalView) -> ^CA.MetalLayer {
	return CA.MetalLayer.layer()
}

// Renderer lifecycle

renderer_create :: proc(parent: rawptr, width, height: i32) -> bridge.Renderer {
	frame := F.Rect{
		origin = {0, 0},
		size = {F.Float(width), F.Float(height)},
	}

	device := MTL.CreateSystemDefaultDevice()
	if device == nil do return nil

	renderer := new(MetalRenderer)
	renderer.device = device
	renderer.logical_width = width
	renderer.logical_height = height
	renderer.scale_factor = 1.0
	renderer.physical_width = width
	renderer.physical_height = height

	view := LindaleMetalView.alloc()->initWithFrameAndContext(frame, context)
	intrinsics.objc_send(nil, view, "setWantsLayer:", bool(true))

	// Get the CAMetalLayer created by makeBackingLayer
	layer := cast(^CA.MetalLayer)view->layer()
	layer->setDevice(device)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setFramebufferOnly(true)
	// Couple Metal present to the same CA transaction as the host's window resize
	layer->setPresentsWithTransaction(true)

	if parent != nil {
		parent_view := cast(^F.View)(parent)
		// NSViewWidthSizable | NSViewHeightSizable — track parent size on resize
		intrinsics.objc_send(nil, view, "setAutoresizingMask:", u64(2 | 16))
		F.View_addSubview(parent_view, view)
	}

	renderer.view = view
	renderer.layer = layer

	renderer.command_queue = device->newCommandQueue()
	if renderer.command_queue == nil {
		free(renderer)
		return nil
	}

	if !create_pipeline(renderer) {
		free(renderer)
		return nil
	}

	// 1MB instance buffer
	instance_buffer_size := F.UInteger(bridge.MAX_INSTANCES * size_of(bridge.DrawInstance))
	renderer.instance_buffer = device->newBufferWithLength(instance_buffer_size, {.StorageModeManaged})
	if renderer.instance_buffer == nil {
		free(renderer)
		return nil
	}
	renderer.instance_capacity = bridge.MAX_INSTANCES

	renderer.uniform_buffer = device->newBufferWithLength(size_of(bridge.UniformBuffer), {.StorageModeManaged})
	if renderer.uniform_buffer == nil {
		free(renderer)
		return nil
	}

	sampler_desc := F.new(MTL.SamplerDescriptor)
	defer F.release(sampler_desc)
	sampler_desc->setMinFilter(.Nearest)
	sampler_desc->setMagFilter(.Nearest)
	sampler_desc->setMipFilter(.NotMipmapped)
	sampler_desc->setSAddressMode(.Repeat)
	sampler_desc->setTAddressMode(.Repeat)
	renderer.sampler = device->newSamplerState(sampler_desc)

	// Create 1x1 white texture for solid color rendering
	renderer.next_texture_slot = 1 // Reserve slot 0 as invalid
	white_pixel := []u8{255, 255, 255, 255}
	renderer.white_texture = create_texture_internal(renderer, 1, 1, .RGBA8)
	upload_texture_internal(renderer, renderer.white_texture, white_pixel)

	// Set initial projection (scale factor will be updated in renderer_begin_pass)
	resize_internal(renderer, width, height, 1.0)

	return bridge.Renderer(renderer)
}

renderer_destroy :: proc(r: bridge.Renderer) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return

	for &slot in renderer.textures {
		if slot.in_use && slot.texture != nil {
			F.release(cast(^F.Object)slot.texture)
		}
	}

	if renderer.sampler != nil do F.release(cast(^F.Object)renderer.sampler)
	if renderer.uniform_buffer != nil do F.release(cast(^F.Object)renderer.uniform_buffer)
	if renderer.instance_buffer != nil do F.release(cast(^F.Object)renderer.instance_buffer)
	if renderer.pipeline != nil do F.release(cast(^F.Object)renderer.pipeline)
	if renderer.command_queue != nil do F.release(cast(^F.Object)renderer.command_queue)

	if renderer.view != nil {
		intrinsics.objc_send(nil, renderer.view, "removeFromSuperview")
		F.release(cast(^F.Object)renderer.view)
	}

	if renderer.device != nil do F.release(cast(^F.Object)renderer.device)

	free(renderer)
}

renderer_set_mouse_state :: proc(r: bridge.Renderer, mouse: ^bridge.MouseState) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	renderer.view.mouse = mouse
}

renderer_set_repaint_callback :: proc(r: bridge.Renderer, callback: proc "c" (rawptr), data: rawptr) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	renderer.view.on_repaint = callback
	renderer.view.on_repaint_data = data
}

renderer_resize :: proc(r: bridge.Renderer, width, height: i32) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	scale_factor := get_backing_scale_factor(renderer)
	resize_internal(renderer, width, height, scale_factor)
}

@(private)
resize_internal :: proc(renderer: ^MetalRenderer, logical_width, logical_height: i32, scale_factor: f32) {
	renderer.logical_width = logical_width
	renderer.logical_height = logical_height
	renderer.scale_factor = scale_factor
	renderer.physical_width = i32(f32(logical_width) * scale_factor)
	renderer.physical_height = i32(f32(logical_height) * scale_factor)

	// Projection maps logical coordinates to physical drawable
	// UI code works in logical coords (0 to logical_width/Height)
	renderer.uniforms.proj_matrix = linalg.matrix_ortho3d_f32(0, f32(logical_width), f32(logical_height), 0, -1, 1)
	renderer.uniforms.dims = {f32(logical_width), f32(logical_height)}
}

@(private)
get_backing_scale_factor :: proc(renderer: ^MetalRenderer) -> f32 {
	// Query the window's backing scale factor via objc
	window := intrinsics.objc_send(^F.Window, renderer.view, "window")
	if window != nil {
		scale := intrinsics.objc_send(F.Float, window, "backingScaleFactor")
		return f32(scale)
	}
	// Fallback if no window yet
	return 1.0
}

renderer_get_size :: proc(r: bridge.Renderer) -> bridge.RendererSize {
	renderer := cast(^MetalRenderer)r
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
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return bridge.INVALID_TEXTURE
	return create_texture_internal(renderer, width, height, format)
}

@(private)
create_texture_internal :: proc(renderer: ^MetalRenderer, width, height: u32, format: bridge.PixelFormat) -> bridge.TextureHandle {
	// Find free slot
	slot: u32 = 0
	for i in 1..<u32(bridge.MAX_TEXTURES) {
		if !renderer.textures[i].in_use {
			slot = i
			break
		}
	}
	if slot == 0 do return bridge.INVALID_TEXTURE

	desc := F.new(MTL.TextureDescriptor)
	defer F.release(desc)
	desc->setTextureType(.Type2D)
	desc->setWidth(F.UInteger(width))
	desc->setHeight(F.UInteger(height))
	desc->setStorageMode(.Managed)
	desc->setUsage({.ShaderRead})

	mtl_format: MTL.PixelFormat
	switch format {
	case .RGBA8:
		mtl_format = .RGBA8Unorm
	case .R8:
		mtl_format = .R8Unorm
	}
	desc->setPixelFormat(mtl_format)

	texture := renderer.device->newTexture(desc)
	if texture == nil do return bridge.INVALID_TEXTURE

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
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if handle == bridge.INVALID_TEXTURE do return
	if u32(handle) >= bridge.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if slot.in_use && slot.texture != nil {
		F.release(cast(^F.Object)slot.texture)
		slot^ = {}
	}
}

renderer_upload_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle, pixels: []u8) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	upload_texture_internal(renderer, handle, pixels)
}

@(private)
upload_texture_internal :: proc(renderer: ^MetalRenderer, handle: bridge.TextureHandle, pixels: []u8) {
	if handle == bridge.INVALID_TEXTURE do return
	if u32(handle) >= bridge.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if !slot.in_use || slot.texture == nil do return

	bytes_per_pixel: u32 = slot.format == .RGBA8 ? 4 : 1
	bytes_per_row := slot.width * bytes_per_pixel

	region := MTL.Region{
		origin = {0, 0, 0},
		size = {F.Integer(slot.width), F.Integer(slot.height), 1},
	}

	slot.texture->replaceRegion(region, 0, raw_data(pixels), F.UInteger(bytes_per_row))
}

renderer_get_white_texture :: proc(r: bridge.Renderer) -> bridge.TextureHandle {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return bridge.INVALID_TEXTURE
	return renderer.white_texture
}

// Frame rendering

renderer_begin_frame :: proc(r: bridge.Renderer) -> bool {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return false

	// contentsScale and drawableSize need to be in lock-step.
	// A cross-DPI screen change updates one but not the other, stranding the drawable at the old pixel count
	scale_factor := get_backing_scale_factor(renderer)
	intrinsics.objc_send(nil, renderer.layer, "setContentsScale:", F.Float(scale_factor))
	bounds := intrinsics.objc_send(F.Rect, renderer.view, "bounds")
	renderer.layer->setDrawableSize(F.Size{bounds.size.width * F.Float(scale_factor), bounds.size.height * F.Float(scale_factor)})

	renderer.current_drawable = renderer.layer->nextDrawable()
	if renderer.current_drawable == nil {
		return false
	}

	renderer.command_buffer = renderer.command_queue->commandBuffer()
	if renderer.command_buffer == nil do return false

	return true
}

renderer_end_frame :: proc(r: bridge.Renderer) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.command_buffer == nil do return

	// With presentsWithTransaction, commit + wait + present manually so the
	// surface lands in the same CA transaction as the host's window-resize update
	renderer.command_buffer->commit()
	if renderer.current_drawable != nil {
		renderer.command_buffer->waitUntilScheduled()
		(cast(^MTL.Drawable)renderer.current_drawable)->present()
	}

	renderer.command_buffer = nil
	renderer.current_drawable = nil
}

renderer_upload_instances :: proc(r: bridge.Renderer, instances: []bridge.DrawInstance) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if len(instances) == 0 do return
	if u32(len(instances)) > renderer.instance_capacity {
		log.errorf("instance overflow: %d > cap %d — dropping upload, GPU buffer stale", len(instances), renderer.instance_capacity)
		assert(false, "draw instance count exceeded MAX_INSTANCES")
		return
	}

	buffer_ptr := renderer.instance_buffer->contentsAsSlice([]bridge.DrawInstance)
	copy(buffer_ptr, instances)

	// Mark the modified range for managed storage mode
	renderer.instance_buffer->didModifyRange(F.Range{0, F.UInteger(len(instances) * size_of(bridge.DrawInstance))})
}

renderer_begin_pass :: proc(r: bridge.Renderer, clear_color: bridge.ColorF32) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.current_drawable == nil do return

	frame_buffer := renderer.current_drawable->texture()

	// Use the actual drawable texture size for the viewport
	physical_width := i32(frame_buffer->width())
	physical_height := i32(frame_buffer->height())

	// View bounds are always in points (logical coordinates)
	bounds := intrinsics.objc_send(F.Rect, renderer.view, "bounds")
	logical_width := i32(bounds.size.width)
	logical_height := i32(bounds.size.height)

	scale_factor := get_backing_scale_factor(renderer)

	if logical_width != renderer.logical_width || logical_height != renderer.logical_height || scale_factor != renderer.scale_factor {
		renderer.logical_width = logical_width
		renderer.logical_height = logical_height
		renderer.scale_factor = scale_factor
		renderer.physical_width = physical_width
		renderer.physical_height = physical_height
		renderer.uniforms.proj_matrix = linalg.matrix_ortho3d_f32(0, f32(logical_width), f32(logical_height), 0, -1, 1)
		renderer.uniforms.dims = {f32(logical_width), f32(logical_height)}
	}

	pass_desc := MTL.RenderPassDescriptor.renderPassDescriptor()
	color_attachment := pass_desc->colorAttachments()->object(0)
	color_attachment->setTexture(frame_buffer)
	color_attachment->setClearColor(MTL.ClearColor{f64(clear_color[0]), f64(clear_color[1]), f64(clear_color[2]), f64(clear_color[3])})
	color_attachment->setLoadAction(.Clear)
	color_attachment->setStoreAction(.Store)

	renderer.render_encoder = renderer.command_buffer->renderCommandEncoderWithDescriptor(pass_desc)
	renderer.render_encoder->setRenderPipelineState(renderer.pipeline)

	viewport := MTL.Viewport{
		originX = 0,
		originY = 0,
		width = f64(physical_width),
		height = f64(physical_height),
		znear = 0,
		zfar = 1,
	}
	renderer.render_encoder->setViewport(viewport)

	// Bind instance buffer (buffer index 1 for vertex data)
	renderer.render_encoder->setVertexBuffer(renderer.instance_buffer, 0, 1)
}

renderer_end_pass :: proc(r: bridge.Renderer) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.render_encoder == nil do return

	renderer.render_encoder->endEncoding()
	renderer.render_encoder = nil
}

renderer_draw :: proc(r: bridge.Renderer, cmd: bridge.DrawCommand) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.render_encoder == nil do return
	if cmd.instance_count == 0 do return

	// Set scissor if specified (scale logical coords to physical pixels)
	if cmd.scissor.w > 0 && cmd.scissor.h > 0 {
		scale := renderer.scale_factor
		scissor_rect := MTL.ScissorRect{
			x = F.Integer(f32(cmd.scissor.x) * scale),
			y = F.Integer(f32(cmd.scissor.y) * scale),
			width = F.Integer(f32(cmd.scissor.w) * scale),
			height = F.Integer(f32(cmd.scissor.h) * scale),
		}
		renderer.render_encoder->setScissorRect(scissor_rect)
	} else {
		// Full viewport scissor (physical pixels)
		scissor_rect := MTL.ScissorRect{
			x = 0,
			y = 0,
			width = F.Integer(renderer.physical_width),
			height = F.Integer(renderer.physical_height),
		}
		renderer.render_encoder->setScissorRect(scissor_rect)
	}

	renderer.uniforms.single_channel_texture = cmd.single_channel_texture ? 1 : 0

	uniform_ptr := renderer.uniform_buffer->contentsAsSlice([]bridge.UniformBuffer)
	uniform_ptr[0] = renderer.uniforms
	renderer.uniform_buffer->didModifyRange(F.Range{0, size_of(bridge.UniformBuffer)})
	renderer.render_encoder->setVertexBuffer(renderer.uniform_buffer, 0, 0)
	renderer.render_encoder->setFragmentBuffer(renderer.uniform_buffer, 0, 0)

	texture_handle := cmd.texture
	if texture_handle == bridge.INVALID_TEXTURE {
		texture_handle = renderer.white_texture
	}

	if u32(texture_handle) < bridge.MAX_TEXTURES {
		slot := &renderer.textures[texture_handle]
		if slot.in_use && slot.texture != nil {
			renderer.render_encoder->setFragmentTexture(slot.texture, 0)
			renderer.render_encoder->setFragmentSamplerState(renderer.sampler, 0)
		}
	}

	// 4 vertices per instance (triangle strip quad), starting at the instance offset
	renderer.render_encoder->drawPrimitivesWithInstances(.TriangleStrip, 0, 4, F.UInteger(cmd.instance_count), F.UInteger(cmd.instance_offset))
}

// Pipeline creation

@(private)
create_pipeline :: proc(renderer: ^MetalRenderer) -> bool {
	// Compile shader
	compile_options := F.new(MTL.CompileOptions)
	defer F.release(compile_options)

	shader_string := F.String.alloc()->initWithBytesNoCopy(raw_data(shader_source), F.UInteger(len(shader_source)), .UTF8, false)
	defer F.release(shader_string)

	library, err := renderer.device->newLibraryWithSource(shader_string, compile_options)
	if err != nil do return false
	defer F.release(cast(^F.Object)library)

	vertex_func := library->newFunctionWithName(F.AT("VSMain"))
	fragment_func := library->newFunctionWithName(F.AT("PSMain"))
	if vertex_func == nil || fragment_func == nil do return false
	defer F.release(cast(^F.Object)vertex_func)
	defer F.release(cast(^F.Object)fragment_func)

	// Create vertex descriptor for instance data
	vertex_desc := F.new(MTL.VertexDescriptor)
	defer F.release(vertex_desc)

	// Attribute 0: pos0
	vertex_desc->attributes()->object(0)->setFormat(.Float2)
	vertex_desc->attributes()->object(0)->setOffset(0)
	vertex_desc->attributes()->object(0)->setBufferIndex(1)

	// Attribute 1: pos1
	vertex_desc->attributes()->object(1)->setFormat(.Float2)
	vertex_desc->attributes()->object(1)->setOffset(2 * size_of(f32))
	vertex_desc->attributes()->object(1)->setBufferIndex(1)

	// Attribute 2: uv0
	vertex_desc->attributes()->object(2)->setFormat(.Float2)
	vertex_desc->attributes()->object(2)->setOffset(4 * size_of(f32))
	vertex_desc->attributes()->object(2)->setBufferIndex(1)

	// Attribute 3: uv1
	vertex_desc->attributes()->object(3)->setFormat(.Float2)
	vertex_desc->attributes()->object(3)->setOffset(6 * size_of(f32))
	vertex_desc->attributes()->object(3)->setBufferIndex(1)

	// Attribute 4: color
	vertex_desc->attributes()->object(4)->setFormat(.UChar4Normalized)
	vertex_desc->attributes()->object(4)->setOffset(8 * size_of(f32))
	vertex_desc->attributes()->object(4)->setBufferIndex(1)

	// Attribute 5: border_color
	vertex_desc->attributes()->object(5)->setFormat(.UChar4Normalized)
	vertex_desc->attributes()->object(5)->setOffset(8 * size_of(f32) + 4)
	vertex_desc->attributes()->object(5)->setBufferIndex(1)

	// Attribute 6: params - border_width, shape_param, no_texture
	vertex_desc->attributes()->object(6)->setFormat(.Float3)
	vertex_desc->attributes()->object(6)->setOffset(10 * size_of(f32))
	vertex_desc->attributes()->object(6)->setBufferIndex(1)

	// Attribute 7: mode - shape selector
	vertex_desc->attributes()->object(7)->setFormat(.UInt)
	vertex_desc->attributes()->object(7)->setOffset(13 * size_of(f32))
	vertex_desc->attributes()->object(7)->setBufferIndex(1)

	// Attribute 8: extras - extra0, extra1
	vertex_desc->attributes()->object(8)->setFormat(.Float2)
	vertex_desc->attributes()->object(8)->setOffset(14 * size_of(f32))
	vertex_desc->attributes()->object(8)->setBufferIndex(1)

	// Buffer layout - per instance
	vertex_desc->layouts()->object(1)->setStride(size_of(bridge.DrawInstance))
	vertex_desc->layouts()->object(1)->setStepFunction(.PerInstance)
	vertex_desc->layouts()->object(1)->setStepRate(1)

	pipeline_desc := F.new(MTL.RenderPipelineDescriptor)
	defer F.release(pipeline_desc)

	pipeline_desc->setVertexFunction(vertex_func)
	pipeline_desc->setFragmentFunction(fragment_func)
	pipeline_desc->setVertexDescriptor(vertex_desc)

	// Color attachment with alpha blending
	color_attachment := pipeline_desc->colorAttachments()->object(0)
	color_attachment->setPixelFormat(.BGRA8Unorm)
	color_attachment->setBlendingEnabled(true)
	color_attachment->setSourceRGBBlendFactor(.SourceAlpha)
	color_attachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	color_attachment->setRgbBlendOperation(.Add)
	color_attachment->setSourceAlphaBlendFactor(.One)
	color_attachment->setDestinationAlphaBlendFactor(.Zero)
	color_attachment->setAlphaBlendOperation(.Add)

	pipeline, pipeline_err := renderer.device->newRenderPipelineState(pipeline_desc)
	if pipeline_err != nil do return false

	renderer.pipeline = pipeline
	return true
}
