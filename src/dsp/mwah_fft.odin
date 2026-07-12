package dsp

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/cmplx"

MAXFACTORS :: 32

radix2_fft :: proc(buf: ^[]complex64) {
	size := u32(len(buf))
	assert(intrinsics.count_ones(size) == 1, "Must use power of 2 for array size")

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
		m2 : u32= m >> 1
		for group_start: u32= 0; group_start < size; group_start += m {
			for j in 0..<m2 {
				// todo: precomputed twiddle factor
				twiddle: complex64
				even := buf[group_start + j]
				odd := buf[group_start + j + m2]
				buf[group_start + j] = even + twiddle * odd
				buf[group_start + j + m2] = even - twiddle * odd
			}
		}
	}
}
