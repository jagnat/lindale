package dsp

import "core:math"
import "core:testing"

Sample :: f32
Phase :: f32 // 0..1, wraps

StereoFrame :: struct {
	left, right: Sample,
}

PI  :: math.PI
TAU :: math.TAU

// Buffer operations

buf_clear :: proc(buf: []Sample) {
	for &s in buf {
		s = 0
	}
}

buf_copy :: proc(dst, src: []Sample) {
	n := min(len(dst), len(src))
	for i in 0 ..< n {
		dst[i] = src[i]
	}
}

buf_mix :: proc(dst, src: []Sample, gain: Sample = 1) {
	n := min(len(dst), len(src))
	for i in 0 ..< n {
		dst[i] += src[i] * gain
	}
}

buf_scale :: proc(buf: []Sample, gain: Sample) {
	for &s in buf {
		s *= gain
	}
}

buf_fade :: proc(buf: []Sample, start_gain, end_gain: Sample) {
	n := len(buf)
	if n == 0 do return
	inv_n := 1.0 / Sample(n)
	for i in 0 ..< n {
		t := Sample(i) * inv_n
		buf[i] *= start_gain + (end_gain - start_gain) * t
	}
}

// Tests

@(test)
test_buf_clear :: proc(t: ^testing.T) {
	buf := [4]Sample{1, 2, 3, 4}
	buf_clear(buf[:])
	for s in buf {
		testing.expect(t, s == 0)
	}
}

@(test)
test_buf_mix :: proc(t: ^testing.T) {
	dst := [4]Sample{1, 1, 1, 1}
	src := [4]Sample{2, 3, 4, 5}
	buf_mix(dst[:], src[:], 0.5)
	testing.expect_value(t, dst[0], 2.0)
	testing.expect_value(t, dst[1], 2.5)
	testing.expect_value(t, dst[2], 3.0)
	testing.expect_value(t, dst[3], 3.5)
}

@(test)
test_buf_scale :: proc(t: ^testing.T) {
	buf := [3]Sample{2, 4, 6}
	buf_scale(buf[:], 0.5)
	testing.expect_value(t, buf[0], 1.0)
	testing.expect_value(t, buf[1], 2.0)
	testing.expect_value(t, buf[2], 3.0)
}

@(test)
test_buf_fade :: proc(t: ^testing.T) {
	buf := [4]Sample{1, 1, 1, 1}
	buf_fade(buf[:], 0, 1)
	testing.expect_value(t, buf[0], 0.0)
	testing.expect(t, buf[1] > 0 && buf[1] < 1)
	testing.expect(t, buf[2] > buf[1])
	testing.expect(t, buf[3] > buf[2])
}

@(test)
test_buf_copy :: proc(t: ^testing.T) {
	src := [3]Sample{10, 20, 30}
	dst := [3]Sample{0, 0, 0}
	buf_copy(dst[:], src[:])
	for i in 0 ..< 3 {
		testing.expect_value(t, dst[i], src[i])
	}
}
