package dsp

import "base:intrinsics"
import "core:math"
import "core:simd"
import "core:testing"

// Biquad — transposed direct form II

BiquadType :: enum {
	Lowpass,
	Highpass,
	Bandpass,
	Notch,
	Allpass,
	PeakingEQ,
	LowShelf,
	HighShelf,
}

BiquadCoeffs :: struct {
	b0, b1, b2, a1, a2: f32,
}

Biquad :: struct {
	coeffs: BiquadCoeffs,
	z1, z2: f32,
}

// Audio EQ Cookbook formulas (Robert Bristow-Johnson)
// a1/a2 are negated for transposed direct form II
biquad_calc_coeffs :: proc(type: BiquadType, freq, q: f32, gain_db: f32 = 0, sample_rate: f32 = 44100) -> BiquadCoeffs {
	w0 := TAU * freq / sample_rate
	cos_w0 := math.cos(w0)
	sin_w0 := math.sin(w0)
	alpha := sin_w0 / (2 * q)

	b0, b1, b2, a0, a1, a2: f32

	switch type {
	case .Lowpass:
		b1 = 1 - cos_w0
		b0 = b1 / 2
		b2 = b0
		a0 = 1 + alpha
		a1 = -2 * cos_w0
		a2 = 1 - alpha

	case .Highpass:
		b1 = -(1 + cos_w0)
		b0 = (1 + cos_w0) / 2
		b2 = b0
		a0 = 1 + alpha
		a1 = -2 * cos_w0
		a2 = 1 - alpha

	case .Bandpass:
		b0 = alpha
		b1 = 0
		b2 = -alpha
		a0 = 1 + alpha
		a1 = -2 * cos_w0
		a2 = 1 - alpha

	case .Notch:
		b0 = 1
		b1 = -2 * cos_w0
		b2 = 1
		a0 = 1 + alpha
		a1 = -2 * cos_w0
		a2 = 1 - alpha

	case .Allpass:
		b0 = 1 - alpha
		b1 = -2 * cos_w0
		b2 = 1 + alpha
		a0 = 1 + alpha
		a1 = -2 * cos_w0
		a2 = 1 - alpha

	case .PeakingEQ:
		A := math.pow(f32(10), gain_db / 40)
		b0 = 1 + alpha * A
		b1 = -2 * cos_w0
		b2 = 1 - alpha * A
		a0 = 1 + alpha / A
		a1 = -2 * cos_w0
		a2 = 1 - alpha / A

	case .LowShelf:
		A := math.pow(f32(10), gain_db / 40)
		sqrt_A := math.sqrt(A)
		b0 = A * ((A + 1) - (A - 1) * cos_w0 + 2 * sqrt_A * alpha)
		b1 = 2 * A * ((A - 1) - (A + 1) * cos_w0)
		b2 = A * ((A + 1) - (A - 1) * cos_w0 - 2 * sqrt_A * alpha)
		a0 = (A + 1) + (A - 1) * cos_w0 + 2 * sqrt_A * alpha
		a1 = -2 * ((A - 1) + (A + 1) * cos_w0)
		a2 = (A + 1) + (A - 1) * cos_w0 - 2 * sqrt_A * alpha

	case .HighShelf:
		A := math.pow(f32(10), gain_db / 40)
		sqrt_A := math.sqrt(A)
		b0 = A * ((A + 1) + (A - 1) * cos_w0 + 2 * sqrt_A * alpha)
		b1 = -2 * A * ((A - 1) + (A + 1) * cos_w0)
		b2 = A * ((A + 1) + (A - 1) * cos_w0 - 2 * sqrt_A * alpha)
		a0 = (A + 1) - (A - 1) * cos_w0 + 2 * sqrt_A * alpha
		a1 = 2 * ((A - 1) - (A + 1) * cos_w0)
		a2 = (A + 1) - (A - 1) * cos_w0 - 2 * sqrt_A * alpha
	}

	// Normalize and negate a1/a2 for DF2T
	inv_a0 := 1.0 / a0
	return BiquadCoeffs{
		b0 = b0 * inv_a0,
		b1 = b1 * inv_a0,
		b2 = b2 * inv_a0,
		a1 = -a1 * inv_a0,
		a2 = -a2 * inv_a0,
	}
}

biquad_process :: proc(f: ^Biquad, input: Sample) -> Sample {
	c := &f.coeffs
	out := c.b0 * input + f.z1
	f.z1 = c.b1 * input + c.a1 * out + f.z2
	f.z2 = c.b2 * input + c.a2 * out
	return out
}

biquad_process_buf :: proc(f: ^Biquad, buf: []Sample) {
	for &s in buf {
		s = biquad_process(f, s)
	}
}

biquad_reset :: proc(f: ^Biquad) {
	f.z1 = 0
	f.z2 = 0
}

// One-pole filter

OnePole :: struct {
	a0, b1, z1: f32,
}

onepole_set_lowpass :: proc(f: ^OnePole, freq: f32, sample_rate: f32) {
	b := math.exp(-TAU * freq / sample_rate)
	f.a0 = 1 - b
	f.b1 = b
}

onepole_set_highpass :: proc(f: ^OnePole, freq: f32, sample_rate: f32) {
	b := math.exp(-TAU * freq / sample_rate)
	f.a0 = (1 + b) / 2
	f.b1 = -b
}

onepole_process :: proc(f: ^OnePole, input: Sample) -> Sample {
	f.z1 = input * f.a0 + f.z1 * f.b1
	return f.z1
}

onepole_process_buf :: proc(f: ^OnePole, buf: []Sample) {
	for &s in buf {
		s = onepole_process(f, s)
	}
}

// DC blocker — y[n] = x[n] - x[n-1] + R * y[n-1]

DCBlocker :: struct {
	x1, y1, r: f32,
}

dc_blocker_init :: proc(d: ^DCBlocker, r: f32 = 0.995) {
	d.r = r
	d.x1 = 0
	d.y1 = 0
}

dc_blocker_process :: proc(d: ^DCBlocker, input: Sample) -> Sample {
	out := input - d.x1 + d.r * d.y1
	d.x1 = input
	d.y1 = out
	return out
}

dc_blocker_process_buf :: proc(d: ^DCBlocker, buf: []Sample) {
	for &s in buf {
		s = dc_blocker_process(d, s)
	}
	d.y1 = flush_denormal(d.y1)
	d.x1 = flush_denormal(d.x1)
}

// State variable filter — Cytomic/Andrew Simper topology

SVFType :: enum {
	Lowpass,
	Highpass,
	Bandpass,
	Notch,
	Allpass,
}

SVFOutputs :: struct {
	low, high, band, notch: Sample,
}

SVF :: struct {
	ic1eq, ic2eq: f32,
	a1, a2, a3:   f32,
	g, k:         f32,
}

svf_set_params :: proc(f: ^SVF, freq, q: f32, sample_rate: f32) {
	f.g = math.tan(PI * freq / sample_rate)
	f.k = 1.0 / q
	f.a1 = 1.0 / (1.0 + f.g * (f.g + f.k))
	f.a2 = f.g * f.a1
	f.a3 = f.g * f.a2
}

svf_process_multi :: proc(f: ^SVF, input: Sample) -> SVFOutputs {
	v3 := input - f.ic2eq
	v1 := f.a1 * f.ic1eq + f.a2 * v3
	v2 := f.ic2eq + f.a2 * f.ic1eq + f.a3 * v3
	f.ic1eq = 2 * v1 - f.ic1eq
	f.ic2eq = 2 * v2 - f.ic2eq

	return SVFOutputs{
		low = v2,
		band = v1,
		high = input - f.k * v1 - v2,
		notch = input - f.k * v1,
	}
}

svf_process :: proc(f: ^SVF, input: Sample, type: SVFType = .Lowpass) -> Sample {
	o := svf_process_multi(f, input)
	switch type {
	case .Lowpass:  return o.low
	case .Highpass: return o.high
	case .Bandpass: return o.band
	case .Notch:    return o.notch
	case .Allpass:  return o.low + o.high
	}
	return o.low
}

svf_process_buf :: proc(f: ^SVF, buf: []Sample, type: SVFType = .Lowpass) {
	for &s in buf {
		s = svf_process(f, s, type)
	}
}

svf_reset :: proc(f: ^SVF) {
	f.ic1eq = 0
	f.ic2eq = 0
}

// Hilbert FIR — windowed-sinc, antisymmetric, half-band, SIMD inner loop.
//
// Returns the analytic signal as a (real, imag) pair: real is the input delayed
// by the filter's group delay (N-1)/2; imag is the Hilbert transform (90° phase
// shift). Together they let you plot a Lissajous of the analytic signal.
//
// Phase is always exactly 90° (antisymmetry guarantees it). N controls the lower
// edge of the magnitude-flat band — below it, output radius sags. Hann window at
// 48 kHz: N=63 flat above ~2.5 kHz, N=255 above ~600 Hz, N=511 above ~300 Hz.
//
// Storage layout, both caller-provided:
//   coeffs_buf — length M = (N+1)/2, holds nonzero taps packed in reverse so
//                coeffs[j] multiplies the sample at window position (N-1) - 2j.
//                Packed walks forward as the read window walks forward.
//   delay_buf  — length 2N + 8. Double-written (delay[i] == delay[i+N] for i in
//                [0,N)) so any length-N read starting in [0,N] is contiguous,
//                no wrap mask needed. The +8 lets the final 4-wide iteration's
//                8-float load run past the active window into padding (unused
//                trailing lanes get shuffled away).
//
// Conv loop loads 8 contiguous delay samples, shuffles out the 4 even-offset
// stride-2 taps, FMA against 4 packed coeffs. Horizontal-sum at the end.
//
// Assumes N ≡ 3 (mod 4) so the nonzero taps start at window position 0.
// (Both N=63 and N=511 satisfy this.)

HilbertFIR :: struct {
	coeffs: []Sample, // length M = (N+1)/2, packed-reverse
	delay:  []Sample, // length 2N + 8, double-written
	N:      int,
	M:      int,
	center: int,      // (N-1)/2, real-out group delay
	idx:    int,      // position of most recent write, in [0, N)
}

hilbert_fir_init :: proc(h: ^HilbertFIR, coeffs_buf, delay_buf: []Sample, window: WindowType = .Hann) {
	assert(len(delay_buf) >= 9, "delay_buf too small")
	N := (len(delay_buf) - 8) / 2
	assert(N % 2 == 1, "N must be odd")
	assert(N % 4 == 3, "SIMD Hilbert requires N ≡ 3 (mod 4)")
	M := (N + 1) / 2
	assert(len(coeffs_buf) >= M, "coeffs_buf must hold (N+1)/2 packed taps")

	h.coeffs = coeffs_buf[:M]
	h.delay  = delay_buf
	h.N      = N
	h.M      = M
	h.center = (N - 1) / 2
	h.idx    = N - 1 // first process call increments to 0

	M_orig := (N - 1) / 2
	inv_span := 1.0 / f32(N - 1)
	for j in 0 ..< M {
		k := N - 1 - 2 * j     // original (unpacked) tap index
		n := k - M_orig         // sinc argument; always odd here
		ideal := 2.0 / (PI * f32(n))
		w := window_sample(window, f32(k) * inv_span)
		h.coeffs[j] = ideal * w
	}
	for i in 0 ..< len(h.delay) do h.delay[i] = 0
}

hilbert_fir_process :: proc(h: ^HilbertFIR, input: Sample) -> (real_out, imag_out: Sample) {
	#no_bounds_check {
		h.idx = (h.idx + 1) % h.N
		h.delay[h.idx]       = input
		h.delay[h.idx + h.N] = input

		// Read window [start, start+N): ascending in array == ascending in time.
		// Even within-window positions (0, 2, 4, …) are the stride-2 nonzero taps.
		start := h.idx + 1

		// `simd.from_slice` is a regular (non-inlined) proc with an assert + element loop, so in
		// debug it shows up as ~9M function calls/sec at 48 kHz × 64 iters × 3 loads. Skip it and
		// reinterpret pointers via `intrinsics.unaligned_load`, which is a true intrinsic and
		// lowers to one vector load. f32 has no alignment requirement on ARM64 or x86 vector loads.
		acc: #simd[4]f32
		j := 0
		for ; j + 4 <= h.M; j += 4 {
			p := start + 2 * j
			lo := intrinsics.unaligned_load(cast(^#simd[4]f32)&h.delay[p])
			hi := intrinsics.unaligned_load(cast(^#simd[4]f32)&h.delay[p + 4])
			d4 := simd.shuffle(lo, hi, 0, 2, 4, 6)
			c4 := intrinsics.unaligned_load(cast(^#simd[4]f32)&h.coeffs[j])
			acc = simd.fma(c4, d4, acc)
		}
		sum := simd.reduce_add_ordered(acc)
		for ; j < h.M; j += 1 {
			sum += h.coeffs[j] * h.delay[start + 2 * j]
		}
		real_out = h.delay[h.idx + h.N - h.center]
		imag_out = sum
		return
	}
}

hilbert_fir_reset :: proc(h: ^HilbertFIR) {
	for i in 0 ..< len(h.delay) do h.delay[i] = 0
	h.idx = h.N - 1
}

// Tests

@(test)
test_biquad_dc_through_lowpass :: proc(t: ^testing.T) {
	f: Biquad
	f.coeffs = biquad_calc_coeffs(.Lowpass, 1000, 0.707, 0, 44100)

	// Feed DC signal, output should converge to same DC
	out: Sample
	for _ in 0 ..< 1000 {
		out = biquad_process(&f, 1.0)
	}
	testing.expect(t, math.abs(out - 1.0) < 0.01)
}

@(test)
test_biquad_reset :: proc(t: ^testing.T) {
	f: Biquad
	f.coeffs = biquad_calc_coeffs(.Lowpass, 1000, 0.707, 0, 44100)
	biquad_process(&f, 1.0)
	biquad_reset(&f)
	testing.expect_value(t, f.z1, f32(0))
	testing.expect_value(t, f.z2, f32(0))
}

@(test)
test_dc_blocker_removes_dc :: proc(t: ^testing.T) {
	d: DCBlocker
	dc_blocker_init(&d)

	out: Sample
	for _ in 0 ..< 10000 {
		out = dc_blocker_process(&d, 1.0)
	}
	// DC should be removed — output near 0
	testing.expect(t, math.abs(out) < 0.01)
}

@(test)
test_hilbert_fir_circle :: proc(t: ^testing.T) {
	// A 1 kHz sine at 48 kHz should produce real² + imag² ≈ 1 after the filter primes.
	N :: 63
	coeffs: [(N + 1) / 2]Sample // packed nonzero taps
	delay:  [2 * N + 8]Sample   // double-write + 8-float SIMD tail pad
	h: HilbertFIR
	hilbert_fir_init(&h, coeffs[:], delay[:])

	sr := f32(48000)
	freq := f32(2500)
	worst: f32 = 0
	for i in 0 ..< 2048 {
		phase := TAU * freq * f32(i) / sr
		_, _ = hilbert_fir_process(&h, math.sin(phase))
	}
	// After priming, measure radius deviation over one full cycle
	for i in 0 ..< 1024 {
		phase := TAU * freq * f32(2048 + i) / sr
		r, im := hilbert_fir_process(&h, math.sin(phase))
		radius := math.sqrt(r * r + im * im)
		dev := math.abs(radius - 1)
		if dev > worst do worst = dev
	}
	testing.expectf(t, worst < 0.02, "worst radius deviation = %f", worst)
}

@(test)
test_svf_lowpass_dc :: proc(t: ^testing.T) {
	f: SVF
	svf_set_params(&f, 1000, 0.707, 44100)

	out: Sample
	for _ in 0 ..< 1000 {
		out = svf_process(&f, 1.0, .Lowpass)
	}
	testing.expect(t, math.abs(out - 1.0) < 0.01)
}
