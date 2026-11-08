package platform_specific

import "../bridge"

// TODO: Stub. Replace with an Xlib + GLX + OpenGL 3.3 renderer

renderer_create :: proc(parent: rawptr, width, height: i32) -> bridge.Renderer {
	return nil
}

renderer_destroy :: proc(r: bridge.Renderer) {
}

renderer_set_mouse_state :: proc(r: bridge.Renderer, mouse: ^bridge.MouseState) {
}

renderer_set_repaint_callback :: proc(r: bridge.Renderer, callback: proc "c" (rawptr), data: rawptr) {
}

renderer_resize :: proc(r: bridge.Renderer, width, height: i32) {
}

renderer_get_size :: proc(r: bridge.Renderer) -> bridge.RendererSize {
	return {}
}

renderer_create_texture :: proc(r: bridge.Renderer, width, height: u32, format: bridge.PixelFormat) -> bridge.TextureHandle {
	return bridge.INVALID_TEXTURE
}

renderer_destroy_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle) {
}

renderer_upload_texture :: proc(r: bridge.Renderer, handle: bridge.TextureHandle, pixels: []u8) {
}

renderer_get_white_texture :: proc(r: bridge.Renderer) -> bridge.TextureHandle {
	return bridge.INVALID_TEXTURE
}

renderer_begin_frame :: proc(r: bridge.Renderer) -> bool {
	return false
}

renderer_end_frame :: proc(r: bridge.Renderer) {
}

renderer_upload_instances :: proc(r: bridge.Renderer, instances: []bridge.DrawInstance) {
}

renderer_begin_pass :: proc(r: bridge.Renderer, clear_color: bridge.ColorF32) {
}

renderer_end_pass :: proc(r: bridge.Renderer) {
}

renderer_draw :: proc(r: bridge.Renderer, cmd: bridge.DrawCommand) {
}
