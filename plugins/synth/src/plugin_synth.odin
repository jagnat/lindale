package synth

import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:time"
import "core:math"
import "core:math/linalg"
import dit "../../../src/thirdparty/uFFT_DIT"
import "core:c"
import "../../../src/sdk"
import b "../../../src/bridge"
import dsp "../../../src/dsp"

@(export)
get_plugin_api :: proc() -> sdk.PluginApi {
	return sdk.FALLBACK_API
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(synth_api)
}

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

ANALYSIS_BUFFER_SIZE :: 2048

// Processor thread
SynthProcessState :: struct {
	voices: [MAX_VOICES]Voice,
	pitch_bend: f32, // -1 to +1

	// Arp state
	arp_notes: [MAX_ARP_NOTES]ArpNote,
	arp_note_count: int,
	arp_step: int,
	arp_synth_note_id: i32, // synthetic counter for arp-triggered voice note_ids
	arp_samples_since: int, // samples elapsed since last arp trigger
	arp_active: bool, // is the arp currently triggering notes

	// SPSC Queue for FFT
	backing_buf: [ANALYSIS_BUFFER_SIZE]dsp.Sample,
	buffer: dsp.RingBuffer,
}

// Controller thread
SynthControlState :: struct {
	test: bool,
	hit: bool,
	fft_window: [ANALYSIS_BUFFER_SIZE]dsp.Sample,
	fft_window_gain: f32
}

// Parameters

PARAM_OSC1_WAVE :: sdk.ParamIndex(0)
PARAM_OSC2_WAVE :: sdk.ParamIndex(1)
PARAM_OSC_MIX   :: sdk.ParamIndex(2)
PARAM_OSC2_DET  :: sdk.ParamIndex(3)
PARAM_ATTACK    :: sdk.ParamIndex(4)
PARAM_DECAY     :: sdk.ParamIndex(5)
PARAM_SUSTAIN   :: sdk.ParamIndex(6)
PARAM_RELEASE   :: sdk.ParamIndex(7)
PARAM_GAIN      :: sdk.ParamIndex(8)
PARAM_ARP_ON    :: sdk.ParamIndex(9)
PARAM_ARP_RATE  :: sdk.ParamIndex(10)

@(rodata) synth_param_table := [?]b.ParamDescriptor {
	{
		name = "Osc1 Wave", short_name = "Osc1", min = 0, max = 4, default_value = 0,
		step_count = 4, unit = .None, flags = {.Automatable, .List}, smooth_ms = sdk.NO_SMOOTHING,
	},
	{
		name = "Osc2 Wave", short_name = "Osc2", min = 0, max = 4, default_value = 1,
		step_count = 4, unit = .None, flags = {.Automatable, .List}, smooth_ms = sdk.NO_SMOOTHING,
	},
	{
		name = "Osc Mix", short_name = "Mix", min = -1, max = 1, default_value = 0,
		unit = .None, flags = {.Automatable},
	},
	{
		name = "Osc2 Detune", short_name = "Det", min = -100, max = 100, default_value = 7,
		step_count = 0, unit = .None, flags = {.Automatable},
	},
	{
		name = "Attack", short_name = "Atk", min = 1, max = 5000, default_value = 10,
		step_count = 0, unit = .Milliseconds, flags = {.Automatable},
	},
	{
		name = "Decay", short_name = "Dec", min = 1, max = 5000, default_value = 100,
		step_count = 0, unit = .Milliseconds, flags = {.Automatable},
	},
	{
		name = "Sustain", short_name = "Sus", min = 0, max = 100, default_value = 70,
		step_count = 0, unit = .Percentage, flags = {.Automatable},
	},
	{
		name = "Release", short_name = "Rel", min = 1, max = 10000, default_value = 200,
		step_count = 0, unit = .Milliseconds, flags = {.Automatable},
	},
	{
		name = "Gain", short_name = "Gain", min = -60, max = 12, default_value = -6,
		step_count = 0, unit = .Decibel, flags = {.Automatable},
	},
	{
		name = "Arp On", short_name = "Arp", min = 0, max = 1, default_value = 0,
		step_count = 1, unit = .None, flags = {.Automatable, .List}, smooth_ms = sdk.NO_SMOOTHING,
	},
	{
		name = "Arp Rate", short_name = "Rate", min = 0, max = 3, default_value = 1,
		step_count = 3, unit = .None, flags = {.Automatable, .List}, smooth_ms = sdk.NO_SMOOTHING,
	},
}

// Descriptor

synth_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		name = "Lindale Synth",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Instrument,
		params = synth_param_table[:],
		max_channels = 2,
	}
}

// Lifecycle

synth_init_state :: proc(state: ^SynthProcessState, sample_rate: f32, alloc: mem.Allocator) {
	for &v in state.voices {
		dsp.osc_init(&v.osc1, sample_rate)
		dsp.osc_init(&v.osc2, sample_rate)
		dsp.adsr_init(&v.env, sample_rate)
	}
	state.arp_synth_note_id = -1000
	dsp.ring_init(&state.buffer, state.backing_buf[:])
}

synth_reset_state :: proc(state: ^SynthProcessState) {
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

arp_insert_note :: proc(state: ^SynthProcessState, pitch: i16, velocity: f32, note_id: i32) {
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

arp_remove_note :: proc(state: ^SynthProcessState, note_id: i32, pitch: i16) {
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

arp_gate_off_all :: proc(state: ^SynthProcessState) {
	for &v in state.voices {
		if v.active && v.is_arp {
			dsp.adsr_gate_off(&v.env)
		}
	}
}

// Audio

synth_process_audio :: proc(plug: ^sdk.PluginProcessor) {
	actx := plug.audio_processor
	if actx == nil do return
	if plug.state == nil do return
	if actx.num_channels == 0 || actx.num_samples == 0 do return

	state := cast(^SynthProcessState)plug.state
	num_samples := actx.num_samples
	num_channels := actx.num_channels
	transport := &actx.transport
	sample_rate := actx.sample_rate

	tempo := transport.tempo if (.Tempo in transport.valid && transport.tempo > 0) else 120.0

	it := sdk.make_block_iterator(actx.events, num_samples)
	for block in sdk.next_block(&it) {
		arp_on := sdk.smoothed_read(actx, PARAM_ARP_ON) > 0.5

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
			sdk.advance_smoothers(actx, abs_sample)

			arp_on = sdk.smoothed_read(actx, PARAM_ARP_ON) > 0.5
			arp_rate := sdk.smoothed_read(actx, PARAM_ARP_RATE)

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

			osc1_wave := waveform_from_param(sdk.smoothed_read(actx, PARAM_OSC1_WAVE))
			osc2_wave := waveform_from_param(sdk.smoothed_read(actx, PARAM_OSC2_WAVE))
			osc2_detune_cents := sdk.smoothed_read(actx, PARAM_OSC2_DET)
			attack := sdk.smoothed_read(actx, PARAM_ATTACK) / 1000.0
			decay := sdk.smoothed_read(actx, PARAM_DECAY) / 1000.0
			sustain := sdk.smoothed_read(actx, PARAM_SUSTAIN) / 100.0
			release := sdk.smoothed_read(actx, PARAM_RELEASE) / 1000.0
			osc_mix := (sdk.smoothed_read(actx, PARAM_OSC_MIX) + 1.0) / 2.0
			gain := dsp.db_to_linear(sdk.smoothed_read(actx, PARAM_GAIN))

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
			dsp.ring_write(&state.buffer, sample)
		}
	}


}

note_on :: proc(state: ^SynthProcessState, evt: b.NoteOn, is_arp: bool = false) {
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

note_off :: proc(state: ^SynthProcessState, evt: b.NoteOff) {
	for &v in state.voices {
		if v.active && (evt.note_id >= 0 ? v.note_id == evt.note_id : v.pitch == evt.pitch) {
			dsp.adsr_gate_off(&v.env)
		}
	}
}

synth_get_latency_samples :: proc(plug: ^sdk.PluginProcessor) -> u32 {
	return 0
}

synth_get_tail_samples :: proc(plug: ^sdk.PluginProcessor) -> u32 {
	return 0
}

// UI

synth_draw :: proc(plug: ^sdk.PluginController) {
	if plug.draw == nil || plug.ui == nil do return

	if plug.in_draw {
		log.warn("Re-entrant draw detected!")
		return
	}
	plug.in_draw = true
	defer plug.in_draw = false

	plug.last_draw_time = time.tick_now()

	// Read FFT buffer (TODO kinda hacky, not at all atomic)
	dbs: [ANALYSIS_BUFFER_SIZE / 2]f32
	if plug.processor_peer != nil {
		pstate := cast(^SynthProcessState)plug.processor_peer.state
		cstate := cast(^SynthControlState)plug.state
		vec: [ANALYSIS_BUFFER_SIZE]complex64
		tmp_buf : [ANALYSIS_BUFFER_SIZE]f32 = pstate.backing_buf
		write_idx := intrinsics.atomic_load_explicit(&pstate.buffer.write_pos, .Relaxed)
		write_idx %= ANALYSIS_BUFFER_SIZE
		// Re-linearize
		tmp_buf2 : [ANALYSIS_BUFFER_SIZE]f32
		first_len := ANALYSIS_BUFFER_SIZE - write_idx
		copy(tmp_buf2[:first_len], tmp_buf[write_idx:])
		copy(tmp_buf2[first_len:], tmp_buf[:write_idx])
		tmp_buf2 = tmp_buf2 * cstate.fft_window
		for val, i in tmp_buf2 do vec[i] = complex64(val)
		dit.fft(&vec[0], ANALYSIS_BUFFER_SIZE)

		for i in 0 ..< ANALYSIS_BUFFER_SIZE / 2 {
			val := vec[i]
			mag := math.sqrt(real(val) * real(val) + imag(val) * imag(val))
			dbs[i] = math.log2(mag + 1) / math.log2(f32(ANALYSIS_BUFFER_SIZE / 2 + 1))
		}
	}

	sdk.draw_set_clear_color(plug.draw, sdk.color_f32_from_color_u8(plug.ui.theme.bg_color))
	sdk.draw_clear(plug.draw)

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

	FftData :: struct {
		vals: []f32,
		sample_rate: f32
	}
	fft_data := FftData {
		vals = dbs[:],
	}
	if plug.processor_peer != nil && plug.processor_peer.audio_processor != nil {
		fft_data.sample_rate = f32(plug.processor_peer.audio_processor.sample_rate)
	}

	scope_draw :: proc(ctx: ^sdk.UIContext, comp: ^sdk.Component, data: rawptr) {
		fft := cast(^FftData)data
		if fft == nil do return
		bounds := comp.calc_bounds

		if fft.sample_rate <= 0 || len(fft.vals) < 2 do return

		FMIN :: f32(20)
		FMAX :: f32(20000)

		fft_size := f32(len(fft.vals) * 2)
		log_span := math.log10(FMAX / FMIN)

		pts: [ANALYSIS_BUFFER_SIZE / 2]sdk.Vec2f
		n := 0
		for val, i in fft.vals {
			freq := f32(i) * fft.sample_rate / fft_size
			if freq < FMIN do continue
			if freq > FMAX do break

			x := bounds.x + bounds.w * (math.log10(freq / FMIN) / log_span)
			t := clamp(val, 0, 1)
			y := bounds.y + bounds.h * (1 - t)
			pts[n] = {x, y}
			n += 1
		}
		if n >= 2 {
			sdk.draw_polyline(ctx.plugin.draw, pts[:n], thickness = 1)
		}
	}

	if sdk.ui_frame_scoped(plug.ui) {
		if sdk.ui_panel(plug.ui, dir = .Vertical, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Grow}, child_gaps = 40, padding = 10) {
			// Envelope params
			if sdk.ui_panel(plug.ui, dir = .Horizontal, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Fit}, child_gaps = 6, padding = 0, skip_draw = true) {
				sdk.ui_knob_param_labeled(plug.ui, PARAM_ATTACK)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_DECAY)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_SUSTAIN)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_RELEASE)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_GAIN)
			}
			// Oscillator param
			if sdk.ui_panel(plug.ui, dir = .Horizontal, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Grow}, child_gaps = 10, padding = 0, skip_draw = true) {
				sdk.ui_knob_param_labeled(plug.ui, PARAM_OSC1_WAVE, enum_to_string = osc_enum_to_string)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_OSC2_WAVE, enum_to_string = osc_enum_to_string)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_OSC_MIX)
				sdk.ui_knob_param_labeled(plug.ui, PARAM_OSC2_DET)
			}
			sdk.ui_canvas(plug.ui, scope_draw, &fft_data)
			
			// Arp controls
			if sdk.ui_panel(plug.ui, dir = .Vertical, sizing_horiz = {type = .Grow}, sizing_vert = {type = .Fit}, child_gaps = 6, padding = 0, skip_draw = true) {
				sdk.ui_toggle_param_labeled(plug.ui, PARAM_ARP_ON)
				sdk.ui_slider_h_param_labeled(plug.ui, PARAM_ARP_RATE, enum_to_string = arp_rate_to_string)
			}
		}
	}

	sdk.draw_submit(plug.draw)
}

// Vtable hooks

synth_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	state := new(SynthProcessState, allocator = plug.host.session_allocator)
	synth_init_state(state, f32(plug.audio_processor.sample_rate), plug.host.session_allocator)
	return state
}

synth_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr {
	state := new(SynthControlState, allocator = plug.host.session_allocator)
	dsp.window_fill(state.fft_window[:], .Hann)
	state.fft_window_gain = dsp.window_coherent_gain(state.fft_window[:])
	return state
}

synth_reset :: proc(plug: ^sdk.PluginProcessor) {
	synth_reset_state(cast(^SynthProcessState)plug.state)
}

synth_api :: sdk.PluginApi {
	get_plugin_descriptor = synth_get_plugin_descriptor,
	process_audio         = synth_process_audio,
	draw                  = synth_draw,

	setup_controller      = synth_setup_controller,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = synth_setup_processor,
	get_latency_samples   = synth_get_latency_samples,
	get_tail_samples      = synth_get_tail_samples,
	reset                 = synth_reset,
}
