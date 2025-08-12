package lindale

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:math"
import "core:math/rand"
import dif "../thirdparty/uFFT_DIF"
import dit "../thirdparty/uFFT_DIT"

Plugin :: struct {
	// Audio processor state
	audioProcessor: ^AudioProcessorContext,

	// UI / controller state
	render: ^RenderContext,
	draw: ^DrawContext,

	flipColor: bool,

	// Common state

	// TODO: DELETE GROSS
	gross_global_glob: AnalysisTransfer
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
		return PluginApi{
			do_analysis = plugin_do_analysis,
			draw = plugin_draw,
			process_audio = plugin_process_audio,
		}
	}
}

plugin_init :: proc(components: PluginComponentSet) -> ^Plugin {
	plugin := new(Plugin)
	if plugin == nil do return nil
	error := false
	defer if error do free(plugin)

	if .Audio in components {
		plugin.audioProcessor = new(AudioProcessorContext)
		if plugin.audioProcessor == nil do error = true
	}
	defer if error && plugin.audioProcessor != nil do free(plugin.audioProcessor)

	if .Controller in components {
		plugin.render = new(RenderContext)
		if plugin.render == nil do error = true

		plugin.draw = new(DrawContext)
		if plugin.draw == nil do error = true
	}
	defer if error && plugin.render != nil do free(plugin.render)
	defer if error && plugin.draw != nil do free(plugin.draw)

	if error do return nil

	if plugin.render != nil do plugin.render.plugin = plugin
	if plugin.draw != nil do plugin.draw.plugin = plugin

	return plugin
}

plugin_destroy :: proc(plug: ^Plugin) {

}

plugin_create_view :: proc(plug: ^Plugin, parentHandle: rawptr) {
	if plug.render == nil do return

	render_init_with_handle(plug.render, parentHandle)
	render_resize(plug.render, 800, 600)

	draw_init(plug.draw)
	draw_generate_random_rects(plug.draw)
}

plugin_remove_view :: proc(plug: ^Plugin) {
	render_deinit(plug.render)
}

log_like_tween :: proc(i: int, N: int) -> f32 {
	return math.pow_f32(f32(i) / f32(N), 0.3)
}

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
	fft_bin_width :: 4
	MIN_FREQ : f32 : 20
	MAX_FREQ : f32 : 22050

	@(static) doLog := true

	draw_clear(plug.draw)
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
			ColorU8{255, 255, 255, u8(alpha * 255)}, width / 2
		}
		draw_push_rect(plug.draw, rect)
	}
	doLog = false
}

plugin_draw :: proc(plug: ^Plugin) {
	// draw_upload(plug.draw)

	// clearColor: ColorF32 = {0.117647, 0.117647, 0.117647, 1} // grey
	// clearColor: ColorF32 = {0.278, 0.216, 0.369, 1} // purple
	// clearColor: ColorF32 = {0.278, 0.716, 0.369, 1}
	// clearColor: ColorF32 = {0.278, 0.716, 0.369, 1}
	// clearColor: ColorF32 = {0.278, 0.716, 0.969, 1}

	choices := [?]ColorF32{{0.117647, 0.117647, 0.117647, 1}, {0.278, 0.216, 0.369, 1}, {0.278, 0.716, 0.369, 1}, {0.278, 0.716, 0.969, 1}}
	@(static) clearColor := ColorF32{0.117647, 0.117647, 0.117647, 1}
	// clearColor := rand.choice(choices[:])
	if plug.flipColor do clearColor = rand.choice(choices[:])
	// clearColor := ColorF32_from_hex(0xca9f85ff)
	// clearColor := ColorF32_from_hex(0xff00ffff)
	// render_begin(plug.render, clearColor)
	// render_draw_rects(plug.render, false)
	// render_end(plug.render)

	draw_submit(plug.draw)
}

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
