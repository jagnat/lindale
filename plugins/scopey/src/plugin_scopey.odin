package scopey

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:log"
import "../../../src/sdk"
import b "../../../src/bridge"
import "../../../src/dsp"
import dit "../../../src/thirdparty/uFFT_DIT"

@(export)
GetPluginApi :: proc() -> sdk.PluginApi {
	return sdk.fallbackApi
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(scopey_api)
}

FFT_SIZE :: 1024
RING_SIZE :: FFT_SIZE * 2 // headroom so audio thread can't overrun a snapshot read
MAX_CHANNELS :: 2

DB_FLOOR :: f32(-100)
SMOOTH_ALPHA :: f32(0.3)
RMS_INTEGRATION_SEC :: f32(0.2)

PEAK_HOLD_SEC :: f32(1.5)
PEAK_HOLD_FALL_DB_PER_SEC :: f32(20)
METER_RELEASE_DB_PER_SEC :: f32(80) // peak bar fall rate

// Hilbert FIR parameters - I don't understand this yet
HILBERT_N :: 511 // logical FIR length, clean magnitude down to ~300 Hz at 48 kHz
HILBERT_TAPS :: (HILBERT_N + 1) / 2 // packed nonzero taps
HILBERT_DELAY :: 2 * HILBERT_N + 8 // double-write + 8-float SIMD tail pad
HILBERT_TRAIL_SIZE :: 2048

GONIOMETER_TRAIL_SIZE :: 4096

// AGC to scale to viewport size
AGC_TARGET_FILL :: f32(0.8) // peak |z| mapped to this fraction of canvas radius
AGC_NOISE_FLOOR :: f32(0.05) // below this, gain saturates so silence stays a dot
AGC_RELEASE :: f32(0.04) // smoothing toward larger gains (quieter signal); ~400 ms at 60 fps

// Decay numbers for plugin bypass
INACTIVE_THRESHOLD_SEC :: f32(0.15)
INACTIVE_TRAIL_DECAY :: f32(0.85)

ScopeyProcessState :: struct {
	backing_bufs: [MAX_CHANNELS][RING_SIZE]f32,
	rings: [MAX_CHANNELS]dsp.RingBuffer,
	dc_blockers: [MAX_CHANNELS]dsp.DCBlocker,

	peak: [MAX_CHANNELS]f32,
	peak_follow: [MAX_CHANNELS]f32, // audio-thread-private peak follower: instant attack, slow release
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
	peak_hold: [MAX_CHANNELS]f32,
	peak_hold_age: [MAX_CHANNELS]f32, // seconds since the held value was last refreshed
	rms: [MAX_CHANNELS]f32,

	goniometer_trail: [2][GONIOMETER_TRAIL_SIZE]f32,
	goniometer_trail_count: int,

	// Controller-side trail ring buf for the Hilbert Lissajous
	hilbert_trail: [HILBERT_TRAIL_SIZE]complex64,
	hilbert_trail_write: int,
	hilbert_trail_count: int,

	agc_gain: f32, // instant attack, slow release
	gonio_gain: f32, // goniometer-specific AGC from peak sqrt(L^2+R^2)

	last_analytic_pos: int, // last seen processor analytic write position
	silence_age: f32, // seconds since the processor last produced samples
}

@(rodata) scopey_param_table := [?]b.ParamDescriptor {
}

scopey_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		name = "Scopey",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Effect,
		params = scopey_param_table[:],
		max_channels = MAX_CHANNELS,

		view = sdk.ViewConfig {
			default_width = 640,
			default_height = 480,
			resizable = true,
		},
	}
}

scopey_process_audio :: proc(plug: ^sdk.PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.state == nil do return
	if actx.numChannels == 0 || actx.numSamples == 0 do return
	state := cast(^ScopeyProcessState)plug.state

	n := actx.numSamples
	num_channels := min(actx.numChannels, MAX_CHANNELS)

	// EMA decay per sample for the running mean-square, converted from the integration time
	rms_decay := 1.0 - 1.0 / (f32(actx.sampleRate) * RMS_INTEGRATION_SEC)
	rms_input_gain := 1.0 - rms_decay

	// Per-sample peak-follower release coeff from the fall rate; instant attack is the max() below
	meter_release := math.pow(f32(10), -METER_RELEASE_DB_PER_SEC / (20 * f32(actx.sampleRate)))

	// Accumulate the mono mix as we DC-block each channel. Only [0..n) is used.
	mono_buf: []f32 = make([]f32, RING_SIZE, allocator=context.temp_allocator)
	inv_chan := 1.0 / f32(num_channels)

	for c in 0 ..< num_channels {
		if actx.inputs[c] == nil || actx.outputs[c] == nil do continue
		copy(actx.outputs[c][:n], actx.inputs[c][:n]) // raw passthrough out to host

		blocked_buf: [RING_SIZE]f32
		copy(blocked_buf[:n], actx.inputs[c][:n])
		dsp.dc_blocker_process_buf(&state.dc_blockers[c], blocked_buf[:n])
		dsp.ring_write_buf(&state.rings[c], blocked_buf[:n])

		m := state.peak_follow[c]
		accum := state.rms_accum[c]
		for i in 0 ..< n {
			s := blocked_buf[i]
			m = max(abs(s), m * meter_release)
			accum = accum * rms_decay + s * s * rms_input_gain
			mono_buf[i] += s * inv_chan
		}
		state.peak_follow[c] = dsp.flush_denormal(m)
		state.rms_accum[c] = dsp.flush_denormal(accum)
		intrinsics.atomic_store_explicit(&state.peak[c], m, .Release)
		intrinsics.atomic_store_explicit(&state.rms[c], math.sqrt(accum), .Release)
	}

	// Mono signal -> Hilbert FIR -> interleaved (r, im) pairs into the analytic ring.
	for i in 0 ..< n {
		r, im := dsp.hilbert_fir_process(&state.hilbert_fir, mono_buf[i])
		pair := [2]f32{r, im}
		dsp.ring_write_buf(&state.analytic_ring, pair[:])
	}
}

scopey_run_analysis :: proc(plug: ^sdk.PluginController) {
	state := cast(^ScopeyControlState)plug.state
	process_state := cast(^ScopeyProcessState)plug.processor_peer.state
	a := &state.analysis

	if plug.processor_peer == nil || plug.processor_peer.audioProcessor == nil {
		a.num_channels = 0
		return
	}
	actx := plug.processor_peer.audioProcessor
	a.sample_rate = f32(actx.sampleRate)
	a.num_channels = min(actx.numChannels, MAX_CHANNELS)
	dt := plug.frameDt

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

	// Meters: pull the audio-thread's latest published scalars, or release toward 0 when inactive.
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

	fft_buf := make([]complex64, FFT_SIZE, allocator=context.temp_allocator)

	if !active { // shrink the frozen figure away rather than re-snapshotting stale rings
		a.goniometer_trail_count = int(f32(a.goniometer_trail_count) * INACTIVE_TRAIL_DECAY)
	} else if a.num_channels >= 2 { // Snapshot the latest trail's worth of L/R against a shared end so the channels stay sample-aligned
		end := min(
			dsp.ring_get_write_pos(&process_state.rings[0]),
			dsp.ring_get_write_pos(&process_state.rings[1]),
		)
		nl := dsp.ring_read_window(&process_state.rings[0], end, a.goniometer_trail[0][:])
		nr := dsp.ring_read_window(&process_state.rings[1], end, a.goniometer_trail[1][:])
		a.goniometer_trail_count = min(nl, nr)
	} else { // If mono, ring[1] is never written, so mirror L into R
		end := dsp.ring_get_write_pos(&process_state.rings[0])
		n := dsp.ring_read_window(&process_state.rings[0], end, a.goniometer_trail[0][:])
		copy(a.goniometer_trail[1][:], a.goniometer_trail[0][:])
		a.goniometer_trail_count = n
	}

	if active { // Goniometer AGC over the freshly snapshotted trail (mono or stereo)
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
	}

	// FFT: snapshot the latest FFT_SIZE samples of each ring
	for c in 0 ..< a.num_channels {
		if !active { // decay smoothed magnitudes toward the floor
			for i in 1 ..< FFT_SIZE / 2 {
				a.fft_smooth_db[c][i] = SMOOTH_ALPHA * DB_FLOOR + (1 - SMOOTH_ALPHA) * a.fft_smooth_db[c][i]
			}
			continue
		}
		time_slice: [FFT_SIZE]f32
		n := dsp.ring_read_latest(&process_state.rings[c], time_slice[:])
		if n < FFT_SIZE {
			// log.info("Not hitting fft size, we got ", n, "and we need", FFT_SIZE)
			continue
		}

		for v, i in time_slice do fft_buf[i] = complex64(v * state.fft_window[i])
		dit.fft(&fft_buf[0], FFT_SIZE)
		// dsp.smooth_brain_dft(&fft_buf)

		// FFT_SIZE/2 normalizes the one-sided bin energy; window gain undoes Hann's amplitude bias.
		norm := f32(FFT_SIZE / 2) * state.fft_window_gain
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
	drain_buf := make([]f32, RING_SIZE, allocator=context.temp_allocator)
	got := dsp.ring_read(&process_state.analytic_ring, drain_buf[:])
	pairs := got / 2
	peak2: f32 = 0 // track squared magnitude to skip per-sample sqrt
	for i in 0 ..< pairs {
		r := drain_buf[2 * i]
		im := drain_buf[2 * i + 1]
		m2 := r * r + im * im
		if m2 > peak2 do peak2 = m2
		a.hilbert_trail[a.hilbert_trail_write] = complex(r, im)
		a.hilbert_trail_write = (a.hilbert_trail_write + 1) % HILBERT_TRAIL_SIZE
		if a.hilbert_trail_count < HILBERT_TRAIL_SIZE do a.hilbert_trail_count += 1
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

	if !active { // shrink the frozen trail away instead of holding it
		a.hilbert_trail_count = int(f32(a.hilbert_trail_count) * INACTIVE_TRAIL_DECAY)
	}
}

draw_canvas_frame :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component) {
	sdk.draw_push_rect(ctx.plugin.draw, sdk.SimpleUIRect {
		x = comp.calcBounds.x, y = comp.calcBounds.y,
		width = comp.calcBounds.w, height = comp.calcBounds.h,
		color = {0, 0, 0, 0},
		cornerRad = 10,
		borderColor = {80, 80, 80, 255},
		borderWidth = 1.2,
	})
}

draw_spectrum_analyzer_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
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

	label_color := sdk.ColorU8{80, 80, 80, 255}
	grid_color := sdk.ColorU8{50, 50, 50, 255}
	label_size := f32(16)

	decades := [?]struct{f: f32, label: string}{{10, "10"}, {100, "100"}, {1000, "1k"}, {10000, "10k"}}
	for decade in decades {
		// 9 gridlines per decade: the decade itself (k*1) plus k*2..k*9
		for k in 1 ..= 9 {
			f := decade.f * f32(k)
			if f >= FMAX do break
			x := bounds.x + bounds.w * (math.log10(f / FMIN) / log_span)
			sdk.draw_push_pill(ctx.plugin.draw, {x, bounds.y}, {x, bounds.y + bounds.h}, 1, grid_color)
		}
		x := bounds.x + bounds.w * (math.log10(decade.f / FMIN) / log_span)
		tw := sdk.draw_measure_text(ctx.plugin.draw, decade.label, label_size).x
		sdk.draw_text(ctx.plugin.draw, decade.label, x - tw / 2, bounds.y + bounds.h + 1, color = label_color, size = label_size)
	}

	// dBFS gridlines and labels every 20db
	for db := DB_TOP; db >= DB_FLOOR; db -= 20 {
		t := (db - DB_FLOOR) / (DB_TOP - DB_FLOOR)
		y := bounds.y + bounds.h * (1 - t)
		if db != DB_TOP do sdk.draw_push_pill(ctx.plugin.draw, {bounds.x, y}, {bounds.x + bounds.w, y}, 1, grid_color)
		s := fmt.tprintf("%d", int(db))
		tsz := sdk.draw_measure_text(ctx.plugin.draw, s, label_size)
		if db != DB_FLOOR do sdk.draw_text(ctx.plugin.draw, s, bounds.x + 2, y, color = label_color, size = label_size)
	}

	cols :[]sdk.ColorU8= {{255, 100, 100, 255}, {100, 100, 255, 255}}

	// Interpolate between bins using catmull-rom when bins are at least SMOOTH_MIN_BIN_PX apart
	SMOOTH_MIN_BIN_PX :: f32(3)
	SMOOTH_SEG_PX :: f32(3) // px of horizontal span per tessellated curve segment
	max_i := FFT_SIZE / 2 - 1
	bin_hz := a.sample_rate / fft_size
	ln10 := f32(2.302585092994046)
	y_lo := bounds.y
	y_hi := bounds.y + bounds.h
	unit_density_freq := bounds.w * bin_hz / (log_span * ln10)
	smooth_freq := clamp(unit_density_freq / SMOOTH_MIN_BIN_PX, FMIN, FMAX)

	for c in 0 ..< a.num_channels {
		pts := make([dynamic]sdk.Vec2f, 0, max_i + int(bounds.w), context.temp_allocator)

		// For low freqs, catmull-rom through the bins up to the threshold
		lf := make([dynamic]sdk.Vec2f, 0, 256, context.temp_allocator)
		for i in 1 ..= max_i {
			freq := f32(i) * bin_hz
			if freq < FMIN do continue
			if freq > smooth_freq do break
			x := bounds.x + bounds.w * (math.log10(freq / FMIN) / log_span)
			y := bounds.y + bounds.h * (1 - clamp((a.fft_smooth_db[c][i] - DB_FLOOR) / (DB_TOP - DB_FLOOR), 0, 1))
			append(&lf, sdk.Vec2f{x, y})
		}

		for k in 0 ..< max(len(lf) - 1, 0) {
			p0 := lf[max(k - 1, 0)]
			p1 := lf[k]
			p2 := lf[k + 1]
			p3 := lf[min(k + 2, len(lf) - 1)]
			segs := max(int(abs(p2.x - p1.x) / SMOOTH_SEG_PX), 1)
			for s in 0 ..< segs {
				pt := sdk.catmull_rom(p0, p1, p2, p3, f32(s) / f32(segs))
				pt.y = clamp(pt.y, y_lo, y_hi)
				append(&pts, pt)
			}
		}
		if len(lf) > 0 do append(&pts, lf[len(lf) - 1])

		// For high freqs, raw one point per bin (overdraw)
		for i in 1 ..= max_i {
			freq := f32(i) * bin_hz
			if freq <= smooth_freq do continue
			if freq > FMAX do break
			x := bounds.x + bounds.w * (math.log10(freq / FMIN) / log_span)
			y := bounds.y + bounds.h * (1 - clamp((a.fft_smooth_db[c][i] - DB_FLOOR) / (DB_TOP - DB_FLOOR), 0, 1))
			append(&pts, sdk.Vec2f{x, y})
		}

		if len(pts) >= 2 do sdk.draw_polyline(ctx.plugin.draw, pts[:], thickness = 1.8, color = cols[c])
	}
}

// Fall off curve for modulating alpha
trail_alpha :: #force_inline proc(t: f32) -> f32 {
	return t * t * t
}

draw_goniometer_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)

	bounds := comp.calcBounds
	a := cast(^AnalysisFrame)data
	if a == nil do return

	cx := bounds.x + bounds.w / 2
	cy := bounds.y + bounds.h / 2

	SQRT_HALF :: f32(0.70710678)
	dc := ctx.plugin.draw

	label_color := sdk.ColorU8{80, 80, 80, 255}
	grid_color := sdk.ColorU8{50, 50, 50, 255}
	label_size := f32(16)
	lp := f32(3)

	mp := sdk.draw_measure_text(dc, "+M", label_size)
	mn := sdk.draw_measure_text(dc, "-M", label_size)
	sp := sdk.draw_measure_text(dc, "+S", label_size)
	sn := sdk.draw_measure_text(dc, "-S", label_size)
	lt := sdk.draw_measure_text(dc, "L", label_size)
	rt := sdk.draw_measure_text(dc, "R", label_size)

	radius_v := bounds.h * 0.5 - max(mp.y, mn.y) - lp
	radius_h := bounds.w * 0.5 - max(sp.x, sn.x) - lp
	radius := min(radius_v, radius_h)
	diag := radius * SQRT_HALF

	sdk.draw_push_rect(dc, sdk.SimpleUIRect{
		x = cx - radius, y = cy - radius,
		width = radius * 2, height = radius * 2,
		cornerRad = radius,
		borderColor = grid_color, borderWidth = 1,
	})
	sdk.draw_push_pill(dc, {cx, cy - radius}, {cx, cy + radius}, 1, grid_color)
	sdk.draw_push_pill(dc, {cx - radius, cy}, {cx + radius, cy}, 1, grid_color)
	sdk.draw_push_pill(dc, {cx - diag, cy - diag}, {cx + diag, cy + diag}, 1, grid_color)
	sdk.draw_push_pill(dc, {cx + diag, cy - diag}, {cx - diag, cy + diag}, 1, grid_color)

	scale := radius * a.gonio_gain

	n := a.goniometer_trail_count
	if n >= 2 {
		l0 := a.goniometer_trail[0][0]
		r0 := a.goniometer_trail[1][0]
		x0 := cx + (r0 - l0) * SQRT_HALF * scale
		y0 := cy - (l0 + r0) * SQRT_HALF * scale

		inv_n := 1.0 / f32(n - 1)
		for k in 1 ..< n {
			l := a.goniometer_trail[0][k]
			r := a.goniometer_trail[1][k]
			x1 := cx + (r - l) * SQRT_HALF * scale
			y1 := cy - (l + r) * SQRT_HALF * scale
			alpha := trail_alpha(f32(k) * inv_n)
			col := sdk.ColorU8{150, 100, 150, u8(alpha * 255)}
			sdk.draw_push_pill(dc, {x0, y0}, {x0, y0}, 2, col)
			x0 = x1
			y0 = y1
		}
	}

	sdk.draw_text(dc, "+M", cx - mp.x / 2, cy - radius - mp.y - lp, label_color, label_size)
	sdk.draw_text(dc, "-M", cx - mn.x / 2, cy + radius + lp, label_color, label_size)
	sdk.draw_text(dc, "+S", cx + radius + lp, cy - sp.y / 2, label_color, label_size)
	sdk.draw_text(dc, "-S", cx - radius - sn.x - lp, cy - sn.y / 2, label_color, label_size)
	sdk.draw_text(dc, "L", cx - diag - lt.x - lp, cy - diag - lt.y - lp, label_color, label_size)
	sdk.draw_text(dc, "R", cx + diag + lp, cy - diag - rt.y - lp, label_color, label_size)
}

draw_hilbert_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	draw_canvas_frame(ctx, comp)
	bounds := comp.calcBounds
	a := cast(^AnalysisFrame)data
	if a == nil do return

	cx := bounds.x + bounds.w / 2
	cy := bounds.y + bounds.h / 2
	// AGC maps peak |z| to AGC_TARGET_FILL of canvas radius (min/2); scale folds gain in
	scale := min(bounds.w, bounds.h) * 0.5 * a.agc_gain

	n := a.hilbert_trail_count
	if n < 2 do return

	start := (a.hilbert_trail_write + HILBERT_TRAIL_SIZE - n) % HILBERT_TRAIL_SIZE
	inv_n := 1.0 / f32(n - 1)
	for k in 0 ..< n - 1 {
		p0 := a.hilbert_trail[(start + k) % HILBERT_TRAIL_SIZE]
		p1 := a.hilbert_trail[(start + k + 1) % HILBERT_TRAIL_SIZE]
		alpha := trail_alpha(f32(k) * inv_n)
		col := sdk.ColorU8{200, 200, 200, 255}
		x0 := cx + real(p0) * scale
		y0 := cy - imag(p0) * scale
		x1 := cx + real(p1) * scale
		y1 := cy - imag(p1) * scale
		sdk.draw_push_pill(ctx.plugin.draw, {x0, y0}, {x1, y1}, 1, col)
	}
}

draw_meter_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	bounds := comp.calcBounds
	a := cast(^AnalysisFrame)data

	METER_OFFSET_X :: 22
	STEREO_SPACING_PX :: 4
	bounds.y += 4
	bounds.h -= 8
	bounds.x += METER_OFFSET_X
	bounds.w -= METER_OFFSET_X
	meterW := (bounds.w - STEREO_SPACING_PX) / 2

	MIN_DB, ORANGE_DB, RED_DB, MAX_DB :: f32(-60), f32(-12), f32(-6), f32(0)

	pix_per_db := bounds.h / (MAX_DB - MIN_DB)
	segments := [?]struct { top_db: f32, peak_color, rms_color: sdk.ColorU8 } {
		{ORANGE_DB, {0, 200, 80, 150}, {0, 200, 80, 255}},
		{RED_DB, {220, 120, 0, 150}, {220, 120, 0, 255}},
		{MAX_DB, {255, 20, 50, 150}, {255, 20, 50, 255}},
	}

	// labels every 6 dB
	label_color := sdk.ColorU8 {80, 80, 80, 255}
	grid_color := sdk.ColorU8 {50, 50, 50, 255}
	label_size := f32(11)
	for db := MAX_DB; db >= MIN_DB; db -= 6 {
		y := bounds.y + bounds.h * (1 - (db - MIN_DB) / (MAX_DB - MIN_DB))
		s := fmt.tprintf("%d", int(db))
		tsz := sdk.draw_measure_text(ctx.plugin.draw, s, label_size)
		sdk.draw_text(ctx.plugin.draw, s, bounds.x - tsz.x - 4, y - tsz.y / 2, color = label_color, size = label_size)
		sdk.draw_push_pill(ctx.plugin.draw, {bounds.x, y}, {bounds.x + bounds.w, y}, 1, grid_color)
	}

	// Peak first, RMS on top
	for is_peak in ([?]bool{true, false}) {
		for i in 0 ..< a.num_channels {
			dbs := sdk.linear_to_decibels(is_peak ? a.peak[i] : a.rms[i])
			if dbs < MIN_DB do continue
			x := bounds.x + f32(i) * (meterW + STEREO_SPACING_PX)
			prev_db := MIN_DB
			for seg in segments {
				top_db := min(dbs, seg.top_db)
				if top_db <= prev_db do break
				h := pix_per_db * (top_db - prev_db)
				y := bounds.y + bounds.h - pix_per_db * (top_db - MIN_DB)
				color := is_peak ? seg.peak_color : seg.rms_color
				sdk.draw_push_rect(ctx.plugin.draw, {
					x = x, y = y, width = meterW, height = h,
					color = color, cornerRad = 2,
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
		x := bounds.x + f32(c) * (meterW + STEREO_SPACING_PX)
		y := bounds.y + bounds.h - pix_per_db * (dbs - MIN_DB)
		sdk.draw_push_rect(ctx.plugin.draw, sdk.SimpleUIRect {
			x = x, y = y - PEAK_TICK_H / 2, width = meterW, height = PEAK_TICK_H,
			color = col, cornerRad = 1,
		})
	}
}

// Main draw proc
scopey_draw :: proc(plug: ^sdk.PluginController) {
	scopey_run_analysis(plug)
	state := cast(^ScopeyControlState)plug.state
	a := &state.analysis

	sdk.draw_set_clear_color(plug.draw, sdk.ColorF32_from_ColorU8(plug.ui.theme.bgColor))
	// sdk.draw_set_clear_color(plug.draw, sdk.ColorF32{ 0, 1, 0, 1})
	sdk.draw_clear(plug.draw)

	if sdk.ui_frame_scoped(plug.ui) {
		if sdk.ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10, padding = 10, skipDraw = true) {
			if sdk.ui_panel(plug.ui, dir=.HORIZONTAL, sizingHoriz= {type = .GROW}, sizingVert = {type = .GROW}, padding = 0, child_gaps = 10, skipDraw = true) {
				// Goniometer
				sdk.ui_canvas(plug.ui, draw_goniometer_canvas, a)
				// Meter (rms plus peaks)
				sdk.ui_canvas(plug.ui, draw_meter_canvas, a, sizingHoriz = sdk.AxisSizing{type = .FIXED, value = 60})
				// david lu esque hilbert transform scope
				sdk.ui_canvas(plug.ui, draw_hilbert_canvas, a)
			}
			// Spectrum analyzer
			sdk.ui_canvas(plug.ui, draw_spectrum_analyzer_canvas, a)
		}
	}

	sdk.draw_submit(plug.draw)
}

scopey_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr {
	state := new(ScopeyControlState, allocator = plug.host.session_allocator)
	dsp.window_fill(state.fft_window[:], .Hann)
	state.fft_window_gain = dsp.window_coherent_gain(state.fft_window[:])
	// Init smoothed to floor (-100db)
	for c in 0..<MAX_CHANNELS {
		for i in 0..<FFT_SIZE / 2 {
			state.analysis.fft_smooth_db[c][i] = DB_FLOOR
		}
	}
	state.analysis.agc_gain = 1
	state.analysis.gonio_gain = 1

	return state
}

scopey_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	state := new(ScopeyProcessState, allocator = plug.host.session_allocator)
	for c in 0 ..< MAX_CHANNELS {
		dsp.ring_init(&state.rings[c], state.backing_bufs[c][:])
		dsp.dc_blocker_init(&state.dc_blockers[c], 0.999) // ~7.6 Hz cutoff at 48k
	}
	dsp.hilbert_fir_init(&state.hilbert_fir, state.hilbert_coeffs[:], state.hilbert_delay[:])
	dsp.ring_init(&state.analytic_ring, state.analytic_buf[:])

	return state
}

scopey_api :: sdk.PluginApi {
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
