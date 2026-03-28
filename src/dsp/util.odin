package dsp

import "core:math"
import "core:testing"

// Conversions

db_to_linear :: proc(db: f32) -> f32 {
	return math.pow(f32(10), db / 20)
}

linear_to_db :: proc(linear: f32) -> f32 {
	if linear <= 0 do return -math.INF_F32
	return 20 * math.log10(linear)
}

midi_to_freq :: proc(note: f32) -> f32 {
	return 440.0 * math.pow(f32(2), (note - 69) / 12)
}

freq_to_midi :: proc(freq: f32) -> f32 {
	if freq <= 0 do return 0
	return 69.0 + 12.0 * math.log2(freq / 440.0)
}

ms_to_samples :: proc(ms: f32, sample_rate: f32) -> f32 {
	return ms * 0.001 * sample_rate
}

samples_to_ms :: proc(samples: f32, sample_rate: f32) -> f32 {
	return samples / sample_rate * 1000
}

// Interpolation

InterpolationType :: enum {
	None,
	Linear,
	Cubic,
}

lerp :: proc(a, b, t: Sample) -> Sample {
	return a + (b - a) * t
}

interp_linear :: proc(buf: []Sample, pos: f32) -> Sample {
	n := len(buf)
	if n == 0 do return 0
	i := int(pos)
	frac := pos - f32(i)
	i0 := i %% n
	i1 := (i + 1) %% n
	return lerp(buf[i0], buf[i1], frac)
}

// Hermite 4-point cubic
interp_cubic :: proc(buf: []Sample, pos: f32) -> Sample {
	n := len(buf)
	if n == 0 do return 0
	i := int(pos)
	frac := pos - f32(i)

	im1 := (i - 1) %% n
	i0 := i %% n
	i1 := (i + 1) %% n
	i2 := (i + 2) %% n

	ym1 := buf[im1]
	y0 := buf[i0]
	y1 := buf[i1]
	y2 := buf[i2]

	c0 := y0
	c1 := 0.5 * (y1 - ym1)
	c2 := ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
	c3 := 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)

	return ((c3 * frac + c2) * frac + c1) * frac + c0
}

// Window functions

WindowType :: enum {
	Hann,
	Hamming,
	Blackman,
	Triangle,
	Gaussian,
	Trapezoid,
}

window_sample :: proc(type: WindowType, t: f32) -> Sample {
	switch type {
	case .Hann:
		return 0.5 * (1 - math.cos(TAU * t))
	case .Hamming:
		return 0.54 - 0.46 * math.cos(TAU * t)
	case .Blackman:
		return 0.42 - 0.5 * math.cos(TAU * t) + 0.08 * math.cos(2 * TAU * t)
	case .Triangle:
		return 1 - math.abs(2 * t - 1)
	case .Gaussian:
		// sigma = 0.4, centered at 0.5
		x := (t - 0.5) / 0.4
		return math.exp(-0.5 * x * x)
	case .Trapezoid:
		// 10% ramp in, 10% ramp out
		if t < 0.1 do return t / 0.1
		if t > 0.9 do return (1 - t) / 0.1
		return 1
	}
	return 0
}

window_fill :: proc(buf: []Sample, type: WindowType) {
	n := len(buf)
	if n == 0 do return
	inv_n := 1.0 / f32(n)
	for i in 0 ..< n {
		buf[i] = window_sample(type, f32(i) * inv_n)
	}
}

// Parameter smoother (one-pole)

Smoother :: struct {
	current, target, coeff: f32,
}

smoother_init :: proc(s: ^Smoother, initial: f32, time_ms: f32, sample_rate: f32) {
	s.current = initial
	s.target = initial
	if time_ms <= 0 {
		s.coeff = 0
	} else {
		s.coeff = math.exp(-TAU / (time_ms * 0.001 * sample_rate))
	}
}

smoother_reset :: proc(s: ^Smoother) {
	s.current = s.target
}

smoother_set_target :: proc(s: ^Smoother, target: f32) {
	s.target = target
}

smoother_next :: proc(s: ^Smoother) -> f32 {
	s.current = s.target + s.coeff * (s.current - s.target)
	return s.current
}

smoother_is_settled :: proc(s: ^Smoother, epsilon: f32 = 1e-6) -> bool {
	return math.abs(s.current - s.target) < epsilon
}

// Tests

@(test)
test_db_conversions :: proc(t: ^testing.T) {
	testing.expect(t, math.abs(db_to_linear(0) - 1.0) < 1e-6)
	testing.expect(t, math.abs(db_to_linear(-6) - 0.501187) < 1e-3)
	testing.expect(t, math.abs(db_to_linear(20) - 10.0) < 1e-4)

	// Round-trip
	testing.expect(t, math.abs(linear_to_db(db_to_linear(3.5)) - 3.5) < 1e-4)
}

@(test)
test_midi_freq :: proc(t: ^testing.T) {
	testing.expect(t, math.abs(midi_to_freq(69) - 440.0) < 0.01)
	testing.expect(t, math.abs(midi_to_freq(60) - 261.626) < 0.01)

	// Round-trip
	testing.expect(t, math.abs(freq_to_midi(midi_to_freq(72)) - 72.0) < 1e-4)
}

@(test)
test_ms_samples :: proc(t: ^testing.T) {
	testing.expect_value(t, ms_to_samples(1000, 44100), f32(44100))
	testing.expect(t, math.abs(samples_to_ms(44100, 44100) - 1000) < 1e-3)
}

@(test)
test_interp_linear :: proc(t: ^testing.T) {
	buf := [4]Sample{0, 1, 0, -1}
	testing.expect_value(t, interp_linear(buf[:], 0), f32(0))
	testing.expect_value(t, interp_linear(buf[:], 1), f32(1))
	testing.expect(t, math.abs(interp_linear(buf[:], 0.5) - 0.5) < 1e-6)
}

@(test)
test_window_hann_endpoints :: proc(t: ^testing.T) {
	testing.expect(t, math.abs(window_sample(.Hann, 0)) < 1e-6)
	testing.expect(t, math.abs(window_sample(.Hann, 0.5) - 1.0) < 1e-6)
}

@(test)
test_smoother :: proc(t: ^testing.T) {
	s: Smoother
	smoother_init(&s, 0, 1, 44100) // 1ms smoothing — fast settling
	smoother_set_target(&s, 1)
	for _ in 0 ..< 44100 {
		smoother_next(&s)
	}
	testing.expect(t, smoother_is_settled(&s))
}
