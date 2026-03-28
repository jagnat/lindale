package dsp

import "core:math"
import "core:testing"

EnvelopeStage :: enum {
	Idle,
	Attack,
	Decay,
	Sustain,
	Release,
}

ADSR :: struct {
	stage:         EnvelopeStage,
	level:         f32,
	sample_rate:   f32,
	attack_rate:   f32,
	decay_rate:    f32,
	release_rate:  f32,
	sustain_level: f32,
}

adsr_init :: proc(e: ^ADSR, sample_rate: f32) {
	e.stage = .Idle
	e.level = 0
	e.sample_rate = sample_rate
	e.sustain_level = 1
}

adsr_reset :: proc(e: ^ADSR) {
	e.stage = .Idle
	e.level = 0
}

// Times in seconds
adsr_set_params :: proc(e: ^ADSR, attack, decay, sustain, release: f32) {
	e.sustain_level = sustain

	// Linear attack rate (samples to go from 0 to 1)
	if attack > 0 {
		e.attack_rate = 1.0 / (attack * e.sample_rate)
	} else {
		e.attack_rate = 1 // instant
	}

	// Exponential decay/release — multiplier per sample
	// Reach ~0.001 (-60dB) of remaining distance in given time
	if decay > 0 {
		e.decay_rate = math.exp(-6.9078 / (decay * e.sample_rate)) // ln(0.001) ≈ -6.9078
	} else {
		e.decay_rate = 0
	}

	if release > 0 {
		e.release_rate = math.exp(-6.9078 / (release * e.sample_rate))
	} else {
		e.release_rate = 0
	}
}

adsr_gate_on :: proc(e: ^ADSR) {
	e.stage = .Attack
	// Start from current level for smooth retrigger
}

adsr_gate_off :: proc(e: ^ADSR) {
	if e.stage != .Idle {
		e.stage = .Release
	}
}

adsr_next :: proc(e: ^ADSR) -> f32 {
	switch e.stage {
	case .Idle:
		return 0

	case .Attack:
		e.level += e.attack_rate
		if e.level >= 1.0 {
			e.level = 1.0
			e.stage = .Decay
		}

	case .Decay:
		e.level = e.sustain_level + (e.level - e.sustain_level) * e.decay_rate
		if math.abs(e.level - e.sustain_level) < 1e-5 {
			e.level = e.sustain_level
			e.stage = .Sustain
		}

	case .Sustain:
		e.level = e.sustain_level

	case .Release:
		e.level *= e.release_rate
		if e.level < 1e-5 {
			e.level = 0
			e.stage = .Idle
		}
	}

	return e.level
}

adsr_fill :: proc(e: ^ADSR, buf: []Sample) {
	for &s in buf {
		s = adsr_next(e)
	}
}

adsr_is_idle :: proc(e: ^ADSR) -> bool {
	return e.stage == .Idle
}

// Tests

@(test)
test_adsr_attack_reaches_one :: proc(t: ^testing.T) {
	e: ADSR
	adsr_init(&e, 44100)
	adsr_set_params(&e, 0.01, 0.1, 0.5, 0.1) // 10ms attack
	adsr_gate_on(&e)

	peak: f32 = 0
	for _ in 0 ..< 44100 {
		val := adsr_next(&e)
		peak = max(peak, val)
	}
	testing.expect(t, peak >= 0.99)
}

@(test)
test_adsr_release_to_idle :: proc(t: ^testing.T) {
	e: ADSR
	adsr_init(&e, 44100)
	adsr_set_params(&e, 0.001, 0.01, 0.5, 0.05) // 50ms release
	adsr_gate_on(&e)

	// Run through attack/decay
	for _ in 0 ..< 44100 {
		adsr_next(&e)
	}

	adsr_gate_off(&e)

	// Run release
	for _ in 0 ..< 44100 {
		adsr_next(&e)
	}

	testing.expect(t, adsr_is_idle(&e))
	testing.expect(t, e.level < 1e-5)
}

@(test)
test_adsr_idle_is_zero :: proc(t: ^testing.T) {
	e: ADSR
	adsr_init(&e, 44100)
	testing.expect_value(t, adsr_next(&e), f32(0))
	testing.expect(t, adsr_is_idle(&e))
}
