package lindale

import "core:fmt"
import "core:os"
import stbtt "vendor:stb/truetype"
import stbi "vendor:stb/image"
import fs "vendor:fontstash"

font_NotoSans := #load("../resources/NotoSans.ttf")

FONT_ATLAS_SIZE :: 512

FontState :: struct {
	fontContext: fs.FontContext,
}

@(private="file")
ctx: FontState

font_init :: proc() {
	ctx.fontContext.callbackResize = __fs_resize
	ctx.fontContext.callbackUpdate = __fs_update

	fs.Init(&ctx.fontContext, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .TOPLEFT)

	fs.AddFontMem(&ctx.fontContext, "Noto Sans", font_NotoSans, false)

	font_draw_text()
}

font_draw_text :: proc() {
	state := fs.__getState(&ctx.fontContext)
	state.size = 16

	iter := fs.TextIterInit(&ctx.fontContext, 0, 0, "The quick brown fox jumps over the lazy dog")

	for {
		quad: fs.Quad
		fs.TextIterNext(&ctx.fontContext, &iter, &quad) or_break
	}

	stbi.write_png("fa.png", i32(ctx.fontContext.width), i32(ctx.fontContext.height), 1, raw_data(ctx.fontContext.textureData), i32(ctx.fontContext.width))
}

__fs_resize :: proc(data: rawptr, w, h: int) {
	fmt.println("HERE>")
}

__fs_update :: proc(data: rawptr, dirtyRect: [4]f32, textureData: rawptr) {
	fmt.println("HERE<")
}