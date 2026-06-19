package dsp

import "core:testing"

POKEY_CHANNELS :: 4

PokeyMachine :: enum {
	NTSC,
	PAL,
}

// Main clock in Hz
POKEY_CLOCK_NTSC :: f64(1789772.5)
POKEY_CLOCK_PAL  :: f64(1773447.0)

// Clock dividers off of main clock for 64 and 15k
POKEY_CYCLE_PERIOD_64K :: 28
POKEY_CYCLE_PERIOD_15K :: 114

// AUDCTL bits
AUDCTL_CLOCK_15 :: u8(0x01) // base divider clock is 15kHz instead of 64kHz
AUDCTL_HPF_CH2  :: u8(0x02) // ch2 high-pass clocked by ch4
AUDCTL_HPF_CH1  :: u8(0x04) // ch1 high-pass clocked by ch3
AUDCTL_JOIN_34  :: u8(0x08) // 16-bit: ch3 lo byte, ch4 hi byte
AUDCTL_JOIN_12  :: u8(0x10) // 16-bit: ch1 lo byte, ch2 hi byte
AUDCTL_CH3_FAST :: u8(0x20) // ch3 clocked at the main clock (1.79MHz)
AUDCTL_CH1_FAST :: u8(0x40) // ch1 clocked at the main clock (1.79MHz)
AUDCTL_POLY9    :: u8(0x80) // 9-bit poly instead of 17-bit

// AUDC bits
AUDC_VOLUME        :: u8(0x0f) // Volume bitmask
AUDC_VOL_ONLY      :: u8(0x10) // force output high, DAC tracks volume (4-bit digis)
AUDC_SQUARE        :: u8(0x20) // Square vs. noise
AUDC_NOISE_POLY4   :: u8(0x40) // For noise mode: if 0, uses 9/17. If 1, uses 4-bit
AUDC_NO_POLY5_DIST :: u8(0x80) // If 0, uses the 5-bit poly to distort signal

// Period offset added to AUDF before the divide, per clocking mode
POKEY_OFFSET_BASE :: u8(1) // 64kHz / 15kHz base clock
POKEY_OFFSET_FAST :: u8(4) // main clock (1.79MHz)
POKEY_OFFSET_LINK :: u8(7) // 16-bit linked pair

PokeyReg :: enum u8 {
	AUDF1, AUDC1,
	AUDF2, AUDC2,
	AUDF3, AUDC3,
	AUDF4, AUDC4,
	AUDCTL,
}

Pokey :: struct {
	// --- Registers and configs
	machine: PokeyMachine,
	main_clock: f64,

	audf: [POKEY_CHANNELS]u8,
	audc: [POKEY_CHANNELS]u8,
	audctl: u8,

	// --- Live-changing data

	counter: [POKEY_CHANNELS]i32, // main-clock ticks until the next divider borrow
	out_flip: [POKEY_CHANNELS]bool, // square-wave flip-flop per channel
	hipass: [2]bool, // high-pass latch flip-flops (ch1, ch2)

	// free-running polynomial counter read positions
	poly4_pos: u32,
	poly5_pos: u32,
	poly9_17_pos: u32,

	clock_divider: i32, // chain deriving the 64kHz / 15kHz enables from the main clock
	tick_accum: f64, // fractional main-clock ticks carried between output samples
}

// Shared maximal-length poly sequences, read-only after generation
@(private) pokey_poly4: [15]u8
@(private) pokey_poly5: [31]u8
@(private) pokey_poly9: [511]u8
@(private) pokey_poly17: [131071]u8
@(private) pokey_polys_ready: bool

pokey_fill_poly4 :: proc(out: []u8) {
	p: u32
	for i in 0..<len(out) {
		p = (p >> 1) + (~((p << 2) ~ (p << 3)) & 8)
		out[i] = u8(p & 1)
	}
}

pokey_fill_poly5 :: proc(out: []u8) {
	p: u32
	for i in 0..<len(out) {
		p = (p >> 1) + (~((p << 2) ~ (p << 4)) & 16)
		out[i] = u8(p & 1)
	}
}
pokey_fill_poly9 :: proc(out: []u8) {
	p: u32
	for i in 0..<len(out) {
		p = (p >> 1) + (~((p << 8) ~ (p << 3)) & 0x100)
		out[i] = u8(p & 1)
	}
}
pokey_fill_poly17 :: proc(out: []u8) {
	p: u32
	for i in 0..<len(out) {
		p = (p >> 1) + (~((p << 16) ~ (p << 11)) & 0x10000)
		out[i] = u8((p >> 8) & 1)
	}
}

pokey_generate_polys :: proc() {
	if pokey_polys_ready do return
	pokey_fill_poly4(pokey_poly4[:])
	pokey_fill_poly5(pokey_poly5[:])
	pokey_fill_poly9(pokey_poly9[:])
	pokey_fill_poly17(pokey_poly17[:])
	pokey_polys_ready = true
}

pokey_init :: proc(p: ^Pokey, machine: PokeyMachine) {
	pokey_generate_polys()
	p^ = {}
	p.machine = machine
	p.main_clock = POKEY_CLOCK_PAL if machine == .PAL else POKEY_CLOCK_NTSC
	pokey_reset(p)
}

pokey_reset :: proc(p: ^Pokey) {
	machine := p.machine
	clock := p.main_clock
	p^ = {}
	p.machine = machine
	p.main_clock = clock
}

pokey_set_audctl :: proc(p: ^Pokey, value: u8) {
	p.audctl = value
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
	case .AUDCTL: pokey_set_audctl(p, value)
	}
}

pokey_update_output :: proc(p: ^Pokey, c: int) {
	#no_bounds_check {
		audc := p.audc[c]

		// Skip sampling if poly-5 distortion is enabled and the current poly-5 bit is 0
		if audc & AUDC_NO_POLY5_DIST == 0 && pokey_poly5[p.poly5_pos] == 0 do return

		// Pure tone toggles the flip-flop, vs noise modes sample-and-hold the poly bit
		if audc & AUDC_SQUARE != 0 {
			p.out_flip[c] = !p.out_flip[c]
		} else if audc & AUDC_NOISE_POLY4 != 0 {
			p.out_flip[c] = pokey_poly4[p.poly4_pos] != 0
		} else {
			noise := p.audctl & AUDCTL_POLY9 != 0 ? pokey_poly9[p.poly9_17_pos] : pokey_poly17[p.poly9_17_pos]
			p.out_flip[c] = noise != 0
		}
	}
}

// Advance one main-clock cycle
pokey_tick :: proc(p: ^Pokey) {
	#no_bounds_check {
		// Advance polynomial position next bit (2^n - 1 bits)
		p.poly4_pos = (p.poly4_pos + 1) % 15
		p.poly5_pos = (p.poly5_pos + 1) % 31
		p.poly9_17_pos = (p.poly9_17_pos + 1) % (p.audctl & AUDCTL_POLY9 != 0 ? 511 : 131071)

		slow_clock_tick := false
		p.clock_divider -= 1
		if p.clock_divider <= 0 {
			p.clock_divider = p.audctl & AUDCTL_CLOCK_15 != 0 ? POKEY_CYCLE_PERIOD_15K : POKEY_CYCLE_PERIOD_64K
			slow_clock_tick = true
		}

		// loop through channels
		for c in 0..<4 {
			join_lo := (c == 0 && p.audctl & AUDCTL_JOIN_12 != 0) || (c == 2 && p.audctl & AUDCTL_JOIN_34 != 0)
			join_hi := (c == 1 && p.audctl & AUDCTL_JOIN_12 != 0) || (c == 3 && p.audctl & AUDCTL_JOIN_34 != 0)
			if join_hi do continue // clocked by lo borrow
			use_fast_clock := (c == 0 && p.audctl & AUDCTL_CH1_FAST != 0) || (c == 2 && p.audctl & AUDCTL_CH3_FAST != 0)
			// If neither fast clock being used, nor a tick happened
			if !use_fast_clock && !slow_clock_tick do continue

			p.counter[c] -= 1
			if p.counter[c] > 0 do continue

			if join_lo {
				// link offset lands on the lo byte: AUDF16+7 cycles fast, AUDF16+1 slow ticks
				pokey_update_output(p, c)
				hi := c + 1
				p.counter[hi] -= 1
				if p.counter[hi] <= 0 {
					p.counter[hi] = i32(p.audf[hi]) + 1
					p.counter[c] = i32(p.audf[c]) + i32(use_fast_clock ? POKEY_OFFSET_LINK : POKEY_OFFSET_BASE)
					pokey_update_output(p, hi)
				} else {
					p.counter[c] = 256
				}
			} else {
				p.counter[c] = i32(p.audf[c]) + i32(use_fast_clock ? POKEY_OFFSET_FAST : POKEY_OFFSET_BASE)
				pokey_update_output(p, c)
			}
		}

		// TODO: Hi-pass
	}
}

// Current digital DAC code in roughly [0,1], before the analog stage. Sums the four
// channels. A channel in volume-only mode contributes its volume regardless of flip.
// TODO: nonlinear / saturating DAC sum
pokey_sample :: proc(p: ^Pokey) -> f32 {
	#no_bounds_check {
		sum: f32
		for c in 0 ..< POKEY_CHANNELS {
			vol := f32(p.audc[c] & AUDC_VOLUME) / 15
			on := p.out_flip[c] || (p.audc[c] & AUDC_VOL_ONLY) != 0
			if on do sum += vol
		}
		return sum / f32(POKEY_CHANNELS)
	}
}

// Tick the core at the main clock and box-sum decimate to the host sample_rate, mono
pokey_render :: proc(p: ^Pokey, out: []f32, sample_rate: f64) {
	#no_bounds_check {
		ticks_per_sample := p.main_clock / sample_rate
		for i in 0 ..< len(out) {
			p.tick_accum += ticks_per_sample
			sum: f32
			count: int
			for p.tick_accum >= 1 {
				pokey_tick(p)
				sum += pokey_sample(p)
				count += 1
				p.tick_accum -= 1
			}
			out[i] = count > 0 ? sum / f32(count) : pokey_sample(p)
		}
	}

}

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
	// POKEY's polys are XNOR LFSRs, so the all-ones state is excluded and each emits
	// 2^(n-1)-1 ones over its 2^n-1 period (the bit-complement of a plain m-sequence).
	testing.expect_value(t, poly_ones(pokey_poly4[:]), 7)
	testing.expect_value(t, poly_ones(pokey_poly5[:]), 15)
	testing.expect_value(t, poly_ones(pokey_poly9[:]), 255)
	testing.expect_value(t, poly_ones(pokey_poly17[:]), 65535)
}

// Ticks until out_flip[c] has toggled a few times, returns main-clock cycles between
// the last two toggles. -1 if the channel never settled into flipping.
@(private)
pokey_flip_period :: proc(p: ^Pokey, c: int, max_ticks: int) -> int {
	prev := p.out_flip[c]
	last := -1
	period := -1
	flips := 0
	for t in 0 ..< max_ticks {
		pokey_tick(p)
		if p.out_flip[c] != prev {
			prev = p.out_flip[c]
			if flips > 0 do period = t - last
			last = t
			flips += 1
			if flips >= 4 do break
		}
	}
	return period
}

// Expected periods from Altirra's RecomputeTimerPeriod: (AUDF+1)*28 slow, (AUDF+1)*114
// at 15kHz, AUDF+4 fast, AUDF16+7 linked fast, (AUDF16+1)*28 linked slow
@(test)
test_pokey_timer_periods :: proc(t: ^testing.T) {
	p: Pokey

	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC1, AUDC_SQUARE | AUDC_NO_POLY5_DIST)
	pokey_write(&p, .AUDF1, 10)
	testing.expect_value(t, pokey_flip_period(&p, 0, 4000), 11 * 28)

	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC1, AUDC_SQUARE | AUDC_NO_POLY5_DIST)
	pokey_write(&p, .AUDF1, 10)
	pokey_write(&p, .AUDCTL, AUDCTL_CLOCK_15)
	testing.expect_value(t, pokey_flip_period(&p, 0, 10000), 11 * 114)

	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC1, AUDC_SQUARE | AUDC_NO_POLY5_DIST)
	pokey_write(&p, .AUDF1, 10)
	pokey_write(&p, .AUDCTL, AUDCTL_CH1_FAST)
	testing.expect_value(t, pokey_flip_period(&p, 0, 200), 14)
}

// Dist C output must equal the poly4 bit sampled at each borrow (sample-and-hold),
// not a poly-gated toggle. The gated toggle sits ~an octave high with the wrong
// pulse rhythm
@(test)
test_pokey_distc_sample_and_hold :: proc(t: ^testing.T) {
	p: Pokey
	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC1, AUDC_NOISE_POLY4 | AUDC_NO_POLY5_DIST | 8)
	pokey_write(&p, .AUDF1, 0)
	pokey_write(&p, .AUDCTL, AUDCTL_CH1_FAST)
	ref: [15]u8
	pokey_fill_poly4(ref[:])
	for _ in 0 ..< 600 {
		pokey_tick(&p)
		if p.counter[0] == 4 { // just reloaded, output sampled this tick
			testing.expect_value(t, p.out_flip[0], ref[p.poly4_pos] != 0)
		}
	}
}

@(test)
test_pokey_linked_timer_periods :: proc(t: ^testing.T) {
	p: Pokey
	audf16 := 0x010E

	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC2, AUDC_SQUARE | AUDC_NO_POLY5_DIST)
	pokey_write(&p, .AUDF1, u8(audf16 & 0xff))
	pokey_write(&p, .AUDF2, u8(audf16 >> 8))
	pokey_write(&p, .AUDCTL, AUDCTL_JOIN_12 | AUDCTL_CH1_FAST)
	testing.expect_value(t, pokey_flip_period(&p, 1, 4000), audf16 + 7)

	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC2, AUDC_SQUARE | AUDC_NO_POLY5_DIST)
	pokey_write(&p, .AUDF1, u8(audf16 & 0xff))
	pokey_write(&p, .AUDF2, u8(audf16 >> 8))
	pokey_write(&p, .AUDCTL, AUDCTL_JOIN_12)
	testing.expect_value(t, pokey_flip_period(&p, 1, 60000), (audf16 + 1) * 28)

	// same chain on the 3/4 pair
	pokey_init(&p, .NTSC)
	pokey_write(&p, .AUDC4, AUDC_SQUARE | AUDC_NO_POLY5_DIST)
	pokey_write(&p, .AUDF3, u8(audf16 & 0xff))
	pokey_write(&p, .AUDF4, u8(audf16 >> 8))
	pokey_write(&p, .AUDCTL, AUDCTL_JOIN_34 | AUDCTL_CH3_FAST)
	testing.expect_value(t, pokey_flip_period(&p, 3, 4000), audf16 + 7)
}

@(test)
test_pokey_silence :: proc(t: ^testing.T) {
	p: Pokey
	pokey_init(&p, .NTSC)
	out: [256]f32
	pokey_render(&p, out[:], 48000)
	for v in out do testing.expect_value(t, v, f32(0))
}
