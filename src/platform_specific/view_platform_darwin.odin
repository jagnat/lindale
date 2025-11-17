package platform_specific

import "vendor:commonmark"
import "base:runtime"

import F "core:sys/darwin/Foundation"
import CF "core:sys/darwin/CoreFoundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

foreign import F2 "system:Foundation.framework"

import "base:intrinsics"

DarwinPlatformView :: struct {
	view: ^LindaleNSView,
	metalDevice: ^MTL.Device,
	metalLayer: ^CA.MetalLayer,
	commandQ: ^MTL.CommandQueue,
}

@(objc_implement,
	objc_class            = "LindaleNSView",
	objc_superclass       = F.View,
	objc_ivar             = LindaleNSView_Var,
	objc_context_provider = LindaleNSView_get_context,
)
LindaleNSView :: struct {
	using _: F.View,
}

LindaleNSView_Var :: struct {
	ctx: runtime.Context,
}

LindaleNSView_get_context :: proc "c" (self: ^LindaleNSView_Var) -> runtime.Context {
	return self.ctx
}

@(objc_type=LindaleNSView, objc_name="initWithFrameAndContext")
LindaleNSView_initWithFrameAndContext :: proc "c" (self: ^LindaleNSView, frame: F.Rect, ctx: runtime.Context) -> ^LindaleNSView {
    self->initWithFrame(frame)
    self.ctx = ctx

    return self
}

@(objc_type=LindaleNSView, objc_implement)
LindaleNSView_acceptsFirstResponder :: proc (self: ^LindaleNSView, _cmd: rawptr) -> F.BOOL {
	return true
}

@(objc_type=LindaleNSView, objc_implement, objc_selector="mouseDown:")
LindaleNSView_mouseDown :: proc (self: ^LindaleNSView, _cmd: rawptr, event: ^F.Event) {
	col3 := F.Color_orangeColor()

	layer := F.View_layer(self)

	cg := intrinsics.objc_send(rawptr, col3, "CGColor")
	intrinsics.objc_send(nil, layer, "setBackgroundColor:", cg)
}

@(objc_type=LindaleNSView, objc_implement=false, objc_is_class_method=true)
LindaleNSView_alloc :: proc "c" () -> ^LindaleNSView {
	return intrinsics.objc_send(^LindaleNSView, LindaleNSView, "alloc")
}

@(objc_type=LindaleNSView, objc_name="makeBackingLayer")
LindaleNSView_makeBackingLayer :: proc(self: ^LindaleNSView) -> ^CA.MetalLayer {
	return CA.MetalLayer.layer()
}

view_create :: proc(parent: rawptr, width, height: i32, title: string) -> PlatformView {
	frame := F.Rect {
		origin = {0, 0},
		size = {800, 600}
	}

	lyr := CA.MetalLayer.layer()

	platformView := new(DarwinPlatformView)

	lindaleView := LindaleNSView.alloc()->initWithFrameAndContext(frame, context)

	F.View_setWantsLayer(lindaleView, true)

	layer := F.View_layer(lindaleView)
	metal_layer := cast(^CA.MetalLayer)layer

	device := MTL.CreateSystemDefaultDevice()
	assert(device != nil)

	commandQ := device->newCommandQueue()
	assert(commandQ != nil)

	metal_layer->setDevice(device)
	metal_layer->setPixelFormat(.BGRA8Unorm)
	metal_layer->setFramebufferOnly(true)


	// col1 := F.Color_cyanColor()
	// col2 := F.Color_blueColor()
	// col3 := F.Color_magentaColor()
	// col4 := F.Color_yellowColor()

	// cols := []^F.Color{col1, col2, col3, col4}

	// @(static)
	// colIdx := 0

	// theCol := cols[colIdx]
	// colIdx = (colIdx + 1) % len(cols)

	// cg := intrinsics.objc_send(rawptr, theCol, "CGColor")

	// tru := true
	// intrinsics.objc_send(nil, layer, "setOpaque:", tru)
	// intrinsics.objc_send(nil, layer, "setNeedsDisplayOnBoundsChange:", tru)
	// intrinsics.objc_send(nil, layer, "setBackgroundColor:", cg)

	if parent != nil {
		parentView := cast(^F.View)(parent)
		window := intrinsics.objc_send(^F.Window, parentView, "window")
		if window != nil {
			scale := window->backingScaleFactor()
			metal_layer->setContentsScale(scale)
		}
		F.View_addSubview(parentView, lindaleView)
	}

	platformView.view = lindaleView
	platformView.metalDevice = device
	platformView.metalLayer = metal_layer
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

