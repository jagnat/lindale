package livecode

import "core:fmt"
import "../../../src/sdk"
import b "../../../src/bridge"
import dsp "../../../src/dsp"

@(export, link_name="lindale_get_plugin_api")
get_plugin_api :: proc() -> sdk.PluginApi {
	return livecode_api
}

// A livecoding playground. The whole instrument is driven from the host
// transport: hit play in the DAW and the patterns in livecode_tick run.
// Edit livecode_tick, rebuild the hot DLL, and it swaps underneath the running
// clock without dropping the beat.
//
// The reusable timing math (grid/euclid/scales) lives in dsp/scheduler.odin.
// This file is just the voice pool plus the edit surface.
//
// State layout below is FROZEN on purpose: hot-reload survives only if the
// struct layout is stable across builds, so edit livecode_tick, not the structs.

MAX_LIVE_VOICES :: 64

LiveVoice :: struct {
	active: bool,
	osc: dsp.Oscillator,
	env: dsp.ADSR,
	gain: f32,
	gate_remaining: int, // samples until gate-off; <=0 means already released
	start_offset: int, // sample within the block where this voice begins
}

LivecodeProcessState :: struct {
	voices: [MAX_LIVE_VOICES]LiveVoice,
	sched: dsp.SchedCtx,
	beat_clock: f64, // self-clocked beat position for hosts that don't report one
	next_voice: int, // round-robin steal cursor
}

LivecodeControlState :: struct {}

@(rodata) livecode_param_table := [?]b.ParamDescriptor {}

livecode_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		name = "Livecode",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Instrument,
		params = livecode_param_table[:],
		max_channels = 2,
		view = {
			default_width = 480, default_height = 200,
			resizable = true,
		},
	}
}

// Thin wrappers over dsp scheduling so the edit surface reads cleanly.
grid :: proc(plug: ^sdk.PluginProcessor, period: f32, phase: f32 = 0) -> []dsp.SchedHit {
	state := cast(^LivecodeProcessState)plug.state
	return dsp.grid(state.sched, period, phase)
}
euclid :: proc(plug: ^sdk.PluginProcessor, hits, steps: int, step_len: f32, phase: f32 = 0) -> []dsp.SchedHit {
	state := cast(^LivecodeProcessState)plug.state
	return dsp.euclid(state.sched, hits, steps, step_len, phase)
}

alloc_voice :: proc(state: ^LivecodeProcessState) -> ^LiveVoice {
	for &v in state.voices {
		if !v.active do return &v
	}
	v := &state.voices[state.next_voice]
	state.next_voice = (state.next_voice + 1) %% MAX_LIVE_VOICES
	return v
}

// Fire a note at a scheduled hit. Defaults give a short percussive blip;
// raise sustain/dur for held notes. Times are in seconds, dur is in beats.
play :: proc(
	plug: ^sdk.PluginProcessor, at: dsp.SchedHit, note: f32,
	wave: dsp.Waveform = .Sine,
	attack: f32 = 0.002, decay: f32 = 0.2, sustain: f32 = 0, release: f32 = 0.06,
	dur: f32 = 0.1, gain: f32 = 0.6,
) {
	state := cast(^LivecodeProcessState)plug.state
	v := alloc_voice(state)
	dsp.osc_reset(&v.osc)
	v.osc.wave = wave
	dsp.osc_set_freq(&v.osc, dsp.midi_to_freq(note))
	dsp.adsr_reset(&v.env)
	dsp.adsr_set_params(&v.env, attack, decay, sustain, release)
	dsp.adsr_gate_on(&v.env)
	v.gain = gain
	v.start_offset = at.offset
	v.gate_remaining = max(1, int(f64(dur) / state.sched.bps))
	v.active = true
}

// ============================================================================
// EDIT HERE. Runs once per audio block while the transport is playing.
// Add/remove tracks freely, then rebuild — the clock keeps running.
// ============================================================================
livecode_tick :: proc(plug: ^sdk.PluginProcessor) {
	// Kick: four on the floor
	for h in grid(plug, 1.0) {
		play(plug, h, note = 28, wave = .Sine, decay = 0.18, dur = 0.05, gain = 0.9)
	}

	// Hat: triplets, drifting against the kick
	for h in grid(plug, 1.0 / 3.0) {
		play(plug, h, note = 90, wave = .Noise, decay = 0.03, dur = 0.02, gain = 0.25)
	}

	// Bass: euclidean 5-in-8 sixteenths, walking a minor scale
	for h in euclid(plug, 5, 8, 0.25) {
		note := dsp.scale_note(40, h.step, dsp.SCALE_MINOR[:])
		play(plug, h, note = note, wave = .Saw, decay = 0.25, dur = 0.18, gain = 0.4)
	}
}

// ============================================================================

livecode_process_audio :: proc(plug: ^sdk.PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil || plug.state == nil do return
	n := actx.numSamples
	nc := actx.numChannels
	if n == 0 || nc == 0 do return

	state := cast(^LivecodeProcessState)plug.state
	transport := &actx.transport

	// Be robust to hosts that don't populate musical time (the arp in
	// plugin_synth hit this). Tempo falls back to 120; we keep our own beat
	// clock and only defer to the host's timeline when it actually provides
	// one. Free-run unless the host explicitly reports a stopped transport.
	tempo := (.Tempo in transport.valid && transport.tempo > 0) ? transport.tempo : 120.0
	playing := !(.Playing in transport.valid) || transport.playing

	for c in 0 ..< nc {
		for i in 0 ..< n do actx.outputs[c][i] = 0
	}

	state.sched.bps = tempo / 60.0 / actx.sampleRate
	state.sched.n = n
	if .BeatPosition in transport.valid {
		state.beat_clock = transport.beat_position // host-accurate, follows loops/seeks
	}
	state.sched.b0 = state.beat_clock

	if playing {
		livecode_tick(plug)
		state.beat_clock += f64(n) * state.sched.bps // advance our own clock (overwritten next block when the host gives one)
	}

	for &v in state.voices {
		if !v.active do continue
		for i in v.start_offset ..< n {
			if v.gate_remaining > 0 {
				v.gate_remaining -= 1
				if v.gate_remaining == 0 do dsp.adsr_gate_off(&v.env)
			}
			env := dsp.adsr_next(&v.env)
			if dsp.adsr_is_idle(&v.env) {
				v.active = false
				break
			}
			s := dsp.osc_next(&v.osc) * env * v.gain
			for c in 0 ..< nc do actx.outputs[c][i] += s
		}
		v.start_offset = 0
	}
}

livecode_draw :: proc(plug: ^sdk.PluginController) {
	if plug.draw == nil do return
	sdk.draw_set_clear_color(plug.draw, sdk.ColorF32{0.07, 0.07, 0.09, 1})
	sdk.draw_clear(plug.draw)

	active := 0
	beat := f64(0)
	if plug.processor_peer != nil && plug.processor_peer.state != nil {
		pstate := cast(^LivecodeProcessState)plug.processor_peer.state
		for &v in pstate.voices {
			if v.active do active += 1
		}
		beat = pstate.beat_clock
	}
	sdk.draw_text(plug.draw, fmt.tprintf("livecode   beat %.2f   voices %d", beat, active), 16, 16, color = sdk.ColorU8{180, 180, 190, 255}, size = 18)
	sdk.draw_submit(plug.draw)
}

livecode_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	state := new(LivecodeProcessState, allocator = plug.host.session_allocator)
	sr := f32(plug.audioProcessor.sampleRate)
	for &v in state.voices {
		dsp.osc_init(&v.osc, sr)
		dsp.adsr_init(&v.env, sr)
		v.active = false
	}
	state.next_voice = 0
	state.beat_clock = 0
	return state
}

livecode_reset :: proc(plug: ^sdk.PluginProcessor) {
	state := cast(^LivecodeProcessState)plug.state
	for &v in state.voices {
		v.active = false
		dsp.adsr_reset(&v.env)
		dsp.osc_reset(&v.osc)
	}
	state.beat_clock = 0
}

livecode_api :: sdk.PluginApi {
	get_plugin_descriptor = livecode_get_plugin_descriptor,
	process_audio         = livecode_process_audio,
	draw                  = livecode_draw,

	setup_controller      = nil,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = livecode_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = nil,
	reset                 = livecode_reset,
}
