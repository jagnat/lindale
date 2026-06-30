package lindale

import "core:math"
import "core:testing"
import b "../bridge"
import "../dsp"

when b.ACTIVE_PLUGIN == "pokey" {

MAX_CHANNELS :: 2

// Independent POKEY chips, each 4 channels, mixed together for more simultaneous voices
POKEY_BANKS :: 4
POKEY_VOICES :: POKEY_BANKS * dsp.POKEY_CHANNELS

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
	chan: u8, // hw channel within the bank, lo channel of the pair for Bass16
	pair: bool,
	timbre: PokeyTimbre, // latched at note-on
}

PokeyProcessState :: struct {
	chip: [POKEY_BANKS]dsp.Pokey,
	voices: [POKEY_VOICES]PokeyVoice, // indexed by bank * POKEY_CHANNELS + owned (lo) hw channel
	samples_to_frame: f64,
}

PokeyControlState :: struct {
}

// Parameters

PARAM_TIMBRE :: ParamIndex(0)
PARAM_ATTACK :: ParamIndex(1)
PARAM_DECAY :: ParamIndex(2)
PARAM_SUSTAIN :: ParamIndex(3)
PARAM_RELEASE :: ParamIndex(4)
PARAM_ARP_RATE :: ParamIndex(5)
PARAM_ARP_STEP1 :: ParamIndex(6)
PARAM_ARP_STEP2 :: ParamIndex(7)
PARAM_VIB_DEPTH :: ParamIndex(8)
PARAM_VIB_SPEED :: ParamIndex(9)
PARAM_VIB_DELAY :: ParamIndex(10)
PARAM_DETUNE :: ParamIndex(11)
PARAM_MACHINE :: ParamIndex(12)

// Time-domain params are in frames (~60Hz NTSC ticks), the era's envelope resolution
@(rodata) pokey_param_table := [?]b.ParamDescriptor {
	{
		name = "Timbre", short_name = "timbre", min = 0, max = 4, default_value = 0,
		step_count = 4, unit = .None, flags = {.Automatable, .List}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Attack", short_name = "atk", min = 0, max = 30, default_value = 0,
		step_count = 30, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Decay", short_name = "dec", min = 0, max = 60, default_value = 12,
		step_count = 60, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Sustain", short_name = "sus", min = 0, max = 100, default_value = 60,
		step_count = 0, unit = .Percentage, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Release", short_name = "rel", min = 0, max = 120, default_value = 10,
		step_count = 120, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Arp Rate", short_name = "rate", min = 1, max = 8, default_value = 2,
		step_count = 7, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Arp Step 1", short_name = "arp1", min = 0, max = 12, default_value = 0,
		step_count = 12, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Arp Step 2", short_name = "arp2", min = 0, max = 12, default_value = 0,
		step_count = 12, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Vib Depth", short_name = "depth", min = 0, max = 100, default_value = 0,
		step_count = 0, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Vib Speed", short_name = "speed", min = 0.5, max = 12, default_value = 6,
		step_count = 0, unit = .Hertz, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Vib Delay", short_name = "delay", min = 0, max = 60, default_value = 20,
		step_count = 60, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Detune", short_name = "tune", min = -50, max = 50, default_value = 0,
		step_count = 0, unit = .None, flags = {.Automatable}, smooth_ms = NO_SMOOTHING
	},
	{
		name = "Machine", short_name = "mach", min = 0, max = 1, default_value = 1,
		step_count = 1, unit = .None, flags = {.List}, smooth_ms = NO_SMOOTHING
	},
}

pokey_get_plugin_descriptor :: proc() -> PluginDescriptor {
	return {
		name = "Pokey Player",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Instrument,
		params = pokey_param_table[:],
		max_channels = MAX_CHANNELS,
		view = {
			min_width = 640, min_height = 480,
			resizable = true,
		}
	}
}

timbre_from_param :: proc(val: f32) -> PokeyTimbre {
	return PokeyTimbre(clamp(int(val + 0.5), 0, len(PokeyTimbre) - 1))
}

@(private="file")
timbre_audc_waveform :: proc(t: PokeyTimbre) -> u8 {
	switch t {
	case .Pure, .Bass16: return dsp.AUDC_SQUARE | dsp.AUDC_NO_POLY5_DIST
	case .Gritty, .Buzzy, .Unstable: return dsp.AUDC_NOISE_POLY4 | dsp.AUDC_NO_POLY5_DIST
	}
	return 0
}

// Tuning: audf = round(clock / (fine * freq)) - cycle. Dist C divisors are measured
// perceived pitch (flat poly4 spectrum -> residue pitch at the sub-pattern rate);
// RMT's 7.5/2.5/1.5 are these halved, naming notes an octave above what you hear

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

// N = audf + 1. The MOD3/MOD5 split picks the poly4 sub-pattern the period collapses to
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

// Map desired note frequency to closest AUDF value that provides it
pokey_audf_for_freq :: proc(chip: ^dsp.Pokey, timbre: PokeyTimbre, freq: f32) -> u16 {
	if freq <= 0 do return 255
	if timbre == .Bass16 {
		target := chip.main_clock / (2 * f64(freq)) - f64(dsp.POKEY_OFFSET_LINK)
		return u16(clamp(target + 0.5, 0, 65535))
	}
	clock := chip.main_clock / dsp.POKEY_CYCLE_PERIOD_64K
	target := clock / (timbre_fine_divisor(timbre) * f64(freq))
	base := int(clamp(target + 0.5, 1, 256)) // N = audf + 1
	for d in 0 ..< 256 {
		if base - d >= 1 && timbre_class_valid(timbre, base - d) do return u16(base - d - 1)
		if base + d <= 256 && timbre_class_valid(timbre, base + d) do return u16(base + d - 1)
	}
	return u16(base - 1)
}

// Frame engine. Domain 3: rewrite registers once per video frame, like the era's
// VBI-driven players. One frame = scanlines * 114 main-clock cycles.

@(private="file")
pokey_frame_cycles :: proc(chip: ^dsp.Pokey) -> f64 {
	return f64((chip.machine == .PAL ? 312 : 262) * 114)
}

@(private="file")
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

@(private="file")
pokey_compute_audctl :: proc(state: ^PokeyProcessState, bank: u8) -> u8 {
	audctl: u8
	for &v in state.voices {
		if !v.active || !v.pair || v.bank != bank do continue
		audctl |= v.chan == 0 ? dsp.AUDCTL_JOIN_12 | dsp.AUDCTL_CH1_FAST : dsp.AUDCTL_JOIN_34 | dsp.AUDCTL_CH3_FAST
	}
	return audctl
}

@(private="file")
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
pokey_voice_write_regs :: proc(state: ^PokeyProcessState, actx: ^AudioProcessContext, v: ^PokeyVoice) {
	attack := smoothed_read(actx, PARAM_ATTACK)
	decay := smoothed_read(actx, PARAM_DECAY)
	sustain := smoothed_read(actx, PARAM_SUSTAIN) / 100
	release := smoothed_read(actx, PARAM_RELEASE)

	chip := &state.chip[v.bank]

	level := voice_env_level(v, attack, decay, sustain, release)
	if !v.gate && level <= 0 {
		dsp.pokey_write(chip, dsp.PokeyReg(v.chan * 2 + 1), 0)
		if v.pair do dsp.pokey_write(chip, dsp.PokeyReg((v.chan + 1) * 2 + 1), 0)
		v.active = false
		return
	}
	vol := u8(clamp(level * v.velocity * 15 + 0.5, 0, 15))

	pitch := v.pitch + smoothed_read(actx, PARAM_DETUNE) / 100

	arp1 := smoothed_read(actx, PARAM_ARP_STEP1)
	arp2 := smoothed_read(actx, PARAM_ARP_STEP2)
	if arp1 != 0 || arp2 != 0 {
		rate := i32(max(smoothed_read(actx, PARAM_ARP_RATE), 1))
		steps := arp2 != 0 ? i32(3) : i32(2)
		switch (v.frames / rate) % steps {
		case 1: pitch += arp1
		case 2: pitch += arp2
		}
	}

	vib_depth := smoothed_read(actx, PARAM_VIB_DEPTH)
	vib_delay := smoothed_read(actx, PARAM_VIB_DELAY)
	if vib_depth > 0 && f32(v.frames) > vib_delay {
		t := f32(v.frames) - vib_delay
		speed := smoothed_read(actx, PARAM_VIB_SPEED)
		pitch += vib_depth / 100 * math.sin(2 * math.PI * speed * t / pokey_frame_rate(chip))
	}

	audf := pokey_audf_for_freq(chip, v.timbre, dsp.midi_to_freq(pitch))
	audc := timbre_audc_waveform(v.timbre) | vol
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
pokey_frame_update :: proc(state: ^PokeyProcessState, actx: ^AudioProcessContext) {
	for bk in 0 ..< POKEY_BANKS {
		dsp.pokey_write(&state.chip[bk], .AUDCTL, pokey_compute_audctl(state, u8(bk)))
	}
	for &v in state.voices {
		if !v.active do continue
		pokey_voice_write_regs(state, actx, &v)
		v.frames += 1
		if !v.gate do v.release_frames += 1
	}
}

pokey_note_on :: proc(state: ^PokeyProcessState, actx: ^AudioProcessContext, n: b.NoteOn) {
	timbre := timbre_from_param(smoothed_read(actx, PARAM_TIMBRE))
	bank := -1
	chan := -1
	find: for bk in 0 ..< POKEY_BANKS {
		if timbre == .Bass16 {
			for base in ([2]u8{0, 2}) {
				if channel_in_use(state, u8(bk), base) || channel_in_use(state, u8(bk), base + 1) do continue
				bank = bk
				chan = int(base)
				break find
			}
		} else {
			for c in 0 ..< dsp.POKEY_CHANNELS {
				if channel_in_use(state, u8(bk), u8(c)) do continue
				bank = bk
				chan = c
				break find
			}
		}
	}
	if chan < 0 do return // out of channels, drop the note

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
		pair = timbre == .Bass16,
		timbre = timbre,
	}
	// write registers now instead of waiting out the frame, mid-frame DAW notes land on time
	dsp.pokey_write(&state.chip[bank], .AUDCTL, pokey_compute_audctl(state, u8(bank)))
	pokey_voice_write_regs(state, actx, v)
}

pokey_note_off :: proc(state: ^PokeyProcessState, actx: ^AudioProcessContext, n: b.NoteOff) {
	for &v in state.voices {
		if !v.active || (n.note_id >= 0 ? v.note_id != n.note_id : v.midi_pitch != n.pitch) do continue
		attack := smoothed_read(actx, PARAM_ATTACK)
		decay := smoothed_read(actx, PARAM_DECAY)
		sustain := smoothed_read(actx, PARAM_SUSTAIN) / 100
		release := smoothed_read(actx, PARAM_RELEASE)
		v.released_level = voice_env_level(&v, attack, decay, sustain, release)
		v.gate = false
		v.release_frames = 0
	}
}

pokey_process_audio :: proc(plug: ^PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.state == nil do return
	if actx.numChannels == 0 || actx.numSamples == 0 do return

	state := plug.state
	sample_rate := f64(actx.sampleRate)
	num_channels := min(actx.numChannels, MAX_CHANNELS)

	machine := smoothed_read(actx, PARAM_MACHINE) < 0.5 ? dsp.PokeyMachine.NTSC : dsp.PokeyMachine.PAL
	if machine != state.chip[0].machine {
		for &chip in state.chip do dsp.pokey_init(&chip, machine) // re-init kills voices, registers are zeroed
		for &v in state.voices do v.active = false
		state.samples_to_frame = 0
	}

	frame_len := sample_rate * pokey_frame_cycles(&state.chip[0]) / state.chip[0].main_clock

	it := make_block_iterator(actx.events, actx.numSamples)
	for block in next_block(&it) {
		advance_smoothers(actx, block.sample_offset)
		for &evt in block.events {
			#partial switch evt.kind {
			case .NoteOn: pokey_note_on(state, actx, evt.note_on)
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
			for c in 1 ..< num_channels {
				copy(actx.outputs[c][offset:][:n], out0)
			}
			state.samples_to_frame -= f64(n)
			offset += n
			remaining -= n
		}
	}
}

// UI

@(private="file")
pokey_machine_to_string :: proc(val: f64) -> string {
	return val < 0.5 ? "NTSC" : "PAL"
}

@(private="file")
pokey_timbre_to_string :: proc(val: f64) -> string {
	switch timbre_from_param(f32(val)) {
	case .Pure: return "Pure"
	case .Gritty: return "Gritty"
	case .Buzzy: return "Buzzy"
	case .Unstable: return "Unstable"
	case .Bass16: return "Bass 16"
	}
	return ""
}

pokey_draw :: proc(plug: ^PluginController) {
	draw_set_clear_color(plug.draw, plug.ui.theme.bgColor)
	draw_clear(plug.draw)

	ui := plug.ui
	if ui_frame_scoped(ui) {
		if ui_panel(ui, skipDraw = true, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 14, padding = 14) {
			if ui_panel(ui, skipDraw = true, dir = .HORIZONTAL, child_gaps = 14, padding = 0) {
				if ui_panel(ui, dir = .VERTICAL, child_gaps = 8, padding = 12) {
					ui_label(ui, "Timbre")
					ui_knob_param_labeled(ui, PARAM_TIMBRE, enum_to_string = pokey_timbre_to_string)
				}
				if ui_panel(ui, dir = .VERTICAL, child_gaps = 8, padding = 12) {
					ui_label(ui, "Envelope")
					if ui_panel(ui, skipDraw = true, dir = .HORIZONTAL, child_gaps = 10, padding = 0) {
						ui_knob_param_labeled(ui, PARAM_ATTACK)
						ui_knob_param_labeled(ui, PARAM_DECAY)
						ui_knob_param_labeled(ui, PARAM_SUSTAIN)
						ui_knob_param_labeled(ui, PARAM_RELEASE)
					}
				}
			}
			if ui_panel(ui, skipDraw = true, dir = .HORIZONTAL, child_gaps = 14, padding = 0) {
				if ui_panel(ui, dir = .VERTICAL, child_gaps = 8, padding = 12) {
					ui_label(ui, "Arpeggio")
					if ui_panel(ui, skipDraw = true, dir = .HORIZONTAL, child_gaps = 10, padding = 0) {
						ui_knob_param_labeled(ui, PARAM_ARP_RATE)
						ui_knob_param_labeled(ui, PARAM_ARP_STEP1)
						ui_knob_param_labeled(ui, PARAM_ARP_STEP2)
					}
				}
				if ui_panel(ui, dir = .VERTICAL, child_gaps = 8, padding = 12) {
					ui_label(ui, "Vibrato")
					if ui_panel(ui, skipDraw = true, dir = .HORIZONTAL, child_gaps = 10, padding = 0) {
						ui_knob_param_labeled(ui, PARAM_VIB_DEPTH)
						ui_knob_param_labeled(ui, PARAM_VIB_SPEED)
						ui_knob_param_labeled(ui, PARAM_VIB_DELAY)
					}
				}
				if ui_panel(ui, dir = .VERTICAL, child_gaps = 8, padding = 12) {
					ui_label(ui, "Tune")
					if ui_panel(ui, skipDraw = true, dir = .HORIZONTAL, child_gaps = 10, padding = 0) {
						ui_knob_param_labeled(ui, PARAM_DETUNE)
						ui_knob_param_labeled(ui, PARAM_MACHINE, enum_to_string = pokey_machine_to_string)
					}
				}
			}
		}
	}

	draw_submit(plug.draw)
}

pokey_setup_controller :: proc(plug: ^PluginController) {
}

pokey_setup_processor :: proc(plug: ^PluginProcessor) {
	for &chip in plug.state.chip do dsp.pokey_init(&chip, .NTSC)
	for &v in plug.state.voices do v.active = false
	plug.state.samples_to_frame = 0
}

pokey_reset :: proc(plug: ^PluginProcessor) {
	for &chip in plug.state.chip do dsp.pokey_reset(&chip)
	for &v in plug.state.voices do v.active = false
	plug.state.samples_to_frame = 0
}

pokey_api :: PluginApi {
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
	testing.expect_value(t, pokey_audf_for_freq(&chip, .Pure, 440), 72)

	// dist C classes land in the right MOD3/MOD5 class and never on MOD15
	for pitch in 24 ..= 72 {
		freq := dsp.midi_to_freq(f32(pitch))
		for timbre in ([3]PokeyTimbre{.Gritty, .Buzzy, .Unstable}) {
			n := int(pokey_audf_for_freq(&chip, timbre, freq)) + 1
			testing.expect(t, timbre_class_valid(timbre, n))
			testing.expect(t, n % 15 != 0)
		}
	}

	// Bass16 A1 55Hz: 1789772.5/110 - 7 = 16263.93 -> 16264
	testing.expect_value(t, pokey_audf_for_freq(&chip, .Bass16, 55), 16264)

	// X-Ray "Is Bored" intro bytes (PAL gritty): A1 -> AUDF 76, A2 -> AUDF 37
	pal: dsp.Pokey
	dsp.pokey_init(&pal, .PAL)
	testing.expect_value(t, pokey_audf_for_freq(&pal, .Gritty, dsp.midi_to_freq(33)), 76)
	testing.expect_value(t, pokey_audf_for_freq(&pal, .Gritty, dsp.midi_to_freq(45)), 37)
}

} // when block
