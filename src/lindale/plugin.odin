package lindale

import "core:log"
import "core:math"
import "core:mem"
import "core:time"
import b "../bridge"
import dsp "../dsp"

// State

PluginState :: struct {
	lines:   [2]dsp.DelayLine,
	buffers: [2][]dsp.Sample,
}

// Parameters

PARAM_DELAY_TIME :: ParamIndex(0)
PARAM_FEEDBACK   :: ParamIndex(1)
PARAM_MIX        :: ParamIndex(2)
PARAM_GAIN       :: ParamIndex(3)

@(rodata) param_table := [?]b.ParamDescriptor {
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

MAX_DELAY_MS :: 2000.0

// Descriptor

get_plugin_descriptor :: proc() -> PluginDescriptor {
	return {
		name          = "Delay",
		plugin_type   = .Effect,
		params        = param_table[:],
		max_channels  = 2,
		latency       = 0,
		tail          = u32(MAX_DELAY_MS * 48000.0 / 1000.0),
		has_wet_dry   = true,
		wet_dry_param = PARAM_MIX,
	}
}

// Lifecycle

plugin_init_state :: proc(state: ^PluginState, sample_rate: f32, alloc: mem.Allocator) {
	max_samples := int(math.ceil(MAX_DELAY_MS * f64(sample_rate) / 1000.0))
	for c in 0 ..< 2 {
		state.buffers[c] = make([]dsp.Sample, max_samples, alloc)
		dsp.delay_init(&state.lines[c], state.buffers[c])
	}
}

// Audio

plugin_process_audio :: proc(plug: ^Plugin) {
	ctx := process_begin(plug)
	if ctx == nil do return

	for s in 0 ..< ctx.num_samples {
		process_advance_params(ctx, s)

		delay_ms := smoothed_next(ctx.params, PARAM_DELAY_TIME)
		feedback := smoothed_next(ctx.params, PARAM_FEEDBACK) / 100.0
		gain := dsp.db_to_linear(smoothed_next(ctx.params, PARAM_GAIN))

		delay_samples := delay_ms * ctx.sample_rate / 1000.0

		for c in 0 ..< ctx.num_channels {
			dry := ctx.inputs[c][s]
			delayed := dsp.delay_read_frac(&plug.state.lines[c], delay_samples)
			dsp.delay_write(&plug.state.lines[c], dry + delayed * feedback)
			ctx.outputs[c][s] = delayed * gain
		}
	}

	process_end(ctx)
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
			ui_slider_param_labeled(plug.ui, "Delay", PARAM_DELAY_TIME)
			ui_slider_param_labeled(plug.ui, "Feedback", PARAM_FEEDBACK)
			ui_slider_param_labeled(plug.ui, "Mix", PARAM_MIX)
			ui_slider_param_labeled(plug.ui, "Gain", PARAM_GAIN)
		}
	}

	plug.draw.frame += 1

	draw_submit(plug.draw)
}
