package dsp

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/cmplx"

Radix2FFT :: struct {
	n: u32,
	twiddles: []complex64,
}

radix2_fft_init :: proc(n: u32, alloc: runtime.Allocator = context.allocator) -> Radix2FFT {
	fft: Radix2FFT
	fft.n = n
	fft.twiddles = make([]complex64, n / 2, alloc)
	compute_twiddles(fft.twiddles)
	return fft
}

compute_twiddles :: proc(buf: []complex64) { // passed half-N buf
	for k in 0..<len(buf) {
		buf[k] = cmplx.exp_complex64(-1i * complex64(math.TAU * f32(k) / f32(len(buf) * 2)))
	}
}

radix2_fft :: proc(buf: []complex64, fft: Radix2FFT) {
	size := u32(len(buf))
	assert(intrinsics.count_ones(size) == 1, "Must use power of 2 for array size")

	// twiddles := make([]complex64, size / 2, allocator = context.temp_allocator)
	// compute_twiddles(twiddles)

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
				twiddle := fft.twiddles[j * twiddle_stride]
				even := buf[group_start + j]
				odd := buf[group_start + j + m2]
				buf[group_start + j] = even + twiddle * odd
				buf[group_start + j + m2] = even - twiddle * odd
			}
		}
	}
}
