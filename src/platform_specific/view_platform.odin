package platform_specific

import api "../platform_api"

// Re-export the Renderer type for convenience
Renderer :: api.Renderer

// Platform-specific renderer interface
// Each platform (Darwin, Windows, Linux) must implement these procedures:
//
// Lifecycle:
//   renderer_create     :: proc(parent: rawptr, width, height: i32) -> api.Renderer
//   renderer_destroy    :: proc(r: api.Renderer)
//   renderer_resize     :: proc(r: api.Renderer, width, height: i32)
//   renderer_get_size   :: proc(r: api.Renderer) -> api.RendererSize
//
// Texture management:
//   renderer_create_texture   :: proc(r: api.Renderer, width, height: u32, format: api.PixelFormat) -> api.TextureHandle
//   renderer_destroy_texture  :: proc(r: api.Renderer, handle: api.TextureHandle)
//   renderer_upload_texture   :: proc(r: api.Renderer, handle: api.TextureHandle, pixels: []u8)
//   renderer_get_white_texture :: proc(r: api.Renderer) -> api.TextureHandle
//
// Frame rendering:
//   renderer_begin_frame      :: proc(r: api.Renderer) -> bool
//   renderer_end_frame        :: proc(r: api.Renderer)33
//   renderer_upload_instances :: proc(r: api.Renderer, instances: []api.RectInstance)
//   renderer_begin_pass       :: proc(r: api.Renderer, clearColor: api.ColorF32)
//   renderer_end_pass         :: proc(r: api.Renderer)
//   renderer_draw             :: proc(r: api.Renderer, cmd: api.DrawCommand)
