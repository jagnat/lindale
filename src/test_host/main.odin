package test_host

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"
import lin "../lindale"

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
				lin.render_resize(render, event.window.data1, event.window.data2)
			}
		}

		lin.draw_clear(draw)

		lin.draw_push_rect(draw, lin.SimpleUIRect{10, 10, 200, 200, 0, 0, 0, 0, lin.ColorU8{255, 255, 255, 20}, 10})

		lin.draw_text(draw, "This is a test.", 100, 100)

		clearColor := lin.ColorF32{0.117647, 0.117647, 0.117647, 1}
		lin.draw_set_clear_color(draw, clearColor)
		lin.draw_submit(draw)

		count += 1
		if count % 256 == 0 {
			newTicks := sdl.GetTicksNS()

			elapsedTimeMs := (newTicks - tick) / 1_000_000

			// fmt.println("elapsedMs: ", elapsedTimeMs)
			// fmt.println("avg ms/frame: ", f32(elapsedTimeMs) / 256)
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

init :: proc() -> (^lin.SdlRenderContext, ^lin.DrawContext) {
	result := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO)
	assert(result == true)

	plugin := new(lin.Plugin)
	ctx := new(lin.SdlRenderContext)
	drawCtx := new(lin.DrawContext)
	ctx.plugin = plugin
	drawCtx.plugin = plugin
	plugin.render = ctx
	plugin.draw = drawCtx

	ctx.window = sdl.CreateWindow("Lindalë", lin.WINDOW_WIDTH,lin.WINDOW_HEIGHT, sdl.WINDOW_HIDDEN | sdl.WINDOW_RESIZABLE)
	assert(ctx.window != nil)

	lin.render_init(ctx)
	lin.render_resize(ctx, lin.WINDOW_WIDTH, lin.WINDOW_HEIGHT)

	lin.draw_init(drawCtx)

	fmt.println(sdl.GetBasePath())
	fmt.println(cstring(sdl.GetPrefPath("jagi", "Lindale")))
	fmt.println(sdl.GetUserFolder(.DOCUMENTS))

	sdl.ShowWindow(ctx.window)

	return ctx, drawCtx
}
