package platform_specific

import "vendor:commonmark"
import "base:runtime"

import F "core:sys/darwin/Foundation"
import CF "core:sys/darwin/CoreFoundation"
import MTL "vendor:darwin/Metal"
import MTK "vendor:darwin/MetalKit"
import CA "vendor:darwin/QuartzCore"

foreign import F2 "system:Foundation.framework"

import "base:intrinsics"

import pd "../platform_data"

DarwinPlatformView :: struct {
	view: ^LindaleMtkView,
	metalDevice: ^MTL.Device,
	commandQ: ^MTL.CommandQueue,
}

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
	col3 := F.Color_orangeColor()

	layer := F.View_layer(self)

	cg := intrinsics.objc_send(rawptr, col3, "CGColor")
	intrinsics.objc_send(nil, layer, "setBackgroundColor:", cg)
}

@(objc_type=LindaleMtkView, objc_implement=false, objc_is_class_method=true)
LindaleMtkView_alloc :: proc "c" () -> ^LindaleMtkView {
	return intrinsics.objc_send(^LindaleMtkView, LindaleMtkView, "alloc")
}

@(objc_type=LindaleMtkView, objc_name="makeBackingLayer")
LindaleMtkView_makeBackingLayer :: proc(self: ^LindaleMtkView) -> ^CA.MetalLayer {
	return CA.MetalLayer.layer()
}

view_create :: proc(parent: rawptr, width, height: i32, title: string) -> PlatformView {
	frame := F.Rect {
		origin = {0, 0},
		size = {800, 600}
	}

	device := MTL.CreateSystemDefaultDevice()
	assert(device != nil)

	platformView := new(DarwinPlatformView)

	lindaleView := LindaleMtkView.alloc()->initWithFrameAndContext(frame, device, context)

	lindaleView->setColorPixelFormat(.BGRA8Unorm)
	lindaleView->setDepthStencilPixelFormat(.Invalid)
	// lindaleView->setDepthStencilPixelFormat(.Depth32Float_Stencil8)
	lindaleView->setSampleCount(1)

	// Disable automatic redraw
	lindaleView->setPaused(true)
	lindaleView->setEnableSetNeedsDisplay(false)

	if parent != nil {
		parentView := cast(^F.View)(parent)
		F.View_addSubview(parentView, lindaleView)
	}

	commandQ := device->newCommandQueue()
	assert(commandQ != nil)

	platformView.view = lindaleView
	platformView.metalDevice = device
	platformView.commandQ = commandQ

	return platformView
}

view_destroy :: proc(platformView: PlatformView) {
	view := cast(^DarwinPlatformView)platformView
	if view.view != nil {
		intrinsics.objc_send(nil, view.view, "removeFromSuperview")
		F.release(cast(^F.Object)view.view)
	}
}

view_get_gpu_device :: proc(view: PlatformView) -> (gpuDevice, gpuDeviceCtx: rawptr) {
	if view == nil do return nil, nil
	return (cast(^DarwinPlatformView)view).metalDevice, nil
}

view_get_gpu_swapchain :: proc(view: PlatformView) -> pd.SwapchainData {
	dv := cast(^DarwinPlatformView)view
	currentDrawable := dv.view->currentDrawable()
	depthStencilTexture := dv.view->depthStencilTexture()
	msaaColorTexture := dv.view->multisampleColorTexture()
	return pd.SwapchainData{currentDrawable, depthStencilTexture, msaaColorTexture}
}

view_get_size :: proc(view: PlatformView) -> (width, height: int) {
	dv := cast(^DarwinPlatformView)view
	sz : F.Size = dv.view->drawableSize()
	return int(sz.width), int(sz.height)
}

// sg_swapchain osx_swapchain(void) {
//     return (sg_swapchain) {
//         .width = (int) [mtk_view drawableSize].width,
//         .height = (int) [mtk_view drawableSize].height,
//         .sample_count = sample_count,
//         .color_format = SG_PIXELFORMAT_BGRA8,
//         .depth_format = depth_format,
//         .metal = {
//             .current_drawable = (__bridge const void*) [mtk_view currentDrawable],
//             .depth_stencil_texture = (__bridge const void*) [mtk_view depthStencilTexture],
//             .msaa_color_texture = (__bridge const void*) [mtk_view multisampleColorTexture],
//         }
//     };
// }