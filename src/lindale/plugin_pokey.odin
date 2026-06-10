package lindale

import b "../bridge"
import "../dsp"

when b.ACTIVE_PLUGIN == "pokey" {

MAX_CHANNELS :: 2
POKEY_PURE_TONE :: dsp.AUDC_SQUARE | dsp.AUDC_NO_POLY5_DIST // Pure square
POKEY_BUZZY :: dsp.AUDC_NOISE_POLY4 | dsp.AUDC_NO_POLY5_DIST // Buzzy distorted
// POKEY_

PokeyMode :: enum {
	Pure,
	Buzzy,
}

PokeyProcessState :: struct {
	chip: dsp.Pokey,
	note_channel: [dsp.POKEY_CHANNELS]i32, // note_id owning each hw channel, -1 = free
}

PokeyControlState :: struct {
}

@(rodata) pokey_param_table := [?]b.ParamDescriptor {
	{
		name = "Pokey Mode", short_name = "mode", min = 0, max = 1, default_value = 0,
		step_count = 1, unit = .None, flags = {.Automatable, .List}, smooth_ms = NO_SMOOTHING
	},
}

PARAM_MODE :: ParamIndex(0)

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

// Crude AUDF from frequency using the 64kHz base clock.
// TODO: choose the clock base from the pitch range and apply the matching period
// offset; this placeholder ignores both, so tuning will drift until pokey_tick lands.
pokey_audf_for_freq :: proc(freq: f32) -> u8 {
	if freq <= 0 do return 255
	div := 64000.0 / (2 * freq) - 1
	return u8(clamp(div, 0, 255))
}

// TODO: Broken I think
pokey_audf_for_freq_buzzy :: proc(freq: f32) -> u8 {
	if freq <= 0 do return 255
	target := 64000.0 / (15 * f64(freq)) - 1
	base := int(clamp(target + 0.5, 0, 255))
	for d in 0 ..= 255 {
		lo := base - d
		hi := base + d
		if lo >= 0 && (lo + 1) % 3 != 0 && (lo + 1) % 5 != 0 do return u8(lo)
		if hi <= 255 && (hi + 1) % 3 != 0 && (hi + 1) % 5 != 0 do return u8(hi)
	}
	return u8(base)
}

pokey_note_on :: proc(state: ^PokeyProcessState, n: b.NoteOn, pokey_mode: u8) {
	for c in 0 ..< dsp.POKEY_CHANNELS {
		if state.note_channel[c] >= 0 do continue
		state.note_channel[c] = n.note_id
		freq := dsp.midi_to_freq(f32(n.pitch))
		audf := pokey_mode == POKEY_BUZZY ? pokey_audf_for_freq_buzzy(freq) : pokey_audf_for_freq(freq)
		vol := u8(clamp(n.velocity * 15, 0, 15))
		dsp.pokey_write(&state.chip, dsp.PokeyReg(u8(c) * 2), audf)
		dsp.pokey_write(&state.chip, dsp.PokeyReg(u8(c) * 2 + 1), pokey_mode | vol)
		return
	}
}

pokey_note_off :: proc(state: ^PokeyProcessState, n: b.NoteOff) {
	for c in 0 ..< dsp.POKEY_CHANNELS {
		if state.note_channel[c] != n.note_id do continue
		state.note_channel[c] = -1
		dsp.pokey_write(&state.chip, dsp.PokeyReg(u8(c) * 2 + 1), 0)
		return
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

	it := make_block_iterator(actx.events, actx.numSamples)
	for block in next_block(&it) {
		advance_smoothers(actx, block.sample_offset)
		mode := mode_from_param(smoothed_read(actx, PARAM_MODE))
		for &evt in block.events {
			#partial switch evt.kind {
			case .NoteOn: pokey_note_on(state, evt.note_on, mode == .Pure? POKEY_PURE_TONE : POKEY_BUZZY)
			case .NoteOff: pokey_note_off(state, evt.note_off)
			}
		}

		out0 := actx.outputs[0][block.sample_offset:][:block.sample_count]
		dsp.pokey_render(&state.chip, out0, sample_rate)
		for c in 1 ..< num_channels {
			copy(actx.outputs[c][block.sample_offset:][:block.sample_count], out0)
		}
	}
}

mode_from_param :: proc(val: f32) -> PokeyMode {
	idx := clamp(int(val + 0.5), 0, 1)
	switch idx {
	case 0: return .Pure
	case 1: return .Buzzy
	}
	return .Pure
}

pokey_draw :: proc(plug: ^PluginController) {
	draw_set_clear_color(plug.draw, plug.ui.theme.bgColor)
	draw_clear(plug.draw)

	pokey_mode_enum_to_string :: proc(val: f64) -> string {
		mode := mode_from_param(f32(val))
		switch mode {
			case .Pure: return "Pure"
			case .Buzzy: return "Buzzy"
		}
		return ""
	}

	if ui_frame_scoped(plug.ui) {
		if ui_panel(plug.ui, skipDraw = true, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 40, padding = 10) {
			ui_knob_param_labeled(plug.ui, PARAM_MODE, enum_to_string = pokey_mode_enum_to_string)
		}
	}

	draw_submit(plug.draw)
}

pokey_setup_controller :: proc(plug: ^PluginController) {
}

pokey_setup_processor :: proc(plug: ^PluginProcessor) {
	dsp.pokey_init(&plug.state.chip, .NTSC)
	for c in 0 ..< dsp.POKEY_CHANNELS do plug.state.note_channel[c] = -1
}

pokey_reset :: proc(plug: ^PluginProcessor) {
	dsp.pokey_reset(&plug.state.chip)
	for c in 0 ..< dsp.POKEY_CHANNELS do plug.state.note_channel[c] = -1
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

} // when block
