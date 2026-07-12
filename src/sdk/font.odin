package sdk

import "core:fmt"
import "core:os"
import stbtt "vendor:stb/truetype"
import stbi "vendor:stb/image"
import fs "vendor:fontstash"

font_noto_sans := #load("../../resources/MapleMono-SemiBold.ttf")

FONT_ATLAS_SIZE :: 1024
FONT_SIZE_DEFAULT :: 22

FontState :: struct {
	font_context: fs.FontContext,
	scale:      f32,
}

font_init :: proc(ctx: ^FontState) {
	ctx.scale = 1.0
	fs.Init(&ctx.font_context, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .TOPLEFT)
	fs.AddFontMem(&ctx.font_context, "Noto Sans", font_noto_sans, false)
}

font_get_text_quads :: proc(ctx: ^FontState, text: string, x, y: f32, size: f32, rects: []DrawInstance) -> int {
	scale := ctx.scale
	state := fs.__getState(&ctx.font_context)
	state.size = size * scale

	// Fontstash works in scaled coordinates, convert input to scaled space
	iter := fs.TextIterInit(&ctx.font_context, x * scale, y * scale, text)
	inv_scale := 1.0 / scale

	i := 0

	for {
		quad: fs.Quad
		fs.TextIterNext(&ctx.font_context, &iter, &quad) or_break
		instance := DrawInstance{
			pos0 = {quad.x0 * inv_scale, quad.y0 * inv_scale},
			pos1 = {quad.x1 * inv_scale, quad.y1 * inv_scale},
			uv0  = {quad.s0, quad.t0},
			uv1  = {quad.s1, quad.t1},
		}
		rects[i] = instance
		i += 1
	}

	return i
}

font_measure_bounds :: proc(ctx: ^FontState, text: string, size: f32) -> Vec2f {
	state := fs.__getState(&ctx.font_context)
	state.size = size * ctx.scale
	inv_scale := 1.0 / ctx.scale
	ret: Vec2f
	ret.x = fs.TextBounds(&ctx.font_context, text) * inv_scale
	_, _, line_height := fs.VerticalMetrics(&ctx.font_context)
	ret.y = line_height * inv_scale
	return ret
}

font_get_vertical_metrics :: proc(ctx: ^FontState, size: f32) -> (ascender, descender, line_height: f32) {
	inv_scale := 1.0 / ctx.scale
	state := fs.__getState(&ctx.font_context)
	state.size = size * ctx.scale
	ascender, descender, line_height = fs.VerticalMetrics(&ctx.font_context)
	ascender *= inv_scale
	descender *= inv_scale
	line_height *= inv_scale
	return
}

font_set_scale :: proc(ctx: ^FontState, scale: f32) {
	if abs(scale - ctx.scale) < 0.01 do return
	ctx.scale = scale
	fs.ResetAtlas(&ctx.font_context, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)
	font_invalidate_texture(ctx)
}

font_get_atlas :: proc(ctx: ^FontState) -> []byte {
	return ctx.font_context.textureData
}

font_is_texture_dirty :: proc(ctx: ^FontState) -> bool {
	// dirty flag isn't properly set by fontstash, so we do the check this way
	return ctx.font_context.dirtyRect[0] < ctx.font_context.dirtyRect[2] && ctx.font_context.dirtyRect[1] < ctx.font_context.dirtyRect[3]
}

font_reset_dirty_flag :: proc(ctx: ^FontState) {
	fs.__dirtyRectReset(&ctx.font_context)
}

font_invalidate_texture :: proc(ctx: ^FontState) {
	ctx.font_context.dirtyRect = {0, 0, f32(FONT_ATLAS_SIZE), f32(FONT_ATLAS_SIZE)}
}

__fs_resize :: proc(data: rawptr, w, h: int) {
	fmt.println("HERE>")
}

__fs_update :: proc(data: rawptr, dirty_rect: [4]f32, texture_data: rawptr) {
	fmt.println("HERE<")
}
