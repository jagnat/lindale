package lindale

import "core:fmt"
import "core:mem"
import vm "core:mem/virtual"
import "core:slice"
import "core:math/linalg"
import "core:c"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "core:log"

RenderContext :: struct {
	plugin: ^Plugin,
	gpuInitialized: bool,
	gpu: ^sdl.GPUDevice,
	pipeline: ^sdl.GPUGraphicsPipeline,
	swapchainFormat: sdl.GPUTextureFormat,
	window: ^sdl.Window,
	instanceBuffer: GraphicsBuffer, // Instance buffer
	width, height: i32,
	sampler: ^sdl.GPUSampler,
	cmdBuf: ^sdl.GPUCommandBuffer,
	renderPass: ^sdl.GPURenderPass,
	swapchainTexture: ^sdl.GPUTexture,
	vertexShader, fragmentShader: ^sdl.GPUShader,
	uniforms: UniformBuffer,
}

BUFFER_SIZE :: 1024 * 1024

UniformBuffer :: struct {
	projMatrix: Mat4f,
	dims: Vec2f,
	singleChannelTexture: u32,
}

GraphicsBuffer :: struct {
	handle: ^sdl.GPUBuffer,
	capacity: u32,
	size: u32,
	count: u32,
	usage: sdl.GPUBufferUsageFlags,
}

Texture2D :: struct {
	texHandle: ^sdl.GPUTexture,
	w, h: u32,
	bytesPerPixel: u32,
	data: []byte,
	uploaded: bool,
	singleChannelTexture: bool,
}

RectInstance :: struct #packed {
	pos0: [2]f32, // Top left
	pos1: [2]f32, // Bottom right
	uv0: [2]f32, // Top left
	uv1: [2]f32, // Bottom right
	color: ColorU8, // rect color
	borderColor: ColorU8,

	// Params: Vec4
	borderWidth: f32,
	cornerRad: f32, // corner radiustc
	noTexture: f32, // 
	_pad: f32, // Ignored
}

render_attach_window :: proc(ctx: ^RenderContext, parent: rawptr) {
	render_detach_window(ctx)
	render_init_gpu_resources(ctx)

	windowPropId := sdl.CreateProperties()
	defer sdl.DestroyProperties(windowPropId)

	// Windower
	when ODIN_OS == .Windows do sdl.SetPointerProperty(windowPropId, sdl.PROP_WINDOW_CREATE_WIN32_HWND_POINTER, parent)
	when ODIN_OS == .Darwin do sdl.SetPointerProperty(windowPropId, sdl.PROP_WINDOW_CREATE_COCOA_VIEW_POINTER, parent)
	when ODIN_OS == .Linux do sdl.SetPointerProperty(windowPropId, sdl.PROP_WINDOW_CREATE_X11_EMBED_WINDOW_ID_POINTER, parent)

	// Render API
	when ODIN_OS == .Windows {
		// sdl.SetBooleanProperty(windowPropId, sdl.PROP_WINDOW_CREATE_, true)
	} else when ODIN_OS == .Linux {
		sdl.SetBooleanProperty(windowPropId, sdl.PROP_WINDOW_CREATE_VULKAN_BOOLEAN, true)
	}
	when ODIN_OS == .Darwin do sdl.SetBooleanProperty(windowPropId, sdl.PROP_WINDOW_CREATE_METAL_BOOLEAN, true)

	sdl.SetStringProperty(windowPropId, sdl.PROP_WINDOW_CREATE_TITLE_STRING, "Lindale")
	sdl.SetNumberProperty(windowPropId, sdl.PROP_WINDOW_CREATE_WIDTH_NUMBER, 800)
	sdl.SetNumberProperty(windowPropId, sdl.PROP_WINDOW_CREATE_HEIGHT_NUMBER, 600)

	// sdl.SetBooleanProperty(windowPropId, sdl.PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, false)
	// sdl.SetBooleanProperty(windowPropId, sdl.PROP_WINDOW_CREATE_MOUSE_GRABBED_BOOLEAN)
	sdl.SetNumberProperty(windowPropId, sdl.PROP_WINDOW_CREATE_FLAGS_NUMBER, i64(sdl.WINDOW_EXTERNAL))

	ctx.window = sdl.CreateWindowWithProperties(windowPropId)
	if ctx.window == nil {
		log.error("Failed to create SDL window")
		return
	}

	result := sdl.ClaimWindowForGPUDevice(ctx.gpu, ctx.window)
	assert(result == true)

	format := sdl.GetGPUSwapchainTextureFormat(ctx.gpu, ctx.window)
	if format != ctx.swapchainFormat {
		render_init_rect_pipeline(ctx, ctx.vertexShader, ctx.fragmentShader, format)
	}
}

render_detach_window :: proc (ctx: ^RenderContext) {
	if ctx.window != nil {
		sdl.HideWindow(ctx.window)
		sdl.ReleaseWindowFromGPUDevice(ctx.gpu, ctx.window)
		sdl.DestroyWindow(ctx.window)
		ctx.window = nil
	}
}

render_init_gpu_resources :: proc(ctx: ^RenderContext) {
	if ctx.gpuInitialized do return

	shaderFormat : sdl.GPUShaderFormat = {.SPIRV}
	when ODIN_OS == .Windows {
		shaderFormat = {.DXIL}
	} else when ODIN_OS == .Linux {
		shaderFormat = {.SPIRV}
	} else when ODIN_OS == .Darwin {
		shaderFormat = {.MSL}
	}
	ctx.gpu = sdl.CreateGPUDevice(shaderFormat, ODIN_DEBUG, nil)
	assert(ctx.gpu != nil)

	when ODIN_OS == .Windows {
		vShaderBits := #load("../shaders/vs.dxil")
		pShaderBits := #load("../shaders/ps.dxil")
	} else when ODIN_OS == .Linux {
		vShaderBits := #load("../shaders/vs.spv")
		pShaderBits := #load("../shaders/ps.spv")
	} else when ODIN_OS == .Darwin {
		vShaderBits := #load("../shaders/shader.metal")
		pShaderBits := #load("../shaders/shader.metal")
	}

	vertexCreate: sdl.GPUShaderCreateInfo
	vertexCreate.code_size = uint(len(vShaderBits))
	vertexCreate.code = &vShaderBits[0]
	vertexCreate.entrypoint = "VSMain"
	vertexCreate.format = shaderFormat
	vertexCreate.stage = .VERTEX
	vertexCreate.num_uniform_buffers = 1
	ctx.vertexShader = sdl.CreateGPUShader(ctx.gpu, vertexCreate)
	assert(ctx.vertexShader != nil)

	pixelCreate: sdl.GPUShaderCreateInfo
	pixelCreate.code_size = uint(len(pShaderBits))
	pixelCreate.code = &pShaderBits[0]
	pixelCreate.entrypoint = "PSMain"
	pixelCreate.format = shaderFormat
	pixelCreate.stage = .FRAGMENT
	pixelCreate.num_uniform_buffers = 1
	pixelCreate.num_samplers = 1
	ctx.fragmentShader = sdl.CreateGPUShader(ctx.gpu, pixelCreate)
	assert(ctx.fragmentShader != nil)

	render_init_rect_pipeline(ctx, ctx.vertexShader, ctx.fragmentShader)

	ctx.instanceBuffer = render_create_gpu_buffer(ctx, BUFFER_SIZE, {.VERTEX})

	// Create sampler
	sci: sdl.GPUSamplerCreateInfo
	sci.min_filter = .NEAREST
	sci.mag_filter = .NEAREST
	sci.mipmap_mode = .NEAREST
	sci.mip_lod_bias = 0
	sci.compare_op = .ALWAYS
	ctx.sampler = sdl.CreateGPUSampler(ctx.gpu, sci)
	assert(ctx.sampler != nil)

	ctx.gpuInitialized = true
}

render_cleanup :: proc(ctx: ^RenderContext) {
	render_detach_window(ctx)
}

@(deprecated = "Keeping temporarily for test host, needs to be removed later")
render_init :: proc(ctx: ^RenderContext) -> ^RenderContext {
	shaderFormat : sdl.GPUShaderFormat = {.SPIRV}
	when ODIN_OS == .Windows {
		shaderFormat = {.DXIL}
	} else when ODIN_OS == .Linux {
		shaderFormat = {.SPIRV}
	} else when ODIN_OS == .Darwin {
		shaderFormat = {.MSL}
	}
	ctx.gpu = sdl.CreateGPUDevice(shaderFormat, ODIN_DEBUG, nil)
	assert(ctx.gpu != nil)

	result := sdl.ClaimWindowForGPUDevice(ctx.gpu, ctx.window)
	assert(result == true)
	when ODIN_OS == .Windows {
		vShaderBits := #load("../shaders/vs.dxil")
		pShaderBits := #load("../shaders/ps.dxil")
	} else when ODIN_OS == .Linux {
		vShaderBits := #load("../shaders/vs.spv")
		pShaderBits := #load("../shaders/ps.spv")
	} else when ODIN_OS == .Darwin {
		vShaderBits := #load("../shaders/shader.metal")
		pShaderBits := #load("../shaders/shader.metal")
	}

	vertexCreate: sdl.GPUShaderCreateInfo
	vertexCreate.code_size = uint(len(vShaderBits))
	vertexCreate.code = &vShaderBits[0]
	vertexCreate.entrypoint = "VSMain"
	vertexCreate.format = shaderFormat
	vertexCreate.stage = .VERTEX
	vertexCreate.num_uniform_buffers = 1
	vertexShader := sdl.CreateGPUShader(ctx.gpu, vertexCreate)
	assert(vertexShader != nil)
	defer sdl.ReleaseGPUShader(ctx.gpu, vertexShader)
	fmt.println("Created vertex shader")

	pixelCreate: sdl.GPUShaderCreateInfo
	pixelCreate.code_size = uint(len(pShaderBits))
	pixelCreate.code = &pShaderBits[0]
	pixelCreate.entrypoint = "PSMain"
	pixelCreate.format = shaderFormat
	pixelCreate.stage = .FRAGMENT
	pixelCreate.num_uniform_buffers = 1
	pixelCreate.num_samplers = 1
	pixelShader := sdl.CreateGPUShader(ctx.gpu, pixelCreate)
	assert(pixelShader != nil)
	defer sdl.ReleaseGPUShader(ctx.gpu, pixelShader)
	fmt.println("Created pixel shader")

	format := sdl.GetGPUSwapchainTextureFormat(ctx.gpu, ctx.window)
	fmt.println("Format: ", format)

	render_init_rect_pipeline(ctx, vertexShader, pixelShader, format)

	ctx.instanceBuffer = render_create_gpu_buffer(ctx, BUFFER_SIZE, {.VERTEX})

	// Create sampler
	sci: sdl.GPUSamplerCreateInfo
	sci.min_filter = .NEAREST
	sci.mag_filter = .NEAREST
	sci.mipmap_mode = .NEAREST
	sci.mip_lod_bias = 0
	sci.compare_op = .ALWAYS
	ctx.sampler = sdl.CreateGPUSampler(ctx.gpu, sci)
	assert(ctx.sampler != nil)
	
	sdl.ShowWindow(ctx.window)

	return ctx
}

DEFAULT_SWAPCHAIN_FORMAT : sdl.GPUTextureFormat : .B8G8R8A8_UNORM

render_init_rect_pipeline :: proc(
		ctx: ^RenderContext,
		vertexShader, pixelShader: ^sdl.GPUShader,
		swapchainFormat: sdl.GPUTextureFormat = DEFAULT_SWAPCHAIN_FORMAT) {
	if ctx.pipeline != nil {
		sdl.ReleaseGPUGraphicsPipeline(ctx.gpu, ctx.pipeline)
		ctx.pipeline = nil
	}

	blendState: sdl.GPUColorTargetBlendState
	blendState.enable_blend = true
	blendState.src_color_blendfactor = .SRC_ALPHA
	blendState.dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA
	blendState.color_blend_op = .ADD
	blendState.src_alpha_blendfactor = .ONE
	blendState.dst_alpha_blendfactor = .ZERO
	blendState.alpha_blend_op = .ADD

	desc : sdl.GPUColorTargetDescription
	desc.format = swapchainFormat
	desc.blend_state = blendState
	ctx.swapchainFormat = swapchainFormat

	pipelineCreate: sdl.GPUGraphicsPipelineCreateInfo
	pipelineCreate.target_info.num_color_targets = 1
	pipelineCreate.target_info.color_target_descriptions = &desc
	pipelineCreate.primitive_type = .TRIANGLESTRIP
	pipelineCreate.vertex_shader = vertexShader
	pipelineCreate.fragment_shader = pixelShader

	vbDesc: sdl.GPUVertexBufferDescription
	vbDesc.slot = 0
	vbDesc.input_rate = .INSTANCE
	vbDesc.pitch = size_of(RectInstance)
	#assert(size_of(RectInstance) == 56)

	vertexInputState: sdl.GPUVertexInputState

	vaDesc: [7]sdl.GPUVertexAttribute
	vaDesc[0] = sdl.GPUVertexAttribute{location = 0, offset = 0 * size_of(f32), buffer_slot = 0, format = .FLOAT2}
	vaDesc[1] = sdl.GPUVertexAttribute{location = 1, offset = 2 * size_of(f32), buffer_slot = 0, format = .FLOAT2}
	vaDesc[2] = sdl.GPUVertexAttribute{location = 2, offset = 4 * size_of(f32), buffer_slot = 0, format = .FLOAT2}
	vaDesc[3] = sdl.GPUVertexAttribute{location = 3, offset = 6 * size_of(f32), buffer_slot = 0, format = .FLOAT2}
	vaDesc[4] = sdl.GPUVertexAttribute{location = 4, offset = 8 * size_of(f32), buffer_slot = 0, format = .UBYTE4_NORM}
	vaDesc[5] = sdl.GPUVertexAttribute{location = 5, offset = 9 * size_of(f32), buffer_slot = 0, format = .UBYTE4_NORM}
	vaDesc[6] = sdl.GPUVertexAttribute{location = 6, offset = 10 * size_of(f32), buffer_slot = 0, format = .FLOAT4}
	vertexInputState.num_vertex_attributes = 7

	vertexInputState.num_vertex_buffers = 1
	vertexInputState.vertex_buffer_descriptions = &vbDesc
	vertexInputState.vertex_attributes = &vaDesc[0]
	pipelineCreate.vertex_input_state = vertexInputState

	pipelineCreate.rasterizer_state.fill_mode = .FILL
	pipelineCreate.rasterizer_state.front_face = .CLOCKWISE
	ctx.pipeline = sdl.CreateGPUGraphicsPipeline(ctx.gpu, pipelineCreate)
	if ctx.pipeline == nil {
		str := sdl.GetError()
		fmt.println(str)
	}
	assert(ctx.pipeline != nil)
}

render_create_gpu_buffer :: proc(ctx: ^RenderContext, sizeInBytes: u32, usage: sdl.GPUBufferUsageFlags) -> GraphicsBuffer {
	bufferCreate: sdl.GPUBufferCreateInfo
	bufferCreate.size = sizeInBytes
	bufferCreate.usage = usage
	buffer := sdl.CreateGPUBuffer(ctx.gpu, bufferCreate)
	assert(buffer != nil)
	return GraphicsBuffer{buffer, sizeInBytes, 0, 0, usage}
}

InstanceUploadContext :: struct {
	transferBufferPtr: rawptr,
	instanceFill: []RectInstance,
}

render_begin_instance_upload :: proc(ctx: ^RenderContext, instanceCount: u32) -> InstanceUploadContext {
	buffer := &ctx.instanceBuffer
	size := u32(instanceCount * size_of(RectInstance))
	assert(size <= buffer.capacity)
	transferBufferCreate: sdl.GPUTransferBufferCreateInfo
	transferBufferCreate.usage = .UPLOAD
	transferBufferCreate.size = size
	transferBuffer := sdl.CreateGPUTransferBuffer(ctx.gpu, transferBufferCreate)
	assert(transferBuffer != nil)

	transferData := sdl.MapGPUTransferBuffer(ctx.gpu, transferBuffer, false)
	assert(transferData != nil)

	buffer.size = size
	buffer.count = u32(instanceCount)

	return {rawptr(transferBuffer), ([^]RectInstance)(transferData)[:instanceCount]}
}

render_end_instance_upload :: proc(ctx: ^RenderContext, uploadCtx: InstanceUploadContext) {
	buffer := &ctx.instanceBuffer
	cmdBuf := ctx.cmdBuf
	if ctx.cmdBuf == nil {
		cmdBuf = sdl.AcquireGPUCommandBuffer(ctx.gpu)
	}
	copyPass := sdl.BeginGPUCopyPass(cmdBuf)
	transferBuffer := cast(^sdl.GPUTransferBuffer)uploadCtx.transferBufferPtr

	tbl := sdl.GPUTransferBufferLocation{transfer_buffer = transferBuffer, offset = 0}
	gbr := sdl.GPUBufferRegion{buffer = buffer.handle, offset = 0, size = buffer.size}
	sdl.UploadToGPUBuffer(copyPass, tbl, gbr, false)

	sdl.EndGPUCopyPass(copyPass)
	sdl.ReleaseGPUTransferBuffer(ctx.gpu, transferBuffer)
}

render_create_texture :: proc(ctx: ^RenderContext, bytesPerPixel: u32, format: sdl.GPUTextureFormat, w, h: u32) -> Texture2D {
	textureCreate: sdl.GPUTextureCreateInfo
	textureCreate.type = .D2
	textureCreate.format = format
	textureCreate.usage = {.SAMPLER}
	textureCreate.width = w
	textureCreate.height = h
	textureCreate.layer_count_or_depth = 1
	textureCreate.num_levels = 1
	texture := sdl.CreateGPUTexture(ctx.gpu, textureCreate)
	assert(texture != nil)

	tex2d: Texture2D
	tex2d.texHandle = texture
	tex2d.w = w
	tex2d.h = h
	tex2d.bytesPerPixel = bytesPerPixel
	if tex2d.bytesPerPixel == 1 do tex2d.singleChannelTexture = true

	return tex2d
}

// NOTE: Only should call within frame render typically
render_upload_texture :: proc(ctx: ^RenderContext, tex: ^Texture2D, data: []byte) {
	transferBufferCreate: sdl.GPUTransferBufferCreateInfo
	transferBufferCreate.usage = .UPLOAD
	transferBufferCreate.size = u32(len(data))
	transferBuffer := sdl.CreateGPUTransferBuffer(ctx.gpu, transferBufferCreate)
	assert(transferBuffer != nil)

	transferData := sdl.MapGPUTransferBuffer(ctx.gpu, transferBuffer, false)
	assert(transferData != nil)

	mem.copy(transferData, raw_data(data), len(data))

	sdl.UnmapGPUTransferBuffer(ctx.gpu, transferBuffer)

	cmdBuf := ctx.cmdBuf
	if ctx.cmdBuf == nil {
		cmdBuf = sdl.AcquireGPUCommandBuffer(ctx.gpu)
	}
	
	copyPass := sdl.BeginGPUCopyPass(cmdBuf)

	tbl := sdl.GPUTransferBufferLocation{transfer_buffer = transferBuffer, offset = 0}
	tti := sdl.GPUTextureTransferInfo{transfer_buffer = transferBuffer, offset = 0, pixels_per_row = tex.w, rows_per_layer = tex.h}
	tr := sdl.GPUTextureRegion{texture = tex.texHandle, mip_level = 0, layer = 0, x = 0, y = 0, z = 0, w = tex.w, h = tex.h, d = 1}
	sdl.UploadToGPUTexture(copyPass, tti, tr, false)

	sdl.EndGPUCopyPass(copyPass)
	if cmdBuf != ctx.cmdBuf {
		result := sdl.SubmitGPUCommandBuffer(cmdBuf)
		assert(result)
	}
	sdl.ReleaseGPUTransferBuffer(ctx.gpu, transferBuffer)

	tex.uploaded = true
}

render_create_texture_from_file :: proc(ctx: ^RenderContext, file: []u8) -> Texture2D {
	x, y, channels: c.int
	tex: Texture2D

	bits := stbi.load_from_memory(raw_data(file), i32(len(file)), &x, &y, &channels, 4)

	tex = render_create_texture(ctx, u32(channels), .R8G8B8A8_UNORM, u32(x), u32(y))
	render_upload_texture(ctx, &tex, bits[:channels * x * y])

	return tex
}

render_frame_begin :: proc(ctx: ^RenderContext) -> bool {
	if ctx.cmdBuf == nil {
		ctx.cmdBuf = sdl.AcquireGPUCommandBuffer(ctx.gpu)
		assert(ctx.cmdBuf != nil)
	}

	result := sdl.WaitAndAcquireGPUSwapchainTexture(ctx.cmdBuf, ctx.window, &ctx.swapchainTexture, nil, nil)
	assert(result == true)
	assert(ctx.swapchainTexture != nil)
	return true
}

render_frame_end :: proc(ctx: ^RenderContext) {
	result := sdl.SubmitGPUCommandBuffer(ctx.cmdBuf)
	assert(result)
	ctx.cmdBuf = nil
}

render_begin_pass :: proc(ctx: ^RenderContext, clearColor: ColorF32 = {0, 0, 0, 1}, clear: bool = true) {
	targetInfo: sdl.GPUColorTargetInfo
	targetInfo.texture = ctx.swapchainTexture
	targetInfo.clear_color = sdl.FColor(clearColor)
	targetInfo.load_op = clear? .CLEAR : .LOAD
	targetInfo.store_op = .STORE

	ctx.renderPass = sdl.BeginGPURenderPass(ctx.cmdBuf, &targetInfo, 1, nil)
	sdl.BindGPUGraphicsPipeline(ctx.renderPass, ctx.pipeline)
	instanceBinding := sdl.GPUBufferBinding{buffer = ctx.instanceBuffer.handle, offset = 0}
	sdl.BindGPUVertexBuffers(ctx.renderPass, 0, &instanceBinding, 1)
}

render_end_pass :: proc(ctx: ^RenderContext) {
	sdl.EndGPURenderPass(ctx.renderPass)
}

render_set_scissor :: proc(ctx: ^RenderContext, rect: RectI32) {
	sdlRect := sdl.Rect{x = rect.x, y = rect.y, w = rect.w, h = rect.h}
	if rect.x == 0 && rect.y == 0 && rect.w == 0 && rect.h == 0 {
		sdlRect.w = ctx.width
		sdlRect.h = ctx.height
	}
	sdl.SetGPUScissor(ctx.renderPass, sdlRect)
}

render_bind_texture :: proc(ctx: ^RenderContext, tex: ^Texture2D) {
	textureBinding : sdl.GPUTextureSamplerBinding
	textureBinding.texture = tex.texHandle
	textureBinding.sampler = ctx.sampler
	sdl.BindGPUFragmentSamplers(ctx.renderPass, 0, &textureBinding, 1)
	ctx.uniforms.singleChannelTexture = tex.singleChannelTexture? 1 : 0
}

render_draw_rects :: proc(ctx: ^RenderContext, instanceOffs, instanceCount: u32) {

	sdl.PushGPUVertexUniformData(ctx.cmdBuf, 0, rawptr(&ctx.uniforms), size_of(UniformBuffer))

	sdl.DrawGPUPrimitives(ctx.renderPass, 4, instanceCount, 0, instanceOffs)
}

render_set_single_channel_texture :: proc(ctx: ^RenderContext, singleChannelTexture: bool) {
	ctx.uniforms.singleChannelTexture = 1 if singleChannelTexture else 0
}

render_resize :: proc(ctx: ^RenderContext, w, h: i32) {
	ctx.width = w
	ctx.height = h
	ctx.uniforms.projMatrix = linalg.matrix_ortho3d_f32(0, f32(ctx.width), f32(ctx.height), 0, -1, 1)
}
