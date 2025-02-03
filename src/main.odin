package lindale

import "core:fmt"
import "core:os"
import sdl "thirdparty/sdl3"
import tt "vendor:stb/truetype"

ProgramContext :: struct {
	window: sdl.Window,
	audioDevice: sdl.AudioDeviceID,
	drawGroup: RectDrawGroup,
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
			eventType := sdl.EventType(event.type)
			#partial switch eventType {
			case .EVENT_QUIT:
				os.exit(0)
			case .EVENT_KEY_DOWN:
				if event.key.scancode == .SCANCODE_ESCAPE {
					sdl.Quit()
				}
			case .EVENT_WINDOW_RESIZED:
				render_resize(event.window.data1, event.window.data2)
			}
		}
		render_upload_rect_instances(draw_get_rects(&ctx.drawGroup))
		render_render()
		count += 1
		if count % 256 == 0 {
			newTicks := sdl.GetTicksNS()

			elapsedTimeMs := (newTicks - tick) / 1_000_000

			fmt.println("elapsedMs: ", elapsedTimeMs)
			fmt.println("avg ms/frame: ", f32(elapsedTimeMs) / 256)
			tick = newTicks
			draw_generate_random_rects(&ctx.drawGroup)
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

	draw_init()

	draw_init_rect_group(&ctx.drawGroup)
	draw_generate_random_rects(&ctx.drawGroup)

	fmt.println(sdl.GetBasePath())
	fmt.println(sdl.GetPrefPath("jagi", "lindale"))
	fmt.println(sdl.GetUserFolder(.FOLDER_DOCUMENTS))

	sdl.ShowWindow(ctx.window)
}
