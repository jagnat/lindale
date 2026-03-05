package dsp

import "core:math"
import "core:math/rand"
import "core:testing"

Waveform :: enum {
	Sine,
	Saw,
	Triangle,
	Square,
	Noise,
}

Oscillator :: struct {
	phase:       Phase,
	phase_inc:   f32,
	sample_rate: f32,
}

osc_init :: proc(o: ^Oscillator, sample_rate: f32) {
	o.phase = 0
	o.phase_inc = 0
	o.sample_rate = sample_rate
}

osc_set_freq :: proc(o: ^Oscillator, freq: f32) {
	o.phase_inc = freq / o.sample_rate
}

osc_reset :: proc(o: ^Oscillator) {
	o.phase = 0
}

osc_next :: proc(o: ^Oscillator, waveform: Waveform) -> Sample {
	out := waveform_at_phase(waveform, o.phase)
	o.phase += o.phase_inc
	// Wrap to 0..1
	o.phase -= f32(int(o.phase))
	if o.phase < 0 do o.phase += 1
	return out
}

osc_fill :: proc(o: ^Oscillator, buf: []Sample, waveform: Waveform) {
	for &s in buf {
		s = osc_next(o, waveform)
	}
}

// Stateless waveform evaluation at a given phase (0..1)
waveform_at_phase :: proc(waveform: Waveform, phase: Phase) -> Sample {
	switch waveform {
	case .Sine:
		return math.sin(TAU * phase)
	case .Saw:
		return 2 * phase - 1
	case .Triangle:
		return 2 * math.abs(2 * phase - 1) - 1
	case .Square:
		return phase < 0.5 ? 1 : -1
	case .Noise:
		return rand.float32_range(-1, 1)
	}
	return 0
}

// Tests

@(test)
test_sine_quarter_phase :: proc(t: ^testing.T) {
	// sin(TAU * 0.25) = sin(PI/2) = 1.0
	val := waveform_at_phase(.Sine, 0.25)
	testing.expect(t, math.abs(val - 1.0) < 1e-6)
}

@(test)
test_saw_endpoints :: proc(t: ^testing.T) {
	testing.expect(t, math.abs(waveform_at_phase(.Saw, 0) - (-1)) < 1e-6)
	testing.expect(t, math.abs(waveform_at_phase(.Saw, 1) - 1) < 1e-6)
}

@(test)
test_osc_full_cycle :: proc(t: ^testing.T) {
	o: Oscillator
	osc_init(&o, 128)
	osc_set_freq(&o, 1) // 1 Hz at 128 sr = power-of-two, exact f32 increment
	for _ in 0 ..< 128 {
		osc_next(&o, .Sine)
	}
	// After exactly one cycle, phase should wrap back near 0
	testing.expect(t, math.abs(o.phase) < 1e-4)
}

@(test)
test_square_wave :: proc(t: ^testing.T) {
	testing.expect_value(t, waveform_at_phase(.Square, 0.0), Sample(1))
	testing.expect_value(t, waveform_at_phase(.Square, 0.25), Sample(1))
	testing.expect_value(t, waveform_at_phase(.Square, 0.5), Sample(-1))
	testing.expect_value(t, waveform_at_phase(.Square, 0.75), Sample(-1))
}
