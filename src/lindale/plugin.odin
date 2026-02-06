package lindale

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:math"
import "core:math/rand"
import vm "core:mem/virtual"
import dif "../thirdparty/uFFT_DIF"
import dit "../thirdparty/uFFT_DIT"

import plat "../platform_api"

Plugin :: struct {
	platform: ^plat.PlatformApi,
	renderer: plat.Renderer,
	fontAtlas: plat.TextureHandle,

	audioProcessor: ^AudioProcessorContext,

	draw: ^DrawContext,
	ui: ^UIContext,
	mouse: plat.MouseState,

	viewBounds: RectI32,
	gross_global_glob: AnalysisTransfer,
}

PluginComponentSet :: bit_set[PluginComponent]
PluginComponent :: enum {
	Audio,
	Controller,
}

PluginApi :: struct {
	do_analysis : proc(plug: ^Plugin, transfer: ^AnalysisTransfer),
	draw : proc(plug: ^Plugin),
	process_audio : proc(plug: ^Plugin),
	view_attached : proc(plug: ^Plugin),
	view_removed : proc(plug: ^Plugin),
	view_resized : proc(plug: ^Plugin, rect: RectI32),
}

fallbackApi :: PluginApi {
	do_analysis = plugin_do_analysis,
	draw = plugin_draw,
	process_audio = plugin_process_audio,
	view_attached = plugin_view_attached,
	view_removed = plugin_view_removed,
	view_resized = plugin_view_resized,
}

// TODO: HACK for demo, not threadsafe, doesn't support multiple instances
ANALYSIS_BUFFER_SIZE :: 2048
AnalysisTransfer :: struct {
	buf: [ANALYSIS_BUFFER_SIZE]f32,
	writeIndex: int,
}

HOT_DLL :: #config(HOT_DLL, false)

when HOT_DLL {
	@(export) GetPluginApi :: proc() -> PluginApi {
		return PluginApi {
			do_analysis = plugin_do_analysis,
			draw = plugin_draw,
			process_audio = plugin_process_audio,
			view_attached = plugin_view_attached,
			view_removed = plugin_view_removed,
			view_resized = plugin_view_resized,
		}
	}
}

// @(private)
plugin_init :: proc(plugin: ^Plugin, components: PluginComponentSet) {
	if .Audio in components {
		if plugin.audioProcessor == nil {
			plugin.audioProcessor = new(AudioProcessorContext)
		}
	}

	if .Controller in components {
		if plugin.draw == nil {
			plugin.draw = new(DrawContext)
			plugin.draw.plugin = plugin
			err := vm.arena_init_growing(&plugin.draw.arena)
			assert(err == .None)
			plugin.draw.alloc = vm.arena_allocator(&plugin.draw.arena)
			plugin.draw.clearColor = {0, 0, 0, 1}

			font_init(&plugin.draw.fontState)
			plugin.draw.initialized = true
		}
		if plugin.ui == nil {
			plugin.ui = new(UIContext)
			plugin.ui.plugin = plugin
			plugin.ui.theme = DEFAULT_THEME
		}
	}
}

@(private)
plugin_destroy :: proc(plug: ^Plugin) {

}

@(private)
plugin_view_attached :: proc(plug: ^Plugin) {
	
}

@(private)
plugin_view_removed :: proc(plug: ^Plugin) {
	if plug.draw != nil {
		font_invalidate_texture(&plug.draw.fontState)
	}
}

@(private)
plugin_view_resized :: proc(plug: ^Plugin, rect: RectI32) {
	plug.viewBounds = rect
	// render_resize(plug.render, plug.viewBounds.w, plug.viewBounds.h)
}

log_like_tween :: proc(i: int, N: int) -> f32 {
	return math.pow_f32(f32(i) / f32(N), 0.3)
}

@(private)
plugin_do_analysis :: proc(plug: ^Plugin, transfer: ^AnalysisTransfer) {
	vec: [ANALYSIS_BUFFER_SIZE]complex64

	for val, i in transfer.buf {
		vec[i] = complex64(val)
	}

	dit.fft(&vec[0], ANALYSIS_BUFFER_SIZE)

	// Generate some rectangles corresponding to FFT result
	startX : f32 = 50
	endX : f32 = 800 - 50
	startY : f32 = 600 - 50
	fft_height :: 1000
	fft_bin_width :: 10
	MIN_FREQ : f32 : 20
	MAX_FREQ : f32 : 22050

	@(static) doLog := true

	@(static) alph: u8 = 128

	alph += u8(plug.mouse.scrollDelta.y)

	// draw_clear(plug.draw)
	// draw_set_scissor(plug.draw, RectI32{200, 300, 400, 200})
	for i in 0 ..< ANALYSIS_BUFFER_SIZE / 2 {
		val := vec[i]
		mag := math.sqrt(real(val) * real(val) + imag(val) * imag(val))
		log2_plus_one := math.log2(mag + 1)
		log2_1025 := math.log2(f32(1025))
		adjusted := log2_plus_one / log2_1025
		height := (adjusted * fft_height) + 5
		freq := f32(i) * 44100.0 / ANALYSIS_BUFFER_SIZE
		t := log_like_tween(i, 1024)
		alpha := 1.0 - t
		width := max(fft_bin_width * 2 * (1 - 0.8 * t), fft_bin_width)
		if freq < MIN_FREQ || freq > MAX_FREQ do continue
		x := linalg.lerp(startX, endX, math.log10(freq / MIN_FREQ) / math.log10(MAX_FREQ / MIN_FREQ))
		y0 := startY - height
		rect := SimpleUIRect{
			x - (fft_bin_width / 2), y0,
			width, height,
			0, 0, 0, 0,
			ColorU8{255, 240, 255, alph}, width/2,
			ColorU8{12, 0, 12, alph}, 0
		}
		// draw_push_rect(plug.draw, rect)
	}
	doLog = false
}

// @(private)
plugin_draw :: proc(plug: ^Plugin) {
	if plug.draw == nil do return

	@(static) frame : i64 = 0

	draw_clear(plug.draw)
	draw_set_clear_color(plug.draw, {0.08, 0.08, 0.1, 1.0})

	x : f32 = 0.0
	y : f32 = 0.0
	w : f32 = 100.0
	h : f32 = 100.0

	hovered := plug.mouse.pos.x >= x && plug.mouse.pos.x <= x + w &&
		plug.mouse.pos.y >= y && plug.mouse.pos.y <= y + h

	color : ColorU8
	if hovered && .Left in plug.mouse.down {
		color = {255, 100, 100, 255}
	} else if hovered {
		color = {255, 200, 100, 255}
	} else {
		color = {0, 144, 200, 255}
	}

	rect := SimpleUIRect {
		x = x, y = y,
		width = w, height = h,
		color = color,
		cornerRad = 10,
		borderWidth = 2,
		borderColor = {255, 255, 255, 255},
	}

	frame = frame + 1

	draw_push_rect(plug.draw, rect)

	rect.x = 700
	rect.y = 500

	draw_push_rect(plug.draw, rect)

	txtBuf: [10]u8
	num := fmt.bprintf(txtBuf[:], "%d", frame)

	draw_text(plug.draw, num, x + 10, y + 10)

	draw_submit(plug.draw)
}

@(private)
plugin_process_audio :: proc(plug: ^Plugin) {
	audioContext := plug.audioProcessor
	if audioContext == nil do return

	freq := norm_to_param(audioContext.lastParamState.values[.Freq], ParamTable[.Freq].range)
	// freq : f64 = 666
	samplesPerHalfPeriod := cast(i32)(audioContext.sampleRate / (2 * freq))

	mix := f32(audioContext.lastParamState.values[.Mix]) // keep mix normalized, 0 to 1

	@(static) squarePhase : i32 = 0

	outputs := audioContext.outputBuffers
	inputs := audioContext.inputBuffers

	if len(outputs) < 1 do return

	// Generate output buffer, iterate samples TODO: should be done channel first?
	for s in 0..< len(outputs[0].buffers32[0]) {
		AMPLITUDE :: 0.01
		squareVal : f32= squarePhase < samplesPerHalfPeriod ? AMPLITUDE : -AMPLITUDE
		squarePhase += 1
		if squarePhase >= 2 * samplesPerHalfPeriod do squarePhase = 0

		for i in 0 ..< len(outputs) {
			outputBufs := outputs[i].buffers32
			numChannels := len(outputs[i].buffers32)
			inputBufs := inputs[i].buffers32

			for c in 0..<numChannels {
				inVal : f32 = 0
				if len(inputs) > 0 && len(inputs[i].buffers32) > c {
					inVal = inputs[i].buffers32[c][s]
				}
				out := outputBufs[c]
				out[s] = mix * squareVal + (1 - mix) * inVal
				if c == 0 {
					plug.gross_global_glob.buf[plug.gross_global_glob.writeIndex] = out[s]
					plug.gross_global_glob.writeIndex = (plug.gross_global_glob.writeIndex + 1) % ANALYSIS_BUFFER_SIZE
				}
			}
		}
	}
}
