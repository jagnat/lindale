package lindale

import "core:log"
import "core:mem"
import "core:time"
import b "../bridge"
import dsp "../dsp"

// Voice

MAX_VOICES :: 16
PITCH_BEND_RANGE :: f32(2.0) // semitones

Voice :: struct {
	active: bool,
	note_id: i32,
	pitch: i16,
	velocity: f32,
	osc1: dsp.Oscillator,
	osc2: dsp.Oscillator,
	env: dsp.ADSR,
}

// State

PluginState :: struct {
	voices: [MAX_VOICES]Voice,
	pitch_bend: f32, // -1 to +1
}

// Parameters

PARAM_OSC1_WAVE :: ParamIndex(0)
PARAM_OSC2_WAVE :: ParamIndex(1)
PARAM_OSC2_DET  :: ParamIndex(2)
PARAM_ATTACK    :: ParamIndex(3)
PARAM_DECAY     :: ParamIndex(4)
PARAM_SUSTAIN   :: ParamIndex(5)
PARAM_RELEASE   :: ParamIndex(6)
PARAM_GAIN      :: ParamIndex(7)

@(rodata) param_table := [?]b.ParamDescriptor {
	{
		name = "Osc1 Wave", short_name = "Osc1",
		min = 0, max = 2, default_value = 0,
		step_count = 2, unit = .None,
		flags = {.Automatable, .List},
		smooth_ms = NO_SMOOTHING,
	},
	{
		name = "Osc2 Wave", short_name = "Osc2",
		min = 0, max = 2, default_value = 1,
		step_count = 2, unit = .None,
		flags = {.Automatable, .List},
		smooth_ms = NO_SMOOTHING,
	},
	{
		name = "Osc2 Detune", short_name = "Det",
		min = -100, max = 100, default_value = 7,
		step_count = 0, unit = .None,
		flags = {.Automatable},
	},
	{
		name = "Attack", short_name = "Atk",
		min = 1, max = 5000, default_value = 10,
		step_count = 0, unit = .Milliseconds,
		flags = {.Automatable},
	},
	{
		name = "Decay", short_name = "Dec",
		min = 1, max = 5000, default_value = 100,
		step_count = 0, unit = .Milliseconds,
		flags = {.Automatable},
	},
	{
		name = "Sustain", short_name = "Sus",
		min = 0, max = 100, default_value = 70,
		step_count = 0, unit = .Percentage,
		flags = {.Automatable},
	},
	{
		name = "Release", short_name = "Rel",
		min = 1, max = 10000, default_value = 200,
		step_count = 0, unit = .Milliseconds,
		flags = {.Automatable},
	},
	{
		name = "Gain", short_name = "Gain",
		min = -60, max = 12, default_value = -6,
		step_count = 0, unit = .Decibel,
		flags = {.Automatable},
	},
}

// Descriptor

get_plugin_descriptor :: proc() -> PluginDescriptor {
	return {
		name = "Lindale Synth",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Instrument,
		params = param_table[:],
		max_channels = 2,
		latency = 0,
		tail = 0,
	}
}

// Lifecycle

plugin_init_state :: proc(state: ^PluginState, sample_rate: f32, alloc: mem.Allocator) {
	for &v in state.voices {
		dsp.osc_init(&v.osc1, sample_rate)
		dsp.osc_init(&v.osc2, sample_rate)
		dsp.adsr_init(&v.env, sample_rate)
	}
}

plugin_reset_state :: proc(state: ^PluginState) {
	state.pitch_bend = 0
	for &v in state.voices {
		v.active = false
		dsp.osc_reset(&v.osc1)
		dsp.osc_reset(&v.osc2)
		dsp.adsr_reset(&v.env)
	}
}

waveform_from_param :: proc(val: f32) -> dsp.Waveform {
	idx := clamp(int(val + 0.5), 0, 2)
	switch idx {
	case 0: return .Sine
	case 1: return .Saw
	case 2: return .Square
	}
	return .Sine
}

// Audio

plugin_process_audio :: proc(plug: ^Plugin) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.state == nil do return
	if actx.numChannels == 0 || actx.numSamples == 0 do return

	state := plug.state
	num_samples := actx.numSamples
	num_channels := actx.numChannels

	it := make_block_iterator(actx.events, num_samples)
	for block in next_block(&it) {
		for &evt in block.events {
			switch evt.kind {
			case .NoteOn:
				note_on(state, evt.note_on)
			case .NoteOff:
				note_off(state, evt.note_off)
			case .PitchBend:
				state.pitch_bend = evt.pitch_bend.value
			case .CC:
			}
		}

		for s in 0 ..< block.sample_count {
			abs_sample := block.sample_offset + s
			advance_smoothers(actx, abs_sample)

			osc1_wave := waveform_from_param(smoothed_read(actx, PARAM_OSC1_WAVE))
			osc2_wave := waveform_from_param(smoothed_read(actx, PARAM_OSC2_WAVE))
			osc2_detune_cents := smoothed_read(actx, PARAM_OSC2_DET)
			attack := smoothed_read(actx, PARAM_ATTACK) / 1000.0
			decay := smoothed_read(actx, PARAM_DECAY) / 1000.0
			sustain := smoothed_read(actx, PARAM_SUSTAIN) / 100.0
			release := smoothed_read(actx, PARAM_RELEASE) / 1000.0
			gain := dsp.db_to_linear(smoothed_read(actx, PARAM_GAIN))

			bend_semitones := state.pitch_bend * PITCH_BEND_RANGE
			for &v in state.voices {
				if !v.active do continue
				dsp.adsr_set_params(&v.env, attack, decay, sustain, release)
				base_freq := dsp.midi_to_freq(f32(v.pitch) + bend_semitones)
				detune_freq := dsp.midi_to_freq(f32(v.pitch) + bend_semitones + osc2_detune_cents / 100.0)
				dsp.osc_set_freq(&v.osc1, base_freq)
				dsp.osc_set_freq(&v.osc2, detune_freq)
			}

			sample: f32 = 0
			for &v in state.voices {
				if !v.active do continue

				env_val := dsp.adsr_next(&v.env)
				if dsp.adsr_is_idle(&v.env) {
					v.active = false
					continue
				}

				o1 := dsp.osc_next(&v.osc1, osc1_wave)
				o2 := dsp.osc_next(&v.osc2, osc2_wave)
				sample += (o1 + o2) * 0.5 * env_val * v.velocity
			}

			sample *= gain

			for c in 0 ..< num_channels {
				actx.outputs[c][abs_sample] = sample
			}
		}
	}
}

note_on :: proc(state: ^PluginState, evt: b.NoteOn) {
	// Find a free voice, or steal the oldest idle one
	slot: ^Voice = nil
	for &v in state.voices {
		if !v.active {
			slot = &v
			break
		}
	}
	// If no free voice, steal the quietest releasing voice
	if slot == nil {
		lowest_level := f32(999)
		for &v in state.voices {
			if v.env.stage == .Release && v.env.level < lowest_level {
				lowest_level = v.env.level
				slot = &v
			}
		}
	}
	// Last resort: steal first voice
	if slot == nil {
		slot = &state.voices[0]
	}

	slot.active = true
	slot.note_id = evt.note_id
	slot.pitch = evt.pitch
	slot.velocity = evt.velocity
	dsp.osc_reset(&slot.osc1)
	dsp.osc_reset(&slot.osc2)
	dsp.adsr_gate_on(&slot.env)
}

note_off :: proc(state: ^PluginState, evt: b.NoteOff) {
	for &v in state.voices {
		if v.active && (evt.note_id >= 0 ? v.note_id == evt.note_id : v.pitch == evt.pitch) {
			dsp.adsr_gate_off(&v.env)
		}
	}
}

// UI

plugin_draw :: proc(plug: ^Plugin) {
	if plug.draw == nil || plug.ui == nil do return

	if plug.inDraw {
		log.warn("Re-entrant draw detected!")
		return
	}
	plug.inDraw = true
	defer plug.inDraw = false

	plug.lastDrawTime = time.tick_now()

	draw_clear(plug.draw)
	draw_set_clear_color(plug.draw, {0.08, 0.08, 0.1, 1.0})

	if ui_frame_scoped(plug.ui) {
		if ui_panel(plug.ui, dir = .HORIZONTAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10) {
			ui_slider_param_labeled(plug.ui, "Osc1", PARAM_OSC1_WAVE)
			ui_slider_param_labeled(plug.ui, "Osc2", PARAM_OSC2_WAVE)
			ui_slider_param_labeled(plug.ui, "Detune", PARAM_OSC2_DET)
			ui_slider_param_labeled(plug.ui, "Attack", PARAM_ATTACK)
			ui_slider_param_labeled(plug.ui, "Decay", PARAM_DECAY)
			ui_slider_param_labeled(plug.ui, "Sustain", PARAM_SUSTAIN)
			ui_slider_param_labeled(plug.ui, "Release", PARAM_RELEASE)
			ui_slider_param_labeled(plug.ui, "Gain", PARAM_GAIN)
		}
	}

	plug.draw.frame += 1

	draw_submit(plug.draw)
}
