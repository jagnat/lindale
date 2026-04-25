package lindale

import "core:log"
import "core:mem"
import "core:time"
import "core:math"
import "core:c"
import stbi "vendor:stb/image"
import b "../bridge"
import dsp "../dsp"

@(private="file") test_tex_loaded: bool
@(private="file") test_tex_handle: TextureHandle
@(private="file") test_love_png := #load("../../resources/love.png")

// Voice
MAX_VOICES :: 16
MAX_ARP_NOTES :: 16
PITCH_BEND_RANGE :: f32(2.0) // semitones

Voice :: struct {
	active: bool,
	is_arp: bool,
	note_id: i32,
	pitch: i16,
	velocity: f32,
	osc1: dsp.Oscillator,
	osc2: dsp.Oscillator,
	env: dsp.ADSR,
}

ArpNote :: struct {
	pitch: i16,
	velocity: f32,
	note_id: i32,
}

// State

// Processor thread
PluginProcessState :: struct {
	voices: [MAX_VOICES]Voice,
	pitch_bend: f32, // -1 to +1

	// Arp state
	arp_notes: [MAX_ARP_NOTES]ArpNote,
	arp_note_count: int,
	arp_step: int,
	arp_synth_note_id: i32, // synthetic counter for arp-triggered voice note_ids
	arp_samples_since: int, // samples elapsed since last arp trigger
	arp_active: bool, // is the arp currently triggering notes
}

// Controller thread
PluginControlState :: struct {
	test: bool,
}

// Parameters

PARAM_OSC1_WAVE :: ParamIndex(0)
PARAM_OSC2_WAVE :: ParamIndex(1)
PARAM_OSC_MIX   :: ParamIndex(2)
PARAM_OSC2_DET  :: ParamIndex(3)
PARAM_ATTACK    :: ParamIndex(4)
PARAM_DECAY     :: ParamIndex(5)
PARAM_SUSTAIN   :: ParamIndex(6)
PARAM_RELEASE   :: ParamIndex(7)
PARAM_GAIN      :: ParamIndex(8)
PARAM_ARP_ON    :: ParamIndex(9)
PARAM_ARP_RATE  :: ParamIndex(10)

@(rodata) param_table := [?]b.ParamDescriptor {
	{
		name = "Osc1 Wave", short_name = "Osc1",
		min = 0, max = 4, default_value = 0,
		step_count = 4, unit = .None,
		flags = {.Automatable, .List},
		smooth_ms = NO_SMOOTHING,
	},
	{
		name = "Osc2 Wave", short_name = "Osc2",
		min = 0, max = 4, default_value = 1,
		step_count = 4, unit = .None,
		flags = {.Automatable, .List},
		smooth_ms = NO_SMOOTHING,
	},
	{
		name = "Osc Mix", short_name = "Mix",
		min = -1, max = 1, default_value = 0,
		unit = .None,
		flags = {.Automatable},
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
	{
		name = "Arp On", short_name = "Arp",
		min = 0, max = 1, default_value = 0,
		step_count = 1, unit = .None,
		flags = {.Automatable, .List},
		smooth_ms = NO_SMOOTHING,
	},
	{
		name = "Arp Rate", short_name = "Rate",
		min = 0, max = 3, default_value = 1,
		step_count = 3, unit = .None,
		flags = {.Automatable, .List},
		smooth_ms = NO_SMOOTHING,
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

plugin_init_state :: proc(state: ^PluginProcessState, sample_rate: f32, alloc: mem.Allocator) {
	for &v in state.voices {
		dsp.osc_init(&v.osc1, sample_rate)
		dsp.osc_init(&v.osc2, sample_rate)
		dsp.adsr_init(&v.env, sample_rate)
	}
	state.arp_synth_note_id = -1000
}

plugin_reset_state :: proc(state: ^PluginProcessState) {
	state.pitch_bend = 0
	for &v in state.voices {
		v.active = false
		dsp.osc_reset(&v.osc1)
		dsp.osc_reset(&v.osc2)
		dsp.adsr_reset(&v.env)
	}
	state.arp_note_count = 0
	state.arp_step = 0
	state.arp_synth_note_id = -1000
	state.arp_samples_since = 0
	state.arp_active = false
}

waveform_from_param :: proc(val: f32) -> dsp.Waveform {
	idx := clamp(int(val + 0.5), 0, 4)
	switch idx {
	case 0: return .Sine
	case 1: return .Saw
	case 2: return .Triangle
	case 3: return .Square
	case 4: return .Noise
	}
	return .Sine
}

// Arp helpers

arp_insert_note :: proc(state: ^PluginProcessState, pitch: i16, velocity: f32, note_id: i32) {
	if state.arp_note_count >= MAX_ARP_NOTES do return
	// Insert in pitch-ascending order
	insert_at := state.arp_note_count
	for i in 0 ..< state.arp_note_count {
		if state.arp_notes[i].pitch > pitch {
			insert_at = i
			break
		}
	}
	for i := state.arp_note_count; i > insert_at; i -= 1 {
		state.arp_notes[i] = state.arp_notes[i - 1]
	}
	state.arp_notes[insert_at] = {pitch = pitch, velocity = velocity, note_id = note_id}
	state.arp_note_count += 1
	// Adjust step index if insertion was before or at current step
	if insert_at <= state.arp_step && state.arp_note_count > 1 {
		state.arp_step += 1
	}
}

arp_remove_note :: proc(state: ^PluginProcessState, note_id: i32, pitch: i16) {
	for i in 0 ..< state.arp_note_count {
		n := state.arp_notes[i]
		if (note_id >= 0 && n.note_id == note_id) || (note_id < 0 && n.pitch == pitch) {
			for j := i; j < state.arp_note_count - 1; j += 1 {
				state.arp_notes[j] = state.arp_notes[j + 1]
			}
			state.arp_note_count -= 1
			if state.arp_note_count == 0 {
				state.arp_step = 0
			} else if i < state.arp_step {
				state.arp_step -= 1
			} else if state.arp_step >= state.arp_note_count {
				state.arp_step = 0
			}
			return
		}
	}
}

// Returns arp step duration in samples for the given rate param and tempo
// 0 -> 1/4, 1 -> 1/8, 2 -> 1/8T, 3 -> 1/8Q
arp_step_samples :: proc(rate_param: f32, tempo: f64, sample_rate: f64) -> int {
	quarter_notes: f64
	switch int(rate_param + 0.5) {
	case 0: quarter_notes = 1.0
	case 1: quarter_notes = 0.5
	case 2: quarter_notes = 1.0 / 3.0
	case 3: quarter_notes = 1.0 / 5.0
	case:    quarter_notes = 0.5
	}
	bpm := tempo if tempo > 0 else 120.0
	return max(1, int(quarter_notes * 60.0 / bpm * sample_rate))
}

arp_gate_off_all :: proc(state: ^PluginProcessState) {
	for &v in state.voices {
		if v.active && v.is_arp {
			dsp.adsr_gate_off(&v.env)
		}
	}
}

// Audio

plugin_process_audio :: proc(plug: ^PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.state == nil do return
	if actx.numChannels == 0 || actx.numSamples == 0 do return

	state := plug.state
	num_samples := actx.numSamples
	num_channels := actx.numChannels
	transport := &actx.transport
	sample_rate := actx.sampleRate

	tempo := transport.tempo if (.Tempo in transport.valid && transport.tempo > 0) else 120.0

	it := make_block_iterator(actx.events, num_samples)
	for block in next_block(&it) {
		arp_on := smoothed_read(actx, PARAM_ARP_ON) > 0.5

		for &evt in block.events {
			switch evt.kind {
			case .NoteOn:
				if arp_on {
					arp_insert_note(state, evt.note_on.pitch, evt.note_on.velocity, evt.note_on.note_id)
				} else {
					note_on(state, evt.note_on)
				}
			case .NoteOff:
				if arp_on {
					arp_remove_note(state, evt.note_off.note_id, evt.note_off.pitch)
					if state.arp_note_count == 0 {
						arp_gate_off_all(state)
						state.arp_active = false
					}
				} else {
					note_off(state, evt.note_off)
				}
			case .PitchBend:
				state.pitch_bend = evt.pitch_bend.value
			case .CC:
			}
		}

		for s in 0 ..< block.sample_count {
			abs_sample := block.sample_offset + s
			advance_smoothers(actx, abs_sample)

			arp_on = smoothed_read(actx, PARAM_ARP_ON) > 0.5
			arp_rate := smoothed_read(actx, PARAM_ARP_RATE)

			if arp_on && state.arp_note_count > 0 {
				step_dur := arp_step_samples(arp_rate, tempo, sample_rate)

				if !state.arp_active || state.arp_samples_since >= step_dur {
					arp_gate_off_all(state)
					n := state.arp_notes[state.arp_step % state.arp_note_count]
					state.arp_synth_note_id -= 1
					note_on(state, {note_id = state.arp_synth_note_id, pitch = n.pitch, velocity = n.velocity}, is_arp = true)
					state.arp_step = (state.arp_step + 1) % state.arp_note_count
					state.arp_samples_since = 0
					state.arp_active = true
				}
				state.arp_samples_since += 1
			} else if !arp_on && state.arp_active {
				arp_gate_off_all(state)
				state.arp_active = false
				state.arp_note_count = 0
				state.arp_step = 0
			}

			osc1_wave := waveform_from_param(smoothed_read(actx, PARAM_OSC1_WAVE))
			osc2_wave := waveform_from_param(smoothed_read(actx, PARAM_OSC2_WAVE))
			osc2_detune_cents := smoothed_read(actx, PARAM_OSC2_DET)
			attack := smoothed_read(actx, PARAM_ATTACK) / 1000.0
			decay := smoothed_read(actx, PARAM_DECAY) / 1000.0
			sustain := smoothed_read(actx, PARAM_SUSTAIN) / 100.0
			release := smoothed_read(actx, PARAM_RELEASE) / 1000.0
			osc_mix := (smoothed_read(actx, PARAM_OSC_MIX) + 1.0) / 2.0
			gain := dsp.db_to_linear(smoothed_read(actx, PARAM_GAIN))

			bend_semitones := state.pitch_bend * PITCH_BEND_RANGE
			for &v in state.voices {
				if !v.active do continue
				dsp.adsr_set_params(&v.env, attack, decay, sustain, release)
				base_freq := dsp.midi_to_freq(f32(v.pitch) + bend_semitones)
				detune_freq := dsp.midi_to_freq(f32(v.pitch) + bend_semitones + osc2_detune_cents / 100.0)
				dsp.osc_set_freq(&v.osc1, base_freq)
				dsp.osc_set_freq(&v.osc2, detune_freq)
				v.osc1.wave = osc1_wave
				v.osc2.wave = osc2_wave
			}

			sample: f32 = 0
			for &v in state.voices {
				if !v.active do continue

				env_val := dsp.adsr_next(&v.env)
				if dsp.adsr_is_idle(&v.env) {
					v.active = false
					continue
				} 

				o1 := dsp.osc_next(&v.osc1)
				o2 := dsp.osc_next(&v.osc2)
				sample += (o1 * math.cos(osc_mix * math.PI/2) + o2 * math.sin(osc_mix * math.PI/2)) * env_val * v.velocity
			}

			sample *= gain

			for c in 0 ..< num_channels {
				actx.outputs[c][abs_sample] = sample
			}
		}
	}
}

note_on :: proc(state: ^PluginProcessState, evt: b.NoteOn, is_arp: bool = false) {
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
	slot.is_arp = is_arp
	slot.note_id = evt.note_id
	slot.pitch = evt.pitch
	slot.velocity = evt.velocity
	dsp.osc_reset(&slot.osc1)
	dsp.osc_reset(&slot.osc2)
	dsp.adsr_gate_on(&slot.env)
}

note_off :: proc(state: ^PluginProcessState, evt: b.NoteOff) {
	for &v in state.voices {
		if v.active && (evt.note_id >= 0 ? v.note_id == evt.note_id : v.pitch == evt.pitch) {
			dsp.adsr_gate_off(&v.env)
		}
	}
}

// UI

plugin_draw :: proc(plug: ^PluginController) {
	if plug.draw == nil || plug.ui == nil do return

	if plug.inDraw {
		log.warn("Re-entrant draw detected!")
		return
	}
	plug.inDraw = true
	defer plug.inDraw = false

	plug.lastDrawTime = time.tick_now()

	draw_set_clear_color(plug.draw, ColorF32_from_ColorU8(plug.ui.theme.bgColor))
	draw_clear(plug.draw)

	osc_enum_to_string :: proc(val: f64) -> string {
		waveform := waveform_from_param(f32(val))
		switch waveform {
			case .Sine: return "Sine"
			case .Saw: return "Saw"
			case .Square: return "Square"
			case .Triangle: return "Triangle"
			case .Noise: return "Noise"
		}
		return ""
	}
	
	arp_rate_to_string :: proc(val: f64) -> string {
		switch int(val + 0.5) {
		case 0: return "1/4"
		case 1: return "1/8"
		case 2: return "1/8T"
		case 3: return "1/8Q"
		}
		return "1/8"
	}

	if ui_frame_scoped(plug.ui) {
		if ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10, padding = 10) {
			// Horizontal sliders for envelope
			if ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .FIT}, child_gaps = 6, padding = 0, skipDraw = true) {
				ui_slider_h_param_labeled(plug.ui, "Attack", PARAM_ATTACK)
				ui_slider_h_param_labeled(plug.ui, "Decay", PARAM_DECAY)
				ui_slider_h_param_labeled(plug.ui, "Sustain", PARAM_SUSTAIN)
				ui_slider_h_param_labeled(plug.ui, "Release", PARAM_RELEASE)
				ui_slider_h_param_labeled(plug.ui, "Gain", PARAM_GAIN)
			}
			// Vertical sliders for oscillator params
			if ui_panel(plug.ui, dir = .HORIZONTAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10, padding = 0, skipDraw = true) {
				ui_slider_param_labeled2(plug.ui, "Osc1", PARAM_OSC1_WAVE, enum_to_string = osc_enum_to_string)
				ui_slider_param_labeled2(plug.ui, "Osc2", PARAM_OSC2_WAVE, enum_to_string = osc_enum_to_string)
				ui_slider_param_labeled2(plug.ui, "Mix", PARAM_OSC_MIX)
				ui_slider_param_labeled2(plug.ui, "Detune", PARAM_OSC2_DET)
			}
			// Arp controls
			if ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .FIT}, child_gaps = 6, padding = 0, skipDraw = true) {
				ui_toggle_param_labeled(plug.ui, "Arp", PARAM_ARP_ON)
				ui_slider_h_param_labeled(plug.ui, "Rate", PARAM_ARP_RATE, enum_to_string = arp_rate_to_string)
			}
		}
	}

	// {
	// 	r := plug.host.renderer
	// 	p := plug.host.platform
	// 	dctx := plug.draw

	// 	if !test_tex_loaded {
	// 		w, h, ch: c.int
	// 		pixels := stbi.load_from_memory(raw_data(test_love_png), c.int(len(test_love_png)), &w, &h, &ch, 4)
	// 		if pixels != nil {
	// 			test_tex_handle = p.create_texture(r, u32(w), u32(h), .RGBA8)
	// 			p.upload_texture(r, test_tex_handle, pixels[:int(w)*int(h)*4])
	// 			stbi.image_free(pixels)
	// 			test_tex_loaded = true
	// 			log.infof("loaded love.png: %dx%d", w, h)
	// 		} else {
	// 			log.error("failed to decode love.png")
	// 		}
	// 	}

	// 	draw_filled_rect(dctx, 0, 0, 800, 600, {30, 30, 40, 255})
	// 	draw_filled_rect(dctx, 20, 20, 360, 260, {50, 50, 70, 255})
	// 	draw_filled_rect(dctx, 300, 200, 300, 260, {70, 50, 50, 255})

	// 	if test_tex_loaded {
	// 		scissorA := RectI32{20, 20, 360, 260}
	// 		draw_set_scissor(dctx, scissorA)
	// 		draw_set_texture(dctx, test_tex_handle, false)
	// 		img := RectInstance{
	// 			pos0 = {40, 40},
	// 			pos1 = {500, 440},
	// 			uv0 = {0, 0},
	// 			uv1 = {1, 1},
	// 			color = {255, 255, 255, 255},
	// 			noTexture = 0,
	// 		}
	// 		draw_push_instance(dctx, img)
	// 		draw_text(dctx, "love clipped by scissor A", 30, 30, {255, 255, 255, 255})

	// 		scissorB := RectI32{300, 200, 300, 260}
	// 		draw_set_scissor(dctx, scissorB)
	// 		draw_set_texture(dctx, test_tex_handle, false)
	// 		img2 := RectInstance{
	// 			pos0 = {260, 180},
	// 			pos1 = {700, 520},
	// 			uv0 = {0, 0},
	// 			uv1 = {1, 1},
	// 			color = {255, 255, 255, 255},
	// 			noTexture = 0,
	// 		}
	// 		draw_push_instance(dctx, img2)
	// 		draw_text(dctx, "scissor B text", 320, 220, {255, 255, 255, 255})

	// 		draw_remove_scissor(dctx)
	// 		draw_text(dctx, "unclipped control text", 20, 560, {200, 255, 200, 255})
	// 	}
	// }

	// Test: pill and arc primitives
	{
		dctx := plug.draw
		// Diagonal pill, no border
		// draw_push_pill(dctx, {50, 540}, {200, 570}, 8, {100, 200, 255, 220})
		// Thick pill with border
		// draw_push_pill(dctx, {50, 520}, {200, 520}, 16, {60, 60, 80, 255}, 2, {180, 180, 255, 255})

		draw_push_arc(dctx, {680, 540}, 28, 0, math.PI * 2, 3, {0xcc, 0xc5, 0xb9, 0xff})
		// end_ang :: 
		draw_push_arc(dctx, {680, 540}, 28, math.PI / 2 + 0.5, math.PI * 2 + math.PI / 2 - 0.5, 8, {0x8d, 0xb3, 0x67, 0xff})
	}

	draw_submit(plug.draw)
}
