package lindale

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

// ProgramContext :: struct {
// 	window: ^sdl.Window,
// 	audioDevice: sdl.AudioDeviceID,
// 	texture: Texture2D,
// }

// WINDOW_WIDTH, WINDOW_HEIGHT : i32 = 1600, 1000

// @(private="file")
// ctx: ProgramContext

main :: proc() {

	render, draw := init()
	fmt.println("Successful Init")

	result: b8

	count: u64
	tick: u64 = sdl.GetTicksNS()

	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			eventType := event.type
			#partial switch eventType {
			case .QUIT:
				os.exit(0)
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					os.exit(0)
				}
			case .WINDOW_RESIZED:
				render_resize(render, event.window.data1, event.window.data2)
			}
		}

		draw_upload(draw)

		render_begin(render)
		render_draw_rects(render)
		render_end(render)

		count += 1
		if count % 256 == 0 {
			newTicks := sdl.GetTicksNS()

			elapsedTimeMs := (newTicks - tick) / 1_000_000

			fmt.println("elapsedMs: ", elapsedTimeMs)
			fmt.println("avg ms/frame: ", f32(elapsedTimeMs) / 256)
			tick = newTicks
			// draw_generate_random_rects(&ctx.drawGroup)
			// draw_generate_random_spheres(&ctx.drawGroup)
			// draw_text(draw, "This is a test.", 300, 300)
			// draw_generate_random_rects()
			// draw_generate_random_textured_rects();
		}
		free_all(context.temp_allocator)
	}
}

init :: proc() -> (^RenderContext, ^DrawContext) {
	result := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO)
	assert(result == true)

	plugin := new(Plugin)
	ctx := new(RenderContext)
	drawCtx := new(DrawContext)
	ctx.plugin = plugin
	drawCtx.plugin = plugin
	plugin.render = ctx
	plugin.draw = drawCtx

	ctx.window = sdl.CreateWindow("Lindalë", WINDOW_WIDTH, WINDOW_HEIGHT, sdl.WINDOW_HIDDEN | sdl.WINDOW_RESIZABLE)
	assert(ctx.window != nil)

	render_init(ctx)

	render_resize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)

	font_init(&drawCtx.fontState)

	draw_init(drawCtx)

	draw_generate_random_rects(drawCtx)

	fmt.println(sdl.GetBasePath())
	fmt.println(cstring(sdl.GetPrefPath("jagi", "Lindale")))
	fmt.println(sdl.GetUserFolder(.DOCUMENTS))

	sdl.ShowWindow(ctx.window)

	return ctx, drawCtx
}
