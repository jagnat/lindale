package lindale

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:math"
import dif "../thirdparty/uFFT_DIF"
import dit "../thirdparty/uFFT_DIT"

Plugin :: struct {
	// // Audio processor state
	// processor: ^AudioProcessorContext,

	// UI / controller state
	render: ^RenderContext,
	draw: ^DrawContext,

	// Common state
}

PluginComponentSet :: bit_set[PluginComponent]
PluginComponent :: enum {
	Audio,
	Controller,
}

PluginApi :: struct {
	do_analysis : proc(plug: ^Plugin, transfer: ^AnalysisTransfer),
	draw : proc(plug: ^Plugin)
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
		}
	}
}

plugin_init :: proc(components: PluginComponentSet) -> ^Plugin {
	plugin := new(Plugin)
	if plugin == nil do return nil
	error := false
	defer if error do free(plugin)

	// if .Audio in components {
	// 	plugin.processor = new(AudioProcessorContext)
	// 	if plugin.processor == nil do error = true
	// }
	// defer if error && plugin.processor != nil do free(plugin.processor)

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

	draw_clear(plug.draw)
	for i in 0 ..< ANALYSIS_BUFFER_SIZE / 2 {
		val := vec[i]
		mag := math.sqrt(real(val) * real(val) + imag(val) * imag(val))
		adjusted := math.log2(mag + 1) / math.log2(f32(1025))
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
			ColorU8{0, 255, 255, u8(alpha * 255)}, width / 2
		}
		draw_push_rect(plug.draw, rect)
	}
}

plugin_draw :: proc(plug: ^Plugin) {
	// draw_generate_random_rects(plug.draw)
	draw_upload(plug.draw)
	render_begin(plug.render, ColorF32{0.1, 0.2, 0, 1})
	render_draw_rects(plug.render, false)
	render_end(plug.render)
}

plugin_param_changed :: proc(plug: ^Plugin, paramName: string) {

}

plugin_process_audio :: proc(plug: ^Plugin) {
	
}
