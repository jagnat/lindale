package dsp

import "core:math"
import "core:testing"

MAX_GRAINS :: 128

GrainEnvelopeType :: enum {
	Hann,
	Triangle,
	Gaussian,
	Trapezoid,
}

Grain :: struct {
	source_pos:   f64, // Sub-sample precision — f32 loses fractional precision at high sample counts
	source_speed: f32,
	amplitude:    f32,
	pan:          f32, // -1..1
	duration:     int, // Total duration in samples
	elapsed:      int,
	envelope:     GrainEnvelopeType,
	active:       bool,
}

GrainParams :: struct {
	// Source buffer
	source:        []Sample,
	source_length: int,

	// Grain generation
	grain_rate:           f32, // Grains per second
	grain_duration:       f32, // Duration in ms
	grain_duration_jitter: f32, // 0..1

	// Position
	scan_pos:        f32, // 0..1 position in source
	position_spread: f32, // Seconds

	// Pitch
	pitch_ratio:   f32, // 1.0 = original speed
	pitch_spread:  f32, // Semitones

	// Amplitude
	amplitude:       f32,
	amplitude_spread: f32,

	// Pan
	pan:        f32, // -1..1
	pan_spread: f32,

	// Envelope
	envelope: GrainEnvelopeType,
}

GrainEngine :: struct {
	grains:            [MAX_GRAINS]Grain,
	params:            GrainParams,
	samples_until_next: f32,
	sample_rate:       f32,
	rng_state:         u64, // Simple xorshift for deterministic noise
}

grain_engine_init :: proc(g: ^GrainEngine, sample_rate: f32) {
	g.sample_rate = sample_rate
	g.samples_until_next = 0
	g.rng_state = 12345

	g.params.grain_rate = 10
	g.params.grain_duration = 100
	g.params.pitch_ratio = 1.0
	g.params.amplitude = 1.0
	g.params.envelope = .Hann
}

grain_engine_set_source :: proc(g: ^GrainEngine, source: []Sample) {
	g.params.source = source
	g.params.source_length = len(source)
}

// Simple xorshift64 for jitter — no core:math/rand dependency in process path
@(private)
grain_rng_next :: proc(g: ^GrainEngine) -> f32 {
	g.rng_state ~= g.rng_state << 13
	g.rng_state ~= g.rng_state >> 7
	g.rng_state ~= g.rng_state << 17
	// Map to 0..1
	return f32(g.rng_state & 0xFFFFFF) / f32(0xFFFFFF)
}

// Map 0..1 to -1..1
@(private)
grain_rng_bipolar :: proc(g: ^GrainEngine) -> f32 {
	return grain_rng_next(g) * 2 - 1
}

@(private)
grain_envelope_to_window :: proc(env: GrainEnvelopeType) -> WindowType {
	switch env {
	case .Hann:      return .Hann
	case .Triangle:  return .Triangle
	case .Gaussian:  return .Gaussian
	case .Trapezoid: return .Trapezoid
	}
	return .Hann
}

@(private)
grain_spawn :: proc(g: ^GrainEngine) {
	p := &g.params
	if p.source_length == 0 do return

	// Find inactive grain slot
	slot: ^Grain
	for &grain in g.grains {
		if !grain.active {
			slot = &grain
			break
		}
	}
	if slot == nil do return // All slots full

	// Duration with jitter
	dur_ms := p.grain_duration * (1 + p.grain_duration_jitter * grain_rng_bipolar(g))
	dur_ms = max(dur_ms, 1) // At least 1ms
	dur_samples := int(ms_to_samples(dur_ms, g.sample_rate))

	// Position in source
	pos := p.scan_pos * f32(p.source_length)
	pos += p.position_spread * g.sample_rate * grain_rng_bipolar(g)

	// Pitch
	pitch := p.pitch_ratio
	if p.pitch_spread > 0 {
		semitone_offset := p.pitch_spread * grain_rng_bipolar(g)
		pitch *= math.pow(f32(2), semitone_offset / 12)
	}

	// Amplitude
	amp := p.amplitude * (1 + p.amplitude_spread * grain_rng_bipolar(g))
	amp = max(amp, 0)

	// Pan
	pan := p.pan + p.pan_spread * grain_rng_bipolar(g)
	pan = clamp(pan, -1, 1)

	slot.source_pos = f64(pos)
	slot.source_speed = pitch
	slot.amplitude = amp
	slot.pan = pan
	slot.duration = dur_samples
	slot.elapsed = 0
	slot.envelope = p.envelope
	slot.active = true
}

// Manual grain trigger bypassing scheduler
grain_engine_trigger :: proc(g: ^GrainEngine) {
	grain_spawn(g)
}

// Read source with cubic interpolation, wrapping around source length
@(private)
grain_read_source :: proc(source: []Sample, pos: f64) -> Sample {
	n := len(source)
	if n == 0 do return 0

	i := int(pos)
	frac := f32(pos - f64(i))

	im1 := (i - 1) %% n
	i0 := i %% n
	i1 := (i + 1) %% n
	i2 := (i + 2) %% n

	ym1 := source[im1]
	y0 := source[i0]
	y1 := source[i1]
	y2 := source[i2]

	// Hermite cubic
	c0 := y0
	c1 := 0.5 * (y1 - ym1)
	c2 := ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
	c3 := 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)

	return ((c3 * frac + c2) * frac + c1) * frac + c0
}

grain_engine_process :: proc(g: ^GrainEngine) -> (out_l: Sample, out_r: Sample) {
	p := &g.params
	if p.source_length == 0 do return 0, 0

	// Scheduling
	g.samples_until_next -= 1
	if g.samples_until_next <= 0 {
		grain_spawn(g)
		if p.grain_rate > 0 {
			g.samples_until_next = g.sample_rate / p.grain_rate
		} else {
			g.samples_until_next = g.sample_rate // 1 Hz fallback
		}
	}

	// Process active grains
	for &grain in g.grains {
		if !grain.active do continue

		// Envelope
		t := f32(grain.elapsed) / f32(grain.duration)
		env := window_sample(grain_envelope_to_window(grain.envelope), t)

		// Read source
		s := grain_read_source(p.source, grain.source_pos)
		s *= env * grain.amplitude

		// Equal-power pan law
		pan_angle := (grain.pan + 1) * PI / 4
		out_l += s * math.cos(pan_angle)
		out_r += s * math.sin(pan_angle)

		// Advance
		grain.source_pos += f64(grain.source_speed)
		grain.elapsed += 1

		if grain.elapsed >= grain.duration {
			grain.active = false
		}
	}

	return
}

grain_engine_process_buf :: proc(g: ^GrainEngine, buf_l, buf_r: []Sample) {
	n := min(len(buf_l), len(buf_r))
	for i in 0 ..< n {
		l, r := grain_engine_process(g)
		buf_l[i] += l
		buf_r[i] += r
	}
}

// Tests

@(test)
test_grain_single_trigger :: proc(t: ^testing.T) {
	// Create a source buffer with a DC signal
	source: [1024]Sample
	for &s in source {
		s = 1.0
	}

	g: GrainEngine
	grain_engine_init(&g, 44100)
	grain_engine_set_source(&g, source[:])
	g.params.grain_rate = 0 // Disable auto-scheduling
	g.samples_until_next = 999999 // Don't auto-trigger

	grain_engine_trigger(&g)

	// Process some samples — should produce windowed output
	has_output := false
	for _ in 0 ..< 44100 {
		l, r := grain_engine_process(&g)
		if math.abs(l) > 1e-6 || math.abs(r) > 1e-6 {
			has_output = true
			break
		}
	}
	testing.expect(t, has_output)
}

@(test)
test_grain_envelope_applied :: proc(t: ^testing.T) {
	source: [4096]Sample
	for &s in source {
		s = 1.0
	}

	g: GrainEngine
	grain_engine_init(&g, 44100)
	grain_engine_set_source(&g, source[:])
	g.params.grain_duration = 10 // 10ms
	g.params.amplitude = 1.0
	g.params.pan = 0

	grain_engine_trigger(&g)

	// First sample of Hann window starts near 0
	l, _ := grain_engine_process(&g)
	testing.expect(t, math.abs(l) < 0.1)
}

@(test)
test_grain_no_source_no_output :: proc(t: ^testing.T) {
	g: GrainEngine
	grain_engine_init(&g, 44100)
	// No source set
	l, r := grain_engine_process(&g)
	testing.expect_value(t, l, Sample(0))
	testing.expect_value(t, r, Sample(0))
}
