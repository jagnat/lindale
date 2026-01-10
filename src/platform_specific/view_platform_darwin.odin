package platform_specific

import "base:runtime"
import "core:math/linalg"

import F "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import MTK "vendor:darwin/MetalKit"
import CA "vendor:darwin/QuartzCore"

import "base:intrinsics"

import api "../platform_api"

shader_source := #load("../shaders/shader.metal")

TextureSlot :: struct {
	texture: ^MTL.Texture,
	width: u32,
	height: u32,
	format: api.PixelFormat,
	inUse: bool,
}

// Metal renderer state - coupled with the view
MetalRenderer :: struct {
	view: ^LindaleMtkView,
	device: ^MTL.Device,
	commandQueue: ^MTL.CommandQueue,
	pipeline: ^MTL.RenderPipelineState,

	// One large buffer for all instances
	instanceBuffer: ^MTL.Buffer,
	instanceCapacity: u32,

	uniformBuffer: ^MTL.Buffer,
	uniforms: api.UniformBuffer,

	textures: [api.MAX_TEXTURES]TextureSlot,
	nextTextureSlot: u32,
	sampler: ^MTL.SamplerState,

	// Current frame state
	commandBuffer: ^MTL.CommandBuffer,
	renderEncoder: ^MTL.RenderCommandEncoder,
	currentDrawable: ^CA.MetalDrawable,

	// logical = points for UI, physical = actual pixels
	logicalWidth: i32,
	logicalHeight: i32,
	scaleFactor: f32,
	physicalWidth: i32,
	physicalHeight: i32,

	// For solid color rendering
	whiteTexture: api.TextureHandle,
}

// Objective-C view implementation
@(objc_implement,
	objc_class            = "LindaleNSView",
	objc_superclass       = MTK.View,
	objc_ivar             = LindaleMtkView_Var,
	objc_context_provider = LindaleMtkView_get_context,
)
LindaleMtkView :: struct {
	using _: MTK.View,
}

LindaleMtkView_Var :: struct {
	ctx: runtime.Context,
}

LindaleMtkView_get_context :: proc "c" (self: ^LindaleMtkView_Var) -> runtime.Context {
	return self.ctx
}

@(objc_type=LindaleMtkView, objc_name="initWithFrameAndContext")
LindaleMtkView_initWithFrameAndContext :: proc "c" (self: ^LindaleMtkView, frame: F.Rect, dev: ^MTL.Device, ctx: runtime.Context) -> ^LindaleMtkView {
	self->initWithFrame(frame, dev)
	self.ctx = ctx
	return self
}

@(objc_type=LindaleMtkView, objc_implement)
LindaleMtkView_acceptsFirstResponder :: proc (self: ^LindaleMtkView, _cmd: rawptr) -> F.BOOL {
	return true
}

@(objc_type=LindaleMtkView, objc_implement, objc_selector="mouseDown:")
LindaleMtkView_mouseDown :: proc (self: ^LindaleMtkView, _cmd: rawptr, event: ^F.Event) {
	// TODO: Handle mouse input
}

@(objc_type=LindaleMtkView, objc_implement=false, objc_is_class_method=true)
LindaleMtkView_alloc :: proc "c" () -> ^LindaleMtkView {
	return intrinsics.objc_send(^LindaleMtkView, LindaleMtkView, "alloc")
}

@(objc_type=LindaleMtkView, objc_name="makeBackingLayer")
LindaleMtkView_makeBackingLayer :: proc(self: ^LindaleMtkView) -> ^CA.MetalLayer {
	return CA.MetalLayer.layer()
}

// Renderer lifecycle

renderer_create :: proc(parent: rawptr, width, height: i32) -> api.Renderer {
	frame := F.Rect{
		origin = {0, 0},
		size = {F.Float(width), F.Float(height)},
	}

	device := MTL.CreateSystemDefaultDevice()
	if device == nil do return nil

	renderer := new(MetalRenderer)
	renderer.device = device
	// Dimensions will be set properly in renderer_begin_pass when we have actual drawable size
	renderer.logicalWidth = width
	renderer.logicalHeight = height
	renderer.scaleFactor = 1.0 // Will be updated when window is available
	renderer.physicalWidth = width
	renderer.physicalHeight = height

	lindaleView := LindaleMtkView.alloc()->initWithFrameAndContext(frame, device, context)
	lindaleView->setColorPixelFormat(.BGRA8Unorm_sRGB)
	lindaleView->setDepthStencilPixelFormat(.Invalid)
	lindaleView->setSampleCount(1)
	lindaleView->setPaused(true)
	lindaleView->setEnableSetNeedsDisplay(false)

	if parent != nil {
		parentView := cast(^F.View)(parent)
		F.View_addSubview(parentView, lindaleView)
	}

	renderer.view = lindaleView

	renderer.commandQueue = device->newCommandQueue()
	if renderer.commandQueue == nil {
		free(renderer)
		return nil
	}

	if !create_pipeline(renderer) {
		free(renderer)
		return nil
	}

	// 1MB instance buffer
	instanceBufferSize := F.UInteger(api.MAX_INSTANCES * size_of(api.RectInstance))
	renderer.instanceBuffer = device->newBufferWithLength(instanceBufferSize, {.StorageModeManaged})
	if renderer.instanceBuffer == nil {
		free(renderer)
		return nil
	}
	renderer.instanceCapacity = api.MAX_INSTANCES

	renderer.uniformBuffer = device->newBufferWithLength(size_of(api.UniformBuffer), {.StorageModeManaged})
	if renderer.uniformBuffer == nil {
		free(renderer)
		return nil
	}

	samplerDesc := F.new(MTL.SamplerDescriptor)
	defer F.release(samplerDesc)
	samplerDesc->setMinFilter(.Nearest)
	samplerDesc->setMagFilter(.Nearest)
	samplerDesc->setMipFilter(.NotMipmapped)
	samplerDesc->setSAddressMode(.ClampToEdge)
	samplerDesc->setTAddressMode(.ClampToEdge)
	renderer.sampler = device->newSamplerState(samplerDesc)

	// Create 1x1 white texture for solid color rendering
	renderer.nextTextureSlot = 1 // Reserve slot 0 as invalid
	whitePixel := []u8{255, 255, 255, 255}
	renderer.whiteTexture = create_texture_internal(renderer, 1, 1, .RGBA8)
	upload_texture_internal(renderer, renderer.whiteTexture, whitePixel)

	// Set initial projection (scale factor will be updated in renderer_begin_pass)
	resize_internal(renderer, width, height, 1.0)

	return api.Renderer(renderer)
}

renderer_destroy :: proc(r: api.Renderer) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return

	for &slot in renderer.textures {
		if slot.inUse && slot.texture != nil {
			F.release(cast(^F.Object)slot.texture)
		}
	}

	if renderer.sampler != nil do F.release(cast(^F.Object)renderer.sampler)
	if renderer.uniformBuffer != nil do F.release(cast(^F.Object)renderer.uniformBuffer)
	if renderer.instanceBuffer != nil do F.release(cast(^F.Object)renderer.instanceBuffer)
	if renderer.pipeline != nil do F.release(cast(^F.Object)renderer.pipeline)
	if renderer.commandQueue != nil do F.release(cast(^F.Object)renderer.commandQueue)

	if renderer.view != nil {
		intrinsics.objc_send(nil, renderer.view, "removeFromSuperview")
		F.release(cast(^F.Object)renderer.view)
	}

	if renderer.device != nil do F.release(cast(^F.Object)renderer.device)

	free(renderer)
}

renderer_resize :: proc(r: api.Renderer, width, height: i32) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	scaleFactor := get_backing_scale_factor(renderer)
	resize_internal(renderer, width, height, scaleFactor)
}

@(private)
resize_internal :: proc(renderer: ^MetalRenderer, logicalWidth, logicalHeight: i32, scaleFactor: f32) {
	renderer.logicalWidth = logicalWidth
	renderer.logicalHeight = logicalHeight
	renderer.scaleFactor = scaleFactor
	renderer.physicalWidth = i32(f32(logicalWidth) * scaleFactor)
	renderer.physicalHeight = i32(f32(logicalHeight) * scaleFactor)

	// Projection maps logical coordinates to physical drawable
	// UI code works in logical coords (0 to logicalWidth/Height)
	renderer.uniforms.projMatrix = linalg.matrix_ortho3d_f32(0, f32(logicalWidth), f32(logicalHeight), 0, -1, 1)
	renderer.uniforms.dims = {f32(logicalWidth), f32(logicalHeight)}
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

renderer_get_size :: proc(r: api.Renderer) -> api.RendererSize {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return {}
	return api.RendererSize{
		logicalWidth = renderer.logicalWidth,
		logicalHeight = renderer.logicalHeight,
		scaleFactor = renderer.scaleFactor,
		physicalWidth = renderer.physicalWidth,
		physicalHeight = renderer.physicalHeight,
	}
}

// Texture management

renderer_create_texture :: proc(r: api.Renderer, width, height: u32, format: api.PixelFormat) -> api.TextureHandle {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return api.INVALID_TEXTURE
	return create_texture_internal(renderer, width, height, format)
}

@(private)
create_texture_internal :: proc(renderer: ^MetalRenderer, width, height: u32, format: api.PixelFormat) -> api.TextureHandle {
	// Find free slot
	slot: u32 = 0
	for i in 1..<u32(api.MAX_TEXTURES) {
		if !renderer.textures[i].inUse {
			slot = i
			break
		}
	}
	if slot == 0 do return api.INVALID_TEXTURE

	desc := F.new(MTL.TextureDescriptor)
	defer F.release(desc)
	desc->setTextureType(.Type2D)
	desc->setWidth(F.UInteger(width))
	desc->setHeight(F.UInteger(height))
	desc->setStorageMode(.Managed)
	desc->setUsage({.ShaderRead})

	mtlFormat: MTL.PixelFormat
	switch format {
	case .RGBA8:
		mtlFormat = .RGBA8Unorm
	case .R8:
		mtlFormat = .R8Unorm
	}
	desc->setPixelFormat(mtlFormat)

	texture := renderer.device->newTexture(desc)
	if texture == nil do return api.INVALID_TEXTURE

	renderer.textures[slot] = TextureSlot{
		texture = texture,
		width = width,
		height = height,
		format = format,
		inUse = true,
	}

	return api.TextureHandle(slot)
}

renderer_destroy_texture :: proc(r: api.Renderer, handle: api.TextureHandle) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if handle == api.INVALID_TEXTURE do return
	if u32(handle) >= api.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if slot.inUse && slot.texture != nil {
		F.release(cast(^F.Object)slot.texture)
		slot^ = {}
	}
}

renderer_upload_texture :: proc(r: api.Renderer, handle: api.TextureHandle, pixels: []u8) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	upload_texture_internal(renderer, handle, pixels)
}

@(private)
upload_texture_internal :: proc(renderer: ^MetalRenderer, handle: api.TextureHandle, pixels: []u8) {
	if handle == api.INVALID_TEXTURE do return
	if u32(handle) >= api.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if !slot.inUse || slot.texture == nil do return

	bytesPerPixel: u32 = slot.format == .RGBA8 ? 4 : 1
	bytesPerRow := slot.width * bytesPerPixel

	region := MTL.Region{
		origin = {0, 0, 0},
		size = {F.Integer(slot.width), F.Integer(slot.height), 1},
	}

	slot.texture->replaceRegion(region, 0, raw_data(pixels), F.UInteger(bytesPerRow))
}

renderer_get_white_texture :: proc(r: api.Renderer) -> api.TextureHandle {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return api.INVALID_TEXTURE
	return renderer.whiteTexture
}

// Frame rendering

renderer_begin_frame :: proc(r: api.Renderer) -> bool {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return false

	renderer.currentDrawable = renderer.view->currentDrawable()
	if renderer.currentDrawable == nil do return false

	renderer.commandBuffer = renderer.commandQueue->commandBuffer()
	if renderer.commandBuffer == nil do return false

	return true
}

renderer_end_frame :: proc(r: api.Renderer) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.commandBuffer == nil do return

	if renderer.currentDrawable != nil {
		renderer.commandBuffer->presentDrawable(renderer.currentDrawable)
	}

	renderer.commandBuffer->commit()
	renderer.commandBuffer = nil
	renderer.currentDrawable = nil
}

renderer_upload_instances :: proc(r: api.Renderer, instances: []api.RectInstance) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if len(instances) == 0 do return
	if u32(len(instances)) > renderer.instanceCapacity do return

	bufferPtr := renderer.instanceBuffer->contentsAsSlice([]api.RectInstance)
	copy(bufferPtr, instances)

	// Mark the modified range for managed storage mode
	renderer.instanceBuffer->didModifyRange(F.Range{0, F.UInteger(len(instances) * size_of(api.RectInstance))})
}

renderer_begin_pass :: proc(r: api.Renderer, clearColor: api.ColorF32) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.currentDrawable == nil do return

	// Update dimensions from actual drawable size and scale factor
	drawableSize := renderer.view->drawableSize()
	physicalWidth := i32(drawableSize.width)
	physicalHeight := i32(drawableSize.height)
	scaleFactor := get_backing_scale_factor(renderer)

	// Calculate logical size from physical size
	logicalWidth := i32(f32(physicalWidth) / scaleFactor)
	logicalHeight := i32(f32(physicalHeight) / scaleFactor)

	if logicalWidth != renderer.logicalWidth || logicalHeight != renderer.logicalHeight || scaleFactor != renderer.scaleFactor {
		resize_internal(renderer, logicalWidth, logicalHeight, scaleFactor)
	}

	frameBuffer := renderer.currentDrawable->texture()

	passDesc := MTL.RenderPassDescriptor.renderPassDescriptor()
	colorAttachment := passDesc->colorAttachments()->object(0)
	colorAttachment->setTexture(frameBuffer)
	colorAttachment->setClearColor(MTL.ClearColor{f64(clearColor[0]), f64(clearColor[1]), f64(clearColor[2]), f64(clearColor[3])})
	colorAttachment->setLoadAction(.Clear)
	colorAttachment->setStoreAction(.Store)

	renderer.renderEncoder = renderer.commandBuffer->renderCommandEncoderWithDescriptor(passDesc)
	renderer.renderEncoder->setRenderPipelineState(renderer.pipeline)

	// Physical pixels
	viewport := MTL.Viewport{
		originX = 0,
		originY = 0,
		width = f64(renderer.physicalWidth),
		height = f64(renderer.physicalHeight),
		znear = 0,
		zfar = 1,
	}
	renderer.renderEncoder->setViewport(viewport)

	// Bind instance buffer (buffer index 1 for vertex data)
	renderer.renderEncoder->setVertexBuffer(renderer.instanceBuffer, 0, 1)
}

renderer_end_pass :: proc(r: api.Renderer) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.renderEncoder == nil do return

	renderer.renderEncoder->endEncoding()
	renderer.renderEncoder = nil
}

renderer_draw :: proc(r: api.Renderer, cmd: api.DrawCommand) {
	renderer := cast(^MetalRenderer)r
	if renderer == nil do return
	if renderer.renderEncoder == nil do return
	if cmd.instanceCount == 0 do return

	// Set scissor if specified (scale logical coords to physical pixels)
	if cmd.scissor.w > 0 && cmd.scissor.h > 0 {
		scale := renderer.scaleFactor
		scissorRect := MTL.ScissorRect{
			x = F.Integer(f32(cmd.scissor.x) * scale),
			y = F.Integer(f32(cmd.scissor.y) * scale),
			width = F.Integer(f32(cmd.scissor.w) * scale),
			height = F.Integer(f32(cmd.scissor.h) * scale),
		}
		renderer.renderEncoder->setScissorRect(scissorRect)
	} else {
		// Full viewport scissor (physical pixels)
		scissorRect := MTL.ScissorRect{
			x = 0,
			y = 0,
			width = F.Integer(renderer.physicalWidth),
			height = F.Integer(renderer.physicalHeight),
		}
		renderer.renderEncoder->setScissorRect(scissorRect)
	}

	renderer.uniforms.singleChannelTexture = cmd.singleChannelTexture ? 1 : 0

	uniformPtr := renderer.uniformBuffer->contentsAsSlice([]api.UniformBuffer)
	uniformPtr[0] = renderer.uniforms
	renderer.uniformBuffer->didModifyRange(F.Range{0, size_of(api.UniformBuffer)})
	renderer.renderEncoder->setVertexBuffer(renderer.uniformBuffer, 0, 0)
	renderer.renderEncoder->setFragmentBuffer(renderer.uniformBuffer, 0, 0)

	textureHandle := cmd.texture
	if textureHandle == api.INVALID_TEXTURE {
		textureHandle = renderer.whiteTexture
	}

	if u32(textureHandle) < api.MAX_TEXTURES {
		slot := &renderer.textures[textureHandle]
		if slot.inUse && slot.texture != nil {
			renderer.renderEncoder->setFragmentTexture(slot.texture, 0)
			renderer.renderEncoder->setFragmentSamplerState(renderer.sampler, 0)
		}
	}

	// 4 vertices per instance (triangle strip quad), starting at the instance offset
	renderer.renderEncoder->drawPrimitivesWithInstances(.TriangleStrip, 0, 4, F.UInteger(cmd.instanceCount), F.UInteger(cmd.instanceOffset))
}

// Pipeline creation

@(private)
create_pipeline :: proc(renderer: ^MetalRenderer) -> bool {
	// Compile shader
	compileOptions := F.new(MTL.CompileOptions)
	defer F.release(compileOptions)

	shaderString := F.String.alloc()->initWithBytesNoCopy(raw_data(shader_source), F.UInteger(len(shader_source)), .UTF8, false)
	defer F.release(shaderString)

	library, err := renderer.device->newLibraryWithSource(shaderString, compileOptions)
	if err != nil do return false
	defer F.release(cast(^F.Object)library)

	vertexFunc := library->newFunctionWithName(F.AT("VSMain"))
	fragmentFunc := library->newFunctionWithName(F.AT("PSMain"))
	if vertexFunc == nil || fragmentFunc == nil do return false
	defer F.release(cast(^F.Object)vertexFunc)
	defer F.release(cast(^F.Object)fragmentFunc)

	// Create vertex descriptor for instance data
	vertexDesc := F.new(MTL.VertexDescriptor)
	defer F.release(vertexDesc)

	// Attribute 0: pos0 (float2)
	vertexDesc->attributes()->object(0)->setFormat(.Float2)
	vertexDesc->attributes()->object(0)->setOffset(0)
	vertexDesc->attributes()->object(0)->setBufferIndex(1)

	// Attribute 1: pos1 (float2)
	vertexDesc->attributes()->object(1)->setFormat(.Float2)
	vertexDesc->attributes()->object(1)->setOffset(2 * size_of(f32))
	vertexDesc->attributes()->object(1)->setBufferIndex(1)

	// Attribute 2: uv0 (float2)
	vertexDesc->attributes()->object(2)->setFormat(.Float2)
	vertexDesc->attributes()->object(2)->setOffset(4 * size_of(f32))
	vertexDesc->attributes()->object(2)->setBufferIndex(1)

	// Attribute 3: uv1 (float2)
	vertexDesc->attributes()->object(3)->setFormat(.Float2)
	vertexDesc->attributes()->object(3)->setOffset(6 * size_of(f32))
	vertexDesc->attributes()->object(3)->setBufferIndex(1)

	// Attribute 4: color (uchar4 normalized)
	vertexDesc->attributes()->object(4)->setFormat(.UChar4Normalized)
	vertexDesc->attributes()->object(4)->setOffset(8 * size_of(f32))
	vertexDesc->attributes()->object(4)->setBufferIndex(1)

	// Attribute 5: borderColor (uchar4 normalized)
	vertexDesc->attributes()->object(5)->setFormat(.UChar4Normalized)
	vertexDesc->attributes()->object(5)->setOffset(8 * size_of(f32) + 4)
	vertexDesc->attributes()->object(5)->setBufferIndex(1)

	// Attribute 6: params (float4) - borderWidth, cornerRad, noTexture, pad
	vertexDesc->attributes()->object(6)->setFormat(.Float4)
	vertexDesc->attributes()->object(6)->setOffset(10 * size_of(f32))
	vertexDesc->attributes()->object(6)->setBufferIndex(1)

	// Buffer layout - per instance
	vertexDesc->layouts()->object(1)->setStride(size_of(api.RectInstance))
	vertexDesc->layouts()->object(1)->setStepFunction(.PerInstance)
	vertexDesc->layouts()->object(1)->setStepRate(1)

	pipelineDesc := F.new(MTL.RenderPipelineDescriptor)
	defer F.release(pipelineDesc)

	pipelineDesc->setVertexFunction(vertexFunc)
	pipelineDesc->setFragmentFunction(fragmentFunc)
	pipelineDesc->setVertexDescriptor(vertexDesc)

	// Color attachment with alpha blending
	colorAttachment := pipelineDesc->colorAttachments()->object(0)
	colorAttachment->setPixelFormat(.BGRA8Unorm_sRGB)
	colorAttachment->setBlendingEnabled(true)
	colorAttachment->setSourceRGBBlendFactor(.SourceAlpha)
	colorAttachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	colorAttachment->setRgbBlendOperation(.Add)
	colorAttachment->setSourceAlphaBlendFactor(.One)
	colorAttachment->setDestinationAlphaBlendFactor(.Zero)
	colorAttachment->setAlphaBlendOperation(.Add)

	pipeline, pipelineErr := renderer.device->newRenderPipelineState(pipelineDesc)
	if pipelineErr != nil do return false

	renderer.pipeline = pipeline
	return true
}
