package facet

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:log"
import "../../../src/sdk"
import b "../../../src/bridge"
import "../../../src/dsp"

@(export)
get_plugin_api :: proc() -> sdk.PluginApi {
	return sdk.FALLBACK_API
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(facet_api)
}

PLUGIN_VERSION :: #config(PLUGIN_VERSION, "0.0.0")

MAX_FFT_SIZE :: 8192
RING_SIZE :: MAX_FFT_SIZE * 2
MAX_CHANNELS :: 8
ANALYSIS_CHANNELS :: 2

DB_FLOOR :: f32(-100)
DB_TOP :: f32(0)
FMIN :: f32(10)
FMAX :: f32(20000)
SMOOTH_ALPHA :: f32(0.3)
RMS_INTEGRATION_SEC :: f32(0.2)

PEAK_HOLD_SEC :: f32(1.5)
PEAK_HOLD_FALL_DB_PER_SEC :: f32(20)
METER_RELEASE_DB_PER_SEC :: f32(80)

DC_BLOCK_HZ :: f32(7.6)

// Hilbert FIR parameters - I don't understand this yet
HILBERT_N :: 511 // logical FIR length, clean magnitude down to ~300 Hz at 48 kHz
HILBERT_TAPS :: (HILBERT_N + 1) / 2 // packed nonzero taps
HILBERT_DELAY :: 2 * HILBERT_N + 8 // double-write + 8-float SIMD tail pad

TRAIL_SEC :: f32(0.085)
TRAIL_SIZE :: 4096
HILBERT_TRAIL_SIZE :: TRAIL_SIZE
GONIOMETER_TRAIL_SIZE :: TRAIL_SIZE

// AGC to scale to viewport size
AGC_TARGET_FILL :: f32(0.8) // peak |z| mapped to this fraction of canvas radius
AGC_NOISE_FLOOR :: f32(0.05) // below this, gain saturates so silence stays a dot
AGC_RELEASE :: f32(0.04)

// Decay numbers for plugin bypass
INACTIVE_THRESHOLD_SEC :: f32(0.15)
INACTIVE_TRAIL_DECAY :: f32(0.85)

LABEL_COLOR : sdk.ColorU8 : {80, 80, 80, 255}
GRID_COLOR : sdk.ColorU8 : {50, 50, 50, 255}
LABEL_SIZE :: f32(16)
METER_LABEL_SIZE :: f32(11)
LABEL_PAD :: f32(3)
SPECTRUM_CONTROLS_INSET :: f32(8)
CONTROL_BG_ALPHA :: u8(0x80)
CONTROL_TEXT_COLOR : sdk.ColorU8 : {126, 126, 126, 255}
CONTROL_BORDER_COLOR : sdk.ColorU8 : {60, 60, 60, 255}
CONTROL_HOVER_COLOR : sdk.ColorU8 : {0x40, 0x42, 0x40, CONTROL_BG_ALPHA}

PARAM_FFT_SIZE :: sdk.ParamIndex(0)
PARAM_FFT_MODE :: sdk.ParamIndex(1)
@(rodata) facet_param_table := [?]b.ParamDescriptor {
	{ name = "FFT Size", short_name = "fftsz", min = 0, max = 3, default_value = 2,
		step_count = 3, unit = .None, flags = {.List, .Hidden}, smooth_ms = sdk.NO_SMOOTHING,
	},
	{ name = "FFT Mode", short_name = "fftmd", min = 0, max = 4, default_value = 0,
		step_count = 4, unit = .None, flags = {.List, .Hidden}, smooth_ms = sdk.NO_SMOOTHING,
	},
}

FacetProcessState :: struct {
	backing_bufs: [ANALYSIS_CHANNELS][RING_SIZE]f32,
	rings: [ANALYSIS_CHANNELS]dsp.RingBuffer(dsp.Sample),
	dc_blockers: [ANALYSIS_CHANNELS]dsp.DCBlocker,

	peak: [ANALYSIS_CHANNELS]f32,
	peak_follow: [ANALYSIS_CHANNELS]f32,
	rms: [ANALYSIS_CHANNELS]f32,
	rms_accum: [ANALYSIS_CHANNELS]f32,

	// Single mono Hilbert path, L+R averaged on the audio thread
	hilbert_coeffs: [HILBERT_TAPS]f32,
	hilbert_delay: [HILBERT_DELAY]f32,
	hilbert_fir: dsp.HilbertFIR,
	analytic_buf: [RING_SIZE * 2]f32, // interleaved (r, im) pairs
	analytic_ring: dsp.RingBuffer(dsp.Sample),
}

FacetControlState :: struct {
	fft_window: []f32,
	fft_window_backing: [MAX_FFT_SIZE]f32,
	fft_window_gain: f32,
	fft: dsp.Radix2FFT,
	twiddles: [MAX_FFT_SIZE / 2]complex64,

	analysis: AnalysisFrame,
}

AnalysisFrame :: struct {
	sample_rate: f32,
	num_channels: int,

	fft_size: int,
	fft_mode: FFTMode,
	fft_num_traces: int,
	fft_smooth_db: [ANALYSIS_CHANNELS][MAX_FFT_SIZE / 2]f32, // exp-avg across frames

	peak: [ANALYSIS_CHANNELS]f32,
	peak_hold: [ANALYSIS_CHANNELS]f32,
	peak_hold_age: [ANALYSIS_CHANNELS]f32, // in seconds
	rms: [ANALYSIS_CHANNELS]f32,

	goniometer_trail: [2][GONIOMETER_TRAIL_SIZE]f32,
	goniometer_trail_count: int,

	hilbert_trail: [HILBERT_TRAIL_SIZE]complex64,
	hilbert_trail_write: int,
	hilbert_trail_count: int,

	agc_gain: f32, // instant attack, slow release
	gonio_gain: f32, // goniometer-specific AGC from peak sqrt(L^2+R^2)

	last_analytic_pos: int, // last seen processor analytic write position
	silence_age: f32, // seconds since the processor last produced samples
}

facet_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		name = "Facet",
		vendor = "JagI",
		version = PLUGIN_VERSION,
		plugin_type = .Effect,
		params = facet_param_table[:],
		max_channels = MAX_CHANNELS,

		view = sdk.ViewConfig {
			default_width = 640,
			default_height = 480,
			min_width = 320, min_height = 240,
			resizable = true,
		},
	}
}

facet_process_audio :: proc(plug: ^sdk.PluginProcessor) {
	actx := plug.audio_processor
	if actx == nil do return
	if plug.state == nil do return
	if actx.num_channels == 0 || actx.num_samples == 0 do return
	state := cast(^FacetProcessState)plug.state

	n := actx.num_samples
	num_channels := min(actx.num_channels, MAX_CHANNELS)

	// EMA decay per sample for the running mean-square, converted from the integration time
	rms_decay := 1.0 - 1.0 / (f32(actx.sample_rate) * RMS_INTEGRATION_SEC)
	rms_input_gain := 1.0 - rms_decay

	// Per-sample peak-follower release coeff from the fall rate; instant attack is the max() below
	meter_release := math.pow(f32(10), -METER_RELEASE_DB_PER_SEC / (20 * f32(actx.sample_rate)))

	// Accumulate the mono mix as we DC-block each channel
	mono_buf := make([]f32, n, allocator = context.temp_allocator)
	blocked_buf := make([]f32, n, allocator = context.temp_allocator)
	inv_chan := 1.0 / f32(min(num_channels, ANALYSIS_CHANNELS))

	for c in 0 ..< num_channels {
		input := actx.inputs[c]
		output := actx.outputs[c]

		// Unconnected input reads as silence so the channel still meters and its output clears
		if input != nil {
			copy(blocked_buf, input[:n])
		} else {
			for i in 0 ..< n do blocked_buf[i] = 0
		}
		if output != nil do copy(output[:n], blocked_buf) // raw passthrough out to host
		if c >= ANALYSIS_CHANNELS do continue

		dsp.dc_blocker_process_buf(&state.dc_blockers[c], blocked_buf)
		dsp.ring_write_buf(&state.rings[c], blocked_buf)

		follow := state.peak_follow[c]
		accum := state.rms_accum[c]
		for i in 0 ..< n {
			s := blocked_buf[i]
			follow = max(abs(s), follow * meter_release)
			accum = accum * rms_decay + s * s * rms_input_gain
			mono_buf[i] += s * inv_chan
		}
		state.peak_follow[c] = dsp.flush_denormal(follow)
		state.rms_accum[c] = dsp.flush_denormal(accum)
		intrinsics.atomic_store_explicit(&state.peak[c], follow, .Release)
		intrinsics.atomic_store_explicit(&state.rms[c], math.sqrt(accum), .Release)
	}

	// Mono signal -> Hilbert FIR -> interleaved (r, im) pairs into the analytic ring
	pairs := make([]f32, 2 * n, allocator = context.temp_allocator)
	for i in 0 ..< n {
		r, im := dsp.hilbert_fir_process(&state.hilbert_fir, mono_buf[i])
		pairs[2 * i] = r
		pairs[2 * i + 1] = im
	}
	dsp.ring_write_buf(&state.analytic_ring, pairs)
}

facet_run_analysis :: proc(plug: ^sdk.PluginController) {
	state := cast(^FacetControlState)plug.state
	a := &state.analysis

	if plug.processor_peer == nil || plug.processor_peer.audio_processor == nil {
		a.num_channels = 0
		return
	}

	process_state := cast(^FacetProcessState)plug.processor_peer.state
	if process_state == nil { // processor exists but setup_processor hasn't run yet
		a.num_channels = 0
		return
	}
	actx := plug.processor_peer.audio_processor
	a.sample_rate = f32(actx.sample_rate)
	a.num_channels = min(actx.num_channels, ANALYSIS_CHANNELS)
	if a.sample_rate <= 0 do return // host hasn't set up processing yet
	dt := plug.frame_dt
	trail_len := clamp(int(a.sample_rate * TRAIL_SEC), 2, TRAIL_SIZE)

	// The analytic ring advances on every process call. If it hasn't for a while, the host has
	// stopped processing (bypass/disable) and we decay the display to rest
	analytic_pos := dsp.ring_get_write_pos(&process_state.analytic_ring)
	if analytic_pos != a.last_analytic_pos {
		a.last_analytic_pos = analytic_pos
		a.silence_age = 0
	} else {
		a.silence_age += dt
	}
	active := a.silence_age < INACTIVE_THRESHOLD_SEC

	// Handle meter - fetch updated peak/rms values, or decay towards zero if silence
	meter_release := math.pow(f32(10), -(METER_RELEASE_DB_PER_SEC * dt) / 20)
	for c in 0 ..< a.num_channels {
		if active {
			a.peak[c] = intrinsics.atomic_load_explicit(&process_state.peak[c], .Acquire)
			a.rms[c] = intrinsics.atomic_load_explicit(&process_state.rms[c], .Acquire)
		} else {
			a.peak[c] *= meter_release
			a.rms[c] *= meter_release
		}
		if a.peak[c] >= a.peak_hold[c] {
			a.peak_hold[c] = a.peak[c]
			a.peak_hold_age[c] = 0
		} else {
			a.peak_hold_age[c] += dt
			if a.peak_hold_age[c] > PEAK_HOLD_SEC {
				a.peak_hold[c] *= math.pow(f32(10), -(PEAK_HOLD_FALL_DB_PER_SEC * dt) / 20)
			}
		}
	}

	// FFT
	fft_size := get_fft_size(plug.host.params)
	if fft_size != state.fft.n do init_fft(plug, state) // param changed the size so reinit
	a.fft_size = int(fft_size)
	mode := get_fft_mode(plug.host.params)
	// silence fft buf when mode is changed (current data is dirty)
	if mode != a.fft_mode {
		a.fft_mode = mode
		for t in 0 ..< ANALYSIS_CHANNELS {
			for i in 0 ..< fft_size / 2 do a.fft_smooth_db[t][i] = DB_FLOOR
		}
	}
	a.fft_num_traces = fft_mode_trace_count(mode, a.num_channels)

	if active {
		// goniometer
		if a.num_channels >= 2 {
			end := min(
				dsp.ring_get_write_pos(&process_state.rings[0]),
				dsp.ring_get_write_pos(&process_state.rings[1]),
			)
			nl := dsp.ring_read_window(&process_state.rings[0], end, a.goniometer_trail[0][:trail_len])
			nr := dsp.ring_read_window(&process_state.rings[1], end, a.goniometer_trail[1][:trail_len])
			a.goniometer_trail_count = min(nl, nr)
		} else { // mono
			// mirror L to R
			end := dsp.ring_get_write_pos(&process_state.rings[0])
			n := dsp.ring_read_window(&process_state.rings[0], end, a.goniometer_trail[0][:trail_len])
			copy(a.goniometer_trail[1][:n], a.goniometer_trail[0][:n])
			a.goniometer_trail_count = n
		}
		// AGC
		gonio_peak2: f32 = 0
		for k in 0 ..< a.goniometer_trail_count {
			l := a.goniometer_trail[0][k]
			r := a.goniometer_trail[1][k]
			m2 := l * l + r * r
			if m2 > gonio_peak2 do gonio_peak2 = m2
		}
		target_gain := AGC_TARGET_FILL / max(math.sqrt(gonio_peak2), AGC_NOISE_FLOOR)
		if target_gain < a.gonio_gain {
			a.gonio_gain = target_gain
		} else {
			a.gonio_gain += (target_gain - a.gonio_gain) * AGC_RELEASE
		}

		// FFT
		fft_buf := make([]complex64, fft_size, allocator=context.temp_allocator)
		ch0 := make([]f32, fft_size, allocator=context.temp_allocator)
		ch1 := ch0
		n0 := dsp.ring_read_latest(&process_state.rings[0], ch0)
		n1 := n0
		if a.num_channels >= 2 {
			ch1 = make([]f32, fft_size, allocator=context.temp_allocator)
			n1 = dsp.ring_read_latest(&process_state.rings[1], ch1)
		}
		if n0 == int(fft_size) && n1 == int(fft_size) {
			trace_in := make([]f32, fft_size, allocator=context.temp_allocator)
			for t in 0 ..< a.fft_num_traces {
				src: []f32
				switch mode {
				case .Overlay: src = ch0 if t == 0 else ch1
				case .Left: src = ch0
				case .Right: src = ch1
				case .Sum: // (L+R)/2 keeps dB comparable to a single channel
					for i in 0 ..< int(fft_size) do trace_in[i] = (ch0[i] + ch1[i]) * 0.5
					src = trace_in
				case .MidSide:
					sign: f32 = 1 if t == 0 else -1
					for i in 0 ..< int(fft_size) do trace_in[i] = (ch0[i] + sign * ch1[i]) * 0.5
					src = trace_in
				}

				for v, i in src do fft_buf[i] = complex64(v * state.fft_window[i])
				dsp.radix2_fft(fft_buf[:], state.fft)

				// fft_size/2 normalizes the one-sided bin energy; window gain undoes Hann's amplitude bias.
				norm := f32(fft_size / 2) * state.fft_window_gain
				for i in 1 ..< fft_size / 2 {
					v := fft_buf[i]
					mag := math.sqrt(real(v) * real(v) + imag(v) * imag(v)) / norm
					db := DB_FLOOR
					if mag > 1e-10 do db = max(20 * math.log10(mag), DB_FLOOR)
					prev := a.fft_smooth_db[t][i]
					a.fft_smooth_db[t][i] = SMOOTH_ALPHA * db + (1 - SMOOTH_ALPHA) * prev
				}
			}
		}

		// hilbert
		drain_buf := make([]f32, RING_SIZE, allocator=context.temp_allocator)
		got := dsp.ring_read(&process_state.analytic_ring, drain_buf[:])
		pairs := got / 2
		peak2: f32 = 0 // track squared magnitude to skip per-sample sqrt
		a.hilbert_trail_count = min(a.hilbert_trail_count, trail_len)
		for i in 0 ..< pairs {
			r := drain_buf[2 * i]
			im := drain_buf[2 * i + 1]
			m2 := r * r + im * im
			if m2 > peak2 do peak2 = m2
			a.hilbert_trail[a.hilbert_trail_write] = complex(r, im)
			a.hilbert_trail_write = (a.hilbert_trail_write + 1) % HILBERT_TRAIL_SIZE
			if a.hilbert_trail_count < trail_len do a.hilbert_trail_count += 1
		}

		// AGC
		if pairs > 0 {
			peak := math.sqrt(peak2)
			target_gain := AGC_TARGET_FILL / max(peak, AGC_NOISE_FLOOR)
			if target_gain < a.agc_gain {
				a.agc_gain = target_gain
			} else {
				a.agc_gain += (target_gain - a.agc_gain) * AGC_RELEASE
			}
		}
	} else { // inactive / silent
		// goniometer
		a.goniometer_trail_count = int(f32(a.goniometer_trail_count) * INACTIVE_TRAIL_DECAY)
		// fft
		for t in 0 ..< ANALYSIS_CHANNELS { // decay to db floor
			for i in 1 ..< fft_size / 2 {
				a.fft_smooth_db[t][i] = SMOOTH_ALPHA * DB_FLOOR + (1 - SMOOTH_ALPHA) * a.fft_smooth_db[t][i]
			}
		}
		// hilbert
		a.hilbert_trail_count = int(f32(a.hilbert_trail_count) * INACTIVE_TRAIL_DECAY)
	}
}

draw_canvas_frame :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component) {
	sdk.draw_push_rect(ctx.plugin.draw, sdk.SimpleUIRect {
		x = comp.calc_bounds.x, y = comp.calc_bounds.y,
		width = comp.calc_bounds.w, height = comp.calc_bounds.h,
		color = {0, 0, 0, 0},
		corner_rad = 10,
		border_color = {80, 80, 80, 255},
		border_width = 1.2,
	})
}

spectrum_x :: #force_inline proc(bounds: sdk.RectF32, freq, log_span: f32) -> f32 {
	return bounds.x + bounds.w * (math.log10(freq / FMIN) / log_span)
}

spectrum_y :: #force_inline proc(bounds: sdk.RectF32, db: f32) -> f32 {
	return bounds.y + bounds.h * (1 - clamp((db - DB_FLOOR) / (DB_TOP - DB_FLOOR), 0, 1))
}

draw_spectrum_analyzer_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
	bounds := comp.calc_bounds
	a := cast(^AnalysisFrame)data
	if a == nil || a.sample_rate <= 0 do return

	SPECTRUM_OFFSET_X :: 12
	SPECTRUM_OFFSET_Y :: 20

	// Adjust bounds to leave room for axes labels
	bounds.x += SPECTRUM_OFFSET_X
	bounds.y += 2
	bounds.w -= SPECTRUM_OFFSET_X + 2
	bounds.h -= SPECTRUM_OFFSET_Y

	log_span := math.log10(FMAX / FMIN)
	fft_size := f32(a.fft_size)

	decades := [?]struct{f: f32, label: string}{{10, "10"}, {100, "100"}, {1000, "1k"}, {10000, "10k"}}
	for decade in decades {
		// 9 gridlines per decade
		for k in 1 ..= 9 {
			f := decade.f * f32(k)
			if f >= FMAX do break
			x := spectrum_x(bounds, f, log_span)
			sdk.draw_push_pill(ctx.plugin.draw, {x, bounds.y}, {x, bounds.y + bounds.h}, 1, GRID_COLOR)
		}
		x := spectrum_x(bounds, decade.f, log_span)
		text_w := sdk.draw_measure_text(ctx.plugin.draw, decade.label, LABEL_SIZE).x
		sdk.draw_text(ctx.plugin.draw, decade.label, x - text_w / 2, bounds.y + bounds.h + 1, color = LABEL_COLOR, size = LABEL_SIZE)
	}

	// dBFS gridlines and labels every 20db
	for db := DB_TOP; db >= DB_FLOOR; db -= 20 {
		y := spectrum_y(bounds, db)
		if db != DB_TOP do sdk.draw_push_pill(ctx.plugin.draw, {bounds.x, y}, {bounds.x + bounds.w, y}, 1, GRID_COLOR)
		if db != DB_FLOOR {
			s := fmt.tprintf("%d", int(db))
			sdk.draw_text(ctx.plugin.draw, s, bounds.x + 2, y, color = LABEL_COLOR, size = LABEL_SIZE)
		}
	}

	styles := fft_trace_styles(a.fft_mode)

	// FFT legend colored to match centered on the top edge
	LEGEND_GAP :: f32(10)
	legend_w: f32
	for t in 0 ..< a.fft_num_traces {
		if t > 0 do legend_w += LEGEND_GAP
		legend_w += sdk.draw_measure_text(ctx.plugin.draw, styles[t].label, LABEL_SIZE).x
	}
	lx := bounds.x + (bounds.w - legend_w) / 2
	for t in 0 ..< a.fft_num_traces {
		sdk.draw_text(ctx.plugin.draw, styles[t].label, lx, bounds.y + 1, styles[t].color, LABEL_SIZE)
		lx += sdk.draw_measure_text(ctx.plugin.draw, styles[t].label, LABEL_SIZE).x + LEGEND_GAP
	}

	// Interpolate between bins using catmull-rom when bins are at least SMOOTH_MIN_BIN_PX apart
	SMOOTH_MIN_BIN_PX :: f32(3)
	SMOOTH_SEG_PX :: f32(3) // px of horizontal span per tessellated curve segment
	max_i := a.fft_size / 2 - 1
	bin_hz := a.sample_rate / fft_size
	// Lowest bin at or above FMIN. Nothing below it is resolvable, so its level holds flat out to
	// the left edge and the trace spans the whole axis at every FFT size
	first_bin := max(1, int(math.ceil(FMIN / bin_hz)))
	y_lo := bounds.y
	y_hi := bounds.y + bounds.h
	unit_density_freq := bounds.w * bin_hz / (log_span * math.LN10)
	smooth_freq := clamp(unit_density_freq / SMOOTH_MIN_BIN_PX, FMIN, FMAX)

	for c in 0 ..< a.fft_num_traces {
		pts := make([dynamic]sdk.Vec2f, 0, max_i + int(bounds.w), context.temp_allocator)

		// For low freqs, catmull-rom through the bins up to the threshold
		low_pts := make([dynamic]sdk.Vec2f, 0, 256, context.temp_allocator)
		append(&low_pts, sdk.Vec2f{bounds.x, spectrum_y(bounds, a.fft_smooth_db[c][first_bin])})
		for i in 1 ..= max_i {
			freq := f32(i) * bin_hz
			if freq < FMIN do continue
			if freq > smooth_freq do break
			append(&low_pts, sdk.Vec2f{spectrum_x(bounds, freq, log_span), spectrum_y(bounds, a.fft_smooth_db[c][i])})
		}

		for k in 0 ..< max(len(low_pts) - 1, 0) {
			p0 := low_pts[max(k - 1, 0)]
			p1 := low_pts[k]
			p2 := low_pts[k + 1]
			p3 := low_pts[min(k + 2, len(low_pts) - 1)]
			segs := max(int(abs(p2.x - p1.x) / SMOOTH_SEG_PX), 1)
			for s in 0 ..< segs {
				pt := sdk.catmull_rom(p0, p1, p2, p3, f32(s) / f32(segs))
				pt.y = clamp(pt.y, y_lo, y_hi)
				append(&pts, pt)
			}
		}
		if len(low_pts) > 0 do append(&pts, low_pts[len(low_pts) - 1])

		// For high freqs, one point per bin
		for i in 1 ..= max_i {
			freq := f32(i) * bin_hz
			if freq <= smooth_freq do continue
			if freq > FMAX do break
			append(&pts, sdk.Vec2f{spectrum_x(bounds, freq, log_span), spectrum_y(bounds, a.fft_smooth_db[c][i])})
		}

		if len(pts) >= 2 do sdk.draw_polyline(ctx.plugin.draw, pts[:], thickness = 1.8, color = styles[c].color)
	}

	// frequency and dB readout at the mouse position
	mp := ctx.mouse.pos
	if mp.x >= bounds.x && mp.x < bounds.x + bounds.w && mp.y >= bounds.y && mp.y < bounds.y + bounds.h {
		freq := FMIN * math.pow(f32(10), log_span * (mp.x - bounds.x) / bounds.w)
		db := DB_TOP - (mp.y - bounds.y) / bounds.h * (DB_TOP - DB_FLOOR)
		s: string
		if freq >= 1000 {
			s = fmt.tprintf("%.2f kHz  %.1f dB", freq / 1000, db)
		} else {
			s = fmt.tprintf("%.0f Hz  %.1f dB", freq, db)
		}
		tsz := sdk.draw_measure_text(ctx.plugin.draw, s, LABEL_SIZE)
		tx := clamp(mp.x + 14, bounds.x, bounds.x + bounds.w - tsz.x)
		ty := clamp(mp.y - tsz.y - 6, bounds.y, bounds.y + bounds.h - tsz.y)
		sdk.draw_text(ctx.plugin.draw, s, tx, ty, CONTROL_TEXT_COLOR, LABEL_SIZE)
	}
}

trail_alpha :: #force_inline proc(t: f32) -> f32 {
	return t * t * t
}

draw_goniometer_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)

	bounds := comp.calc_bounds
	a := cast(^AnalysisFrame)data
	if a == nil do return

	cx := bounds.x + bounds.w / 2
	cy := bounds.y + bounds.h / 2

	SQRT_HALF :: f32(0.70710678)
	dc := ctx.plugin.draw

	m_plus := sdk.draw_measure_text(dc, "+M", LABEL_SIZE)
	m_minus := sdk.draw_measure_text(dc, "-M", LABEL_SIZE)
	s_plus := sdk.draw_measure_text(dc, "+S", LABEL_SIZE)
	s_minus := sdk.draw_measure_text(dc, "-S", LABEL_SIZE)
	l_size := sdk.draw_measure_text(dc, "L", LABEL_SIZE)
	r_size := sdk.draw_measure_text(dc, "R", LABEL_SIZE)

	radius_v := bounds.h * 0.5 - m_plus.y - LABEL_PAD
	radius_h := bounds.w * 0.5 - max(s_plus.x, s_minus.x) - LABEL_PAD * 2
	radius := min(radius_v, radius_h)
	diag := radius * SQRT_HALF

	sdk.draw_push_rect(dc, sdk.SimpleUIRect{
		x = cx - radius, y = cy - radius,
		width = radius * 2, height = radius * 2,
		corner_rad = radius,
		border_color = GRID_COLOR, border_width = 1,
	})
	sdk.draw_push_pill(dc, {cx, cy - radius}, {cx, cy + radius}, 1, GRID_COLOR)
	sdk.draw_push_pill(dc, {cx - radius, cy}, {cx + radius, cy}, 1, GRID_COLOR)
	sdk.draw_push_pill(dc, {cx - diag, cy - diag}, {cx + diag, cy + diag}, 1, GRID_COLOR)
	sdk.draw_push_pill(dc, {cx + diag, cy - diag}, {cx - diag, cy + diag}, 1, GRID_COLOR)

	scale := radius * a.gonio_gain

	n := a.goniometer_trail_count
	if n >= 2 {
		inv_n := 1.0 / f32(n - 1)
		for k in 0 ..< n {
			l := a.goniometer_trail[0][k]
			r := a.goniometer_trail[1][k]
			x := cx + (r - l) * SQRT_HALF * scale
			y := cy - (l + r) * SQRT_HALF * scale
			alpha := trail_alpha(f32(k) * inv_n)
			col := sdk.ColorU8{150, 100, 150, u8(alpha * 255)}
			sdk.draw_push_pill(dc, {x, y}, {x, y}, 2, col)
		}
	}

	sdk.draw_text(dc, "+M", cx - m_plus.x / 2, cy - radius - m_plus.y - LABEL_PAD, LABEL_COLOR, LABEL_SIZE)
	sdk.draw_text(dc, "-M", cx - m_minus.x / 2, cy + radius + LABEL_PAD, LABEL_COLOR, LABEL_SIZE)
	sdk.draw_text(dc, "+S", cx + radius + LABEL_PAD, cy - s_plus.y / 2, LABEL_COLOR, LABEL_SIZE)
	sdk.draw_text(dc, "-S", cx - radius - s_minus.x - LABEL_PAD, cy - s_minus.y / 2, LABEL_COLOR, LABEL_SIZE)
	sdk.draw_text(dc, "L", cx - diag - l_size.x - LABEL_PAD, cy - diag - l_size.y - LABEL_PAD, LABEL_COLOR, LABEL_SIZE)
	sdk.draw_text(dc, "R", cx + diag + LABEL_PAD, cy - diag - r_size.y - LABEL_PAD, LABEL_COLOR, LABEL_SIZE)
}

draw_hilbert_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
	bounds := comp.calc_bounds
	a := cast(^AnalysisFrame)data
	if a == nil do return

	cx := bounds.x + bounds.w / 2
	cy := bounds.y + bounds.h / 2
	// scale goes from 0 to (bounds / 2) ish
	scale := min(bounds.w, bounds.h) * 0.5 * a.agc_gain

	n := a.hilbert_trail_count
	if n < 2 do return

	start := (a.hilbert_trail_write + HILBERT_TRAIL_SIZE - n) % HILBERT_TRAIL_SIZE
	inv_n := 1.0 / f32(n - 1)
	trace_color := sdk.ColorU8{80, 190, 180, 255}
	thickness := clamp(min(bounds.w, bounds.h) * 0.007, 1.5, 2.5)
	for k in 0 ..< n - 1 {
		p0 := a.hilbert_trail[(start + k) % HILBERT_TRAIL_SIZE]
		p1 := a.hilbert_trail[(start + k + 1) % HILBERT_TRAIL_SIZE]
		opacity := trail_alpha(f32(k + 1) * inv_n)
		col := sdk.color_u8_lerp(ctx.theme.bg_color, trace_color, opacity)
		x0 := cx + real(p0) * scale
		y0 := cy - imag(p0) * scale
		x1 := cx + real(p1) * scale
		y1 := cy - imag(p1) * scale
		sdk.draw_push_pill(ctx.plugin.draw, {x0, y0}, {x1, y1}, thickness, col)
	}
}

draw_meter_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	bounds := comp.calc_bounds
	a := cast(^AnalysisFrame)data
	if a == nil do return

	METER_OFFSET_X :: 22
	METER_SPACING_PX :: f32(4)
	bounds.y += 4
	bounds.h -= 8
	bounds.x += METER_OFFSET_X
	bounds.w -= METER_OFFSET_X
	num_meters := max(a.num_channels, 1)
	meter_w := (bounds.w - METER_SPACING_PX * f32(num_meters - 1)) / f32(num_meters)

	MIN_DB, ORANGE_DB, RED_DB, MAX_DB :: f32(-60), f32(-12), f32(-6), f32(0)

	pix_per_db := bounds.h / (MAX_DB - MIN_DB)
	segments := [?]struct { top_db: f32, peak_color, rms_color: sdk.ColorU8 } {
		{ORANGE_DB, {0, 200, 80, 150}, {0, 200, 80, 255}},
		{RED_DB, {220, 120, 0, 150}, {220, 120, 0, 255}},
		{MAX_DB, {255, 20, 50, 150}, {255, 20, 50, 255}},
	}

	// labels every 6 dB
	for db := MAX_DB; db >= MIN_DB; db -= 6 {
		y := bounds.y + bounds.h * (1 - (db - MIN_DB) / (MAX_DB - MIN_DB))
		s := fmt.tprintf("%d", int(db))
		tsz := sdk.draw_measure_text(ctx.plugin.draw, s, METER_LABEL_SIZE)
		sdk.draw_text(ctx.plugin.draw, s, bounds.x - tsz.x - 4, y - tsz.y / 2, color = LABEL_COLOR, size = METER_LABEL_SIZE)
		sdk.draw_push_pill(ctx.plugin.draw, {bounds.x, y}, {bounds.x + bounds.w, y}, 1, GRID_COLOR)
	}

	// Peak first, RMS on top
	for is_peak in ([?]bool{true, false}) {
		for i in 0 ..< a.num_channels {
			dbs := sdk.linear_to_decibels(is_peak ? a.peak[i] : a.rms[i])
			if dbs < MIN_DB do continue
			x := bounds.x + f32(i) * (meter_w + METER_SPACING_PX)
			prev_db := MIN_DB
			for seg in segments {
				top_db := min(dbs, seg.top_db)
				if top_db <= prev_db do break
				h := pix_per_db * (top_db - prev_db)
				y := bounds.y + bounds.h - pix_per_db * (top_db - MIN_DB)
				color := is_peak ? seg.peak_color : seg.rms_color
				sdk.draw_push_rect(ctx.plugin.draw, {
					x = x, y = y, width = meter_w, height = h,
					color = color, corner_rad = 2,
				})
				prev_db = seg.top_db
			}
		}
	}

	PEAK_TICK_H :: f32(2)
	for c in 0..< a.num_channels {
		dbs := sdk.linear_to_decibels(a.peak_hold[c])
		if dbs < MIN_DB do continue
		col := segments[len(segments) - 1].rms_color
		for seg in segments {
			if dbs <= seg.top_db {
				col = seg.rms_color
				break
			}
		}
		x := bounds.x + f32(c) * (meter_w + METER_SPACING_PX)
		y := bounds.y + bounds.h - pix_per_db * (dbs - MIN_DB)
		sdk.draw_push_rect(ctx.plugin.draw, sdk.SimpleUIRect {
			x = x, y = y - PEAK_TICK_H / 2, width = meter_w, height = PEAK_TICK_H,
			color = col, corner_rad = 1,
		})
	}
}

facet_draw :: proc(plug: ^sdk.PluginController) {
	facet_run_analysis(plug)
	state := cast(^FacetControlState)plug.state
	a := &state.analysis

	sdk.draw_set_clear_color(plug.draw, sdk.color_f32_from_color_u8(plug.ui.theme.bg_color))
	sdk.draw_clear(plug.draw)

	if sdk.ui_frame_scoped(plug.ui) {
		if sdk.ui_panel(plug.ui, dir = .Vertical, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Grow}, child_gaps = 10, padding = 10, skip_draw = true) {
			if sdk.ui_panel(plug.ui, dir = .Horizontal, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Grow, weight = 1.1}, padding = 0, child_gaps = 10, skip_draw = true) {
				sdk.ui_canvas(plug.ui, draw_goniometer_canvas, a, sizing_horiz = {type = .Grow, weight = 1})
				sdk.ui_canvas(plug.ui, draw_hilbert_canvas, a, sizing_horiz = {type = .Grow, weight = 2})
				sdk.ui_canvas(plug.ui, draw_meter_canvas, a, sizing_horiz = {type = .Fixed, value = 60})
			}
			if sdk.ui_panel(plug.ui, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Grow, weight = 0.9}, padding = 0, skip_draw = true) {
				sdk.ui_canvas(plug.ui, draw_spectrum_analyzer_canvas, a)
				if sdk.ui_panel(plug.ui, floating = true, align_x = .Right, align_y = .Top,
					float_offset = {-SPECTRUM_CONTROLS_INSET, SPECTRUM_CONTROLS_INSET},
					padding = 0, child_gaps = 6, skip_draw = true) {
					sdk.ui_label(plug.ui, "FFT Size:", align_y = .Center)
					sdk.ui_drop_down_param(plug.ui, PARAM_FFT_SIZE, enum_to_string = fft_size_label)
					sdk.ui_label(plug.ui, "Mode:", align_y = .Center)
					sdk.ui_drop_down_param(plug.ui, PARAM_FFT_MODE, enum_to_string = fft_mode_label)
				}
			}
		}
	}

	sdk.draw_submit(plug.draw)
}

get_fft_size :: proc(params: ^b.ParamValues) -> u32 {
	fft_exp: u32 = u32(params.values[PARAM_FFT_SIZE])
	return 1 << (fft_exp + 10) // 2^(10 + fft_exp)
}

@(rodata) FFT_SIZE_LABELS := [?]string{"1024", "2048", "4096", "8192"}

fft_size_label :: proc(val: f64) -> string {
	i := int(val + 0.5)
	if i < 0 || i >= len(FFT_SIZE_LABELS) do return ""
	return FFT_SIZE_LABELS[i]
}

FFTMode :: enum { Overlay, Left, Right, Sum, MidSide }

@(rodata) FFT_MODE_LABELS := [?]string{"L+R", "L", "R", "Sum", "M/S"}

fft_mode_label :: proc(val: f64) -> string {
	i := int(val + 0.5)
	if i < 0 || i >= len(FFT_MODE_LABELS) do return ""
	return FFT_MODE_LABELS[i]
}

get_fft_mode :: proc(params: ^b.ParamValues) -> FFTMode {
	return FFTMode(int(params.values[PARAM_FFT_MODE] + 0.5))
}

TraceStyle :: struct {
	label: string,
	color: sdk.ColorU8,
}

CH_L_COLOR : sdk.ColorU8 : {255, 100, 100, 255}
CH_R_COLOR : sdk.ColorU8 : {100, 100, 255, 255}
SUM_COLOR : sdk.ColorU8 : {210, 210, 210, 255}
MID_COLOR : sdk.ColorU8 : {235, 180, 90, 255}
SIDE_COLOR : sdk.ColorU8 : {160, 110, 230, 255}

fft_trace_styles :: proc(mode: FFTMode) -> [2]TraceStyle {
	switch mode {
	case .Overlay: return {{"L", CH_L_COLOR}, {"R", CH_R_COLOR}}
	case .Left: return {{"L", CH_L_COLOR}, {}}
	case .Right: return {{"R", CH_R_COLOR}, {}}
	case .Sum: return {{"Sum", SUM_COLOR}, {}}
	case .MidSide: return {{"M", MID_COLOR}, {"S", SIDE_COLOR}}
	}
	return {}
}

fft_mode_trace_count :: proc(mode: FFTMode, num_channels: int) -> int {
	switch mode {
	case .Overlay: return min(num_channels, ANALYSIS_CHANNELS)
	case .Left, .Right, .Sum: return 1
	case .MidSide: return 2
	}
	return 0
}

init_fft :: proc(plug: ^sdk.PluginController, state: ^FacetControlState) {
	fft_size := get_fft_size(plug.host.params)
	state.fft_window = state.fft_window_backing[:fft_size]
	dsp.window_fill(state.fft_window, .Hann)
	state.fft_window_gain = dsp.window_coherent_gain(state.fft_window)
	state.fft = dsp.radix2_fft_init(fft_size, state.twiddles[:])
	for c in 0 ..< ANALYSIS_CHANNELS { // bins remap on resize, so reset smoothing to the floor
		for i in 0 ..< fft_size / 2 {
			state.analysis.fft_smooth_db[c][i] = DB_FLOOR
		}
	}
}

facet_view_attached :: proc(plug: ^sdk.PluginController) {
	theme := sdk.THEME_JQ
	theme.font_size = LABEL_SIZE
	theme.menu_item_height = LABEL_SIZE + 8
	theme.button_color.a = CONTROL_BG_ALPHA
	theme.button_hover_color.a = CONTROL_BG_ALPHA
	theme.button_active_color.a = CONTROL_BG_ALPHA
	theme.popup_bg_color.a = CONTROL_BG_ALPHA
	theme.menu_item_hover_color = CONTROL_HOVER_COLOR
	theme.text_color = CONTROL_TEXT_COLOR
	theme.border_color = GRID_COLOR 
	theme.popup_border_color = GRID_COLOR 
	sdk.ui_set_theme(plug.ui, theme)
}

facet_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr {
	state := new(FacetControlState, allocator = plug.host.session_allocator)
	init_fft(plug, state)
	state.analysis.agc_gain = 1
	state.analysis.gonio_gain = 1
	return state
}

facet_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	state := new(FacetProcessState, allocator = plug.host.session_allocator)
	dc_r := math.exp(-math.TAU * DC_BLOCK_HZ / f32(plug.audio_processor.sample_rate))
	for c in 0 ..< ANALYSIS_CHANNELS {
		dsp.ring_init(&state.rings[c], state.backing_bufs[c][:])
		dsp.dc_blocker_init(&state.dc_blockers[c], dc_r)
	}
	dsp.hilbert_fir_init(&state.hilbert_fir, state.hilbert_coeffs[:], state.hilbert_delay[:])
	dsp.ring_init(&state.analytic_ring, state.analytic_buf[:])
	return state
}

facet_api :: sdk.PluginApi {
	get_plugin_descriptor = facet_get_plugin_descriptor,
	process_audio = facet_process_audio,
	draw = facet_draw,
	view_attached = facet_view_attached,
	setup_controller = facet_setup_controller,
	setup_processor = facet_setup_processor,
}
