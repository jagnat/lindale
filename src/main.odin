package lindale

import "core:fmt"
import "core:os"
import sdl "thirdparty/sdl3"
import tt "vendor:stb/truetype"

ProgramContext :: struct {
	window: sdl.Window,
	audioDevice: sdl.AudioDeviceID,
}

@(private="file")
ctx: ProgramContext

main :: proc() {

	init()
	fmt.println("Successful Init")

	result: b8

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

		render_render()
	}
}

init :: proc() {
	result := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO)
	assert(result == true)

	ctx.window = sdl.CreateWindow("Lindalë", 1600, 1000, sdl.WINDOW_HIDDEN | sdl.WINDOW_RESIZABLE)
	assert(ctx.window != nil)

	render_init(ctx.window)

	render_resize(1600, 1000)

	fmt.println(sdl.GetBasePath())
	fmt.println(sdl.GetPrefPath("jagi", "lindale"))
	fmt.println(sdl.GetUserFolder(.FOLDER_DOCUMENTS))

	sdl.ShowWindow(ctx.window)
}

