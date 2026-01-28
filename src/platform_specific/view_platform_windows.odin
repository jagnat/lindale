package platform_specific

import "core:fmt"
import "core:mem"
import "core:math/linalg"

import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"
import win "core:sys/windows"

import api "../platform_api"

shader_source := #load("../shaders/shader.hlsl", string)

TextureSlot :: struct {
	texture: ^d3d11.ITexture2D,
	srv: ^d3d11.IShaderResourceView,
	width: u32,
	height: u32,
	format: api.PixelFormat,
	inUse: bool,
}

DX11Renderer :: struct {
	hwnd: win.HWND,
	device: ^d3d11.IDevice,
	deviceContext: ^d3d11.IDeviceContext,
	swapChain: ^dxgi.ISwapChain,

	renderTargetView: ^d3d11.IRenderTargetView,

	vertexShader: ^d3d11.IVertexShader,
	pixelShader: ^d3d11.IPixelShader,
	inputLayout: ^d3d11.IInputLayout,

	instanceBuffer: ^d3d11.IBuffer,
	instanceCapacity: u32,

	uniformBuffer: ^d3d11.IBuffer,
	uniforms: api.UniformBuffer,

	textures: [api.MAX_TEXTURES]TextureSlot,
	nextTextureSlot: u32,
	sampler: ^d3d11.ISamplerState,

	blendState: ^d3d11.IBlendState,
	rasterizerState: ^d3d11.IRasterizerState,

	// logical = points for UI, physical = actual pixels
	logicalWidth: i32,
	logicalHeight: i32,
	scaleFactor: f32,
	physicalWidth: i32,
	physicalHeight: i32,

	whiteTexture: api.TextureHandle,
}

// Renderer lifecycle

renderer_create :: proc(parent: rawptr, width, height: i32) -> api.Renderer {
	if parent == nil do return nil

	hwnd := win.HWND(parent)
	renderer := new(DX11Renderer)
	renderer.hwnd = hwnd

	dpi := win.GetDpiForWindow(hwnd)
	renderer.scaleFactor = f32(dpi) / 96.0
	renderer.logicalWidth = width
	renderer.logicalHeight = height
	renderer.physicalWidth = i32(f32(width) * renderer.scaleFactor)
	renderer.physicalHeight = i32(f32(height) * renderer.scaleFactor)

	featureLevels := []d3d11.FEATURE_LEVEL{._11_0, ._10_1, ._10_0}
	deviceFlags: d3d11.CREATE_DEVICE_FLAGS = {}
	when ODIN_DEBUG {
		deviceFlags += {.DEBUG}
	}

	hr := d3d11.CreateDevice(
		nil,
		.HARDWARE,
		nil,
		deviceFlags,
		raw_data(featureLevels),
		u32(len(featureLevels)),
		d3d11.SDK_VERSION,
		&renderer.device,
		nil,
		&renderer.deviceContext,
	)
	if hr < 0 {
		free(renderer)
		return nil
	}

	dxgiDevice: ^dxgi.IDevice
	hr = renderer.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgiDevice))
	if hr < 0 {
		renderer.device->Release()
		free(renderer)
		return nil
	}
	defer dxgiDevice->Release()

	adapter: ^dxgi.IAdapter
	hr = dxgiDevice->GetAdapter(&adapter)
	if hr < 0 {
		renderer.device->Release()
		free(renderer)
		return nil
	}
	defer adapter->Release()

	factory: ^dxgi.IFactory
	hr = adapter->GetParent(dxgi.IFactory_UUID, (^rawptr)(&factory))
	if hr < 0 {
		renderer.device->Release()
		free(renderer)
		return nil
	}
	defer factory->Release()

	swapChainDesc := dxgi.SWAP_CHAIN_DESC{
		BufferDesc = {
			Width = u32(renderer.physicalWidth),
			Height = u32(renderer.physicalHeight),
			RefreshRate = {Numerator = 60, Denominator = 1},
			Format = .B8G8R8A8_UNORM,
		},
		SampleDesc = {Count = 1, Quality = 0},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		OutputWindow = hwnd,
		Windowed = true,
		SwapEffect = .DISCARD,
	}

	hr = factory->CreateSwapChain(renderer.device, &swapChainDesc, &renderer.swapChain)
	if hr < 0 {
		renderer.device->Release()
		free(renderer)
		return nil
	}

	if !create_render_target_view(renderer) {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}

	if !create_pipeline(renderer) {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}

	// 1MB instance buffer
	instanceBufferSize := api.MAX_INSTANCES * size_of(api.RectInstance)
	instanceBufferDesc := d3d11.BUFFER_DESC{
		ByteWidth = u32(instanceBufferSize),
		Usage = .DYNAMIC,
		BindFlags = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = renderer.device->CreateBuffer(&instanceBufferDesc, nil, &renderer.instanceBuffer)
	if hr < 0 {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}
	renderer.instanceCapacity = api.MAX_INSTANCES

	uniformBufferDesc := d3d11.BUFFER_DESC{
		ByteWidth = size_of(api.UniformBuffer),
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = renderer.device->CreateBuffer(&uniformBufferDesc, nil, &renderer.uniformBuffer)
	if hr < 0 {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}

	samplerDesc := d3d11.SAMPLER_DESC{
		Filter = .MIN_MAG_MIP_POINT,
		AddressU = .WRAP,
		AddressV = .WRAP,
		AddressW = .WRAP,
		ComparisonFunc = .NEVER,
		MinLOD = 0,
		MaxLOD = d3d11.FLOAT32_MAX,
	}
	hr = renderer.device->CreateSamplerState(&samplerDesc, &renderer.sampler)
	if hr < 0 {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}

	blendDesc := d3d11.BLEND_DESC{
		AlphaToCoverageEnable = false,
		IndependentBlendEnable = false,
		RenderTarget = {
			0 = {
				BlendEnable = true,
				SrcBlend = .SRC_ALPHA,
				DestBlend = .INV_SRC_ALPHA,
				BlendOp = .ADD,
				SrcBlendAlpha = .ONE,
				DestBlendAlpha = .ZERO,
				BlendOpAlpha = .ADD,
				RenderTargetWriteMask = 0xf,
			},
		},
	}
	hr = renderer.device->CreateBlendState(&blendDesc, &renderer.blendState)
	if hr < 0 {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}

	rasterizerDesc := d3d11.RASTERIZER_DESC{
		FillMode = .SOLID,
		CullMode = .NONE,
		FrontCounterClockwise = false,
		DepthClipEnable = false,
		ScissorEnable = true,
		MultisampleEnable = false,
		AntialiasedLineEnable = false,
	}
	hr = renderer.device->CreateRasterizerState(&rasterizerDesc, &renderer.rasterizerState)
	if hr < 0 {
		renderer_destroy(api.Renderer(renderer))
		return nil
	}

	renderer.nextTextureSlot = 1
	whitePixel := []u8{255, 255, 255, 255}
	renderer.whiteTexture = create_texture_internal(renderer, 1, 1, .RGBA8)
	upload_texture_internal(renderer, renderer.whiteTexture, whitePixel)

	resize_internal(renderer, width, height, renderer.scaleFactor)

	return api.Renderer(renderer)
}

renderer_destroy :: proc(r: api.Renderer) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return

	for &slot in renderer.textures {
		if slot.inUse {
			if slot.srv != nil do slot.srv->Release()
			if slot.texture != nil do slot.texture->Release()
		}
	}

	if renderer.rasterizerState != nil do renderer.rasterizerState->Release()
	if renderer.blendState != nil do renderer.blendState->Release()
	if renderer.sampler != nil do renderer.sampler->Release()
	if renderer.uniformBuffer != nil do renderer.uniformBuffer->Release()
	if renderer.instanceBuffer != nil do renderer.instanceBuffer->Release()
	if renderer.inputLayout != nil do renderer.inputLayout->Release()
	if renderer.pixelShader != nil do renderer.pixelShader->Release()
	if renderer.vertexShader != nil do renderer.vertexShader->Release()
	if renderer.renderTargetView != nil do renderer.renderTargetView->Release()
	if renderer.swapChain != nil do renderer.swapChain->Release()
	if renderer.deviceContext != nil do renderer.deviceContext->Release()
	if renderer.device != nil do renderer.device->Release()

	free(renderer)
}

renderer_resize :: proc(r: api.Renderer, width, height: i32) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return

	dpi := win.GetDpiForWindow(renderer.hwnd)
	scaleFactor := f32(dpi) / 96.0

	if renderer.renderTargetView != nil {
		renderer.renderTargetView->Release()
		renderer.renderTargetView = nil
	}

	physicalWidth := u32(f32(width) * scaleFactor)
	physicalHeight := u32(f32(height) * scaleFactor)
	renderer.swapChain->ResizeBuffers(0, physicalWidth, physicalHeight, .UNKNOWN, {})

	create_render_target_view(renderer)

	resize_internal(renderer, width, height, scaleFactor)
}

@(private)
resize_internal :: proc(renderer: ^DX11Renderer, logicalWidth, logicalHeight: i32, scaleFactor: f32) {
	renderer.logicalWidth = logicalWidth
	renderer.logicalHeight = logicalHeight
	renderer.scaleFactor = scaleFactor
	renderer.physicalWidth = i32(f32(logicalWidth) * scaleFactor)
	renderer.physicalHeight = i32(f32(logicalHeight) * scaleFactor)

	renderer.uniforms.projMatrix = linalg.matrix_ortho3d_f32(0, f32(logicalWidth), f32(logicalHeight), 0, -1, 1)
	renderer.uniforms.dims = {f32(logicalWidth), f32(logicalHeight)}
}

renderer_get_size :: proc(r: api.Renderer) -> api.RendererSize {
	renderer := cast(^DX11Renderer)r
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
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return api.INVALID_TEXTURE
	return create_texture_internal(renderer, width, height, format)
}

@(private)
create_texture_internal :: proc(renderer: ^DX11Renderer, width, height: u32, format: api.PixelFormat) -> api.TextureHandle {
	slot: u32 = 0
	for i in 1..<u32(api.MAX_TEXTURES) {
		if !renderer.textures[i].inUse {
			slot = i
			break
		}
	}
	if slot == 0 do return api.INVALID_TEXTURE

	dxgiFormat: dxgi.FORMAT
	switch format {
	case .RGBA8:
		dxgiFormat = .R8G8B8A8_UNORM
	case .R8:
		dxgiFormat = .R8_UNORM
	}

	textureDesc := d3d11.TEXTURE2D_DESC{
		Width = width,
		Height = height,
		MipLevels = 1,
		ArraySize = 1,
		Format = dxgiFormat,
		SampleDesc = {Count = 1, Quality = 0},
		Usage = .DEFAULT,
		BindFlags = {.SHADER_RESOURCE},
		CPUAccessFlags = {},
	}

	texture: ^d3d11.ITexture2D
	hr := renderer.device->CreateTexture2D(&textureDesc, nil, &texture)
	if hr < 0 do return api.INVALID_TEXTURE

	srvDesc := d3d11.SHADER_RESOURCE_VIEW_DESC{
		Format = dxgiFormat,
		ViewDimension = .TEXTURE2D,
		Texture2D = {MostDetailedMip = 0, MipLevels = 1},
	}

	srv: ^d3d11.IShaderResourceView
	hr = renderer.device->CreateShaderResourceView(texture, &srvDesc, &srv)
	if hr < 0 {
		texture->Release()
		return api.INVALID_TEXTURE
	}

	renderer.textures[slot] = TextureSlot{
		texture = texture,
		srv = srv,
		width = width,
		height = height,
		format = format,
		inUse = true,
	}

	return api.TextureHandle(slot)
}

renderer_destroy_texture :: proc(r: api.Renderer, handle: api.TextureHandle) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if handle == api.INVALID_TEXTURE do return
	if u32(handle) >= api.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if slot.inUse {
		if slot.srv != nil do slot.srv->Release()
		if slot.texture != nil do slot.texture->Release()
		slot^ = {}
	}
}

renderer_upload_texture :: proc(r: api.Renderer, handle: api.TextureHandle, pixels: []u8) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	upload_texture_internal(renderer, handle, pixels)
}

@(private)
upload_texture_internal :: proc(renderer: ^DX11Renderer, handle: api.TextureHandle, pixels: []u8) {
	if handle == api.INVALID_TEXTURE do return
	if u32(handle) >= api.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if !slot.inUse || slot.texture == nil do return

	bytesPerPixel: u32 = slot.format == .RGBA8 ? 4 : 1
	bytesPerRow := slot.width * bytesPerPixel

	box := d3d11.BOX{
		left = 0,
		top = 0,
		front = 0,
		right = slot.width,
		bottom = slot.height,
		back = 1,
	}

	renderer.deviceContext->UpdateSubresource(slot.texture, 0, &box, raw_data(pixels), bytesPerRow, 0)
}

renderer_get_white_texture :: proc(r: api.Renderer) -> api.TextureHandle {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return api.INVALID_TEXTURE
	return renderer.whiteTexture
}

// Frame rendering

renderer_begin_frame :: proc(r: api.Renderer) -> bool {
	return true
}

renderer_end_frame :: proc(r: api.Renderer) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if renderer.swapChain == nil do return

	renderer.swapChain->Present(1, {})
}

renderer_upload_instances :: proc(r: api.Renderer, instances: []api.RectInstance) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if len(instances) == 0 do return
	if u32(len(instances)) > renderer.instanceCapacity do return

	mappedResource: d3d11.MAPPED_SUBRESOURCE
	hr := renderer.deviceContext->Map(renderer.instanceBuffer, 0, .WRITE_DISCARD, {}, &mappedResource)
	if hr < 0 do return

	mem.copy(mappedResource.pData, raw_data(instances), len(instances) * size_of(api.RectInstance))
	renderer.deviceContext->Unmap(renderer.instanceBuffer, 0)
}

renderer_begin_pass :: proc(r: api.Renderer, clearColor: api.ColorF32) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if renderer.renderTargetView == nil do return

	clearColorArray := clearColor
	renderer.deviceContext->ClearRenderTargetView(renderer.renderTargetView, &clearColorArray)

	renderer.deviceContext->OMSetRenderTargets(1, &renderer.renderTargetView, nil)

	// physical pixels
	viewport := d3d11.VIEWPORT{
		TopLeftX = 0,
		TopLeftY = 0,
		Width = f32(renderer.physicalWidth),
		Height = f32(renderer.physicalHeight),
		MinDepth = 0,
		MaxDepth = 1,
	}
	renderer.deviceContext->RSSetViewports(1, &viewport)

	renderer.deviceContext->VSSetShader(renderer.vertexShader, nil, 0)
	renderer.deviceContext->PSSetShader(renderer.pixelShader, nil, 0)
	renderer.deviceContext->IASetInputLayout(renderer.inputLayout)

	stride := u32(size_of(api.RectInstance))
	offset: u32 = 0
	renderer.deviceContext->IASetVertexBuffers(0, 1, &renderer.instanceBuffer, &stride, &offset)

	renderer.deviceContext->IASetPrimitiveTopology(.TRIANGLESTRIP)

	blendFactor := [4]f32{0, 0, 0, 0}
	renderer.deviceContext->OMSetBlendState(renderer.blendState, &blendFactor, 0xffffffff)

	renderer.deviceContext->RSSetState(renderer.rasterizerState)
}

renderer_end_pass :: proc(r: api.Renderer) {
	// Nothing needed for immediate context
}

renderer_draw :: proc(r: api.Renderer, cmd: api.DrawCommand) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if cmd.instanceCount == 0 do return

	if cmd.scissor.w > 0 && cmd.scissor.h > 0 {
		scale := renderer.scaleFactor
		scissorRect := d3d11.RECT{
			left = i32(f32(cmd.scissor.x) * scale),
			top = i32(f32(cmd.scissor.y) * scale),
			right = i32(f32(cmd.scissor.x + cmd.scissor.w) * scale),
			bottom = i32(f32(cmd.scissor.y + cmd.scissor.h) * scale),
		}
		renderer.deviceContext->RSSetScissorRects(1, &scissorRect)
	} else {
		scissorRect := d3d11.RECT{
			left = 0,
			top = 0,
			right = renderer.physicalWidth,
			bottom = renderer.physicalHeight,
		}
		renderer.deviceContext->RSSetScissorRects(1, &scissorRect)
	}

	renderer.uniforms.singleChannelTexture = cmd.singleChannelTexture ? 1 : 0

	mappedResource: d3d11.MAPPED_SUBRESOURCE
	hr := renderer.deviceContext->Map(renderer.uniformBuffer, 0, .WRITE_DISCARD, {}, &mappedResource)
	if hr >= 0 {
		mem.copy(mappedResource.pData, &renderer.uniforms, size_of(api.UniformBuffer))
		renderer.deviceContext->Unmap(renderer.uniformBuffer, 0)
	}

	renderer.deviceContext->VSSetConstantBuffers(0, 1, &renderer.uniformBuffer)
	renderer.deviceContext->PSSetConstantBuffers(0, 1, &renderer.uniformBuffer)

	textureHandle := cmd.texture
	if textureHandle == api.INVALID_TEXTURE {
		textureHandle = renderer.whiteTexture
	}

	if u32(textureHandle) < api.MAX_TEXTURES {
		slot := &renderer.textures[textureHandle]
		if slot.inUse && slot.srv != nil {
			renderer.deviceContext->PSSetShaderResources(0, 1, &slot.srv)
			renderer.deviceContext->PSSetSamplers(0, 1, &renderer.sampler)
		}
	}

	// 4 vertices per instance (triangle strip quad)
	renderer.deviceContext->DrawInstanced(4, cmd.instanceCount, 0, cmd.instanceOffset)
}

// Pipeline creation

@(private)
create_render_target_view :: proc(renderer: ^DX11Renderer) -> bool {
	backBuffer: ^d3d11.ITexture2D
	hr := renderer.swapChain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&backBuffer))
	if hr < 0 do return false
	defer backBuffer->Release()

	hr = renderer.device->CreateRenderTargetView(backBuffer, nil, &renderer.renderTargetView)
	return hr >= 0
}

@(private)
create_pipeline :: proc(renderer: ^DX11Renderer) -> bool {
	vsBlob: ^d3dc.ID3DBlob
	errorBlob: ^d3dc.ID3DBlob
	defer if vsBlob != nil do vsBlob->Release()
	defer if errorBlob != nil do errorBlob->Release()

	shaderDefines := []d3dc.SHADER_MACRO{
		{Name = "VERTEX", Definition = "1"},
		{},
	}

	hr := d3dc.Compile(
		raw_data(shader_source),
		len(shader_source),
		"shader.hlsl",
		raw_data(shaderDefines),
		nil,
		"VSMain",
		"vs_5_0",
		transmute(u32)d3dc.D3DCOMPILE{.ENABLE_STRICTNESS},
		0,
		&vsBlob,
		&errorBlob,
	)
	if hr < 0 {
		if errorBlob != nil {
			errorSize := errorBlob->GetBufferSize()
			errorData := ([^]byte)(errorBlob->GetBufferPointer())[:errorSize]
			fmt.println("VS compile error:", string(errorData))
		}
		return false
	}

	hr = renderer.device->CreateVertexShader(
		vsBlob->GetBufferPointer(),
		vsBlob->GetBufferSize(),
		nil,
		&renderer.vertexShader,
	)
	if hr < 0 do return false

	psBlob: ^d3dc.ID3DBlob
	defer if psBlob != nil do psBlob->Release()

	psDefines := []d3dc.SHADER_MACRO{
		{},
	}

	hr = d3dc.Compile(
		raw_data(shader_source),
		len(shader_source),
		"shader.hlsl",
		raw_data(psDefines),
		nil,
		"PSMain",
		"ps_5_0",
		transmute(u32)d3dc.D3DCOMPILE{.ENABLE_STRICTNESS},
		0,
		&psBlob,
		&errorBlob,
	)
	if hr < 0 {
		if errorBlob != nil {
			errorSize := errorBlob->GetBufferSize()
			errorData := ([^]byte)(errorBlob->GetBufferPointer())[:errorSize]
			fmt.println("PS compile error:", string(errorData))
		}
		return false
	}

	hr = renderer.device->CreatePixelShader(
		psBlob->GetBufferPointer(),
		psBlob->GetBufferSize(),
		nil,
		&renderer.pixelShader,
	)
	if hr < 0 do return false

	inputElements := []d3d11.INPUT_ELEMENT_DESC{
		{SemanticName = "TEXCOORD", SemanticIndex = 0, Format = .R32G32_FLOAT, InputSlot = 0, AlignedByteOffset = 0, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		{SemanticName = "TEXCOORD", SemanticIndex = 1, Format = .R32G32_FLOAT, InputSlot = 0, AlignedByteOffset = 8, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		{SemanticName = "TEXCOORD", SemanticIndex = 2, Format = .R32G32_FLOAT, InputSlot = 0, AlignedByteOffset = 16, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		{SemanticName = "TEXCOORD", SemanticIndex = 3, Format = .R32G32_FLOAT, InputSlot = 0, AlignedByteOffset = 24, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		{SemanticName = "TEXCOORD", SemanticIndex = 4, Format = .R8G8B8A8_UNORM, InputSlot = 0, AlignedByteOffset = 32, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		{SemanticName = "TEXCOORD", SemanticIndex = 5, Format = .R8G8B8A8_UNORM, InputSlot = 0, AlignedByteOffset = 36, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		{SemanticName = "TEXCOORD", SemanticIndex = 6, Format = .R32G32B32A32_FLOAT, InputSlot = 0, AlignedByteOffset = 40, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
	}

	hr = renderer.device->CreateInputLayout(
		raw_data(inputElements),
		u32(len(inputElements)),
		vsBlob->GetBufferPointer(),
		vsBlob->GetBufferSize(),
		&renderer.inputLayout,
	)
	if hr < 0 do return false

	return true
}
