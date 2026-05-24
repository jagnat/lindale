package lindale

import "core:math"
import "core:log"
import b "../bridge"
import "../dsp"
import dit "../thirdparty/uFFT_DIT"

when b.ACTIVE_PLUGIN == "scopey" {

FFT_SIZE :: 4096
RING_SIZE :: FFT_SIZE * 2 // headroom so audio thread can't overrun a snapshot read
MAX_CHANNELS :: 2

DB_FLOOR :: f32(-100)
SMOOTH_ALPHA :: f32(0.5)


ScopeyProcessState :: struct {
	backing_bufs: [MAX_CHANNELS][RING_SIZE]f32,
	rings: [MAX_CHANNELS]dsp.RingBuffer,
}

ScopeyControlState :: struct {
	fft_window: [FFT_SIZE]f32,
	fft_window_gain: f32,

	analysis: AnalysisFrame,
}

AnalysisFrame :: struct {
	sample_rate: f32,
	num_channels: int,

	time: [MAX_CHANNELS][FFT_SIZE]f32, // latest FFT_SIZE samples per channel
	time_valid: [MAX_CHANNELS]int,

	// Magnitudes in dBFS, normalized for FFT size and window coherent gain
	fft_db: [MAX_CHANNELS][FFT_SIZE / 2]f32,
	fft_smooth_db: [MAX_CHANNELS][FFT_SIZE / 2]f32, // exp-avg across frames

	peak: [MAX_CHANNELS]f32,
	rms: [MAX_CHANNELS]f32,
}

@(rodata) scopey_param_table := [?]b.ParamDescriptor {
}

scopey_get_plugin_descriptor :: proc() -> PluginDescriptor {
	return {
		name = "Scopey",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Effect,
		params = scopey_param_table[:],
		max_channels = MAX_CHANNELS,

		view = ViewConfig {
			default_width = 640,
			default_height = 480,
			resizable = true,
		},
	}
}

scopey_process_audio :: proc(plug: ^PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.state == nil do return
	if actx.numChannels == 0 || actx.numSamples == 0 do return

	n := actx.numSamples
	num_channels := min(actx.numChannels, MAX_CHANNELS)

	for c in 0 ..< num_channels {
		if actx.inputs[c] == nil || actx.outputs[c] == nil do continue
		copy(actx.outputs[c][:n], actx.inputs[c][:n])
		dsp.ring_write_buf(&plug.state.rings[c], actx.inputs[c][:n])
	}
}

scopey_run_analysis :: proc(plug: ^PluginController) {
	a := &plug.state.analysis

	if plug.processor_peer == nil || plug.processor_peer.audioProcessor == nil {
		a.num_channels = 0
		return
	}
	actx := plug.processor_peer.audioProcessor
	a.sample_rate = f32(actx.sampleRate)
	a.num_channels = min(actx.numChannels, MAX_CHANNELS)

	fft_buf: [FFT_SIZE]complex64

	for c in 0 ..< a.num_channels {
		n := dsp.ring_read_latest(&plug.processor_peer.state.rings[c], a.time[c][:])
		a.time_valid[c] = n

		peak: f32 = 0
		sum_sq: f32 = 0
		for s in a.time[c][:n] {
			ab := abs(s)
			if ab > peak do peak = ab
			sum_sq += s * s
		}
		a.peak[c] = peak
		a.rms[c] = math.sqrt(sum_sq / f32(max(n, 1)))

		if n < FFT_SIZE do continue

		// mean: f32 = 0
		// for s in a.time[c] do mean += s
		// mean /= f32(FFT_SIZE)
		// for &s in a.time[c] do s -= mean
		// for &s in windowed do s -= mean

		// for i in 0 ..< FFT_SIZE do fft_buf[i] = complex64((a.time[c][i] - mean) * plug.state.fft_window[i])
		windowed := a.time[c] * plug.state.fft_window
		for v, i in windowed do fft_buf[i] = complex64(v)
		dit.fft(&fft_buf[0], FFT_SIZE)

		// FFT_SIZE/2 normalizes the one-sided bin energy; window gain undoes Hann's amplitude bias.
		norm := f32(FFT_SIZE / 2) * plug.state.fft_window_gain
		for i in 0 ..< FFT_SIZE / 2 {
			v := fft_buf[i]
			mag := math.sqrt(real(v) * real(v) + imag(v) * imag(v)) / norm
			// Bin 0 (DC) has no negative-frequency mirror; the 2x baked into `norm`
			// for the one-sided spectrum doesn't apply to it.
			if i == 0 do mag *= 0.5
			db := DB_FLOOR
			if mag > 1e-10 do db = max(20 * math.log10(mag), DB_FLOOR)
			a.fft_db[c][i] = db
			prev := a.fft_smooth_db[c][i]
			a.fft_smooth_db[c][i] = SMOOTH_ALPHA * db + (1 - SMOOTH_ALPHA) * prev
		}
		// if c == 0 {
		// 	log.debugf("bin 0 dB: %.1f  bin 1 dB: %.1f  bin 2 dB: %.1f  bin 5 dB: %.1f  mean: %.4f",
		// 		a.fft_db[c][0], a.fft_db[c][1], a.fft_db[c][2], a.fft_db[c][5], mean)
		// }
	}
}

draw_canvas_frame :: proc(ctx: ^UIContext, comp: ^Component) {
	draw_push_rect(ctx.plugin.draw, SimpleUIRect {
		x = comp.calcBounds.x, y = comp.calcBounds.y,
		width = comp.calcBounds.w, height = comp.calcBounds.h,
		color = {0, 0, 0, 0},
		cornerRad = 10,
		borderColor = {80, 80, 80, 255},
		borderWidth = 1.2,
	})
}

draw_spectrum_analyzer_canvas :: proc(ctx: ^UIContext, comp: ^Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
	bounds := comp.calcBounds
	a := cast(^AnalysisFrame)data
	if a == nil || a.sample_rate <= 0 do return

	// bounds.x += 5
	// bounds.y -= 5
	// bounds.w -= 10
	// bounds.h -= 10

	draw_text(ctx.plugin.draw, "1k", bounds.x + bounds.w / 2, bounds.y + bounds.h / 2, color = {80, 80, 80, 255}, size = 16)

	FMIN :: f32(10)
	FMAX :: f32(20000)
	DB_TOP :: f32(0)

	log_span := math.log10(FMAX / FMIN)
	fft_size := f32(FFT_SIZE)

	cols :[]ColorU8= {{255,100, 100, 255}, {100, 100, 255, 255}}

	pts: [FFT_SIZE / 2]Vec2f
	for c in 0 ..< a.num_channels {
		n := 0
		for i in 1 ..< FFT_SIZE / 2 { // skip DC
			freq := f32(i) * a.sample_rate / fft_size
			if freq < FMIN do continue
			if freq > FMAX do break
			db := a.fft_smooth_db[c][i]
			x := bounds.x + bounds.w * (math.log10(freq / FMIN) / log_span)
			if n == 0 do x = bounds.x // snap first plotted bin to the left edge (bin 1 at FMIN=10 falls ~2% in)
			t := clamp((db - DB_FLOOR) / (DB_TOP - DB_FLOOR), 0, 1)
			y := bounds.y + bounds.h * (1 - t)
			pts[n] = {x, y}
			n += 1
		}
		if n >= 2 do draw_polyline(ctx.plugin.draw, pts[:n], thickness = 5, color = cols[c], border_width = 1, border_color = {255, 255, 255, 255})
	}
}

draw_oscilloscope_canvas :: proc(ctx: ^UIContext, comp: ^Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
}

// Main draw proc
scopey_draw :: proc(plug: ^PluginController) {
	scopey_run_analysis(plug)
	a := &plug.state.analysis

	draw_set_clear_color(plug.draw, ColorF32_from_ColorU8(plug.ui.theme.bgColor))
	draw_clear(plug.draw)

	if ui_frame_scoped(plug.ui) {
		if ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10, padding = 10, skipDraw = true) {
			ui_label(plug.ui, "Scopey")
			if ui_panel(plug.ui, dir=.HORIZONTAL, sizingHoriz= {type = .GROW}, sizingVert = {type = .GROW}, padding = 0, child_gaps = 10, skipDraw = true) {
				// Will be scope (with slider underneath for zoom, maybe??)
				ui_canvas(plug.ui, draw_oscilloscope_canvas, a)
				// Will be david lu esque hilbert transform scope
				ui_canvas(plug.ui, draw_oscilloscope_canvas, a)
				// Will be meter
				ui_canvas(plug.ui, draw_oscilloscope_canvas, a, sizingHoriz = AxisSizing{type = .FIXED, value = 20})
			}
			// Spectrum analyzer
			ui_canvas(plug.ui, draw_spectrum_analyzer_canvas, a)
		}
	}

	draw_submit(plug.draw)
}

scopey_setup_controller :: proc(plug: ^PluginController) {
	dsp.window_fill(plug.state.fft_window[:], .Hann)
	plug.state.fft_window_gain = dsp.window_coherent_gain(plug.state.fft_window[:])
	// Init smoothed to floor (-100db)
	for c in 0..<MAX_CHANNELS {
		for i in 0..<FFT_SIZE / 2 {
			plug.state.analysis.fft_smooth_db[c][i] = DB_FLOOR
		}
	}
}

scopey_setup_processor :: proc(plug: ^PluginProcessor) {
	for c in 0 ..< MAX_CHANNELS {
		dsp.ring_init(&plug.state.rings[c], plug.state.backing_bufs[c][:])
	}
}

scopey_api :: PluginApi {
	get_plugin_descriptor = scopey_get_plugin_descriptor,
	process_audio         = scopey_process_audio,
	draw                  = scopey_draw,

	setup_controller      = scopey_setup_controller,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = scopey_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = nil,
	reset                 = nil,
}

} // when block
