package delay

import "core:log"
import "core:math"
import "core:mem"
import "core:time"
import "../../../src/sdk"
import b "../../../src/bridge"
import dsp "../../../src/dsp"

@(export)
GetPluginApi :: proc() -> sdk.PluginApi {
	return sdk.fallbackApi
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(delay_api)
}

MAX_DELAY_MS :: 2000.0

// State

DelayProcessState :: struct {
	lines:   [2]dsp.DelayLine,
	buffers: [2][]dsp.Sample,
}

DelayControlState :: struct {}

// Parameters

PARAM_DELAY_TIME  :: sdk.ParamIndex(0)
PARAM_FEEDBACK    :: sdk.ParamIndex(1)
PARAM_MIX         :: sdk.ParamIndex(2)
DELAY_PARAM_GAIN  :: sdk.ParamIndex(3)

@(rodata) delay_param_table := [?]b.ParamDescriptor {
	{
		name = "Delay Time", short_name = "Delay",
		min = 1.0, max = 2000.0, default_value = 250.0,
		step_count = 0, unit = .Milliseconds,
		flags = {.Automatable},
	},
	{
		name = "Feedback", short_name = "Fdbk",
		min = 0.0, max = 99.0, default_value = 30.0,
		step_count = 0, unit = .Percentage,
		flags = {.Automatable},
	},
	{
		name = "Mix", short_name = "Mix",
		min = 0.0, max = 100.0, default_value = 50.0,
		step_count = 0, unit = .Percentage,
		flags = {.Automatable},
	},
	{
		name = "Gain", short_name = "Gain",
		min = -60.0, max = 12.0, default_value = 0.0,
		step_count = 0, unit = .Decibel,
		flags = {.Automatable},
	},
}

// Descriptor

delay_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		name         = "Lindale Delay",
		vendor       = "JagI",
		version      = "0.0.1",
		plugin_type  = .Effect,
		params       = delay_param_table[:],
		max_channels = 2,
	}
}

// Lifecycle

delay_init_state :: proc(state: ^DelayProcessState, sample_rate: f32, alloc: mem.Allocator) {
	max_samples := int(math.ceil(MAX_DELAY_MS * f64(sample_rate) / 1000.0))
	for c in 0 ..< 2 {
		state.buffers[c] = make([]dsp.Sample, max_samples, alloc)
		dsp.delay_init(&state.lines[c], state.buffers[c])
	}
}

delay_reset_state :: proc(state: ^DelayProcessState) {
	for c in 0 ..< 2 {
		for i in 0 ..< len(state.buffers[c]) {
			state.buffers[c][i] = 0
		}
		state.lines[c].write_pos = 0
	}
}

// Audio

delay_process_audio :: proc(plug: ^sdk.PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.state == nil do return
	if actx.numChannels == 0 || actx.numSamples == 0 do return
	if actx.inputs[0] == nil do return

	state := cast(^DelayProcessState)plug.state
	num_samples := actx.numSamples
	num_channels := actx.numChannels
	sample_rate := f32(actx.sampleRate)

	dry := sdk.capture_dry(actx.inputs[:num_channels], num_samples, plug.host.frame_allocator)

	for s in 0 ..< num_samples {
		sdk.advance_smoothers(actx, s)

		delay_ms := sdk.smoothed_read(actx, PARAM_DELAY_TIME)
		feedback := sdk.smoothed_read(actx, PARAM_FEEDBACK) / 100.0
		mix := sdk.smoothed_read(actx, PARAM_MIX) / 100.0
		gain := dsp.db_to_linear(sdk.smoothed_read(actx, DELAY_PARAM_GAIN))
		delay_samples := delay_ms * sample_rate / 1000.0

		for c in 0 ..< num_channels {
			input := actx.inputs[c][s]
			delayed := dsp.delay_read_frac(&state.lines[c], delay_samples)
			dsp.delay_write(&state.lines[c], input + delayed * feedback)
			actx.outputs[c][s] = dry[c][s] * (1 - mix) + delayed * gain * mix
		}
	}
}

// UI

delay_draw :: proc(plug: ^sdk.PluginController) {
	if plug.draw == nil || plug.ui == nil do return

	if plug.inDraw {
		log.warn("Re-entrant draw detected!")
		return
	}
	plug.inDraw = true
	defer plug.inDraw = false

	plug.lastDrawTime = time.tick_now()

	sdk.draw_set_clear_color(plug.draw, sdk.ColorF32_from_ColorU8(plug.ui.theme.bgColor))
	sdk.draw_clear(plug.draw)

	if sdk.ui_frame_scoped(plug.ui) {
		if sdk.ui_panel(plug.ui, dir = .HORIZONTAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10, padding = 10) {
			sdk.ui_knob_param_labeled(plug.ui, PARAM_DELAY_TIME)
			sdk.ui_knob_param_labeled(plug.ui, PARAM_FEEDBACK)
			sdk.ui_knob_param_labeled(plug.ui, PARAM_MIX)
			sdk.ui_knob_param_labeled(plug.ui, DELAY_PARAM_GAIN)
		}
	}

	sdk.draw_submit(plug.draw)
}

// Vtable hooks

delay_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	state := new(DelayProcessState, allocator = plug.host.session_allocator)
	delay_init_state(state, f32(plug.audioProcessor.sampleRate), plug.host.session_allocator)
	return state
}

delay_reset :: proc(plug: ^sdk.PluginProcessor) {
	delay_reset_state(cast(^DelayProcessState)plug.state)
}

delay_get_tail_samples :: proc(plug: ^sdk.PluginProcessor) -> u32 {
	if plug.audioProcessor == nil do return 0
	return u32(MAX_DELAY_MS * plug.audioProcessor.sampleRate / 1000.0)
}

delay_api :: sdk.PluginApi {
	get_plugin_descriptor = delay_get_plugin_descriptor,
	process_audio         = delay_process_audio,
	draw                  = delay_draw,

	setup_controller      = nil,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = delay_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = delay_get_tail_samples,
	reset                 = delay_reset,
}
