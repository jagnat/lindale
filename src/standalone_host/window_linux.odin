package standalone_host

import "core:log"
import "core:strings"
import "core:sys/posix"
import "vendor:x11/xlib"

import "../sdk"
import plat "../platform_specific"

PlatformWindow :: struct {
	display: ^xlib.Display,
	window: xlib.Window,
	parent_view: rawptr,
}

@(private="file")
main_window: PlatformWindow

@(private="file")
wm_delete_window: xlib.Atom

window_create :: proc(title: string, cfg: sdk.ViewConfig) -> PlatformWindow {
	display := xlib.OpenDisplay(nil)
	if display == nil {
		log.error("Failed to open X display")
		return {}
	}

	root := xlib.RootWindow(display, xlib.DefaultScreen(display))
	window := xlib.CreateSimpleWindow(display, root, 0, 0, u32(cfg.default_width), u32(cfg.default_height), 0, 0, 0)

	if !cfg.resizable {
		hints := xlib.AllocSizeHints()
		hints.flags = {.PMinSize, .PMaxSize}
		hints.min_width = cfg.default_width
		hints.min_height = cfg.default_height
		hints.max_width = cfg.default_width
		hints.max_height = cfg.default_height
		xlib.SetWMNormalHints(display, window, hints)
		xlib.Free(hints)
	}

	xlib.StoreName(display, window, strings.clone_to_cstring(title, context.temp_allocator))

	// Ask the WM for a close message instead of having it kill the connection
	wm_delete_window = xlib.InternAtom(display, "WM_DELETE_WINDOW", false)
	xlib.SetWMProtocols(display, window, &wm_delete_window, 1)

	xlib.MapWindow(display, window)
	// The renderer parents into this window over its own connection, so it must exist server side first
	xlib.Sync(display, false)

	main_window = {
		display = display,
		window = window,
		parent_view = rawptr(uintptr(window)),
	}
	return main_window
}

window_run_event_loop :: proc() {
	display := main_window.display
	if display == nil do return

	fds := [1]posix.pollfd{{fd = posix.FD(xlib.ConnectionNumber(display)), events = {.IN}}}
	for {
		for xlib.Pending(display) > 0 {
			event: xlib.XEvent
			xlib.NextEvent(display, &event)
			if event.type == .ClientMessage && xlib.Atom(event.xclient.data.l[0]) == wm_delete_window do return
		}
		posix.poll(&fds[0], 1, plat.timer_poll())
	}
}
