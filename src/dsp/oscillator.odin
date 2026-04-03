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
	phase: Phase,
	phase_inc: f32, // Freq in seconds per sample
	sample_rate: f32,
	wave: Waveform,

	// Running variables
	val, lastVal: Sample,
	triAcc: Sample, // pre-normalization triangle integrator state
}

osc_init :: proc(o: ^Oscillator, sample_rate: f32) {
	o^ = {}
	o.sample_rate = sample_rate
	o.wave = .Sine
}

osc_set_freq :: proc(o: ^Oscillator, freq: f32) {
	o.phase_inc = freq / o.sample_rate
}

osc_set_waveform :: proc(o: ^Oscillator, wav: Waveform) {
	o.wave = wav
}

osc_reset :: proc(o: ^Oscillator) {
	o.phase = 0
}

osc_next :: proc(o: ^Oscillator) -> Sample {
	o.lastVal = o.val
	o.val = osc_polyblep_value(o)
	o.phase += o.phase_inc
	// Wrap to 0..1
	o.phase -= f32(int(o.phase))
	if o.phase < 0 do o.phase += 1
	return o.val
}

osc_fill :: proc(o: ^Oscillator, buf: []Sample) {
	for &s in buf {
		s = osc_next(o)
	}
}

osc_waveform_value :: proc(o: ^Oscillator) -> Sample {
	switch o.wave {
	case .Sine:
		return math.sin(TAU * o.phase)
	case .Saw:
		return 2 * o.phase - 1
	case .Triangle:
		return 2 * math.abs(2 * o.phase - 1) - 1
	case .Square:
		return o.phase < 0.5 ? 1 : -1
	case .Noise:
		return rand.float32_range(-1, 1)
	}
	return 0
}

@(private="file")
blep :: proc(t, dt: Sample) -> Sample {
	if (t < dt) {
		return - ((t / dt - 1) * (t / dt - 1));
	} else if (t > 1 - dt) {
		return ((t - 1) / dt + 1) * ((t - 1) / dt + 1)
	} else {
		return 0
	}
}

osc_polyblep_value :: proc(o: ^Oscillator) -> Sample {
	val := f32(0)
	phase := o.phase
	phase_inc := o.phase_inc
	switch o.wave {
	case .Sine:
		val = math.sin(TAU * phase)
	case .Saw:
		val = 2 * phase - 1
		val -= blep(phase, phase_inc)
	case .Square, .Triangle:
		val = phase < 0.5 ? 1 : -1
		val += blep(phase, phase_inc)
		val -= blep(math.mod(phase + 0.5, 1.0), phase_inc)
		if o.wave == .Triangle {
			o.triAcc = phase_inc * val + (1 - phase_inc) * o.triAcc
			val = o.triAcc * 4.0
		}
	case .Noise:
		val = rand.float32_range(-1, 1)
	}
	return val
}

// Tests

@(test)
test_sine_quarter_phase :: proc(t: ^testing.T) {
	// sin(TAU * 0.25) = sin(PI/2) = 1.0
	o: Oscillator
	o.wave = .Sine
	o.phase = 0.25
	val := osc_waveform_value(&o)
	testing.expect(t, math.abs(val - 1.0) < 1e-6)
}

@(test)
test_polyblep_amplitude :: proc(t: ^testing.T) {
	SR :: f32(44100)
	FREQ :: f32(440)
	samples_per_cycle := int(math.trunc(SR / FREQ))
	run_cycles :: 2

	warmup_cycles :: 5
	waves := [?]Waveform{.Sine, .Saw, .Triangle, .Square}
	for wave in waves {
		o: Oscillator
		osc_init(&o, SR)
		osc_set_freq(&o, FREQ)
		o.wave = wave

		for _ in 0 ..< samples_per_cycle * warmup_cycles do osc_next(&o)

		peak: f32 = 0
		for _ in 0 ..< samples_per_cycle * run_cycles {
			v := math.abs(osc_next(&o))
			if v > peak do peak = v
		}
		testing.expect(t, peak >= 0.8 && peak <= 1.2)
	}
}

@(test)
test_polyblep_dc_offset :: proc(t: ^testing.T) {
	SR :: f32(44100)
	FREQ :: f32(440)
	samples_per_cycle := int(math.trunc(SR / FREQ))
	run_cycles :: 10

	warmup_cycles :: 5
	waves := [?]Waveform{.Sine, .Saw, .Triangle, .Square}
	for wave in waves {
		o: Oscillator
		osc_init(&o, SR)
		osc_set_freq(&o, FREQ)
		o.wave = wave

		for _ in 0 ..< samples_per_cycle * warmup_cycles do osc_next(&o)

		sum: f32 = 0
		n := samples_per_cycle * run_cycles
		for _ in 0 ..< n {
			sum += osc_next(&o)
		}
		mean := sum / f32(n)
		testing.expect(t, mean >= -0.05 && mean <= 0.05)
	}
}

@(test)
test_polyblep_phase_wrap :: proc(t: ^testing.T) {
	o: Oscillator
	osc_init(&o, 128)
	osc_set_freq(&o, 1)
	o.wave = .Sine
	for _ in 0 ..< 128 {
		osc_next(&o)
	}
	testing.expect(t, math.abs(o.phase) < 1e-4)
}
