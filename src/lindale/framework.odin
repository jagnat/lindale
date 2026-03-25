package lindale

import "core:time"
import b "../bridge"
import dsp "../dsp"

PluginType :: enum {
	Effect,
	Instrument,
}

PluginDescriptor :: struct {
	name: string,
	vendor: string,
	version:string,
	plugin_type: PluginType,
	params: []b.ParamDescriptor,
	max_channels: int,
	latency: u32,
	tail: u32,
	has_wet_dry: bool,
	wet_dry_param: ParamIndex,
}

Plugin :: struct {
	instance: ^b.PluginInstance,
	state: ^PluginState,
	audioProcessor: ^AudioProcessorContext,
	process_ctx: ProcessContext,
	smoothed: SmoothedParams,
	generation: u64,

	draw: ^DrawContext,
	ui: ^UIContext,
	mouse: b.MouseState,
	viewBounds: RectI32,
	inDraw: bool,
	lastDrawTime: time.Tick,
}

PluginComponentSet :: bit_set[PluginComponent]
PluginComponent :: enum {
	Audio,
	Controller,
}

PluginApi :: struct {
	process_audio:          proc(plug: ^Plugin),
	draw:                   proc(plug: ^Plugin),
	view_attached:          proc(plug: ^Plugin),
	view_removed:           proc(plug: ^Plugin),
	view_resized:           proc(plug: ^Plugin, rect: RectI32),
	query_parameter_layout: proc() -> []b.ParamDescriptor,
	get_plugin_descriptor:  proc() -> PluginDescriptor,
	get_latency_samples:    proc(plug: ^Plugin) -> u32,
	get_tail_samples:       proc(plug: ^Plugin) -> u32,
	setup_processing:       proc(plug: ^Plugin, sample_rate: f64, max_block_size: i32),
	reset:                  proc(plug: ^Plugin),
}

fallbackApi :: PluginApi {
	process_audio          = plugin_process_audio,
	draw                   = plugin_draw,
	view_attached          = plugin_view_attached,
	view_removed           = plugin_view_removed,
	view_resized           = plugin_view_resized,
	query_parameter_layout = plugin_query_parameter_layout,
	get_plugin_descriptor  = get_plugin_descriptor,
	get_latency_samples    = plugin_get_latency_samples,
	get_tail_samples       = plugin_get_tail_samples,
	setup_processing       = plugin_setup_processing,
	reset                  = plugin_reset,
}

HOT_DLL :: #config(HOT_DLL, false)

when HOT_DLL {
	@(export) GetPluginApi :: proc() -> PluginApi {
		return PluginApi {
			process_audio          = plugin_process_audio,
			draw                   = plugin_draw,
			view_attached          = plugin_view_attached,
			view_removed           = plugin_view_removed,
			view_resized           = plugin_view_resized,
			query_parameter_layout = plugin_query_parameter_layout,
			get_plugin_descriptor  = get_plugin_descriptor,
			get_latency_samples    = plugin_get_latency_samples,
			get_tail_samples       = plugin_get_tail_samples,
			setup_processing       = plugin_setup_processing,
			reset                  = plugin_reset,
		}
	}
}

// Lifecycle

plugin_query_parameter_layout :: proc() -> []b.ParamDescriptor {
	return get_plugin_descriptor().params
}

plugin_init :: proc(plugin: ^Plugin, components: PluginComponentSet) {
	desc := get_plugin_descriptor()
	if .Audio in components {
		if plugin.audioProcessor == nil {
			plugin.audioProcessor = new(AudioProcessorContext)
		}
		if plugin.audioProcessor.paramChanges == nil {
			plugin.audioProcessor.paramChanges = make([][]ParameterChange, len(desc.params))
		}
	}
	if .Controller in components {
		param_init(desc.params)
	}
}

plugin_destroy :: proc(plug: ^Plugin) {
}

plugin_view_attached :: proc(plug: ^Plugin) {
	if plug.draw == nil {
		plug.draw = new(DrawContext)
		plug.draw.plugin = plug
		plug.draw.clearColor = {0, 0, 0, 1}
		font_init(&plug.draw.fontState)
		plug.draw.initialized = true
	}
	if plug.ui == nil {
		plug.ui = new(UIContext)
		plug.ui.plugin = plug
	}
}

plugin_view_removed :: proc(plug: ^Plugin) {
	if plug.draw != nil {
		font_invalidate_texture(&plug.draw.fontState)
	}
}

plugin_view_resized :: proc(plug: ^Plugin, rect: RectI32) {
	plug.viewBounds = rect
}

plugin_get_latency_samples :: proc(plug: ^Plugin) -> u32 {
	return get_plugin_descriptor().latency
}

plugin_get_tail_samples :: proc(plug: ^Plugin) -> u32 {
	return get_plugin_descriptor().tail
}

// Processing framework

PARAM_SMOOTH_MS :: f32(5.0)

ProcessContext :: struct {
	inputs: [][]f32,
	outputs: [][]f32,
	num_samples: int,
	num_channels: int,
	sample_rate: f32,
	params: ^SmoothedParams,
	events: []b.Event,
	sample_offset: int, // absolute offset within the full process block

	// Internal
	dry: [][]f32,
	has_wet_dry: bool,
	wet_dry_param: ParamIndex,
	mix_buf: []f32,
	change_indices: []int,
	audio_ctx: ^AudioProcessorContext,
}

SmoothedParams :: struct {
	smoothers: []dsp.Smoother,
}

smoothed_next :: proc(p: ^SmoothedParams, index: ParamIndex) -> f32 {
	return p.smoothers[int(index)].current
}

process_begin :: proc(plug: ^Plugin) -> ^ProcessContext {
	actx := plug.audioProcessor
	if actx == nil do return nil
	if plug.instance == nil || plug.instance.params == nil do return nil

	outputs := actx.outputBuffers
	inputs := actx.inputBuffers
	if len(outputs) < 1 do return nil

	out_buf := outputs[0]
	if len(out_buf.buffers32) == 0 || len(out_buf.buffers32[0]) == 0 do return nil

	desc := get_plugin_descriptor()
	sr := f32(actx.sampleRate)
	if sr <= 0 do sr = 48000

	// Hot-reload or first-call init
	if plug.generation != plug.instance.generation {
		alloc := plug.instance.session_allocator
		plug.state = new(PluginState, alloc)
		plugin_init_state(plug.state, sr, alloc)
		plug.smoothed.smoothers = make([]dsp.Smoother, len(desc.params), alloc)
		for &s, i in plug.smoothed.smoothers {
			dsp.smoother_init(&s, f32(desc.params[i].default_value), PARAM_SMOOTH_MS, sr)
			dsp.smoother_set_target(&s, f32(plug.instance.params.values[i]))
		}
		plug.generation = plug.instance.generation
	}

	num_channels := min(channel_count(out_buf), desc.max_channels)
	num_samples := len(out_buf.buffers32[0])
	alloc := plug.instance.frame_allocator

	ctx := &plug.process_ctx
	ctx.num_samples = num_samples
	ctx.num_channels = num_channels
	ctx.sample_rate = sr
	ctx.sample_offset = 0
	ctx.params = &plug.smoothed
	ctx.audio_ctx = actx
	ctx.has_wet_dry = desc.has_wet_dry
	ctx.wet_dry_param = desc.wet_dry_param

	ctx.outputs = make([][]f32, num_channels, alloc)
	for c in 0 ..< num_channels {
		ctx.outputs[c] = out_buf.buffers32[c][:num_samples]
	}

	if len(inputs) > 0 && len(inputs[0].buffers32) > 0 {
		ctx.inputs = make([][]f32, num_channels, alloc)
		for c in 0 ..< num_channels {
			if len(inputs[0].buffers32) > c {
				ctx.inputs[c] = inputs[0].buffers32[c][:num_samples]
			} else {
				ctx.inputs[c] = make([]f32, num_samples, alloc)
			}
		}
	} else {
		ctx.inputs = nil
	}

	if ctx.has_wet_dry && ctx.inputs != nil {
		ctx.dry = make([][]f32, num_channels, alloc)
		ctx.mix_buf = make([]f32, num_samples, alloc)
		for c in 0 ..< num_channels {
			ctx.dry[c] = make([]f32, num_samples, alloc)
			dsp.buf_copy(ctx.dry[c], ctx.inputs[c])
		}
	}

	ctx.change_indices = make([]int, len(desc.params), alloc)
	ctx.events = actx.events

	return ctx
}

process_advance_params :: proc(ctx: ^ProcessContext, sample: int) {
	for p in 0 ..< len(ctx.params.smoothers) {
		changes := ctx.audio_ctx.paramChanges[p]
		for ctx.change_indices[p] < len(changes) && changes[ctx.change_indices[p]].sampleOffset <= i32(sample) {
			dsp.smoother_set_target(&ctx.params.smoothers[p], f32(changes[ctx.change_indices[p]].value))
			ctx.change_indices[p] += 1
		}
	}
	for &s in ctx.params.smoothers {
		dsp.smoother_next(&s)
	}
	if ctx.has_wet_dry && ctx.mix_buf != nil {
		ctx.mix_buf[sample] = ctx.params.smoothers[int(ctx.wet_dry_param)].current / 100.0
	}
}

process_end :: proc(ctx: ^ProcessContext) {
	if !ctx.has_wet_dry do return
	for c in 0 ..< ctx.num_channels {
		for s in 0 ..< ctx.num_samples {
			mix := ctx.mix_buf[s]
			ctx.outputs[c][s] = ctx.dry[c][s] * (1 - mix) + ctx.outputs[c][s] * mix
		}
	}
}

// Block splitting — calls process_fn for each sub-block split at event boundaries.
// Events at each split point are attached to ctx.events for that sub-block.
// Output/input slices are views into the full buffer (no allocation).
// Param advancement is the plugin's responsibility — call process_advance_params
// per-sample using ctx.sample_offset + s for absolute indexing.
// When no events are present, calls process_fn once for the full block.
process_split_blocks :: proc(ctx: ^ProcessContext, plug: ^Plugin, process_fn: proc(ctx: ^ProcessContext, plug: ^Plugin)) {
	if len(ctx.events) == 0 {
		process_fn(ctx, plug)
		return
	}

	alloc := plug.instance.frame_allocator
	nc := ctx.num_channels

	// Save original per-channel slices so sub-block reslicing doesn't alias
	full_outputs := make([][]f32, nc, alloc)
	copy(full_outputs, ctx.outputs)
	full_inputs: [][]f32
	if ctx.inputs != nil {
		full_inputs = make([][]f32, nc, alloc)
		copy(full_inputs, ctx.inputs)
	}
	full_num_samples := ctx.num_samples
	full_events := ctx.events

	block_start := 0
	event_idx := 0

	for block_start < full_num_samples {
		// Collect events at this offset
		sub_event_start := event_idx
		for event_idx < len(full_events) && int(full_events[event_idx].sample_offset) <= block_start {
			event_idx += 1
		}

		// Next split point
		block_end := full_num_samples
		if event_idx < len(full_events) {
			block_end = int(full_events[event_idx].sample_offset)
		}

		sub_len := block_end - block_start
		if sub_len <= 0 do break

		// Sub-block views for outputs and inputs
		for c in 0 ..< nc {
			ctx.outputs[c] = full_outputs[c][block_start:block_end]
		}
		if full_inputs != nil {
			for c in 0 ..< nc {
				ctx.inputs[c] = full_inputs[c][block_start:block_end]
			}
		}

		ctx.num_samples = sub_len
		ctx.sample_offset = block_start
		ctx.events = full_events[sub_event_start:event_idx]

		process_fn(ctx, plug)

		block_start = block_end
	}

	// Restore full context
	ctx.inputs = full_inputs
	ctx.outputs = full_outputs
	ctx.num_samples = full_num_samples
	ctx.events = full_events
	ctx.sample_offset = 0
}

plugin_setup_processing :: proc(plug: ^Plugin, sample_rate: f64, max_block_size: i32) {
	
}

plugin_reset :: proc(plug: ^Plugin) {}
