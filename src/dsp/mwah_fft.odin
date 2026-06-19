package dsp

import "base:runtime"
import "core:math"
import "core:math/cmplx"

MAXFACTORS :: 32

FftConfig :: struct {
	nfft: i32,
	inverse: bool,
	factors: [2*MAXFACTORS]i32,
	twiddles: []complex64,

}

mwah_fft_create :: proc(nfft: i32, inverse: bool = false, alloc: runtime.Allocator = context.allocator) -> FftConfig {
	cfg := FftConfig {
		nfft = nfft,
		inverse = inverse,
	}

	cfg.twiddles = make([]complex64, nfft);

	for i in 0..<nfft {
		phase := math.TAU * -1.0 * f32(i) / f32(nfft)
		if cfg.inverse do phase *= -1
		cfg.twiddles[i] = cmplx.exp(phase)
	}

	mwah_factor(nfft, cfg.factors[:])
	return cfg
}

// Factorize n into slice
mwah_factor :: proc(n: i32, factors: []i32) {
	n := n
	p := i32(4)
	floor_sqrt := math.floor(math.sqrt(f32(n)))
	factorIdx := 0

	for { // Do
		for n % p != 0 {
			if p == 4 do p = 2
			else if p == 2 do p = 3
			else do p += 2

			if f32(p) > floor_sqrt do p = n
		}
		n /= p
		factors[factorIdx] = p
		factors[factorIdx + 1] = n
		factorIdx += 2

		if n <= 1 do break // While n > 1
	}
}

mwah_fft :: proc(cfg: FftConfig, input: []complex64, output: []complex64) {
	mwah_fft_stride(cfg, input, output, 1)
}

mwah_fft_stride :: proc(cfg: FftConfig, input: []complex64, output: []complex64, strid: i32) {
	
}