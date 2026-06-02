package dsp

import "core:math/bits"
import "core:testing"

// POKEY audio core — cycle-tick emulation: register writes in, DAC samples out.
// The analog output stage (DAC nonlinearity, per-machine coloration) is a separate
// layer on top. Keep differential tests against reference emulators (Altirra, MAME
// pokey.cpp, ASAP) pointed at this digital core, never past the analog stage.

POKEY_CHANNELS :: 4

PokeyMachine :: enum {
	NTSC,
	PAL,
}

// Main clock in Hz
POKEY_CLOCK_NTSC :: f64(1789772.5)
POKEY_CLOCK_PAL  :: f64(1773447.0)

// AUDCTL bits
AUDCTL_CLOCK_15 :: u8(0x01) // base divider clock is 15kHz instead of 64kHz
AUDCTL_HPF_CH2  :: u8(0x02) // ch2 high-pass clocked by ch4
AUDCTL_HPF_CH1  :: u8(0x04) // ch1 high-pass clocked by ch3
AUDCTL_JOIN_34  :: u8(0x08) // 16-bit: ch3 low byte, ch4 high byte
AUDCTL_JOIN_12  :: u8(0x10) // 16-bit: ch1 low byte, ch2 high byte
AUDCTL_CH3_FAST :: u8(0x20) // ch3 clocked at the main clock (1.79MHz)
AUDCTL_CH1_FAST :: u8(0x40) // ch1 clocked at the main clock (1.79MHz)
AUDCTL_POLY9    :: u8(0x80) // 9-bit poly instead of 17-bit

// AUDC bits
AUDC_VOLUME   :: u8(0x0f)
AUDC_VOL_ONLY :: u8(0x10) // force output high, DAC tracks volume (4-bit digis)

// Period offset added to AUDF before the divide, per clocking mode. The gate-level
// origin is the Cell 20 vs Cell 24 decrementer borrow delay.
// TODO: confirm against Altirra and wire into pokey_tick's reload.
POKEY_OFFSET_BASE :: i32(1) // 64kHz / 15kHz base clock
POKEY_OFFSET_FAST :: i32(4) // main clock (1.79MHz)
POKEY_OFFSET_LINK :: i32(7) // 16-bit linked pair

PokeyReg :: enum u8 {
	AUDF1, AUDC1,
	AUDF2, AUDC2,
	AUDF3, AUDC3,
	AUDF4, AUDC4,
	AUDCTL,
}

Pokey :: struct {
	machine: PokeyMachine,
	main_clock: f64,

	audf: [POKEY_CHANNELS]u8,
	audc: [POKEY_CHANNELS]u8,
	audctl: u8,

	counter: [POKEY_CHANNELS]i32, // main-clock ticks until the next divider borrow
	out_flip: [POKEY_CHANNELS]bool, // square-wave flip-flop per channel
	hipass: [2]bool, // high-pass latch flip-flops (ch1, ch2)

	// free-running polynomial counter read positions
	poly4_pos: u32,
	poly5_pos: u32,
	poly9_pos: u32,
	poly17_pos: u32,

	clock_divider: i32, // chain deriving the 64kHz / 15kHz enables from the main clock
	tick_accum: f64, // fractional main-clock ticks carried between output samples
}

// Shared maximal-length poly sequences, read-only after generation
@(private) pokey_poly4: [15]u8
@(private) pokey_poly5: [31]u8
@(private) pokey_poly9: [511]u8
@(private) pokey_poly17: [131071]u8
@(private) pokey_polys_ready: bool

// Fibonacci LFSR. The tap masks below are primitive polynomials, so each sequence
// is maximal-length (period 2^n-1).
// TODO: match Altirra's exact bit ordering/phase so timbre lines up, not just the
// statistics — the maximal-length test only pins the latter.
@(private)
pokey_fill_poly :: proc(out: []u8, n: uint, taps: u32) {
	mask := (u32(1) << n) - 1
	state := mask // any nonzero seed
	for i in 0 ..< len(out) {
		out[i] = u8(state & 1)
		fb := u32(bits.count_ones(state & taps) & 1)
		state = ((state >> 1) | (fb << (n - 1))) & mask
	}
}

pokey_generate_polys :: proc() {
	if pokey_polys_ready do return
	pokey_fill_poly(pokey_poly4[:], 4, 0x9) // x^4 + x^3 + 1
	pokey_fill_poly(pokey_poly5[:], 5, 0x5) // x^5 + x^2 + 1
	pokey_fill_poly(pokey_poly9[:], 9, 0x11) // x^9 + x^4 + 1
	pokey_fill_poly(pokey_poly17[:], 17, 0x9) // x^17 + x^3 + 1
	pokey_polys_ready = true
}

pokey_init :: proc(p: ^Pokey, machine: PokeyMachine) {
	pokey_generate_polys()
	p^ = {}
	p.machine = machine
	p.main_clock = POKEY_CLOCK_PAL if machine == .PAL else POKEY_CLOCK_NTSC
}

pokey_reset :: proc(p: ^Pokey) {
	machine := p.machine
	clock := p.main_clock
	p^ = {}
	p.machine = machine
	p.main_clock = clock
}

pokey_write :: proc(p: ^Pokey, reg: PokeyReg, value: u8) {
	switch reg {
	case .AUDF1: p.audf[0] = value
	case .AUDC1: p.audc[0] = value
	case .AUDF2: p.audf[1] = value
	case .AUDC2: p.audc[1] = value
	case .AUDF3: p.audf[2] = value
	case .AUDC3: p.audc[2] = value
	case .AUDF4: p.audf[3] = value
	case .AUDC4: p.audc[3] = value
	case .AUDCTL: p.audctl = value
	}
}

// Advance one main-clock cycle.
// TODO: derive the 64k/15k enables from clock_divider, step the poly read positions,
// decrement per-channel counters and reload with the mode-dependent offset on borrow,
// flip the channel output through the asymmetric poly gate (a low->high edge passes
// only when the selected poly bit is high), then clock the high-pass flip-flops.
pokey_tick :: proc(p: ^Pokey) {
	// TODO
}

// Current digital DAC code in roughly [0,1], before the analog stage. Sums the four
// channels; a channel in volume-only mode contributes its volume regardless of flip.
// TODO: nonlinear / saturating DAC sum instead of this linear placeholder.
pokey_sample :: proc(p: ^Pokey) -> f32 {
	sum: f32
	for c in 0 ..< POKEY_CHANNELS {
		vol := f32(p.audc[c] & AUDC_VOLUME) / 15
		on := p.out_flip[c] || (p.audc[c] & AUDC_VOL_ONLY) != 0
		if on do sum += vol
	}
	return sum / f32(POKEY_CHANNELS)
}

// Tick the core at the main clock and decimate to the host sample_rate, mono.
// TODO: anti-alias the decimation (box-sum or polyphase) instead of point-sampling.
pokey_render :: proc(p: ^Pokey, out: []f32, sample_rate: f64) {
	ticks_per_sample := p.main_clock / sample_rate
	for i in 0 ..< len(out) {
		p.tick_accum += ticks_per_sample
		for p.tick_accum >= 1 {
			pokey_tick(p)
			p.tick_accum -= 1
		}
		out[i] = pokey_sample(p)
	}
}

// Analog output stage — per-machine coloration layered on the digital DAC codes.
// Tuned by ear per target board, never diffed against reference emulators.
PokeyAnalog :: struct {
	// TODO: output high-pass / DC block, machine-specific low-pass, drive/saturation
}

pokey_analog_process :: proc(a: ^PokeyAnalog, buf: []f32) {
	// TODO: passthrough until modeled
}

@(private)
poly_ones :: proc(s: []u8) -> int {
	n: int
	for v in s do n += int(v)
	return n
}

@(test)
test_pokey_poly_maximal_length :: proc(t: ^testing.T) {
	pokey_generate_polys()
	// A maximal-length n-bit LFSR emits exactly 2^(n-1) ones over its 2^n-1 period.
	testing.expect_value(t, poly_ones(pokey_poly4[:]), 8)
	testing.expect_value(t, poly_ones(pokey_poly5[:]), 16)
	testing.expect_value(t, poly_ones(pokey_poly9[:]), 256)
	testing.expect_value(t, poly_ones(pokey_poly17[:]), 65536)
}

@(test)
test_pokey_silence :: proc(t: ^testing.T) {
	p: Pokey
	pokey_init(&p, .NTSC)
	out: [256]f32
	pokey_render(&p, out[:], 48000)
	for v in out do testing.expect_value(t, v, f32(0))
}
