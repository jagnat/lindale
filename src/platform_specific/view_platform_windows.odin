package platform_specific

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:math/linalg"

import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"
import win "core:sys/windows"

import "../bridge"

// GetModuleHandleExW isn't bound in core:sys/windows
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	GetModuleHandleExW :: proc(flags: win.DWORD, module_name: win.LPCWSTR, module: ^win.HMODULE) -> win.BOOL ---
}

GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: 0x00000002
GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS       :: 0x00000004

shader_source := #load("../shaders/shader.hlsl", string)

@(private="file")
window_class_atom: win.ATOM

@(private="file")
arrow_cursor: win.HCURSOR

TextureSlot :: struct {
	texture: ^d3d11.ITexture2D,
	srv: ^d3d11.IShaderResourceView,
	width: u32,
	height: u32,
	format: bridge.PixelFormat,
	in_use: bool,
}

DX11Renderer :: struct {
	hwnd: win.HWND,        // Our child window
	parent_hwnd: win.HWND,  // DAW's parent window
	device: ^d3d11.IDevice,
	device_context: ^d3d11.IDeviceContext,
	swap_chain: ^dxgi.ISwapChain,

	render_target_view: ^d3d11.IRenderTargetView,

	vertex_shader: ^d3d11.IVertexShader,
	pixel_shader: ^d3d11.IPixelShader,
	input_layout: ^d3d11.IInputLayout,

	instance_buffer: ^d3d11.IBuffer,
	instance_capacity: u32,

	uniform_buffer: ^d3d11.IBuffer,
	uniforms: bridge.UniformBuffer,

	textures: [bridge.MAX_TEXTURES]TextureSlot,
	next_texture_slot: u32,
	sampler: ^d3d11.ISamplerState,

	blend_state: ^d3d11.IBlendState,
	rasterizer_state: ^d3d11.IRasterizerState,

	// logical = points for UI, physical = actual pixels
	logical_width: i32,
	logical_height: i32,
	scale_factor: f32,
	physical_width: i32,
	physical_height: i32,

	white_texture: bridge.TextureHandle,

	mouse: ^bridge.MouseState,
	on_repaint: proc "c" (rawptr),
	on_repaint_data: rawptr,
	parent_old_wnd_proc: win.WNDPROC,
	ctx: runtime.Context,
}

@(private="file")
prop_renderer: win.LPCWSTR = win.L("LindaleRenderer")

@(private)
parent_wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.LRESULT {
	renderer := transmute(^DX11Renderer)win.GetPropW(hwnd, prop_renderer)
	if renderer == nil {
		return win.DefWindowProcW(hwnd, msg, wParam, lParam)
	}

	if msg == win.WM_SIZE {
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)
	}

	return win.CallWindowProcW(renderer.parent_old_wnd_proc, hwnd, msg, wParam, lParam)
}

// Renderer lifecycle

// The plugin DLL's own module handle. Registering the window class against
// this (rather than the host's, via GetModuleHandleW(nil)) keys the class to
// this module, so Windows unregisters it automatically when the DLL unloads.
// FROM_ADDRESS resolves the module owning any address; window_class_atom is
// just a file-local symbol that lives in this DLL.
@(private="file")
self_module :: proc() -> win.HINSTANCE {
	hmod: win.HMODULE
	GetModuleHandleExW(
		GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		win.LPCWSTR(rawptr(&window_class_atom)),
		&hmod)
	return win.HINSTANCE(hmod)
}

@(private)
register_window_class :: proc() {
	if window_class_atom != 0 do return

	h_instance := self_module()
	arrow_cursor = win.LoadCursorW(nil, transmute(win.LPCWSTR)uintptr(32512))
	// a Win32 window class is process-global, so two
	// Lindale plugins in one host must not register the same name
	class_name := win.utf8_to_wstring(fmt.tprintf("LindalePlugin_%s\x00", bridge.BUILD_ID))

	wcex := win.WNDCLASSEXW{
		cbSize = size_of(win.WNDCLASSEXW),
		style = win.CS_DBLCLKS,
		lpfnWndProc = lindale_wndproc,
		hInstance = h_instance,
		lpszClassName = class_name,
		hCursor = arrow_cursor,
	}

	window_class_atom = win.RegisterClassExW(&wcex)
	//log.infof("Registered window class, atom: %d", window_class_atom)
}

renderer_create :: proc(parent: rawptr, width, height: i32) -> bridge.Renderer {
	//log.infof("renderer_create called: parent=%p, size=%dx%d", parent, width, height)

	if parent == nil do return nil

	parent_hwnd := win.HWND(parent)
	renderer := new(DX11Renderer)
	renderer.parent_hwnd = parent_hwnd
	renderer.ctx = context

	register_window_class()

	dpi := win.GetDpiForWindow(parent_hwnd)
	renderer.scale_factor = f32(dpi) / 96.0
	renderer.logical_width = width
	renderer.logical_height = height
	renderer.physical_width = i32(f32(width) * renderer.scale_factor)
	renderer.physical_height = i32(f32(height) * renderer.scale_factor)

	h_instance := self_module()

	renderer.hwnd = win.CreateWindowExW(
		0,
		transmute(win.LPCWSTR)uintptr(window_class_atom),
		nil,
		win.WS_CHILD | win.WS_VISIBLE,
		0, 0,
		renderer.physical_width, renderer.physical_height,
		parent_hwnd,
		nil,
		h_instance,
		nil,
	)

	if renderer.hwnd == nil {
		log.error("Failed to create child window")
		free(renderer)
		return nil
	}

	// Store renderer pointer in window user data so WndProc can find it
	win.SetWindowLongPtrW(renderer.hwnd, win.GWLP_USERDATA, transmute(win.LONG_PTR)renderer)

	log.infof("Created child HWND: %p, parent: %p, size: %dx%d", renderer.hwnd, parent_hwnd, renderer.physical_width, renderer.physical_height)

	// Subclass parent window to catch resize events
	win.SetPropW(parent_hwnd, prop_renderer, transmute(win.HANDLE)renderer)
	renderer.parent_old_wnd_proc = transmute(win.WNDPROC)win.SetWindowLongPtrW(parent_hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)parent_wndproc)

	feature_levels := []d3d11.FEATURE_LEVEL{._11_0, ._10_1, ._10_0}
	device_flags: d3d11.CREATE_DEVICE_FLAGS = {}
	when ODIN_DEBUG {
		device_flags += {.DEBUG}
	}

	hr := d3d11.CreateDevice(
		nil,
		.HARDWARE,
		nil,
		device_flags,
		raw_data(feature_levels),
		u32(len(feature_levels)),
		d3d11.SDK_VERSION,
		&renderer.device,
		nil,
		&renderer.device_context,
	)
	if hr < 0 {
		free(renderer)
		return nil
	}

	dxgi_device: ^dxgi.IDevice
	hr = renderer.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
	if hr < 0 {
		renderer.device->Release()
		free(renderer)
		return nil
	}
	defer dxgi_device->Release()

	adapter: ^dxgi.IAdapter
	hr = dxgi_device->GetAdapter(&adapter)
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

	swap_chain_desc := dxgi.SWAP_CHAIN_DESC{
		BufferDesc = {
			Width = u32(renderer.physical_width),
			Height = u32(renderer.physical_height),
			RefreshRate = {Numerator = 60, Denominator = 1},
			Format = .B8G8R8A8_UNORM,
		},
		SampleDesc = {Count = 1, Quality = 0},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		OutputWindow = renderer.hwnd,
		Windowed = true,
		SwapEffect = .DISCARD,
	}

	hr = factory->CreateSwapChain(renderer.device, &swap_chain_desc, &renderer.swap_chain)
	if hr < 0 {
		renderer.device->Release()
		free(renderer)
		return nil
	}

	if !create_render_target_view(renderer) {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	if !create_pipeline(renderer) {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	// 1MB instance buffer
	instance_buffer_size := bridge.MAX_INSTANCES * size_of(bridge.DrawInstance)
	instance_buffer_desc := d3d11.BUFFER_DESC{
		ByteWidth = u32(instance_buffer_size),
		Usage = .DYNAMIC,
		BindFlags = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = renderer.device->CreateBuffer(&instance_buffer_desc, nil, &renderer.instance_buffer)
	if hr < 0 {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}
	renderer.instance_capacity = bridge.MAX_INSTANCES

	uniform_buffer_desc := d3d11.BUFFER_DESC{
		ByteWidth = size_of(bridge.UniformBuffer),
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = renderer.device->CreateBuffer(&uniform_buffer_desc, nil, &renderer.uniform_buffer)
	if hr < 0 {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	sampler_desc := d3d11.SAMPLER_DESC{
		Filter = .MIN_MAG_MIP_POINT,
		AddressU = .WRAP,
		AddressV = .WRAP,
		AddressW = .WRAP,
		ComparisonFunc = .NEVER,
		MinLOD = 0,
		MaxLOD = d3d11.FLOAT32_MAX,
	}
	hr = renderer.device->CreateSamplerState(&sampler_desc, &renderer.sampler)
	if hr < 0 {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	blend_desc := d3d11.BLEND_DESC{
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
	hr = renderer.device->CreateBlendState(&blend_desc, &renderer.blend_state)
	if hr < 0 {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	rasterizer_desc := d3d11.RASTERIZER_DESC{
		FillMode = .SOLID,
		CullMode = .NONE,
		FrontCounterClockwise = false,
		DepthClipEnable = false,
		ScissorEnable = true,
		MultisampleEnable = false,
		AntialiasedLineEnable = false,
	}
	hr = renderer.device->CreateRasterizerState(&rasterizer_desc, &renderer.rasterizer_state)
	if hr < 0 {
		renderer_destroy(bridge.Renderer(renderer))
		return nil
	}

	renderer.next_texture_slot = 1
	white_pixel := []u8{255, 255, 255, 255}
	renderer.white_texture = create_texture_internal(renderer, 1, 1, .RGBA8)
	upload_texture_internal(renderer, renderer.white_texture, white_pixel)

	resize_internal(renderer, width, height, renderer.scale_factor)

	return bridge.Renderer(renderer)
}

renderer_destroy :: proc(r: bridge.Renderer) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return

	// Restore parent wndproc before destroying child
	if renderer.parent_hwnd != nil && renderer.parent_old_wnd_proc != nil {
		win.SetWindowLongPtrW(renderer.parent_hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)renderer.parent_old_wnd_proc)
		win.RemovePropW(renderer.parent_hwnd, prop_renderer)
	}

	if renderer.hwnd != nil {
		win.DestroyWindow(renderer.hwnd)
	}

	for &slot in renderer.textures {
		if slot.in_use {
			if slot.srv != nil do slot.srv->Release()
			if slot.texture != nil do slot.texture->Release()
		}
	}

	if renderer.rasterizer_state != nil do renderer.rasterizer_state->Release()
	if renderer.blend_state != nil do renderer.blend_state->Release()
	if renderer.sampler != nil do renderer.sampler->Release()
	if renderer.uniform_buffer != nil do renderer.uniform_buffer->Release()
	if renderer.instance_buffer != nil do renderer.instance_buffer->Release()
	if renderer.input_layout != nil do renderer.input_layout->Release()
	if renderer.pixel_shader != nil do renderer.pixel_shader->Release()
	if renderer.vertex_shader != nil do renderer.vertex_shader->Release()
	if renderer.render_target_view != nil do renderer.render_target_view->Release()
	if renderer.swap_chain != nil do renderer.swap_chain->Release()
	if renderer.device_context != nil do renderer.device_context->Release()
	if renderer.device != nil do renderer.device->Release()

	free(renderer)
}

renderer_set_mouse_state :: proc(r: bridge.Renderer, mouse: ^bridge.MouseState) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return

	renderer.mouse = mouse
	log.infof("renderer_set_mouse_state: renderer=%p, hwnd=%p, mouse=%p", renderer, renderer.hwnd, mouse)
}

renderer_set_repaint_callback :: proc(r: bridge.Renderer, callback: proc "c" (rawptr), data: rawptr) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	renderer.on_repaint = callback
	renderer.on_repaint_data = data
}

@(private)
get_mouse_pos :: #force_inline proc "contextless" (renderer: ^DX11Renderer, lParam: win.LPARAM) -> bridge.Vec2f {
	x := win.GET_X_LPARAM(lParam)
	y := win.GET_Y_LPARAM(lParam)
	scale := renderer.scale_factor
	return {f32(x) / scale, f32(y) / scale}
}

@(private)
WM_MOUSEHWHEEL :: 0x020E

@(private)
lindale_wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.LRESULT {
	renderer := transmute(^DX11Renderer)win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)
	if renderer == nil || renderer.mouse == nil {
		return win.DefWindowProcW(hwnd, msg, wParam, lParam)
	}

	switch msg {
	case win.WM_MOUSEMOVE:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_LBUTTONDOWN:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		renderer.mouse.down += {.Left}
		renderer.mouse.pressed += {.Left}
		win.SetCapture(hwnd)
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_LBUTTONDBLCLK:
		renderer.mouse.double_clicked += {.Left}

	case win.WM_LBUTTONUP:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		renderer.mouse.down -= {.Left}
		renderer.mouse.released += {.Left}
		if renderer.mouse.down == {} do win.ReleaseCapture()
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_RBUTTONDOWN:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		renderer.mouse.down += {.Right}
		renderer.mouse.pressed += {.Right}
		win.SetCapture(hwnd)
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_RBUTTONDBLCLK:
	renderer.mouse.double_clicked += {.Right}

	case win.WM_RBUTTONUP:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		renderer.mouse.down -= {.Right}
		renderer.mouse.released += {.Right}
		if renderer.mouse.down == {} do win.ReleaseCapture()
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_MBUTTONDOWN:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		renderer.mouse.down += {.Middle}
		renderer.mouse.pressed += {.Middle}
		win.SetCapture(hwnd)
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_MBUTTONUP:
		renderer.mouse.pos = get_mouse_pos(renderer, lParam)
		renderer.mouse.down -= {.Middle}
		renderer.mouse.released += {.Middle}
		if renderer.mouse.down == {} do win.ReleaseCapture()
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_MOUSEWHEEL:
		delta := win.GET_WHEEL_DELTA_WPARAM(wParam)
		renderer.mouse.scroll_delta.y += f32(delta) / 120.0
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case WM_MOUSEHWHEEL:
		delta := win.GET_WHEEL_DELTA_WPARAM(wParam)
		renderer.mouse.scroll_delta.x += f32(delta) / 120.0
		if renderer.on_repaint != nil do renderer.on_repaint(renderer.on_repaint_data)

	case win.WM_SETCURSOR:
		if win.LOWORD(u32(lParam)) == win.HTCLIENT {
			win.SetCursor(arrow_cursor)
			return 1
		}
	}

	return win.DefWindowProcW(hwnd, msg, wParam, lParam)
}

renderer_resize :: proc(r: bridge.Renderer, width, height: i32) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return

	dpi := win.GetDpiForWindow(renderer.hwnd)
	scale_factor := f32(dpi) / 96.0

	if renderer.render_target_view != nil {
		renderer.render_target_view->Release()
		renderer.render_target_view = nil
	}

	physical_width := u32(f32(width) * scale_factor)
	physical_height := u32(f32(height) * scale_factor)
	renderer.swap_chain->ResizeBuffers(0, physical_width, physical_height, .UNKNOWN, {})

	create_render_target_view(renderer)

	resize_internal(renderer, width, height, scale_factor)
}

@(private)
resize_internal :: proc(renderer: ^DX11Renderer, logical_width, logical_height: i32, scale_factor: f32) {
	renderer.logical_width = logical_width
	renderer.logical_height = logical_height
	renderer.scale_factor = scale_factor
	renderer.physical_width = i32(f32(logical_width) * scale_factor)
	renderer.physical_height = i32(f32(logical_height) * scale_factor)

	renderer.uniforms.proj_matrix = linalg.matrix_ortho3d_f32(0, f32(logical_width), f32(logical_height), 0, -1, 1)
	renderer.uniforms.dims = {f32(logical_width), f32(logical_height)}
}

renderer_get_size :: proc(r: bridge.Renderer) -> bridge.RendererSize {
	renderer := cast(^DX11Renderer)r
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
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return bridge.INVALID_TEXTURE
	return create_texture_internal(renderer, width, height, format)
}

@(private)
create_texture_internal :: proc(renderer: ^DX11Renderer, width, height: u32, format: bridge.PixelFormat) -> bridge.TextureHandle {
	slot: u32 = 0
	for i in 1..<u32(bridge.MAX_TEXTURES) {
		if !renderer.textures[i].in_use {
			slot = i
			break
		}
	}
	if slot == 0 do return bridge.INVALID_TEXTURE

	dxgi_format: dxgi.FORMAT
	switch format {
	case .RGBA8:
		dxgi_format = .R8G8B8A8_UNORM
	case .R8:
		dxgi_format = .R8_UNORM
	}

	texture_desc := d3d11.TEXTURE2D_DESC{
		Width = width,
		Height = height,
		MipLevels = 1,
		ArraySize = 1,
		Format = dxgi_format,
		SampleDesc = {Count = 1, Quality = 0},
		Usage = .DEFAULT,
		BindFlags = {.SHADER_RESOURCE},
		CPUAccessFlags = {},
	}

	texture: ^d3d11.ITexture2D
	hr := renderer.device->CreateTexture2D(&texture_desc, nil, &texture)
	if hr < 0 do return bridge.INVALID_TEXTURE

	srv_desc := d3d11.SHADER_RESOURCE_VIEW_DESC{
		Format = dxgi_format,
		ViewDimension = .TEXTURE2D,
		Texture2D = {MostDetailedMip = 0, MipLevels = 1},
	}

	srv: ^d3d11.IShaderResourceView
	hr = renderer.device->CreateShaderResourceView(texture, &srv_desc, &srv)
	if hr < 0 {
		texture->Release()
		return bridge.INVALID_TEXTURE
	}

	renderer.textures[slot] = TextureSlot{
		texture = texture,
		srv = srv,
		width = width,
		height = height,
		format = format,
		in_use = true,
	}

	return bridge.TextureHandle(slot)
}

renderer_destroy_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if handle == bridge.INVALID_TEXTURE do return
	if u32(handle) >= bridge.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if slot.in_use {
		if slot.srv != nil do slot.srv->Release()
		if slot.texture != nil do slot.texture->Release()
		slot^ = {}
	}
}

renderer_upload_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle, pixels: []u8) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	upload_texture_internal(renderer, handle, pixels)
}

@(private)
upload_texture_internal :: proc(renderer: ^DX11Renderer, handle: bridge.TextureHandle, pixels: []u8) {
	if handle == bridge.INVALID_TEXTURE do return
	if u32(handle) >= bridge.MAX_TEXTURES do return

	slot := &renderer.textures[handle]
	if !slot.in_use || slot.texture == nil do return

	bytes_per_pixel: u32 = slot.format == .RGBA8 ? 4 : 1
	bytes_per_row := slot.width * bytes_per_pixel

	box := d3d11.BOX{
		left = 0,
		top = 0,
		front = 0,
		right = slot.width,
		bottom = slot.height,
		back = 1,
	}

	renderer.device_context->UpdateSubresource(slot.texture, 0, &box, raw_data(pixels), bytes_per_row, 0)
}

renderer_get_white_texture :: proc(r: bridge.Renderer) -> bridge.TextureHandle {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return bridge.INVALID_TEXTURE
	return renderer.white_texture
}

// Frame rendering

renderer_begin_frame :: proc(r: bridge.Renderer) -> bool {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return false

	// Detect parent window resize, matching macOS pattern of auto-detecting in the render path
	parent_rect: win.RECT
	win.GetClientRect(renderer.parent_hwnd, &parent_rect)
	parent_width := i32(parent_rect.right - parent_rect.left)
	parent_height := i32(parent_rect.bottom - parent_rect.top)
	if parent_width > 0 && parent_height > 0 {
		dpi := win.GetDpiForWindow(renderer.hwnd)
		scale_factor := f32(dpi) / 96.0

		if parent_width != renderer.physical_width || parent_height != renderer.physical_height || scale_factor != renderer.scale_factor {
			// Resize child window to match parent
			win.SetWindowPos(renderer.hwnd, nil, 0, 0, parent_width, parent_height, win.SWP_NOZORDER | win.SWP_NOMOVE)

			renderer.device_context->OMSetRenderTargets(0, nil, nil)
			if renderer.render_target_view != nil {
				renderer.render_target_view->Release()
				renderer.render_target_view = nil
			}
			renderer.swap_chain->ResizeBuffers(0, u32(parent_width), u32(parent_height), .UNKNOWN, {})
			create_render_target_view(renderer)

			logical_width := i32(f32(parent_width) / scale_factor)
			logical_height := i32(f32(parent_height) / scale_factor)
			resize_internal(renderer, logical_width, logical_height, scale_factor)
		}
	}

	return true
}

renderer_end_frame :: proc(r: bridge.Renderer) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if renderer.swap_chain == nil do return

	renderer.swap_chain->Present(1, {})
}

renderer_upload_instances :: proc(r: bridge.Renderer, instances: []bridge.DrawInstance) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if len(instances) == 0 do return
	if u32(len(instances)) > renderer.instance_capacity {
		log.errorf("instance overflow: %d > cap %d — dropping upload, GPU buffer stale", len(instances), renderer.instance_capacity)
		assert(false, "draw instance count exceeded MAX_INSTANCES")
		return
	}

	mapped_resource: d3d11.MAPPED_SUBRESOURCE
	hr := renderer.device_context->Map(renderer.instance_buffer, 0, .WRITE_DISCARD, {}, &mapped_resource)
	if hr < 0 do return

	mem.copy(mapped_resource.pData, raw_data(instances), len(instances) * size_of(bridge.DrawInstance))
	renderer.device_context->Unmap(renderer.instance_buffer, 0)
}

renderer_begin_pass :: proc(r: bridge.Renderer, clear_color: bridge.ColorF32) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if renderer.render_target_view == nil do return

	clear_color_array := clear_color
	renderer.device_context->ClearRenderTargetView(renderer.render_target_view, &clear_color_array)

	renderer.device_context->OMSetRenderTargets(1, &renderer.render_target_view, nil)

	// physical pixels
	viewport := d3d11.VIEWPORT{
		TopLeftX = 0,
		TopLeftY = 0,
		Width = f32(renderer.physical_width),
		Height = f32(renderer.physical_height),
		MinDepth = 0,
		MaxDepth = 1,
	}
	renderer.device_context->RSSetViewports(1, &viewport)

	renderer.device_context->VSSetShader(renderer.vertex_shader, nil, 0)
	renderer.device_context->PSSetShader(renderer.pixel_shader, nil, 0)
	renderer.device_context->IASetInputLayout(renderer.input_layout)

	stride := u32(size_of(bridge.DrawInstance))
	offset: u32 = 0
	renderer.device_context->IASetVertexBuffers(0, 1, &renderer.instance_buffer, &stride, &offset)

	renderer.device_context->IASetPrimitiveTopology(.TRIANGLESTRIP)

	blend_factor := [4]f32{0, 0, 0, 0}
	renderer.device_context->OMSetBlendState(renderer.blend_state, &blend_factor, 0xffffffff)

	renderer.device_context->RSSetState(renderer.rasterizer_state)
}

renderer_end_pass :: proc(r: bridge.Renderer) {
	// Nothing needed for immediate context
}

renderer_draw :: proc(r: bridge.Renderer, cmd: bridge.DrawCommand) {
	renderer := cast(^DX11Renderer)r
	if renderer == nil do return
	if cmd.instance_count == 0 do return

	if cmd.scissor.w > 0 && cmd.scissor.h > 0 {
		scale := renderer.scale_factor
		scissor_rect := d3d11.RECT{
			left = i32(f32(cmd.scissor.x) * scale),
			top = i32(f32(cmd.scissor.y) * scale),
			right = i32(f32(cmd.scissor.x + cmd.scissor.w) * scale),
			bottom = i32(f32(cmd.scissor.y + cmd.scissor.h) * scale),
		}
		renderer.device_context->RSSetScissorRects(1, &scissor_rect)
	} else {
		scissor_rect := d3d11.RECT{
			left = 0,
			top = 0,
			right = renderer.physical_width,
			bottom = renderer.physical_height,
		}
		renderer.device_context->RSSetScissorRects(1, &scissor_rect)
	}

	renderer.uniforms.single_channel_texture = cmd.single_channel_texture ? 1 : 0

	mapped_resource: d3d11.MAPPED_SUBRESOURCE
	hr := renderer.device_context->Map(renderer.uniform_buffer, 0, .WRITE_DISCARD, {}, &mapped_resource)
	if hr >= 0 {
		mem.copy(mapped_resource.pData, &renderer.uniforms, size_of(bridge.UniformBuffer))
		renderer.device_context->Unmap(renderer.uniform_buffer, 0)
	}

	renderer.device_context->VSSetConstantBuffers(0, 1, &renderer.uniform_buffer)
	renderer.device_context->PSSetConstantBuffers(0, 1, &renderer.uniform_buffer)

	texture_handle := cmd.texture
	if texture_handle == bridge.INVALID_TEXTURE {
		texture_handle = renderer.white_texture
	}

	if u32(texture_handle) < bridge.MAX_TEXTURES {
		slot := &renderer.textures[texture_handle]
		if slot.in_use && slot.srv != nil {
			renderer.device_context->PSSetShaderResources(0, 1, &slot.srv)
			renderer.device_context->PSSetSamplers(0, 1, &renderer.sampler)
		}
	}

	// 4 vertices per instance (triangle strip quad)
	renderer.device_context->DrawInstanced(4, cmd.instance_count, 0, cmd.instance_offset)
}

// Pipeline creation

@(private)
create_render_target_view :: proc(renderer: ^DX11Renderer) -> bool {
	back_buffer: ^d3d11.ITexture2D
	hr := renderer.swap_chain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&back_buffer))
	if hr < 0 do return false
	defer back_buffer->Release()

	hr = renderer.device->CreateRenderTargetView(back_buffer, nil, &renderer.render_target_view)
	return hr >= 0
}

@(private)
create_pipeline :: proc(renderer: ^DX11Renderer) -> bool {
	vs_blob: ^d3dc.ID3DBlob
	error_blob: ^d3dc.ID3DBlob
	defer if vs_blob != nil do vs_blob->Release()
	defer if error_blob != nil do error_blob->Release()

	shader_defines := []d3dc.SHADER_MACRO{
		{Name = "VERTEX", Definition = "1"},
		{},
	}

	hr := d3dc.Compile(
		raw_data(shader_source),
		len(shader_source),
		"shader.hlsl",
		raw_data(shader_defines),
		nil,
		"VSMain",
		"vs_5_0",
		transmute(u32)d3dc.D3DCOMPILE{.ENABLE_STRICTNESS},
		0,
		&vs_blob,
		&error_blob,
	)
	if hr < 0 {
		if error_blob != nil {
			error_size := error_blob->GetBufferSize()
			error_data := ([^]byte)(error_blob->GetBufferPointer())[:error_size]
			fmt.println("VS compile error:", string(error_data))
		}
		return false
	}

	hr = renderer.device->CreateVertexShader(
		vs_blob->GetBufferPointer(),
		vs_blob->GetBufferSize(),
		nil,
		&renderer.vertex_shader,
	)
	if hr < 0 do return false

	ps_blob: ^d3dc.ID3DBlob
	defer if ps_blob != nil do ps_blob->Release()

	ps_defines := []d3dc.SHADER_MACRO{
		{},
	}

	hr = d3dc.Compile(
		raw_data(shader_source),
		len(shader_source),
		"shader.hlsl",
		raw_data(ps_defines),
		nil,
		"PSMain",
		"ps_5_0",
		transmute(u32)d3dc.D3DCOMPILE{.ENABLE_STRICTNESS},
		0,
		&ps_blob,
		&error_blob,
	)
	if hr < 0 {
		if error_blob != nil {
			error_size := error_blob->GetBufferSize()
			error_data := ([^]byte)(error_blob->GetBufferPointer())[:error_size]
			fmt.println("PS compile error:", string(error_data))
		}
		return false
	}

	hr = renderer.device->CreatePixelShader(
		ps_blob->GetBufferPointer(),
		ps_blob->GetBufferSize(),
		nil,
		&renderer.pixel_shader,
	)
	if hr < 0 do return false

	input_elements := []d3d11.INPUT_ELEMENT_DESC{
		// Attribute 0: pos0
		{SemanticName = "TEXCOORD", SemanticIndex = 0, Format = .R32G32_FLOAT,        InputSlot = 0, AlignedByteOffset = 0,  InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 1: pos1
		{SemanticName = "TEXCOORD", SemanticIndex = 1, Format = .R32G32_FLOAT,        InputSlot = 0, AlignedByteOffset = 8,  InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 2: uv0
		{SemanticName = "TEXCOORD", SemanticIndex = 2, Format = .R32G32_FLOAT,        InputSlot = 0, AlignedByteOffset = 16, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 3: uv1
		{SemanticName = "TEXCOORD", SemanticIndex = 3, Format = .R32G32_FLOAT,        InputSlot = 0, AlignedByteOffset = 24, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 4: color
		{SemanticName = "TEXCOORD", SemanticIndex = 4, Format = .R8G8B8A8_UNORM,      InputSlot = 0, AlignedByteOffset = 32, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 5: border_color
		{SemanticName = "TEXCOORD", SemanticIndex = 5, Format = .R8G8B8A8_UNORM,      InputSlot = 0, AlignedByteOffset = 36, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 6: params - border_width, shape_param, no_texture
		{SemanticName = "TEXCOORD", SemanticIndex = 6, Format = .R32G32B32_FLOAT,     InputSlot = 0, AlignedByteOffset = 40, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 7: mode - shape selector
		{SemanticName = "TEXCOORD", SemanticIndex = 7, Format = .R32_UINT,            InputSlot = 0, AlignedByteOffset = 52, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
		// Attribute 8: extras - extra0, extra1
		{SemanticName = "TEXCOORD", SemanticIndex = 8, Format = .R32G32_FLOAT,        InputSlot = 0, AlignedByteOffset = 56, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
	}

	hr = renderer.device->CreateInputLayout(
		raw_data(input_elements),
		u32(len(input_elements)),
		vs_blob->GetBufferPointer(),
		vs_blob->GetBufferSize(),
		&renderer.input_layout,
	)
	if hr < 0 do return false

	return true
}
