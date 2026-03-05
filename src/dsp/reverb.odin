package dsp

import "core:math"
import "core:testing"

// Freeverb — 8 parallel comb filters + 4 series allpass filters, stereo

COMB_COUNT :: 8
ALLPASS_COUNT :: 4

COMB_BUF_SIZE :: 4096
ALLPASS_BUF_SIZE :: 2048

// Freeverb tuning constants
STEREO_SPREAD :: 23

@(rodata)
COMB_LENGTHS := [COMB_COUNT]int{
	1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617,
}

@(rodata)
ALLPASS_LENGTHS := [ALLPASS_COUNT]int{
	556, 441, 341, 225,
}

CombFilter :: struct {
	delay:    DelayLine,
	buffer:   [COMB_BUF_SIZE]Sample,
	filter:   f32,
	feedback: f32,
	damp1:    f32,
	damp2:    f32,
}

comb_init :: proc(c: ^CombFilter, length: int) {
	delay_init(&c.delay, c.buffer[:length])
	c.filter = 0
}

comb_process :: proc(c: ^CombFilter, input: Sample) -> Sample {
	out := delay_read(&c.delay, c.delay.length)
	c.filter = out * c.damp2 + c.filter * c.damp1
	delay_write(&c.delay, input + c.filter * c.feedback)
	return out
}

AllpassFilter :: struct {
	delay:    DelayLine,
	buffer:   [ALLPASS_BUF_SIZE]Sample,
	feedback: f32,
}

allpass_init :: proc(a: ^AllpassFilter, length: int) {
	delay_init(&a.delay, a.buffer[:length])
	a.feedback = 0.5
}

allpass_process :: proc(a: ^AllpassFilter, input: Sample) -> Sample {
	buf_out := delay_read(&a.delay, a.delay.length)
	out := -input + buf_out
	delay_write(&a.delay, input + buf_out * a.feedback)
	return out
}

Reverb :: struct {
	combs_l:    [COMB_COUNT]CombFilter,
	combs_r:    [COMB_COUNT]CombFilter,
	allpasses_l: [ALLPASS_COUNT]AllpassFilter,
	allpasses_r: [ALLPASS_COUNT]AllpassFilter,

	room_size:  f32,
	damping:    f32,
	wet:        f32,
	dry:        f32,
	width:      f32,
	sample_rate: f32,
}

reverb_init :: proc(r: ^Reverb, sample_rate: f32) {
	r.sample_rate = sample_rate
	scale := sample_rate / 44100 // Scale delay lengths for sample rate

	for i in 0 ..< COMB_COUNT {
		len_l := min(int(f32(COMB_LENGTHS[i]) * scale), COMB_BUF_SIZE)
		len_r := min(int(f32(COMB_LENGTHS[i] + STEREO_SPREAD) * scale), COMB_BUF_SIZE)
		comb_init(&r.combs_l[i], len_l)
		comb_init(&r.combs_r[i], len_r)
	}

	for i in 0 ..< ALLPASS_COUNT {
		len_l := min(int(f32(ALLPASS_LENGTHS[i]) * scale), ALLPASS_BUF_SIZE)
		len_r := min(int(f32(ALLPASS_LENGTHS[i] + STEREO_SPREAD) * scale), ALLPASS_BUF_SIZE)
		allpass_init(&r.allpasses_l[i], len_l)
		allpass_init(&r.allpasses_r[i], len_r)
	}

	r.wet = 0.3
	r.dry = 0.7
	r.width = 1.0
	reverb_set_room_size(r, 0.5)
	reverb_set_damping(r, 0.5)
}

reverb_set_room_size :: proc(r: ^Reverb, size: f32) {
	r.room_size = size
	feedback := size * 0.28 + 0.7 // Map 0..1 to 0.7..0.98
	for i in 0 ..< COMB_COUNT {
		r.combs_l[i].feedback = feedback
		r.combs_r[i].feedback = feedback
	}
}

reverb_set_damping :: proc(r: ^Reverb, damping: f32) {
	r.damping = damping
	for i in 0 ..< COMB_COUNT {
		r.combs_l[i].damp1 = damping
		r.combs_l[i].damp2 = 1 - damping
		r.combs_r[i].damp1 = damping
		r.combs_r[i].damp2 = 1 - damping
	}
}

reverb_set_wet :: proc(r: ^Reverb, wet: f32) {
	r.wet = wet
}

reverb_set_dry :: proc(r: ^Reverb, dry: f32) {
	r.dry = dry
}

reverb_set_width :: proc(r: ^Reverb, width: f32) {
	r.width = width
}

reverb_process :: proc(r: ^Reverb, in_l, in_r: Sample) -> (out_l: Sample, out_r: Sample) {
	input := (in_l + in_r) * 0.5 // Mono input to reverb

	// Parallel comb filters
	wet_l, wet_r: Sample
	for i in 0 ..< COMB_COUNT {
		wet_l += comb_process(&r.combs_l[i], input)
		wet_r += comb_process(&r.combs_r[i], input)
	}

	// Series allpass filters
	for i in 0 ..< ALLPASS_COUNT {
		wet_l = allpass_process(&r.allpasses_l[i], wet_l)
		wet_r = allpass_process(&r.allpasses_r[i], wet_r)
	}

	// Stereo width
	wet1 := r.wet * (1 + r.width) / 2
	wet2 := r.wet * (1 - r.width) / 2

	out_l = in_l * r.dry + wet_l * wet1 + wet_r * wet2
	out_r = in_r * r.dry + wet_r * wet1 + wet_l * wet2
	return
}

reverb_process_buf :: proc(r: ^Reverb, buf_l, buf_r: []Sample) {
	n := min(len(buf_l), len(buf_r))
	for i in 0 ..< n {
		buf_l[i], buf_r[i] = reverb_process(r, buf_l[i], buf_r[i])
	}
}

// Tests

@(test)
test_reverb_silence_in_silence_out :: proc(t: ^testing.T) {
	r := new(Reverb)
	defer free(r)
	reverb_init(r, 44100)

	l, rr := reverb_process(r, 0, 0)
	testing.expect_value(t, l, Sample(0))
	testing.expect_value(t, rr, Sample(0))
}

@(test)
test_reverb_produces_output :: proc(t: ^testing.T) {
	r := new(Reverb)
	defer free(r)
	reverb_init(r, 44100)
	reverb_set_wet(r, 1.0)
	reverb_set_dry(r, 0.0)

	// Feed an impulse
	reverb_process(r, 1.0, 1.0)

	// After some samples, reverb tail should be nonzero
	has_output := false
	for _ in 0 ..< 2000 {
		l, _ := reverb_process(r, 0, 0)
		if math.abs(l) > 1e-6 {
			has_output = true
			break
		}
	}
	testing.expect(t, has_output)
}
