package pokey

import "core:math"
import "core:testing"
import "lindale:sdk"
import b "lindale:bridge"
import "lindale:dsp"
import "base:intrinsics"

@(export)
get_plugin_api :: proc() -> sdk.PluginApi {
	return sdk.FALLBACK_API
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(pokey_api)
}

MAX_CHANNELS :: 2

// Independent POKEY chips, each 4 channels, mixed together for more simultaneous voices
POKEY_BANKS :: 4
POKEY_VOICES :: POKEY_BANKS * dsp.POKEY_CHANNELS

// fits the scope span plus one period of trigger search for the lowest notes
RING_SIZE :: 16384
PERIOD_RING_SIZE :: 64
SCOPE_PERIODS :: 2
SCOPE_IDLE_SPAN :: 1024 // samples shown with no tracked voice
SCOPE_FULL_SCALE :: 0.125 // one full volume voice, swinging around zero after the dc block

// RMT's timbre classes
PokeyTimbre :: enum {
	Pure, 
	Gritty,
	Buzzy,
	Unstable,
	Bass16,
}

PokeyVoice :: struct {
	active: bool,
	note_id: i32, // -1 = host didn't assign one, match note-offs by pitch
	midi_pitch: i16,
	pitch: f32,
	velocity: f32,
	gate: bool,
	frames: i32, // frames since note-on
	release_frames: i32,
	released_level: f32, // envelope level when the gate dropped
	bank: u8, // which POKEY chip owns this voice
	chan: u8, // hw channel within the bank, lo channel of the pair when paired
	pair: bool,
	timbre: PokeyTimbre, // latched at note-on
	period: f64, // in samples, from the written AUDF
}

// Period of the scope voice from ring position pos onward, 0 = no voice
PeriodMark :: struct {
	pos: int,
	period: f64,
}

PokeyProcessState :: struct {
	chip: [POKEY_BANKS]dsp.Pokey,
	analog: dsp.PokeyAnalog,
	voices: [POKEY_VOICES]PokeyVoice, // indexed by bank * POKEY_CHANNELS + owned (lo) hw channel
	samples_to_frame: f64,
	write_ring: dsp.RingBuffer(f32),
	write_buf: [RING_SIZE]f32,
	period_ring: dsp.RingBuffer(PeriodMark),
	period_buf: [PERIOD_RING_SIZE]PeriodMark,
	scope_voice: int, // -1 = none
	scope_period: f64, // last published
}

PokeyControlState :: struct {
	sample_buf: [RING_SIZE]f32,
	sample_count: int,
	trig_pos: f64, // absolute ring position the view starts at
	trig_period: f64,
	view_start: f64, // offset into sample_buf
	view_len: f64,
}

// Parameters

Param :: enum {
	Timbre,
	Attack,
	Decay,
	Sustain,
	Release,
	ArpRate,
	ArpStep1,
	ArpStep2,
	VibDepth,
	VibSpeed,
	VibDelay,
	Detune,
	Machine,
}

// Time-domain params are in frames (~60Hz NTSC ticks), the era's envelope resolution
@(rodata) pokey_param_table := [Param]b.ParamDescriptor {
	.Timbre = {
		id = "timbre",
		name = "Timbre", short_name = "timbre", min = 0, max = 4, default_value = 0,
		step_count = 4, unit = .None, flags = {.Automatable, .List}, smooth_ms = sdk.NO_SMOOTHING
	},
	.Attack = {
		id = "attack",
		name = "Attack", short_name = "atk", min = 0, max = 30, default_value = 0,
		step_count = 30, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.Decay = {
		id = "decay",
		name = "Decay", short_name = "dec", min = 0, max = 60, default_value = 12,
		step_count = 60, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.Sustain = {
		id = "sustain",
		name = "Sustain", short_name = "sus", min = 0, max = 100, default_value = 60,
		step_count = 0, unit = .Percentage, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.Release = {
		id = "release",
		name = "Release", short_name = "rel", min = 0, max = 120, default_value = 10,
		step_count = 120, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.ArpRate = {
		id = "arp_rate",
		name = "Arp Rate", short_name = "rate", min = 1, max = 8, default_value = 2,
		step_count = 7, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.ArpStep1 = {
		id = "arp_step1",
		name = "Arp Step 1", short_name = "arp1", min = 0, max = 12, default_value = 0,
		step_count = 12, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.ArpStep2 = {
		id = "arp_step2",
		name = "Arp Step 2", short_name = "arp2", min = 0, max = 12, default_value = 0,
		step_count = 12, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.VibDepth = {
		id = "vib_depth",
		name = "Vib Depth", short_name = "depth", min = 0, max = 100, default_value = 0,
		step_count = 0, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.VibSpeed = {
		id = "vib_speed",
		name = "Vib Speed", short_name = "speed", min = 0.5, max = 12, default_value = 6,
		step_count = 0, unit = .Hertz, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.VibDelay = {
		id = "vib_delay",
		name = "Vib Delay", short_name = "delay", min = 0, max = 60, default_value = 20,
		step_count = 60, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.Detune = {
		id = "detune",
		name = "Detune", short_name = "tune", min = -50, max = 50, default_value = 0,
		step_count = 0, unit = .None, flags = {.Automatable}, smooth_ms = sdk.NO_SMOOTHING
	},
	.Machine = {
		id = "machine",
		name = "Machine", short_name = "mach", min = 0, max = 1, default_value = 1,
		step_count = 1, unit = .None, flags = {.List}, smooth_ms = sdk.NO_SMOOTHING
	},
}

pokey_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		.Instrument,
		sdk.param_table(&pokey_param_table),
		MAX_CHANNELS,
		sdk.ViewConfig {
			min_width = 890, min_height = 400,
			resizable = true,
			aspect_ratio = 890.0 / 400.0,
		}
	}
}

timbre_from_param :: proc(val: f32) -> PokeyTimbre {
	return PokeyTimbre(clamp(int(val + 0.5), 0, len(PokeyTimbre) - 1))
}

// Tuning: freq = clock / (fine * N). Dist C divisors are measured
// perceived pitch (flat poly4 spectrum -> residue pitch at the sub-pattern rate);
// RMT's 7.5/2.5/1.5 are these halved, naming notes an octave above what you hear

// 8-bit voices further off than this take a 16-bit pair instead
TUNE_TOLERANCE_CENTS :: 10

@(private="file")
timbre_fine_divisor :: proc(t: PokeyTimbre) -> f64 {
	switch t {
	case .Pure, .Bass16: return 2
	case .Gritty: return 15
	case .Buzzy: return 5
	case .Unstable: return 3
	}
	return 2
}

// N is the period in clock ticks. The MOD3/MOD5 split picks the poly4 sub-pattern the period collapses to
@(private="file")
timbre_class_valid :: proc(t: PokeyTimbre, n: int) -> bool {
	switch t {
	case .Pure, .Bass16: return true
	case .Gritty: return n % 3 != 0 && n % 5 != 0
	case .Buzzy: return n % 3 == 0 && n % 5 != 0
	case .Unstable: return n % 5 == 0 && n % 3 != 0
	}
	return true
}

// 8-bit runs off 64kHz with N = audf + 1, pairs off the main clock with N = audf16 + 7
@(private="file")
pokey_mode_clock :: proc(chip: ^dsp.Pokey, pair: bool) -> (clock: f64, offset: int, max_n: int) {
	if pair do return chip.main_clock, int(dsp.POKEY_OFFSET_LINK), 65535 + int(dsp.POKEY_OFFSET_LINK)
	return chip.main_clock / dsp.POKEY_CYCLE_PERIOD_64K, int(dsp.POKEY_OFFSET_BASE), 255 + int(dsp.POKEY_OFFSET_BASE)
}

// Map desired note frequency to the AUDF whose pitch is closest to it
pokey_audf_for_freq :: proc(chip: ^dsp.Pokey, timbre: PokeyTimbre, pair: bool, freq: f32) -> u16 {
	clock, offset, max_n := pokey_mode_clock(chip, pair)
	if freq <= 0 do return u16(max_n - offset)
	target := clock / (timbre_fine_divisor(timbre) * f64(freq))
	lo := clamp(int(target), offset, max_n)
	for lo > offset && !timbre_class_valid(timbre, lo) do lo -= 1
	hi := clamp(int(target) + 1, offset, max_n)
	for hi < max_n && !timbre_class_valid(timbre, hi) do hi += 1
	// pitch goes as 1/N, so hi is closer in cents when hi / target < target / lo
	n := lo
	if !timbre_class_valid(timbre, lo) || (timbre_class_valid(timbre, hi) && f64(hi) * f64(lo) < target * target) do n = hi
	return u16(n - offset)
}

pokey_tuning_error_cents :: proc(chip: ^dsp.Pokey, timbre: PokeyTimbre, pair: bool, freq: f32) -> f32 {
	clock, offset, _ := pokey_mode_clock(chip, pair)
	n := f64(pokey_audf_for_freq(chip, timbre, pair, freq)) + f64(offset)
	return f32(1200 * math.log2(clock / (timbre_fine_divisor(timbre) * n * f64(freq))))
}

// Pair up when any arp step of the note is out of tune in 8-bit, like a tracker
// musician switching to 16-bit for notes the 64kHz divider can't hit
@(private="file")
voice_wants_pair :: proc(chip: ^dsp.Pokey, actx: ^sdk.AudioProcessContext, timbre: PokeyTimbre, pitch: f32) -> bool {
	if timbre == .Bass16 do return true
	pitch := pitch + sdk.smoothed_read(actx, Param.Detune) / 100
	steps := [3]f32{0, sdk.smoothed_read(actx, Param.ArpStep1), sdk.smoothed_read(actx, Param.ArpStep2)}
	for s in steps {
		if abs(pokey_tuning_error_cents(chip, timbre, false, dsp.midi_to_freq(pitch + s))) > TUNE_TOLERANCE_CENTS do return true
	}
	return false
}

// Frame engine. Domain 3: rewrite registers once per video frame, like the era's
// VBI-driven players. One frame = scanlines * 114 main-clock cycles.

pokey_frame_cycles :: proc(chip: ^dsp.Pokey) -> f64 {
	return f64((chip.machine == .PAL ? 312 : 262) * 114)
}

pokey_frame_rate :: proc(chip: ^dsp.Pokey) -> f32 {
	return f32(chip.main_clock / pokey_frame_cycles(chip))
}

@(private="file")
channel_in_use :: proc(state: ^PokeyProcessState, bank, c: u8) -> bool {
	for &v in state.voices {
		if !v.active || v.bank != bank do continue
		if v.chan == c || (v.pair && v.chan + 1 == c) do return true
	}
	return false
}

pokey_compute_audctl :: proc(state: ^PokeyProcessState, bank: u8) -> u8 {
	audctl: u8
	for &v in state.voices {
		if !v.active || !v.pair || v.bank != bank do continue
		audctl |= v.chan == 0 ? dsp.AUDCTL_JOIN_12 | dsp.AUDCTL_CH1_FAST : dsp.AUDCTL_JOIN_34 | dsp.AUDCTL_CH3_FAST
	}
	return audctl
}

voice_env_level :: proc(v: ^PokeyVoice, attack, decay, sustain, release: f32) -> f32 {
	if !v.gate {
		if release <= 0 || f32(v.release_frames) >= release do return 0
		return v.released_level * (1 - f32(v.release_frames) / release)
	}
	f := f32(v.frames)
	if attack > 0 && f < attack do return f / attack
	f -= attack
	if decay > 0 && f < decay do return 1 - (1 - sustain) * (f / decay)
	return sustain
}

// Writes the voice's registers from the current frame counters and live params.
// Frees the voice once the release envelope hits zero.
@(private="file")
pokey_voice_write_regs :: proc(state: ^PokeyProcessState, actx: ^sdk.AudioProcessContext, v: ^PokeyVoice) {
	attack := sdk.smoothed_read(actx, Param.Attack)
	decay := sdk.smoothed_read(actx, Param.Decay)
	sustain := sdk.smoothed_read(actx, Param.Sustain) / 100
	release := sdk.smoothed_read(actx, Param.Release)

	chip := &state.chip[v.bank]

	level := voice_env_level(v, attack, decay, sustain, release)
	if !v.gate && level <= 0 {
		dsp.pokey_write(chip, dsp.PokeyReg(v.chan * 2 + 1), 0)
		if v.pair do dsp.pokey_write(chip, dsp.PokeyReg((v.chan + 1) * 2 + 1), 0)
		v.active = false
		return
	}
	vol := u8(clamp(level * v.velocity * 15 + 0.5, 0, 15))

	pitch := v.pitch + sdk.smoothed_read(actx, Param.Detune) / 100

	arp1 := sdk.smoothed_read(actx, Param.ArpStep1)
	arp2 := sdk.smoothed_read(actx, Param.ArpStep2)
	if arp1 != 0 || arp2 != 0 {
		rate := i32(max(sdk.smoothed_read(actx, Param.ArpRate), 1))
		steps := arp2 != 0 ? i32(3) : i32(2)
		switch (v.frames / rate) % steps {
		case 1: pitch += arp1
		case 2: pitch += arp2
		}
	}

	vib_depth := sdk.smoothed_read(actx, Param.VibDepth)
	vib_delay := sdk.smoothed_read(actx, Param.VibDelay)
	if vib_depth > 0 && f32(v.frames) > vib_delay {
		t := f32(v.frames) - vib_delay
		speed := sdk.smoothed_read(actx, Param.VibSpeed)
		pitch += vib_depth / 100 * math.sin(2 * math.PI * speed * t / pokey_frame_rate(chip))
	}

	audf := pokey_audf_for_freq(chip, v.timbre, v.pair, dsp.midi_to_freq(pitch))
	audc := timbre_audc_waveform(v.timbre) | vol
	// the fine divisor is also the true repeat: poly4 sampled every N underflows repeats after 15 / gcd(N, 15)
	cycles := timbre_fine_divisor(v.timbre) * (v.pair ? f64(audf) + f64(dsp.POKEY_OFFSET_LINK) : f64(audf + 1) * dsp.POKEY_CYCLE_PERIOD_64K)
	v.period = cycles * f64(actx.sample_rate) / chip.main_clock
	if v.pair {
		dsp.pokey_write(chip, dsp.PokeyReg(v.chan * 2), u8(audf & 0xff))
		dsp.pokey_write(chip, dsp.PokeyReg((v.chan + 1) * 2), u8(audf >> 8))
		dsp.pokey_write(chip, dsp.PokeyReg(v.chan * 2 + 1), 0) // lo channel muted
		dsp.pokey_write(chip, dsp.PokeyReg((v.chan + 1) * 2 + 1), audc)
	} else {
		dsp.pokey_write(chip, dsp.PokeyReg(v.chan * 2), u8(audf))
		dsp.pokey_write(chip, dsp.PokeyReg(v.chan * 2 + 1), audc)
	}
}

@(private="file")
pokey_frame_update :: proc(state: ^PokeyProcessState, actx: ^sdk.AudioProcessContext) {
	for bk in 0 ..< POKEY_BANKS {
		dsp.pokey_write(&state.chip[bk], .AUDCTL, pokey_compute_audctl(state, u8(bk)))
	}
	for &v in state.voices {
		if !v.active do continue
		pokey_voice_write_regs(state, actx, &v)
		v.frames += 1
		if !v.gate do v.release_frames += 1
	}
	pokey_publish_scope_period(state)
}

// Tags the scope voice's period with the ring position it starts applying at
@(private="file")
pokey_publish_scope_period :: proc(state: ^PokeyProcessState) {
	if state.scope_voice < 0 || !state.voices[state.scope_voice].active {
		// fall back to the most recently started voice still sounding
		state.scope_voice = -1
		for &v, i in state.voices {
			if !v.active do continue
			if state.scope_voice < 0 || v.frames < state.voices[state.scope_voice].frames do state.scope_voice = i
		}
	}
	period: f64
	if state.scope_voice >= 0 do period = state.voices[state.scope_voice].period
	if period == state.scope_period do return
	state.scope_period = period
	dsp.ring_write(&state.period_ring, PeriodMark{dsp.ring_get_write_pos(&state.write_ring), period})
}

@(private="file")
pokey_alloc_channel :: proc(state: ^PokeyProcessState, pair: bool) -> (bank, chan: int, ok: bool) {
	if pair {
		for bk in 0 ..< POKEY_BANKS {
			for base in ([2]u8{0, 2}) {
				if !channel_in_use(state, u8(bk), base) && !channel_in_use(state, u8(bk), base + 1) do return bk, int(base), true
			}
		}
		return
	}
	// prefer channels whose partner is taken, keeping whole pairs free for 16-bit voices
	for pass in 0 ..< 2 {
		for bk in 0 ..< POKEY_BANKS {
			for c in 0 ..< dsp.POKEY_CHANNELS {
				if channel_in_use(state, u8(bk), u8(c)) do continue
				if pass == 0 && !channel_in_use(state, u8(bk), u8(c ~ 1)) do continue
				return bk, c, true
			}
		}
	}
	return
}

pokey_note_on :: proc(state: ^PokeyProcessState, actx: ^sdk.AudioProcessContext, n: b.NoteOn) {
	timbre := timbre_from_param(sdk.smoothed_read(actx, Param.Timbre))
	pair := voice_wants_pair(&state.chip[0], actx, timbre, f32(n.pitch) + n.tuning)
	bank, chan, ok := pokey_alloc_channel(state, pair)
	if !ok && pair {
		// no pair free, an out of tune note beats a dropped one
		pair = false
		bank, chan, ok = pokey_alloc_channel(state, false)
	}
	if !ok do return // out of channels, drop the note

	v := &state.voices[bank * dsp.POKEY_CHANNELS + chan]
	v^ = {
		active = true,
		note_id = n.note_id,
		midi_pitch = n.pitch,
		pitch = f32(n.pitch) + n.tuning,
		velocity = n.velocity,
		gate = true,
		bank = u8(bank),
		chan = u8(chan),
		pair = pair,
		timbre = timbre,
	}
	// write registers now instead of waiting out the frame, mid-frame DAW notes land on time
	dsp.pokey_write(&state.chip[bank], .AUDCTL, pokey_compute_audctl(state, u8(bank)))
	pokey_voice_write_regs(state, actx, v)
	state.scope_voice = bank * dsp.POKEY_CHANNELS + chan
	pokey_publish_scope_period(state)
}

pokey_note_off :: proc(state: ^PokeyProcessState, actx: ^sdk.AudioProcessContext, n: b.NoteOff) {
	for &v in state.voices {
		if !v.active || (n.note_id >= 0 ? v.note_id != n.note_id : v.midi_pitch != n.pitch) do continue
		attack := sdk.smoothed_read(actx, Param.Attack)
		decay := sdk.smoothed_read(actx, Param.Decay)
		sustain := sdk.smoothed_read(actx, Param.Sustain) / 100
		release := sdk.smoothed_read(actx, Param.Release)
		v.released_level = voice_env_level(&v, attack, decay, sustain, release)
		v.gate = false
		v.release_frames = 0
	}
}

pokey_process_audio :: proc(plug: ^sdk.PluginProcessor) {
	actx := plug.audio_processor
	if actx == nil do return
	if plug.state == nil do return
	if actx.num_channels == 0 || actx.num_samples == 0 do return

	state := cast(^PokeyProcessState)plug.state
	sample_rate := f64(actx.sample_rate)
	num_channels := min(actx.num_channels, MAX_CHANNELS)

	machine := sdk.smoothed_read(actx, Param.Machine) < 0.5 ? dsp.PokeyMachine.NTSC : dsp.PokeyMachine.PAL
	if machine != state.chip[0].machine {
		for &chip in state.chip do dsp.pokey_init(&chip, machine) // re-init kills voices, registers are zeroed
		for &v in state.voices do v.active = false
		state.samples_to_frame = 0
	}

	frame_len := sample_rate * pokey_frame_cycles(&state.chip[0]) / state.chip[0].main_clock

	it := sdk.make_block_iterator(actx.events, actx.num_samples)
	for block in sdk.next_block(&it) {
		sdk.advance_smoothers(actx, block.sample_offset)
		for &evt in block.events {
			#partial switch evt.kind {
			case .NoteOn: {
				pokey_note_on(state, actx, evt.note_on)
			}
			case .NoteOff: pokey_note_off(state, actx, evt.note_off)
			}
		}

		offset := block.sample_offset
		remaining := block.sample_count
		for remaining > 0 {
			if state.samples_to_frame < 1 {
				pokey_frame_update(state, actx)
				state.samples_to_frame += frame_len
			}
			n := min(remaining, max(int(state.samples_to_frame), 1))
			out0 := actx.outputs[0][offset:][:n]
			dsp.pokey_render_mix(state.chip[:], out0, sample_rate)
			dsp.pokey_analog_process(&state.analog, out0, sample_rate)
			dsp.ring_write_buf(&state.write_ring, out0)
			for c in 1 ..< num_channels {
				copy(actx.outputs[c][offset:][:n], out0)
			}
			state.samples_to_frame -= f64(n)
			offset += n
			remaining -= n
		}
	}
}

@(private="file")
timbre_audc_waveform :: proc(t: PokeyTimbre) -> u8 {
	switch t {
	case .Pure, .Bass16: return dsp.AUDC_SQUARE | dsp.AUDC_NO_POLY5_DIST
	case .Gritty, .Buzzy, .Unstable: return dsp.AUDC_NOISE_POLY4 //| dsp.AUDC_NO_POLY5_DIST
	}
	return 0
}

// UI
pokey_draw :: proc(plug: ^sdk.PluginController) {
	sdk.draw_set_clear_color(plug.draw, plug.ui.theme.bg_color)
	sdk.draw_clear(plug.draw)
	pokey_update_scope(plug)

	ui := plug.ui
	my_theme := sdk.THEME_JQ
	// my_theme.slider_color = {191, 148, 228, 255} // lavender
	sdk.ui_set_theme(ui, my_theme)
	if sdk.ui_frame_scoped(ui) {
		if sdk.ui_panel(ui, {dir = .Vertical, w = sdk.ui_grow(), h = sdk.ui_grow(), padding = sdk.ui_pad(14), gap = 14}) {
			if sdk.ui_panel(ui, {w = sdk.ui_grow(), gap = 14}) {
				if sdk.ui_box(ui, {dir = .Vertical, h = sdk.ui_grow(), padding = sdk.ui_pad(12), gap = 8, align_y = .Center}) {
					sdk.ui_knob_param_labeled(ui, Param.Timbre, enum_to_string = sdk.enum_label(PokeyTimbre))
				}
				if sdk.ui_box(ui, {dir = .Vertical, padding = sdk.ui_pad(12), gap = 8, align_x = .Center}) {
					sdk.ui_label(ui, "Envelope")
					if sdk.ui_panel(ui, {gap = 10}) {
						sdk.ui_knob_param_labeled(ui, Param.Attack)
						sdk.ui_knob_param_labeled(ui, Param.Decay)
						sdk.ui_knob_param_labeled(ui, Param.Sustain)
						sdk.ui_knob_param_labeled(ui, Param.Release)
					}
				}
				sdk.ui_canvas(ui, pokey_draw_waveform_canvas, plug.state)
			}
			// grow spacers split the leftover width evenly, half gaps keep the 14 minimum
			if sdk.ui_panel(ui, {w = sdk.ui_grow(), gap = 7}) {
				if sdk.ui_box(ui, {dir = .Vertical, padding = sdk.ui_pad(12), gap = 8, align_x = .Center}) {
					sdk.ui_label(ui, "Arpeggio")
					if sdk.ui_panel(ui, {gap = 10}) {
						sdk.ui_knob_param_labeled(ui, Param.ArpRate)
						sdk.ui_knob_param_labeled(ui, Param.ArpStep1)
						sdk.ui_knob_param_labeled(ui, Param.ArpStep2)
					}
				}
				sdk.ui_spacer(ui)
				if sdk.ui_box(ui, {dir = .Vertical, padding = sdk.ui_pad(12), gap = 8, align_x = .Center}) {
					sdk.ui_label(ui, "Vibrato")
					if sdk.ui_panel(ui, {gap = 10}) {
						sdk.ui_knob_param_labeled(ui, Param.VibDepth)
						sdk.ui_knob_param_labeled(ui, Param.VibSpeed)
						sdk.ui_knob_param_labeled(ui, Param.VibDelay)
					}
				}
				sdk.ui_spacer(ui)
				if sdk.ui_box(ui, {dir = .Vertical, padding = sdk.ui_pad(12), gap = 8, align_x = .Center}) {
					sdk.ui_label(ui, "Tune")
					if sdk.ui_panel(ui, {gap = 10}) {
						sdk.ui_knob_param_labeled(ui, Param.Detune)
						sdk.ui_knob_param_labeled(ui, Param.Machine, enum_to_string = sdk.enum_label(dsp.PokeyMachine))
					}
				}
			}
		}
	}

	sdk.draw_submit(plug.draw)
}

pokey_draw_waveform_canvas :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
	state := cast(^PokeyControlState)data
	r := comp.calc_bounds
	sdk.draw_rect(ctx.plugin.draw, r, {border = {80, 80, 80, 255}, border_width = 1.2}, 10)
	if state.view_len <= 0 || state.sample_count < 2 do return

	PAD :: 10
	cols := max(int(r.w - 2 * PAD), 2)
	pts := make([]sdk.Vec2f, cols, allocator = ctx.plugin.host.frame_allocator)
	vals := make([]f32, cols, allocator = ctx.plugin.host.frame_allocator)
	peak: f32 = SCOPE_FULL_SCALE
	for i in 0 ..< cols {
		p := state.view_start + state.view_len * f64(i) / f64(cols - 1)
		j := clamp(int(p), 0, state.sample_count - 2)
		frac := f32(clamp(p - f64(j), 0, 1))
		vals[i] = state.sample_buf[j] * (1 - frac) + state.sample_buf[j + 1] * frac
		peak = max(peak, abs(vals[i]))
	}
	for i in 0 ..< cols {
		pts[i] = {
			r.x + PAD + (r.w - 2 * PAD) * f32(i) / f32(cols - 1),
			r.y + r.h / 2 - (r.h / 2 - PAD) * vals[i] / peak,
		}
	}
	sdk.draw_polyline(ctx.plugin.draw, pts, 1.5, {fill = ctx.theme.slider_color})
}

// Snapshots the latest samples and picks a view window phase-locked to the scope voice's period
pokey_update_scope :: proc(plug: ^sdk.PluginController) {
	state := cast(^PokeyControlState)plug.state
	state.view_len = 0
	if plug.processor_peer == nil || plug.processor_peer.state == nil do return
	ps := cast(^PokeyProcessState)plug.processor_peer.state

	end := dsp.ring_get_write_pos(&ps.write_ring)

	// marks at or past end apply to samples not written yet
	marks: [PERIOD_RING_SIZE]PeriodMark
	period: f64
	for i := dsp.ring_read_latest(&ps.period_ring, marks[:]) - 1; i >= 0; i -= 1 {
		if marks[i].pos < end {
			period = marks[i].period
			break
		}
	}

	// keep one period behind the view for the trigger search, 1 sample after it for interpolation
	span := min(period * SCOPE_PERIODS, f64(RING_SIZE) - period - 4)
	if period <= 1 || span < period {
		state.trig_period = 0
		state.sample_count = dsp.ring_read_window(&ps.write_ring, end, state.sample_buf[:SCOPE_IDLE_SPAN])
		state.view_start = 0
		state.view_len = f64(state.sample_count - 1)
		return
	}
	need := int(span + period) + 4
	n := dsp.ring_read_window(&ps.write_ring, end, state.sample_buf[:need])
	state.sample_count = n
	if n < need do return
	buf_start := f64(end - n)
	latest := f64(end) - span - 1

	if period == state.trig_period {
		// same period, step by whole periods so the phase holds still
		state.trig_pos += math.floor((latest - state.trig_pos) / period) * period
	} else {
		// new period, retrigger on the latest rising mid-level crossing within one period
		state.trig_period = period
		state.trig_pos = latest
		lo, hi := max(f32), min(f32)
		for s in state.sample_buf[:n] {
			lo = min(lo, s)
			hi = max(hi, s)
		}
		mid := (lo + hi) / 2
		first := max(int(latest - period - buf_start), 1)
		for i := int(latest - buf_start); i >= first; i -= 1 {
			s0, s1 := state.sample_buf[i - 1], state.sample_buf[i]
			if s0 < mid && s1 >= mid {
				state.trig_pos = buf_start + f64(i - 1) + f64((mid - s0) / (s1 - s0))
				break
			}
		}
	}
	state.view_start = state.trig_pos - buf_start
	state.view_len = span
}

pokey_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	state := new(PokeyProcessState, allocator = plug.host.session_allocator)
	for &chip in state.chip do dsp.pokey_init(&chip, .NTSC)
	for &v in state.voices do v.active = false
	state.samples_to_frame = 0
	dsp.ring_init(&state.write_ring, state.write_buf[:])
	dsp.ring_init(&state.period_ring, state.period_buf[:])
	state.scope_voice = -1
	return state
}

pokey_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr {
	return new(PokeyControlState, allocator = plug.host.session_allocator)
}

pokey_reset :: proc(plug: ^sdk.PluginProcessor) {
	state := cast(^PokeyProcessState)plug.state
	for &chip in state.chip do dsp.pokey_reset(&chip)
	state.analog = {}
	for &v in state.voices do v.active = false
	state.samples_to_frame = 0
	state.scope_voice = -1
}

pokey_api :: sdk.PluginApi {
	get_plugin_descriptor = pokey_get_plugin_descriptor,
	process_audio         = pokey_process_audio,
	draw                  = pokey_draw,

	setup_controller      = pokey_setup_controller,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = pokey_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = nil,
	reset                 = pokey_reset,
}

@(test)
test_pokey_tuning :: proc(t: ^testing.T) {
	chip: dsp.Pokey
	dsp.pokey_init(&chip, .NTSC)

	// pure A4: N = (1789772.5/28) / (2*440) = 72.6 -> audf 72
	testing.expect_value(t, pokey_audf_for_freq(&chip, .Pure, false, 440), 72)

	// dist C classes land in the right MOD3/MOD5 class and never on MOD15
	for pitch in 24 ..= 72 {
		freq := dsp.midi_to_freq(f32(pitch))
		for timbre in ([3]PokeyTimbre{.Gritty, .Buzzy, .Unstable}) {
			for pair in ([2]bool{false, true}) {
				n := int(pokey_audf_for_freq(&chip, timbre, pair, freq)) + int(pair ? dsp.POKEY_OFFSET_LINK : dsp.POKEY_OFFSET_BASE)
				testing.expect(t, timbre_class_valid(timbre, n))
				testing.expect(t, n % 15 != 0)
			}
		}
	}

	// Bass16 A1 55Hz: 1789772.5/110 - 7 = 16263.93 -> 16264
	testing.expect_value(t, pokey_audf_for_freq(&chip, .Bass16, true, 55), 16264)

	// PAL gritty: A1 -> AUDF 76, A2 -> AUDF 37
	pal: dsp.Pokey
	dsp.pokey_init(&pal, .PAL)
	testing.expect_value(t, pokey_audf_for_freq(&pal, .Gritty, false, dsp.midi_to_freq(33)), 76)
	testing.expect_value(t, pokey_audf_for_freq(&pal, .Gritty, false, dsp.midi_to_freq(45)), 37)
}

// whichever mode a note picks stays in tune: pure everywhere, dist C until the
// main clock runs out of resolution around C6
@(test)
test_pokey_tuning_auto_mode :: proc(t: ^testing.T) {
	chip: dsp.Pokey
	dsp.pokey_init(&chip, .NTSC)
	for timbre in PokeyTimbre {
		top := timbre == .Pure || timbre == .Bass16 ? 108 : 76
		for pitch in 24 ..= top {
			freq := dsp.midi_to_freq(f32(pitch))
			err := pokey_tuning_error_cents(&chip, timbre, false, freq)
			if timbre == .Bass16 || abs(err) > TUNE_TOLERANCE_CENTS do err = pokey_tuning_error_cents(&chip, timbre, true, freq)
			testing.expectf(t, abs(err) <= TUNE_TOLERANCE_CENTS, "%v pitch %d off by %.1f cents", timbre, pitch, err)
		}
	}
}
