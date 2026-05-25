package lindale

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:log"
import b "../bridge"
import "../dsp"
import dit "../thirdparty/uFFT_DIT"

when b.ACTIVE_PLUGIN == "scopey" {

FFT_SIZE :: 4096
RING_SIZE :: FFT_SIZE * 8 // headroom so audio thread can't overrun a snapshot read
MAX_CHANNELS :: 2

DB_FLOOR :: f32(-100)
SMOOTH_ALPHA :: f32(0.3)
RMS_INTEGRATION_SEC :: f32(0.2)

// Hilbert FIR parameters - I don't understand this yet
HILBERT_N :: 511 // logical FIR length, clean magnitude down to ~300 Hz at 48 kHz
HILBERT_TAPS :: (HILBERT_N + 1) / 2 // packed nonzero taps
HILBERT_DELAY :: 2 * HILBERT_N + 8 // double-write + 8-float SIMD tail pad
TRAIL_HISTORY :: 8192
// AGC to scale to viewport size
AGC_TARGET_FILL :: f32(0.8) // peak |z| mapped to this fraction of canvas radius
AGC_NOISE_FLOOR :: f32(0.05) // below this, gain saturates so silence stays a dot
AGC_RELEASE :: f32(0.04) // smoothing toward larger gains (quieter signal); ~400 ms at 60 fps

TrailPoint :: struct {
	r, im: f32,
}

ScopeyProcessState :: struct {
	backing_bufs: [MAX_CHANNELS][RING_SIZE]f32,
	rings: [MAX_CHANNELS]dsp.RingBuffer,
	dc_blockers: [MAX_CHANNELS]dsp.DCBlocker,

	peak: [MAX_CHANNELS]f32,
	rms: [MAX_CHANNELS]f32,
	rms_accum: [MAX_CHANNELS]f32, // audio-thread-private mean-square accumulator

	// Single mono Hilbert path, L+R averaged on the audio thread, then one FIR + one analytic ring
	hilbert_coeffs: [HILBERT_TAPS]f32,
	hilbert_delay: [HILBERT_DELAY]f32,
	hilbert_fir: dsp.HilbertFIR,
	analytic_buf: [RING_SIZE * 2]f32, // interleaved (r, im) pairs
	analytic_ring: dsp.RingBuffer,
}

ScopeyControlState :: struct {
	fft_window: [FFT_SIZE]f32,
	fft_window_gain: f32,

	analysis: AnalysisFrame,
}

AnalysisFrame :: struct {
	sample_rate: f32,
	num_channels: int,

	// Magnitudes in dBFS, normalized for FFT size and window coherent gain
	fft_db: [MAX_CHANNELS][FFT_SIZE / 2]f32,
	fft_smooth_db: [MAX_CHANNELS][FFT_SIZE / 2]f32, // exp-avg across frames

	// Latest atomic snapshot of audio-thread meters
	peak: [MAX_CHANNELS]f32,
	rms: [MAX_CHANNELS]f32,

	// Controller-side trail ring buf for the Hilbert Lissajous
	trail: [TRAIL_HISTORY]TrailPoint,
	trail_write: int,
	trail_count: int,

	agc_gain: f32, // instant attack, slow release
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

	// EMA decay per sample for the running mean-square, converted from the integration time
	rms_decay := 1.0 - 1.0 / (f32(actx.sampleRate) * RMS_INTEGRATION_SEC)
	rms_input_gain := 1.0 - rms_decay

	// Accumulate the mono mix as we DC-block each channel. Only [0..n) is used.
	mono_buf: [RING_SIZE]f32
	inv_chan := 1.0 / f32(num_channels)

	for c in 0 ..< num_channels {
		if actx.inputs[c] == nil || actx.outputs[c] == nil do continue
		copy(actx.outputs[c][:n], actx.inputs[c][:n]) // raw passthrough out to host

		blocked_buf: [RING_SIZE]f32
		copy(blocked_buf[:n], actx.inputs[c][:n])
		dsp.dc_blocker_process_buf(&plug.state.dc_blockers[c], blocked_buf[:n])
		dsp.ring_write_buf(&plug.state.rings[c], blocked_buf[:n])

		peak: f32 = 0
		accum := plug.state.rms_accum[c]
		for i in 0 ..< n {
			s := blocked_buf[i]
			ab := abs(s)
			if ab > peak do peak = ab
			accum = accum * rms_decay + s * s * rms_input_gain
			mono_buf[i] += s * inv_chan
		}
		plug.state.rms_accum[c] = accum
		intrinsics.atomic_store_explicit(&plug.state.peak[c], peak, .Release)
		intrinsics.atomic_store_explicit(&plug.state.rms[c], math.sqrt(accum), .Release)
	}

	// Mono signal -> Hilbert FIR -> interleaved (r, im) pairs into the analytic ring.
	for i in 0 ..< n {
		r, im := dsp.hilbert_fir_process(&plug.state.hilbert_fir, mono_buf[i])
		pair := [2]f32{r, im}
		dsp.ring_write_buf(&plug.state.analytic_ring, pair[:])
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

	// Meters: pull the audio-thread's latest published scalars.
	for c in 0 ..< a.num_channels {
		a.peak[c] = intrinsics.atomic_load_explicit(&plug.processor_peer.state.peak[c], .Acquire)
		a.rms[c] = intrinsics.atomic_load_explicit(&plug.processor_peer.state.rms[c], .Acquire)
	}

	fft_buf: [FFT_SIZE]complex64

	// FFT: snapshot the latest FFT_SIZE samples of each ring
	for c in 0 ..< a.num_channels {
		time_slice: [FFT_SIZE]f32
		n := dsp.ring_read_latest(&plug.processor_peer.state.rings[c], time_slice[:])
		if n < FFT_SIZE do continue

		windowed := time_slice * plug.state.fft_window
		for v, i in windowed do fft_buf[i] = complex64(v)
		dit.fft(&fft_buf[0], FFT_SIZE)

		// FFT_SIZE/2 normalizes the one-sided bin energy; window gain undoes Hann's amplitude bias.
		norm := f32(FFT_SIZE / 2) * plug.state.fft_window_gain
		for i in 1 ..< FFT_SIZE / 2 {
			v := fft_buf[i]
			mag := math.sqrt(real(v) * real(v) + imag(v) * imag(v)) / norm
			db := DB_FLOOR
			if mag > 1e-10 do db = max(20 * math.log10(mag), DB_FLOOR)
			a.fft_db[c][i] = db
			prev := a.fft_smooth_db[c][i]
			a.fft_smooth_db[c][i] = SMOOTH_ALPHA * db + (1 - SMOOTH_ALPHA) * prev
		}
	}

	// Drain newly-produced analytic pairs into the controller-side trail ring.
	drain_buf: [RING_SIZE]f32
	got := dsp.ring_read(&plug.processor_peer.state.analytic_ring, drain_buf[:])
	pairs := got / 2
	peak2: f32 = 0 // track squared magnitude to skip per-sample sqrt
	for i in 0 ..< pairs {
		r := drain_buf[2 * i]
		im := drain_buf[2 * i + 1]
		m2 := r * r + im * im
		if m2 > peak2 do peak2 = m2
		a.trail[a.trail_write] = TrailPoint{r = r, im = im}
		a.trail_write = (a.trail_write + 1) % TRAIL_HISTORY
		if a.trail_count < TRAIL_HISTORY do a.trail_count += 1
	}

	// AGC
	peak := math.sqrt(peak2)
	target_gain := AGC_TARGET_FILL / max(peak, AGC_NOISE_FLOOR)
	if target_gain < a.agc_gain {
		a.agc_gain = target_gain
	} else {
		a.agc_gain += (target_gain - a.agc_gain) * AGC_RELEASE
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

	spectrum_offset_x :: 12
	spectrum_offset_y :: 20

	// Adjust bounds to leave room for axes labels
	bounds.x += spectrum_offset_x
	bounds.y += 2
	bounds.w -= spectrum_offset_x + 2
	bounds.h -= spectrum_offset_y

	FMIN :: f32(10)
	FMAX :: f32(20000)
	DB_TOP :: f32(0)

	log_span := math.log10(FMAX / FMIN)
	fft_size := f32(FFT_SIZE)

	label_color := ColorU8{80, 80, 80, 255}
	grid_color := ColorU8{50, 50, 50, 255}
	label_size := f32(16)

	decades := [?]struct{f: f32, label: string}{{10, "10"}, {100, "100"}, {1000, "1k"}, {10000, "10k"}}
	for decade in decades {
		// 9 gridlines per decade: the decade itself (k*1) plus k*2..k*9
		for k in 1 ..= 9 {
			f := decade.f * f32(k)
			if f >= FMAX do break
			x := bounds.x + bounds.w * (math.log10(f / FMIN) / log_span)
			draw_push_pill(ctx.plugin.draw, {x, bounds.y}, {x, bounds.y + bounds.h}, 1, grid_color)
		}
		x := bounds.x + bounds.w * (math.log10(decade.f / FMIN) / log_span)
		tw := draw_measure_text(ctx.plugin.draw, decade.label, label_size).x
		draw_text(ctx.plugin.draw, decade.label, x - tw / 2, bounds.y + bounds.h + 1, color = label_color, size = label_size)
	}

	// dBFS gridlines and labels every 20db
	for db := DB_TOP; db >= DB_FLOOR; db -= 20 {
		t := (db - DB_FLOOR) / (DB_TOP - DB_FLOOR)
		y := bounds.y + bounds.h * (1 - t)
		if db != DB_TOP do draw_push_pill(ctx.plugin.draw, {bounds.x, y}, {bounds.x + bounds.w, y}, 1, grid_color)
		s := fmt.tprintf("%d", int(db))
		tsz := draw_measure_text(ctx.plugin.draw, s, label_size)
		if db != DB_FLOOR do draw_text(ctx.plugin.draw, s, bounds.x + 2, y, color = label_color, size = label_size)
	}

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
			if n == 0 do x = bounds.x // snap first plotted bin to the left edge (bin 1 slightly past fmin=10)
			t := clamp((db - DB_FLOOR) / (DB_TOP - DB_FLOOR), 0, 1)
			y := bounds.y + bounds.h * (1 - t)
			pts[n] = {x, y}
			n += 1
		}
		if n >= 2 do draw_polyline(ctx.plugin.draw, pts[:n], thickness = 1.4, color = cols[c],)
	}
}

draw_oscilloscope_canvas :: proc(ctx: ^UIContext, comp: ^Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
}

draw_hilbert_canvas :: proc(ctx: ^UIContext, comp: ^Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
	bounds := comp.calcBounds
	a := cast(^AnalysisFrame)data
	if a == nil do return

	sx:=bounds.x
	sy:=bounds.y + bounds.h / 2

	cx := bounds.x + bounds.w / 2
	cy := bounds.y + bounds.h / 2
	// AGC maps peak |z| to AGC_TARGET_FILL of canvas radius (min/2); scale folds gain in
	scale := min(bounds.w, bounds.h) * 0.5 * a.agc_gain

	n := a.trail_count
	if n < 2 do return

	start := (a.trail_write + TRAIL_HISTORY - n) % TRAIL_HISTORY
	inv_n := 1.0 / f32(n - 1)
	for k in 0 ..< n - 1 {
		p0 := a.trail[(start + k) % TRAIL_HISTORY]
		p1 := a.trail[(start + k + 1) % TRAIL_HISTORY]
		alpha := f32(k) * inv_n // 0 at oldest, 1 at newest
		col := ColorU8{200, 200, 200, u8(alpha * 255)}
		x0 := cx + p0.r * scale
		y0 := cy - p0.im * scale // screen y grows down → negate imag
		x1 := cx + p1.r * scale
		y1 := cy - p1.im * scale
		draw_push_pill(ctx.plugin.draw, {x0, y0}, {x1, y1}, 1, col)
	}
}

draw_meter_canvas :: proc(ctx: ^UIContext, comp: ^Component, data: rawptr) {
	bounds := comp.calcBounds
	a := cast(^AnalysisFrame)data

	bounds.y += 4
	bounds.h -= 8

	METER_OFFSET_X :: 22
	STEREO_SPACING_PX :: 4
	bounds.x += METER_OFFSET_X
	bounds.w -= METER_OFFSET_X
	meterW := (bounds.w - STEREO_SPACING_PX) / 2

	MIN_DB :: f32(-60)
	ORANGE_DB :: f32(-12)
	RED_DB :: f32(-6)
	MAX_DB :: f32(0)

	pix_per_db := bounds.h / (MAX_DB - MIN_DB)
	segments := [?]struct { top_db: f32, peak_color, rms_color: ColorU8 } {
		{ORANGE_DB, {0, 200, 80, 150},  {0, 200, 80, 255}},
		{RED_DB, {220, 120, 0, 150}, {220, 120, 0, 255}},
		{MAX_DB, {255, 20, 50, 150}, {255, 20, 50, 255}},
	}

	// labels every 6 dB
	label_color := ColorU8 {80, 80, 80, 255}
	grid_color := ColorU8 {50, 50, 50, 255}
	label_size := f32(11)
	for db := MAX_DB; db >= MIN_DB; db -= 6 {
		y := bounds.y + bounds.h * (1 - (db - MIN_DB) / (MAX_DB - MIN_DB))
		s := fmt.tprintf("%d", int(db))
		tsz := draw_measure_text(ctx.plugin.draw, s, label_size)
		draw_text(ctx.plugin.draw, s, bounds.x - tsz.x - 4, y - tsz.y / 2, color = label_color, size = label_size)
		draw_push_pill(ctx.plugin.draw, {bounds.x, y}, {bounds.x + bounds.w, y}, 1, grid_color)
	}

	// Peak first, RMS on top
	for is_peak in ([?]bool{true, false}) {
		for i in 0 ..< a.num_channels {
			dbs := linear_to_decibels(is_peak ? a.peak[i] : a.rms[i])
			if dbs < MIN_DB do continue
			x := bounds.x + f32(i) * (meterW + STEREO_SPACING_PX)
			prev_db := MIN_DB
			for seg in segments {
				top_db := min(dbs, seg.top_db)
				if top_db <= prev_db do break
				h := pix_per_db * (top_db - prev_db)
				y := bounds.y + bounds.h - pix_per_db * (top_db - MIN_DB)
				color := is_peak ? seg.peak_color : seg.rms_color
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = x, y = y, width = meterW, height = h,
					color = color, cornerRad = 2,
				})
				prev_db = seg.top_db
			}
		}
	}
}

// Main draw proc
scopey_draw :: proc(plug: ^PluginController) {
	scopey_run_analysis(plug)
	a := &plug.state.analysis

	draw_set_clear_color(plug.draw, ColorF32_from_ColorU8(plug.ui.theme.bgColor))
	draw_clear(plug.draw)

	if ui_frame_scoped(plug.ui) {
		if ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10, padding = 10, skipDraw = true) {
			if ui_panel(plug.ui, dir=.HORIZONTAL, sizingHoriz= {type = .GROW}, sizingVert = {type = .GROW}, padding = 0, child_gaps = 10, skipDraw = true) {
				// Will be scope (with slider underneath for zoom, maybe??)
				ui_canvas(plug.ui, draw_oscilloscope_canvas, a)
				// Meter (rms plus peaks)
				ui_canvas(plug.ui, draw_meter_canvas, a, sizingHoriz = AxisSizing{type = .FIXED, value = 60})
				// david lu esque hilbert transform scope
				ui_canvas(plug.ui, draw_hilbert_canvas, a)
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
	plug.state.analysis.agc_gain = 1
}

scopey_setup_processor :: proc(plug: ^PluginProcessor) {
	for c in 0 ..< MAX_CHANNELS {
		dsp.ring_init(&plug.state.rings[c], plug.state.backing_bufs[c][:])
		dsp.dc_blocker_init(&plug.state.dc_blockers[c], 0.999) // ~7.6 Hz cutoff at 48k
	}
	dsp.hilbert_fir_init(&plug.state.hilbert_fir, plug.state.hilbert_coeffs[:], plug.state.hilbert_delay[:])
	dsp.ring_init(&plug.state.analytic_ring, plug.state.analytic_buf[:])
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
