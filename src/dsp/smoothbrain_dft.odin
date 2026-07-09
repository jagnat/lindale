package dsp

import "core:math/cmplx"
import "core:math"

smooth_brain_dft :: proc(buf: ^[]complex64) {
	tmp_buf := make([]complex64, len(buf), allocator = context.temp_allocator)
	for m in 0..<len(buf) {
		sum : complex64
		for n in 0..<len(buf) {
			x_n := buf[n]
			e_bla := cmplx.exp_complex64(-1i * complex64(math.TAU * f32(n * m) / f32(len(buf))))
			sum += x_n * e_bla
		}
		tmp_buf[m] = sum
	}

	for m in 0..<len(buf) {
		buf[m] = tmp_buf[m]
	}
}
