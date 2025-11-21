package platform_specific

PlatformView :: rawptr

// Each platform layer provides these procedures
// view_create :: proc(parent: rawptr, width, height: i32, title: string) -> ^PlatformView,
// view_destroy :: proc(view: PlatformView),
// view_get_gpu_device :: proc(view: PlatformView) -> (gpuDevice, gpuDeviceCtx: rawptr)
// view_get_gpu_swapchain :: proc(view: PlatformView) -> (rawptr, rawptr, rawptr)
// view_get_size :: proc(view: PlatformView) -> (width, height: int)

// view_set_callbacks: proc(view: ^PlatformView, callbacks: ViewCallbacks)
// view_set_size: proc(view: ^PlatformView, width, height: i32),
// view_get_size: proc(view: ^PlatformView) -> (i32, i32),
// view_invalidate: proc(view: ^IPlatformView, rect: Rect),
// view_set_cursor: proc(view: ^IPlatformView, cursor: CursorType),

// Client callbacks
// ViewCallbacks :: struct {
// 	on_mouse_down: proc(pos: Point, button: MouseButton, mods: Modifiers),
// 	on_mouse_up: proc(pos: Point, button: MouseButton, mods: Modifiers),
// 	on_mouse_move: proc(pos: Point, mods: Modifiers),
// 	on_key_down: proc(key: VirtualKey, char: rune, mods: Modifiers),
// 	on_key_up: proc(key: VirtualKey, char: rune, mods: Modifiers),
// 	on_resize: proc(width, height: i32),
// 	user_data: rawptr,
// }