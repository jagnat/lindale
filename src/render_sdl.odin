package lindale

import "core:fmt"
import "core:mem"
import vm "core:mem/virtual"
import "core:slice"
import "core:math/linalg"
import "core:c"
import sdl "thirdparty/sdl3"
import stbi "vendor:stb/image"

clearColor: ColorF32 = {0.117647, 0.117647, 0.117647, 1}

RenderContext :: struct {
	gpu: sdl.GPUDevice,
	pipeline: sdl.GPUGraphicsPipeline,
	window: sdl.Window,
	instanceBuffer: GPUBuffer, // Instance buffer
	numInstances: int,
	width, height: f32,
	emptyTexture: Texture2D,
	sampler: sdl.GPUSampler,
	cmdBuf: sdl.GPUCommandBuffer,
	renderPass: sdl.GPURenderPass,
}

BUFFER_SIZE :: 1024 * 1024

@(private="file")
ctx: RenderContext

UniformBufferContents :: struct {
	projMatrix: linalg.Matrix4x4f32,
	dim: [2]f32,
}

GPUBuffer :: struct {
	handle: sdl.GPUBuffer,
	capacity: u32,
	size: u32,
	count: u32,
	usage: sdl.GPUBufferUsageFlags,
}

Texture2D :: struct {
	texHandle: sdl.GPUTexture,
	w, h: u32,
	bytesPerPixel: u32
}

RectInstance :: struct #packed {
	pos1: [2]f32, // Top left
	pos2: [2]f32, // Bottom right
	colors: [4]ColorU8, // top left, bottom left, top right, bottom right
	cornerRad: [4]f32, // Same order as above
}

render_init :: proc(window: sdl.Window) {
	ctx.window = window
	ctx.gpu = sdl.CreateGPUDevice(.SPIRV, ODIN_DEBUG, nil)
	assert(ctx.gpu != nil)

	result := sdl.ClaimWindowForGPUDevice(ctx.gpu, ctx.window)
	assert(result == true)

	vShaderBits := #load("shaders/vs.spv")

	vertexCreate: sdl.GPUShaderCreateInfo
	vertexCreate.code_size = u64(len(vShaderBits))
	vertexCreate.code = &vShaderBits[0]
	vertexCreate.entrypoint = "VSMain"
	vertexCreate.format = .SPIRV
	vertexCreate.stage = .GPU_SHADERSTAGE_VERTEX
	vertexCreate.num_uniform_buffers = 1
	vertexShader := sdl.CreateGPUShader(ctx.gpu, &vertexCreate)
	assert(vertexShader != nil)
	defer sdl.ReleaseGPUShader(ctx.gpu, vertexShader)
	fmt.println("Created vertex shader")

	pShaderBits := #load("shaders/ps.spv")

	pixelCreate: sdl.GPUShaderCreateInfo
	pixelCreate.code_size = u64(len(pShaderBits))
	pixelCreate.code = &pShaderBits[0]
	pixelCreate.entrypoint = "PSMain"
	pixelCreate.format = .SPIRV
	pixelCreate.stage = .GPU_SHADERSTAGE_FRAGMENT
	pixelCreate.num_samplers = 1
	pixelShader := sdl.CreateGPUShader(ctx.gpu, &pixelCreate)
	assert(pixelShader != nil)
	defer sdl.ReleaseGPUShader(ctx.gpu, pixelShader)
	fmt.println("Created pixel shader")

	render_init_rect_pipeline(vertexShader, pixelShader)

	ctx.instanceBuffer = render_create_gpu_buffer(BUFFER_SIZE, .VERTEX)

	ctx.emptyTexture = render_create_texture(4, .GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, 1, 1)
	textureData := []byte{255, 255, 255, 255}
	render_upload_texture(ctx.emptyTexture, textureData)

	// Create sampler
	sci: sdl.GPUSamplerCreateInfo
	sci.min_filter = .GPU_FILTER_NEAREST
	sci.mag_filter = .GPU_FILTER_NEAREST
	sci.mipmap_mode = .GPU_SAMPLERMIPMAPMODE_NEAREST
	sci.mip_lod_bias = 0
	sci.compare_op = .GPU_COMPAREOP_ALWAYS
	ctx.sampler = sdl.CreateGPUSampler(ctx.gpu, &sci)
	assert(ctx.sampler != nil)
}

render_init_rect_pipeline :: proc(vertexShader, pixelShader: rawptr) {
	blendState: sdl.GPUColorTargetBlendState
	blendState.enable_blend = true
	blendState.src_color_blendfactor = .GPU_BLENDFACTOR_SRC_ALPHA
	blendState.dst_color_blendfactor = .GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
	blendState.color_blend_op = .GPU_BLENDOP_ADD
	blendState.src_alpha_blendfactor = .GPU_BLENDFACTOR_ONE
	blendState.dst_alpha_blendfactor = .GPU_BLENDFACTOR_ZERO
	blendState.alpha_blend_op = .GPU_BLENDOP_ADD

	colorFmt := sdl.GetGPUSwapchainTextureFormat(ctx.gpu, ctx.window)
	desc : sdl.GPUColorTargetDescription
	desc.format = colorFmt
	desc.blend_state = blendState

	pipelineCreate: sdl.GPUGraphicsPipelineCreateInfo
	pipelineCreate.target_info.num_color_targets = 1
	pipelineCreate.target_info.color_target_descriptions = &desc
	pipelineCreate.primitive_type = .GPU_PRIMITIVETYPE_TRIANGLESTRIP
	pipelineCreate.vertex_shader = vertexShader
	pipelineCreate.fragment_shader = pixelShader

	vbDesc: sdl.GPUVertexBufferDescription
	vbDesc.slot = 0
	vbDesc.input_rate = .GPU_VERTEXINPUTRATE_INSTANCE
	vbDesc.instance_step_rate = 1
	vbDesc.pitch = size_of(RectInstance)

	vertexInputState: sdl.GPUVertexInputState

	vaDesc: [7]sdl.GPUVertexAttribute
	vaDesc[0] = sdl.GPUVertexAttribute{location = 0, offset = 0, buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_FLOAT2}
	vaDesc[1] = sdl.GPUVertexAttribute{location = 1, offset = 2 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_FLOAT2}
	vaDesc[2] = sdl.GPUVertexAttribute{location = 2, offset = 4 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM}
	vaDesc[3] = sdl.GPUVertexAttribute{location = 3, offset = 5 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM}
	vaDesc[4] = sdl.GPUVertexAttribute{location = 4, offset = 6 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM}
	vaDesc[5] = sdl.GPUVertexAttribute{location = 5, offset = 7 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM}
	vaDesc[6] = sdl.GPUVertexAttribute{location = 6, offset = 8 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_FLOAT4}
	vertexInputState.num_vertex_attributes = 7

	vertexInputState.num_vertex_buffers = 1
	vertexInputState.vertex_buffer_descriptions = &vbDesc
	vertexInputState.vertex_attributes = &vaDesc[0]
	pipelineCreate.vertex_input_state = vertexInputState

	pipelineCreate.rasterizer_state.fill_mode = .GPU_FILLMODE_FILL
	pipelineCreate.rasterizer_state.front_face = .GPU_FRONTFACE_CLOCKWISE
	ctx.pipeline = sdl.CreateGPUGraphicsPipeline(ctx.gpu, &pipelineCreate)
	assert(ctx.pipeline != nil)
	fmt.println("Created GPU pipeline")
}

render_create_gpu_buffer :: proc(sizeInBytes: u32, usage: sdl.GPUBufferUsageFlags) -> GPUBuffer {
	bufferCreate: sdl.GPUBufferCreateInfo
	bufferCreate.size = sizeInBytes
	bufferCreate.usage = usage
	buffer := sdl.CreateGPUBuffer(ctx.gpu, &bufferCreate)
	assert(buffer != nil)
	return GPUBuffer{buffer, sizeInBytes, 0, 0, usage}
}

render_upload_rect_draw_batch :: proc(batch: ^RectDrawBatch) {
	buffer := &ctx.instanceBuffer
	size := u32(batch.totalInstanceCount * size_of(RectInstance))
	assert(size <= buffer.capacity)
	transferBufferCreate: sdl.GPUTransferBufferCreateInfo
	transferBufferCreate.usage = .GPU_TRANSFERBUFFERUSAGE_UPLOAD
	transferBufferCreate.size = size
	transferBuffer := sdl.CreateGPUTransferBuffer(ctx.gpu, &transferBufferCreate)
	assert(transferBuffer != nil)

	transferData := sdl.MapGPUTransferBuffer(ctx.gpu, transferBuffer, false)
	assert(transferData != nil)

	transferPtr := ([^]RectInstance)(transferData)

	index := 0

	for chunk := batch.chunkFirst; chunk != nil; chunk = chunk.next {
		mem.copy(&transferPtr[index], &chunk.instancePool[0], chunk.instanceCount * size_of(RectInstance))
		index += chunk.instanceCount
	}

	cmdBuf := sdl.AcquireGPUCommandBuffer(ctx.gpu)
	copyPass := sdl.BeginGPUCopyPass(cmdBuf)

	tbl := sdl.GPUTransferBufferLocation{transfer_buffer = transferBuffer, offset = 0}
	gbr := sdl.GPUBufferRegion{buffer = buffer.handle, offset = 0, size = size}
	sdl.UploadToGPUBuffer(copyPass, &tbl, &gbr, false)

	sdl.EndGPUCopyPass(copyPass)
	sdl.SubmitGPUCommandBuffer(cmdBuf)
	sdl.ReleaseGPUTransferBuffer(ctx.gpu, transferBuffer)
	buffer.size = size
	buffer.count = u32(batch.totalInstanceCount)
}

render_upload_buffer_data :: proc(buffer: ^GPUBuffer, ary: []$T) {
	data := slice.to_bytes(ary)
	assert(u64(len(data)) < u64(buffer.capacity))
	transferBufferCreate: sdl.GPUTransferBufferCreateInfo
	transferBufferCreate.usage = .GPU_TRANSFERBUFFERUSAGE_UPLOAD
	transferBufferCreate.size = u32(len(data))
	transferBuffer := sdl.CreateGPUTransferBuffer(ctx.gpu, &transferBufferCreate)
	assert(transferBuffer != nil)

	transferData := sdl.MapGPUTransferBuffer(ctx.gpu, transferBuffer, false)
	assert(transferData != nil)

	mem.copy(transferData, raw_data(data), len(data))

	sdl.UnmapGPUTransferBuffer(ctx.gpu, transferBuffer)

	cmdBuf := sdl.AcquireGPUCommandBuffer(ctx.gpu)
	copyPass := sdl.BeginGPUCopyPass(cmdBuf)

	tbl := sdl.GPUTransferBufferLocation{transfer_buffer = transferBuffer, offset = 0}
	gbr := sdl.GPUBufferRegion{buffer = buffer.handle, offset = 0, size = u32(len(data))}
	sdl.UploadToGPUBuffer(copyPass, &tbl, &gbr, false)

	sdl.EndGPUCopyPass(copyPass)
	sdl.SubmitGPUCommandBuffer(cmdBuf)
	sdl.ReleaseGPUTransferBuffer(ctx.gpu, transferBuffer)
	buffer.size = u32(len(data))
}

render_upload_rect_instances :: proc(rects: []RectInstance) {
	render_upload_buffer_data(&ctx.instanceBuffer, rects)
	ctx.numInstances = len(rects)
}

render_create_texture :: proc(bpp: u32, format: sdl.GPUTextureFormat, w, h: u32) -> Texture2D {
	textureCreate: sdl.GPUTextureCreateInfo
	textureCreate.type = .GPU_TEXTURETYPE_2D
	textureCreate.format = format
	// TODO: Add more flags if needed (such as writing to texture)
	textureCreate.usage = (1 << 0) // SDL_GPU_TEXTUREUSAGE_SAMPLER
	textureCreate.width = w
	textureCreate.height = h
	textureCreate.layer_count_or_depth = 1
	textureCreate.num_levels = 1
	texture := sdl.CreateGPUTexture(ctx.gpu, &textureCreate)
	assert(texture != nil)

	tex2d: Texture2D
	tex2d.texHandle = texture
	tex2d.w = w
	tex2d.h = h
	tex2d.bytesPerPixel = bpp

	return tex2d
}

render_upload_texture :: proc(tex: Texture2D, data: []byte) {
	transferBufferCreate: sdl.GPUTransferBufferCreateInfo
	transferBufferCreate.usage = .GPU_TRANSFERBUFFERUSAGE_UPLOAD
	transferBufferCreate.size = u32(len(data))
	transferBuffer := sdl.CreateGPUTransferBuffer(ctx.gpu, &transferBufferCreate)
	assert(transferBuffer != nil)

	transferData := sdl.MapGPUTransferBuffer(ctx.gpu, transferBuffer, false)
	assert(transferData != nil)

	mem.copy(transferData, raw_data(data), len(data))

	sdl.UnmapGPUTransferBuffer(ctx.gpu, transferBuffer)

	cmdBuf := sdl.AcquireGPUCommandBuffer(ctx.gpu)
	copyPass := sdl.BeginGPUCopyPass(cmdBuf)

	tbl := sdl.GPUTransferBufferLocation{transfer_buffer = transferBuffer, offset = 0}
	tti := sdl.GPUTextureTransferInfo{transfer_buffer = transferBuffer, offset = 0, pixels_per_row = tex.w, rows_per_layer = tex.h}
	tr := sdl.GPUTextureRegion{texture = tex.texHandle, mip_level = 0, layer = 0, x = 0, y = 0, z = 0, w = tex.w, h = tex.h, d = 1}
	sdl.UploadToGPUTexture(copyPass, &tti, &tr, false)

	sdl.EndGPUCopyPass(copyPass)
	sdl.SubmitGPUCommandBuffer(cmdBuf)
	sdl.ReleaseGPUTransferBuffer(ctx.gpu, transferBuffer)
}

render_begin :: proc() {
	ctx.cmdBuf = sdl.AcquireGPUCommandBuffer(ctx.gpu)
	assert(ctx.cmdBuf != nil)

	swapchainTexture : ^sdl.GPUTexture

	result := sdl.WaitAndAcquireGPUSwapchainTexture(ctx.cmdBuf, ctx.window, &swapchainTexture, nil, nil)
	assert(result == true)
	assert(swapchainTexture != nil)

	targetInfo: sdl.GPUColorTargetInfo
	targetInfo.texture = swapchainTexture
	targetInfo.clear_color = sdl.FColor(clearColor)
	targetInfo.load_op = .GPU_LOADOP_CLEAR
	targetInfo.store_op = .GPU_STOREOP_STORE

	ctx.renderPass = sdl.BeginGPURenderPass(ctx.cmdBuf, &targetInfo, 1, nil)
}

render_draw_rects :: proc(scissor: bool = false) {
	scissorRect := sdl.Rect{x = 100, y = 100, w = i32(ctx.width - 200), h = i32(ctx.height - 200)}
	fullScissorRect := sdl.Rect{x = 0, y = 0, w = i32(ctx.width), h = i32(ctx.height)}
	if scissor {
		sdl.SetGPUScissor(ctx.renderPass, &scissorRect)
	} else {
		sdl.SetGPUScissor(ctx.renderPass, &fullScissorRect)
	}
	sdl.BindGPUGraphicsPipeline(ctx.renderPass, ctx.pipeline)
	instanceBinding := sdl.GPUBufferBinding{buffer = ctx.instanceBuffer.handle, offset = 0}
	sdl.BindGPUVertexBuffers(ctx.renderPass, 0, &instanceBinding, 1)

	textureBinding : sdl.GPUTextureSamplerBinding
	textureBinding.texture = ctx.emptyTexture.texHandle
	textureBinding.sampler = ctx.sampler
	sdl.BindGPUFragmentSamplers(ctx.renderPass, 0, &textureBinding, 1)

	unif: UniformBufferContents
	unif.projMatrix = linalg.matrix_ortho3d_f32(0, ctx.width, ctx.height, 0, -1, 1)

	sdl.PushGPUVertexUniformData(ctx.cmdBuf, 0, rawptr(&unif), size_of(UniformBufferContents))

	sdl.DrawGPUPrimitives(ctx.renderPass, 4, u32(ctx.instanceBuffer.count), 0, 0)
}

render_end :: proc() {
	sdl.EndGPURenderPass(ctx.renderPass)
	sdl.SubmitGPUCommandBuffer(ctx.cmdBuf)
}

render_resize :: proc(w, h: i32) {
	ctx.width = f32(w)
	ctx.height = f32(h)
}
