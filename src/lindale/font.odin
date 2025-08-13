package lindale

import "core:fmt"
import "core:os"
import stbtt "vendor:stb/truetype"
import stbi "vendor:stb/image"
import fs "vendor:fontstash"

font_NotoSans := #load("../../resources/NotoSans.ttf")

FONT_ATLAS_SIZE :: 512

FontState :: struct {
	fontContext: fs.FontContext,
}

font_init :: proc(ctx: ^FontState) {

	fs.Init(&ctx.fontContext, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .TOPLEFT)

	fs.AddFontMem(&ctx.fontContext, "Noto Sans", font_NotoSans, false)
}

font_get_text_quads :: proc(ctx: ^FontState, text: string, x, y: f32, rects: []RectInstance) -> int {
	state := fs.__getState(&ctx.fontContext)
	state.size = 22

	iter := fs.TextIterInit(&ctx.fontContext, x, y, text)

	i := 0

	for {
		quad: fs.Quad
		fs.TextIterNext(&ctx.fontContext, &iter, &quad) or_break
		instance := RectInstance{
			{quad.x0, quad.y0},
			{quad.x1, quad.y1},
			{quad.s0, quad.t0},
			{quad.s1, quad.t1},
			{}, // Color
			0, // Corner Radius
			0, // Not white texture
			0, // Padding
		}
		rects[i] = instance
		i += 1
	}

	return i
}

font_get_atlas :: proc(ctx: ^FontState) -> []byte {
	return ctx.fontContext.textureData
}


__fs_resize :: proc(data: rawptr, w, h: int) {
	fmt.println("HERE>")
}

__fs_update :: proc(data: rawptr, dirtyRect: [4]f32, textureData: rawptr) {
	fmt.println("HERE<")
}