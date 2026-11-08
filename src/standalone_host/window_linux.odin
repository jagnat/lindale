package standalone_host

import "../sdk"

// TODO: Stub. Replace with an Xlib window and frame loop

PlatformWindow :: struct {
	parent_view: rawptr,
}

window_create :: proc(title: string, cfg: sdk.ViewConfig) -> PlatformWindow {
	return {}
}

window_run_event_loop :: proc() {
}
