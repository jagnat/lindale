package lindale

import "core:fmt"
import "core:os"
import stbtt "vendor:stb/truetype"
import stbi "vendor:stb/image"
import fs "vendor:fontstash"

font_NotoSans := #load("../../resources/MapleMono-SemiBold.ttf")

FONT_ATLAS_SIZE :: 1024
FONT_SIZE :: 22

FontState :: struct {
	fontContext: fs.FontContext,
	scale:      f32,
}

font_init :: proc(ctx: ^FontState) {
	ctx.scale = 1.0
	fs.Init(&ctx.fontContext, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .TOPLEFT)
	fs.AddFontMem(&ctx.fontContext, "Noto Sans", font_NotoSans, false)
}

font_get_text_quads :: proc(ctx: ^FontState, text: string, x, y: f32, rects: []RectInstance) -> int {
	scale := ctx.scale
	state := fs.__getState(&ctx.fontContext)
	state.size = FONT_SIZE * scale

	// Fontstash works in scaled coordinates, convert input to scaled space
	iter := fs.TextIterInit(&ctx.fontContext, x * scale, y * scale, text)
	invScale := 1.0 / scale

	i := 0

	for {
		quad: fs.Quad
		fs.TextIterNext(&ctx.fontContext, &iter, &quad) or_break
		instance := RectInstance{
			{quad.x0 * invScale, quad.y0 * invScale},
			{quad.x1 * invScale, quad.y1 * invScale},
			{quad.s0, quad.t0},
			{quad.s1, quad.t1},
			{}, // Color
			{}, // Border color
			0, // Border width
			0, // Corner Radius
			0, // Not white texture
			0, // Padding
		}
		rects[i] = instance
		i += 1
	}

	return i
}

font_measure_bounds :: proc(ctx: ^FontState, text: string) -> Vec2f {
	invScale := 1.0 / ctx.scale
	ret: Vec2f
	ret.x = fs.TextBounds(&ctx.fontContext, text) * invScale
	_, _, lineHeight := fs.VerticalMetrics(&ctx.fontContext)
	ret.y = lineHeight * invScale
	return ret
}

font_get_vertical_metrics :: proc(ctx: ^FontState) -> (ascender, descender, lineHeight: f32) {
	invScale := 1.0 / ctx.scale
	state := fs.__getState(&ctx.fontContext)
	state.size = FONT_SIZE * ctx.scale
	ascender, descender, lineHeight = fs.VerticalMetrics(&ctx.fontContext)
	ascender *= invScale
	descender *= invScale
	lineHeight *= invScale
	return
}

font_set_scale :: proc(ctx: ^FontState, scale: f32) {
	if abs(scale - ctx.scale) < 0.01 do return
	ctx.scale = scale
	fs.ResetAtlas(&ctx.fontContext, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)
	font_invalidate_texture(ctx)
}

font_get_atlas :: proc(ctx: ^FontState) -> []byte {
	return ctx.fontContext.textureData
}

font_is_texture_dirty :: proc(ctx: ^FontState) -> bool {
	// dirty flag isn't properly set by fontstash, so we do the check this way
	return ctx.fontContext.dirtyRect[0] < ctx.fontContext.dirtyRect[2] && ctx.fontContext.dirtyRect[1] < ctx.fontContext.dirtyRect[3]
}

font_reset_dirty_flag :: proc(ctx: ^FontState) {
	fs.__dirtyRectReset(&ctx.fontContext)
}

font_invalidate_texture :: proc(ctx: ^FontState) {
	ctx.fontContext.dirtyRect = {0, 0, f32(FONT_ATLAS_SIZE), f32(FONT_ATLAS_SIZE)}
}

__fs_resize :: proc(data: rawptr, w, h: int) {
	fmt.println("HERE>")
}

__fs_update :: proc(data: rawptr, dirtyRect: [4]f32, textureData: rawptr) {
	fmt.println("HERE<")
}