package lindale

import "core:mem"
import "core:time"
import b "../bridge"
import dsp "../dsp"

ParameterChange :: struct {
	sampleOffset: i32,
	value: f64,
}

AudioProcessContext :: struct {
	// Host-written fields (set by the VST layer before calling process)
	sampleRate: f64,
	maxBlockSize: i32,
	projectTimeSamples: i64,
	outputs: [][]f32,
	inputs: [][]f32,
	numChannels: int,
	numSamples: int,
	paramChanges: [][]ParameterChange,
	events: []b.Event,

	// Framework-managed fields (set during setup_processor)
	smoothers: []dsp.Smoother,
	changeIndices: []int,
}

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
}

PluginProcessor :: struct {
	host: ^b.HostContext,

	state: ^PluginProcessState, // User code state
	audioProcessor: ^AudioProcessContext,
}

PluginController :: struct {
	host: ^b.HostContext,

	state: ^PluginControlState,
	draw: ^DrawContext,
	ui: ^UIContext,
	mouse: b.MouseState,
	viewBounds: RectI32,
	inDraw: bool,
	lastDrawTime: time.Tick,
}

PluginApi :: struct {
	get_plugin_descriptor:  proc() -> PluginDescriptor,

	setup_controller:       proc(plug: ^PluginController),
	draw:                   proc(plug: ^PluginController),
	view_attached:          proc(plug: ^PluginController),
	view_removed:           proc(plug: ^PluginController),
	view_resized:           proc(plug: ^PluginController, rect: RectI32),

	setup_processor:        proc(plug: ^PluginProcessor),
	process_audio:          proc(plug: ^PluginProcessor),
	get_latency_samples:    proc(plug: ^PluginProcessor) -> u32,
	get_tail_samples:       proc(plug: ^PluginProcessor) -> u32,
	reset:                  proc(plug: ^PluginProcessor),
}

fallbackApi :: PluginApi {
	get_plugin_descriptor  = get_plugin_descriptor,

	setup_controller       = plugin_setup_controller,
	draw                   = plugin_draw,
	view_attached          = plugin_view_attached,
	view_removed           = plugin_view_removed,
	view_resized           = plugin_view_resized,

	setup_processor        = plugin_setup_processor,
	process_audio          = plugin_process_audio,
	get_latency_samples    = plugin_get_latency_samples,
	get_tail_samples       = plugin_get_tail_samples,
	reset                  = plugin_reset,
}

HOT_DLL :: #config(HOT_DLL, false)

when HOT_DLL {
	@(export) GetPluginApi :: proc() -> PluginApi {
		return PluginApi {
			get_plugin_descriptor  = get_plugin_descriptor,

			setup_controller       = plugin_setup_controller,
			draw                   = plugin_draw,
			view_attached          = plugin_view_attached,
			view_removed           = plugin_view_removed,
			view_resized           = plugin_view_resized,

			setup_processor        = plugin_setup_processor,
			process_audio          = plugin_process_audio,
			get_latency_samples    = plugin_get_latency_samples,
			get_tail_samples       = plugin_get_tail_samples,
			reset                  = plugin_reset,
		}
	}
}

// Lifecycle

plugin_init_processor :: proc(plugin: ^PluginProcessor) {
	desc := get_plugin_descriptor()
	if plugin.audioProcessor == nil {
		plugin.audioProcessor = new(AudioProcessContext)
	}
	if plugin.audioProcessor.paramChanges == nil {
		plugin.audioProcessor.paramChanges = make([][]ParameterChange, len(desc.params))
	}
}

plugin_init_controller :: proc(plugin: ^PluginController) {
	desc := get_plugin_descriptor()
	param_init(desc.params)
}

plugin_view_attached :: proc(plug: ^PluginController) {
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

plugin_view_removed :: proc(plug: ^PluginController) {
	if plug.draw != nil {
		font_invalidate_texture(&plug.draw.fontState)
	}
}

plugin_view_resized :: proc(plug: ^PluginController, rect: RectI32) {
	plug.viewBounds = rect
}

plugin_get_latency_samples :: proc(plug: ^PluginProcessor) -> u32 {
	return get_plugin_descriptor().latency
}

plugin_get_tail_samples :: proc(plug: ^PluginProcessor) -> u32 {
	return get_plugin_descriptor().tail
}

// Processing

DEFAULT_SMOOTH_MS :: f32(5.0)
NO_SMOOTHING :: f32(-1)

plugin_setup_processor :: proc(plug: ^PluginProcessor) {
	actx := plug.audioProcessor
	if actx == nil do return
	if plug.host == nil do return

	desc := get_plugin_descriptor()
	sr := f32(actx.sampleRate)
	alloc := plug.host.session_allocator

	// Allocate plugin state and call plugin-specific init
	plug.state = new(PluginProcessState, alloc)
	plugin_init_state(plug.state, sr, alloc)

	// Allocate smoothers based on param table
	actx.smoothers = make([]dsp.Smoother, len(desc.params), alloc)
	params := plug.host.params
	for p, i in desc.params {
		initial := f32(params.values[i]) if params != nil else f32(p.default_value)
		smooth_time: f32
		if .List in p.flags || p.smooth_ms < 0 {
			smooth_time = 0 // pass-through
		} else if p.smooth_ms == 0 {
			smooth_time = DEFAULT_SMOOTH_MS
		} else {
			smooth_time = p.smooth_ms
		}
		dsp.smoother_init(&actx.smoothers[i], initial, smooth_time, sr)
	}

	// Pre-allocate per-call arrays (resliced, not reallocated, each process call)
	actx.changeIndices = make([]int, len(desc.params), alloc)
	actx.outputs = make([][]f32, desc.max_channels, alloc)
	actx.inputs = make([][]f32, desc.max_channels, alloc)
}

plugin_reset :: proc(plug: ^PluginProcessor) {
	if plug.state == nil do return
	plugin_reset_state(plug.state)
	if plug.audioProcessor != nil {
		for &s in plug.audioProcessor.smoothers {
			dsp.smoother_reset(&s)
		}
	}
}

plugin_setup_controller :: proc(plug: ^PluginController) {
	plug.state = new(PluginControlState, plug.host.session_allocator)
}

// Utilities

// Block iterator — splits a process block at note event boundaries
BlockIterator :: struct {
	events: []b.Event,
	total_samples: int,
	pos: int,
	event_idx: int,
}

BlockInfo :: struct {
	events: []b.Event,
	sample_offset: int,
	sample_count: int,
}

make_block_iterator :: proc(events: []b.Event, total_samples: int) -> BlockIterator {
	return {events = events, total_samples = total_samples}
}

next_block :: proc(it: ^BlockIterator) -> (BlockInfo, bool) {
	if it.pos >= it.total_samples do return {}, false

	// Collect events at current position
	sub_event_start := it.event_idx
	for it.event_idx < len(it.events) && int(it.events[it.event_idx].sample_offset) <= it.pos {
		it.event_idx += 1
	}

	// Next split point
	block_end := it.total_samples
	if it.event_idx < len(it.events) {
		block_end = int(it.events[it.event_idx].sample_offset)
	}

	sample_count := block_end - it.pos
	if sample_count <= 0 do return {}, false

	info := BlockInfo {
		events = it.events[sub_event_start:it.event_idx],
		sample_offset = it.pos,
		sample_count = sample_count,
	}
	it.pos = block_end
	return info, true
}

// Smoother utilities

advance_smoothers :: proc(actx: ^AudioProcessContext, sample: int) {
	for p in 0 ..< len(actx.smoothers) {
		changes := actx.paramChanges[p]
		for actx.changeIndices[p] < len(changes) && changes[actx.changeIndices[p]].sampleOffset <= i32(sample) {
			dsp.smoother_set_target(&actx.smoothers[p], f32(changes[actx.changeIndices[p]].value))
			actx.changeIndices[p] += 1
		}
	}
	for &s in actx.smoothers {
		dsp.smoother_next(&s)
	}
}

smoothed_read :: proc(actx: ^AudioProcessContext, index: ParamIndex) -> f32 {
	return actx.smoothers[int(index)].current
}

// Wet/dry utilities

capture_dry :: proc(inputs: [][]f32, num_samples: int, alloc: mem.Allocator) -> [][]f32 {
	dry := make([][]f32, len(inputs), alloc)
	for c in 0 ..< len(inputs) {
		dry[c] = make([]f32, num_samples, alloc)
		copy(dry[c], inputs[c][:num_samples])
	}
	return dry
}

apply_wet_dry :: proc(outputs: [][]f32, dry: [][]f32, mix: f32, num_samples: int) {
	for c in 0 ..< len(outputs) {
		for s in 0 ..< num_samples {
			outputs[c][s] = dry[c][s] * (1 - mix) + outputs[c][s] * mix
		}
	}
}
