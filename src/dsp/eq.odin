package dsp

import "core:math"
import "core:testing"

MAX_EQ_BANDS :: 8

EQBandConfig :: struct {
	type:    BiquadType,
	freq:    f32,
	q:       f32,
	gain_db: f32,
	enabled: bool,
}

EQ :: struct {
	bands:       [MAX_EQ_BANDS]Biquad,
	band_config: [MAX_EQ_BANDS]EQBandConfig,
	num_bands:   int,
	sample_rate: f32,
}

eq_init :: proc(eq: ^EQ, sample_rate: f32, num_bands: int = MAX_EQ_BANDS) {
	eq.sample_rate = sample_rate
	eq.num_bands = min(num_bands, MAX_EQ_BANDS)
}

eq_set_band :: proc(eq: ^EQ, index: int, config: EQBandConfig) {
	if index < 0 || index >= eq.num_bands do return
	eq.band_config[index] = config
	if config.enabled {
		eq.bands[index].coeffs = biquad_calc_coeffs(config.type, config.freq, config.q, config.gain_db, eq.sample_rate)
	}
}

eq_process :: proc(eq: ^EQ, input: Sample) -> Sample {
	out := input
	for i in 0 ..< eq.num_bands {
		if !eq.band_config[i].enabled do continue
		out = biquad_process(&eq.bands[i], out)
	}
	return out
}

eq_process_buf :: proc(eq: ^EQ, buf: []Sample) {
	for i in 0 ..< eq.num_bands {
		if !eq.band_config[i].enabled do continue
		biquad_process_buf(&eq.bands[i], buf)
	}
}

eq_reset :: proc(eq: ^EQ) {
	for i in 0 ..< eq.num_bands {
		biquad_reset(&eq.bands[i])
	}
}

// Tests

@(test)
test_eq_passthrough :: proc(t: ^testing.T) {
	eq: EQ
	eq_init(&eq, 44100, 3)

	// No bands enabled — signal passes through unchanged
	testing.expect_value(t, eq_process(&eq, 0.5), Sample(0.5))
}

@(test)
test_eq_dc_through_lowpass :: proc(t: ^testing.T) {
	eq: EQ
	eq_init(&eq, 44100, 1)
	eq_set_band(&eq, 0, EQBandConfig{
		type = .Lowpass,
		freq = 5000,
		q = 0.707,
		gain_db = 0,
		enabled = true,
	})

	out: Sample
	for _ in 0 ..< 1000 {
		out = eq_process(&eq, 1.0)
	}
	testing.expect(t, math.abs(out - 1.0) < 0.01)
}

@(test)
test_eq_disabled_band_skipped :: proc(t: ^testing.T) {
	eq: EQ
	eq_init(&eq, 44100, 1)
	eq_set_band(&eq, 0, EQBandConfig{
		type = .Highpass,
		freq = 10000,
		q = 0.707,
		gain_db = 0,
		enabled = false,
	})

	// Disabled band should not affect signal
	testing.expect_value(t, eq_process(&eq, 0.75), Sample(0.75))
}
