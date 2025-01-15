package lindale

import "core:fmt"
import "core:os"
import sdl "thirdparty/sdl3"
// import "vendor:"

ProgramContext :: struct {
	window: sdl.Window,
	gpuDevice: sdl.GPUDevice,
	audioDevice: sdl.AudioDeviceID,
	pipeline: sdl.GPUGraphicsPipeline,
	vertexBuffer: sdl.GPUBuffer,
}

PosColorVertex :: struct {
	x, y, z: f32,
	r, g, b, a: u8,
}

_ctx: ProgramContext

main :: proc() {

	init()
	fmt.println("Successful Init")

	result: b8

	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			eventType := sdl.EventType(event.type)
			#partial switch eventType {
			case .EVENT_QUIT:
				os.exit(0)
			case .EVENT_KEY_DOWN:
				if event.key.scancode == .SCANCODE_ESCAPE {
					sdl.Quit()
				}
			}
		}

		cmdBuf := sdl.AcquireGPUCommandBuffer(_ctx.gpuDevice)
		assert(cmdBuf != nil)

		swapchainTexture : ^sdl.GPUTexture

		result = sdl.WaitAndAcquireGPUSwapchainTexture(cmdBuf, _ctx.window, &swapchainTexture, nil, nil)
		assert(result == true)
		assert(swapchainTexture != nil)

		targetInfo: sdl.GPUColorTargetInfo
		targetInfo.texture = swapchainTexture
		targetInfo.clear_color = sdl.FColor{0.157, 0.161, 0.137, 1}
		targetInfo.load_op = .GPU_LOADOP_CLEAR
		targetInfo.store_op = .GPU_STOREOP_STORE

		renderPass := sdl.BeginGPURenderPass(cmdBuf, &targetInfo, 1, nil)
		sdl.BindGPUGraphicsPipeline(renderPass, _ctx.pipeline)
		bufferBinding := sdl.GPUBufferBinding{buffer = _ctx.vertexBuffer, offset = 0}
		sdl.BindGPUVertexBuffers(renderPass, 0, &bufferBinding, 1)

		sdl.DrawGPUPrimitives(renderPass,3, 1, 0, 0)
		
		sdl.EndGPURenderPass(renderPass)

		sdl.SubmitGPUCommandBuffer(cmdBuf)
	}
}

init :: proc() {
	result := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO)
	assert(result == true)

	_ctx.window = sdl.CreateWindow("Lindalë", 1600, 1000, sdl.WINDOW_HIDDEN)
	assert(_ctx.window != nil)

	_ctx.gpuDevice = sdl.CreateGPUDevice(.SPIRV, ODIN_DEBUG, nil)
	assert(_ctx.gpuDevice != nil)

	result = sdl.ClaimWindowForGPUDevice(_ctx.gpuDevice, _ctx.window)
	assert(result == true)

	vShaderBits := #load("shaders/vs.spv")

	vertexCreate: sdl.GPUShaderCreateInfo
	vertexCreate.code_size = u64(len(vShaderBits))
	vertexCreate.code = &vShaderBits[0]
	vertexCreate.entrypoint = "VSMain"
	vertexCreate.format = .SPIRV
	vertexCreate.stage = .GPU_SHADERSTAGE_VERTEX
	vertexShader := sdl.CreateGPUShader(_ctx.gpuDevice, &vertexCreate)
	assert(vertexShader != nil)
	defer sdl.ReleaseGPUShader(_ctx.gpuDevice, vertexShader)
	fmt.println("Created vertex shader")

	pShaderBits := #load("shaders/ps.spv")

	pixelCreate: sdl.GPUShaderCreateInfo
	pixelCreate.code_size = u64(len(pShaderBits))
	pixelCreate.code = &pShaderBits[0]
	pixelCreate.entrypoint = "PSMain"
	pixelCreate.format = .SPIRV
	pixelCreate.stage = .GPU_SHADERSTAGE_FRAGMENT
	pixelShader := sdl.CreateGPUShader(_ctx.gpuDevice, &pixelCreate)
	assert(pixelShader != nil)
	defer sdl.ReleaseGPUShader(_ctx.gpuDevice, pixelShader)
	fmt.println("Created pixel shader")

	colorFmt := sdl.GetGPUSwapchainTextureFormat(_ctx.gpuDevice, _ctx.window)
	desc : sdl.GPUColorTargetDescription
	desc.format = colorFmt
	fmt.println("Created swapchain")

	pipelineCreate: sdl.GPUGraphicsPipelineCreateInfo
	pipelineCreate.target_info.num_color_targets = 1
	pipelineCreate.target_info.color_target_descriptions = &desc
	pipelineCreate.primitive_type = .GPU_PRIMITIVETYPE_TRIANGLELIST
	pipelineCreate.vertex_shader = vertexShader
	pipelineCreate.fragment_shader = pixelShader

	vbDesc: sdl.GPUVertexBufferDescription
	vbDesc.slot = 0
	vbDesc.input_rate = .GPU_VERTEXINPUTRATE_VERTEX
	vbDesc.pitch = size_of(PosColorVertex)

	vaDesc: [2]sdl.GPUVertexAttribute
	vaDesc[0] = sdl.GPUVertexAttribute{location = 0, offset = 0, buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_FLOAT3}
	vaDesc[1] = sdl.GPUVertexAttribute{location = 1, offset = 3 * size_of(f32), buffer_slot = 0, format = .GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM}

	vertexInputState: sdl.GPUVertexInputState
	vertexInputState.num_vertex_buffers = 1
	vertexInputState.vertex_buffer_descriptions = &vbDesc
	vertexInputState.num_vertex_attributes = 2
	vertexInputState.vertex_attributes = &vaDesc[0]

	pipelineCreate.vertex_input_state = vertexInputState

	pipelineCreate.rasterizer_state.fill_mode = .GPU_FILLMODE_FILL
	_ctx.pipeline = sdl.CreateGPUGraphicsPipeline(_ctx.gpuDevice, &pipelineCreate)
	assert(_ctx.pipeline != nil)
	fmt.println("Created GPU pipeline")

	// Create vertex buffer
	bufferCreate: sdl.GPUBufferCreateInfo
	bufferCreate.size = 3 * size_of(PosColorVertex)
	bufferCreate.usage = .VERTEX
	_ctx.vertexBuffer = sdl.CreateGPUBuffer(_ctx.gpuDevice, &bufferCreate)
	assert(_ctx.vertexBuffer != nil)

	transferBufferCreate: sdl.GPUTransferBufferCreateInfo
	transferBufferCreate.usage = .GPU_TRANSFERBUFFERUSAGE_UPLOAD
	transferBufferCreate.size = 3 * size_of(PosColorVertex)
	transferBuffer := sdl.CreateGPUTransferBuffer(_ctx.gpuDevice, &transferBufferCreate)
	assert(transferBuffer != nil)

	transferData: []PosColorVertex = ([^]PosColorVertex)(sdl.MapGPUTransferBuffer(_ctx.gpuDevice, transferBuffer, false))[:3]
	transferData[0] = PosColorVertex {    -1,    -1, 0, 255,   0,   0, 255 }
	transferData[1] = PosColorVertex {     1,    -1, 0,   0, 255,   0, 255 }
	transferData[2] = PosColorVertex {     0,     1, 0,   0,   0, 255, 255 }

	sdl.UnmapGPUTransferBuffer(_ctx.gpuDevice, transferBuffer)

	cmdBuf := sdl.AcquireGPUCommandBuffer(_ctx.gpuDevice)
	copyPass := sdl.BeginGPUCopyPass(cmdBuf)

	tbl := sdl.GPUTransferBufferLocation{transfer_buffer = transferBuffer, offset = 0}
	gbr := sdl.GPUBufferRegion{buffer = _ctx.vertexBuffer, offset = 0, size = 3 * size_of(PosColorVertex)}
	sdl.UploadToGPUBuffer(copyPass, &tbl, &gbr, false)

	sdl.EndGPUCopyPass(copyPass)
	sdl.SubmitGPUCommandBuffer(cmdBuf)
	sdl.ReleaseGPUTransferBuffer(_ctx.gpuDevice, transferBuffer)

	sdl.ShowWindow(_ctx.window)
}