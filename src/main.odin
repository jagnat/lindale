package lindale

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

ProgramContext :: struct {
	window: ^sdl.Window,
	audioDevice: sdl.AudioDeviceID,
}

WINDOW_WIDTH, WINDOW_HEIGHT : i32 = 1600, 1000

@(private="file")
ctx: ProgramContext

main :: proc() {

	init()
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
					sdl.Quit()
				}
			case .WINDOW_RESIZED:
				render_resize(event.window.data1, event.window.data2)
			}
		}

		draw_upload()

		render_begin()
		render_draw_rects(true)
		render_end()

		count += 1
		if count % 256 == 0 {
			newTicks := sdl.GetTicksNS()

			elapsedTimeMs := (newTicks - tick) / 1_000_000

			fmt.println("elapsedMs: ", elapsedTimeMs)
			fmt.println("avg ms/frame: ", f32(elapsedTimeMs) / 256)
			tick = newTicks
			// draw_generate_random_rects(&ctx.drawGroup)
			// draw_generate_random_spheres(&ctx.drawGroup)
			draw_generate_random_rects()
		}
	}
}

init :: proc() {
	result := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO)
	assert(result == true)

	ctx.window = sdl.CreateWindow("Lindalë", WINDOW_WIDTH, WINDOW_HEIGHT, sdl.WINDOW_HIDDEN | sdl.WINDOW_RESIZABLE)
	assert(ctx.window != nil)

	render_init(ctx.window)

	render_resize(WINDOW_WIDTH, WINDOW_HEIGHT)

	font_init()

	draw_init()

	draw_generate_random_rects()

	fmt.println(sdl.GetBasePath())
	fmt.println(sdl.GetPrefPath("jagi", "lindale"))
	fmt.println(sdl.GetUserFolder(.DOCUMENTS))

	sdl.ShowWindow(ctx.window)
}
