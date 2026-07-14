package dsp

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/cmplx"

compute_twiddles :: proc(buf: []complex64) { // passed half-N buf
	for k in 0..<len(buf) {
		buf[k] = cmplx.exp_complex64(-1i * complex64(math.TAU * f32(k) / f32(len(buf) * 2)))
	}
}

radix2_fft :: proc(buf: []complex64) {
	size := u32(len(buf))
	assert(intrinsics.count_ones(size) == 1, "Must use power of 2 for array size")

	half := size / 2
	twiddles := make([]complex64, half, allocator = context.temp_allocator)
	compute_twiddles(twiddles)

	// Perform bit-reversal swap relative to the size of the array
	bit_width := intrinsics.count_trailing_zeros(size)
	for i in 0..<size {
		rev := intrinsics.reverse_bits(i) >> (32 - bit_width)
		if i < rev {
			buf[i], buf[rev] = buf[rev], buf[i]
		}
	}

	for stage in 1..=bit_width {
		m : u32= 1 << stage
		twiddle_stride := size / m
		m2 : u32= m >> 1
		for group_start: u32= 0; group_start < size; group_start += m {
			for j in 0..<m2 {
				twiddle := twiddles[j * twiddle_stride]
				even := buf[group_start + j]
				odd := buf[group_start + j + m2]
				buf[group_start + j] = even + twiddle * odd
				buf[group_start + j + m2] = even - twiddle * odd
			}
		}
	}
}
