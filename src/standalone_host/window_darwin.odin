package standalone_host

import "base:runtime"
import "base:intrinsics"
import F "core:sys/darwin/Foundation"

import "../bridge"
import "../sdk"

PlatformWindow :: struct {
	window: ^F.Window,
	parent_view: rawptr,
}

DELEGATE_CLASS :: "LindaleStandaloneDelegate_" + string(bridge.BUILD_ID)

@(objc_implement,
	objc_class            = DELEGATE_CLASS,
	objc_superclass       = F.Object,
	objc_ivar             = StandaloneDelegateVar,
	objc_context_provider = standalone_delegate_get_context,
)
StandaloneWindowDelegate :: struct {
	using _: F.Object,
}

StandaloneDelegateVar :: struct {
	ctx: runtime.Context,
}

standalone_delegate_get_context :: proc "c" (self: ^StandaloneDelegateVar) -> runtime.Context {
	return self.ctx
}

@(objc_type=StandaloneWindowDelegate, objc_implement, objc_selector="windowWillClose:")
StandaloneWindowDelegate_windowWillClose :: proc(self: ^StandaloneWindowDelegate, notification: ^F.Notification) {
	F.Application.sharedApplication()->stop(nil)
}

window_create :: proc(title: string, cfg: sdk.ViewConfig) -> PlatformWindow {
	app := F.Application.sharedApplication()
	app->setActivationPolicy(.Regular)

	style := F.WindowStyleMaskTitled | F.WindowStyleMaskClosable | F.WindowStyleMaskMiniaturizable
	if cfg.resizable do style |= F.WindowStyleMaskResizable

	rect := F.Rect {
		origin = {0, 0},
		size = {F.Float(cfg.default_width), F.Float(cfg.default_height)},
	}
	window := F.Window.alloc()->initWithContentRect(rect, style, .Buffered, false)

	title_str := F.String.alloc()->initWithOdinString(title)
	window->setTitle(title_str)
	window->center()

	delegate := intrinsics.objc_send(^StandaloneWindowDelegate, StandaloneWindowDelegate, "alloc")
	delegate = intrinsics.objc_send(^StandaloneWindowDelegate, delegate, "init")
	delegate.ctx = context
	intrinsics.objc_send(nil, window, "setDelegate:", delegate)

	window->makeKeyAndOrderFront(nil)
	app->activateIgnoringOtherApps(true)

	return {
		window = window,
		parent_view = window->contentView(),
	}
}

window_run_event_loop :: proc() {
	F.Application.sharedApplication()->run()
}
