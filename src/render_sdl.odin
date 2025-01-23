package lindale

import "core:fmt"
import "core:mem"
import vm "core:mem/virtual"
import "core:slice"
import "core:math/linalg"
import sdl "thirdparty/sdl3"

clearColor: ColorF32

RenderContext :: struct {
	gpu: sdl.GPUDevice,
	pipeline: sdl.GPUGraphicsPipeline,
	window: sdl.Window,
	instanceBuffer: GPUBuffer, // Instance buffer
	width, height: f32,
}

BUFFER_SIZE :: 8192

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
	usage: sdl.GPUBufferUsageFlags,
}

PosColorVertex :: struct {
	x, y, z: f32,
	r, g, b, a: u8,
}

RectInstance :: struct {
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

	clearColor = {0.1333,0.1333,0.1333,1}

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
	pixelShader := sdl.CreateGPUShader(ctx.gpu, &pixelCreate)
	assert(pixelShader != nil)
	defer sdl.ReleaseGPUShader(ctx.gpu, pixelShader)
	fmt.println("Created pixel shader")

	render_init_rect_pipeline(vertexShader, pixelShader)

	ctx.instanceBuffer = render_create_gpu_buffer(BUFFER_SIZE, .VERTEX)

	transferData: [6]PosColorVertex

	v0 := PosColorVertex{10, 10, 0, 255, 0, 0, 255}
	v0_0 := PosColorVertex{10, 210, 0, 255, 0, 0, 255}
	v0_1 := PosColorVertex{210, 10, 0, 255, 0, 0, 255}
	v1 := PosColorVertex{210, 210, 0, 255, 0, 0, 255}
	transferData[0] = v0
	transferData[1] = v0_1
	transferData[2] = v0_0
	transferData[3] = v1
	transferData[4] = v0_0
	transferData[5] = v0_1

	red := ColorU8{100, 0, 0, 255}
	instanceData: [2] RectInstance
	instanceData[0].pos1 = {200, 200}
	instanceData[0].pos2 = {400, 400}
	instanceData[0].colors[0] = red
	instanceData[0].colors[1] = red
	instanceData[0].colors[2] = red
	instanceData[0].colors[3] = red

	instanceData[1].pos1 = {550, 550}
	instanceData[1].pos2 = {850, 850}
	instanceData[1].colors[0] = ColorU8{255, 0, 0, 255}
	instanceData[1].colors[1] = ColorU8{0, 0, 0, 0}
	instanceData[1].colors[2] = ColorU8{0, 0, 255, 255}
	instanceData[1].colors[3] = ColorU8{0, 0, 0, 255}

	render_upload_buffer_data(&ctx.instanceBuffer, instanceData[:])
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
	return GPUBuffer{buffer, sizeInBytes, 0, usage}
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

render_upload_rect_instances :: proc(data: rawptr, bytes: u32) {
	
}

render_render :: proc() {
	cmdBuf := sdl.AcquireGPUCommandBuffer(ctx.gpu)
	assert(cmdBuf != nil)

	swapchainTexture : ^sdl.GPUTexture

	result := sdl.WaitAndAcquireGPUSwapchainTexture(cmdBuf, ctx.window, &swapchainTexture, nil, nil)
	assert(result == true)
	assert(swapchainTexture != nil)

	targetInfo: sdl.GPUColorTargetInfo
	targetInfo.texture = swapchainTexture
	targetInfo.clear_color = sdl.FColor(clearColor)
	targetInfo.load_op = .GPU_LOADOP_CLEAR
	targetInfo.store_op = .GPU_STOREOP_STORE

	renderPass := sdl.BeginGPURenderPass(cmdBuf, &targetInfo, 1, nil)
	sdl.BindGPUGraphicsPipeline(renderPass, ctx.pipeline)
	instanceBinding := sdl.GPUBufferBinding{buffer = ctx.instanceBuffer.handle, offset = 0}
	sdl.BindGPUVertexBuffers(renderPass, 0, &instanceBinding, 1)

	unif: UniformBufferContents
	unif.projMatrix = linalg.matrix_ortho3d_f32(0, ctx.width, ctx.height, 0, -1, 1)

	sdl.PushGPUVertexUniformData(cmdBuf, 0, rawptr(&unif), size_of(UniformBufferContents))

	sdl.DrawGPUPrimitives(renderPass, 4, 2, 0, 0)
	
	sdl.EndGPURenderPass(renderPass)

	sdl.SubmitGPUCommandBuffer(cmdBuf)
}

render_resize :: proc(w, h: i32) {
	ctx.width = f32(w)
	ctx.height = f32(h)
}
