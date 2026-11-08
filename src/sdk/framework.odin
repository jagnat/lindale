package sdk

import "base:intrinsics"
import "core:mem"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import b "../bridge"
import dsp "../dsp"

@(private) active_plugin: PluginApi

register_plugin :: proc "contextless" (api: PluginApi) {
	active_plugin = api
}

plugin_api :: proc() -> PluginApi {
	return active_plugin
}

ParamDescriptor :: b.ParamDescriptor

ParamIndex :: distinct int

// Flattens a [Param]ParamDescriptor table for PluginDescriptor
// Enum order can change between versions, saved state and host ids come from ParamDescriptor.id
param_table :: proc(table: ^[$E]b.ParamDescriptor) -> []b.ParamDescriptor where intrinsics.type_enum_is_contiguous(E) {
	#assert(int(min(E)) == 0)
	return slice.enumerated_array(table)
}

// Convert .List flagged parameter's values to their string labels
enum_label :: proc($E: typeid) -> proc(val: f64) -> string {
	return proc(val: f64) -> string {
		names := reflect.enum_field_names(E)
		i := int(val + 0.5)
		if i < 0 || i >= len(names) do return ""
		return names[i]
	}
}

ParameterChange :: struct {
	sample_offset: i32,
	value: f64,
}

TransportValidFlags :: enum u8 {
	Tempo,
	TimeSig,
	BeatPosition,
	BarPosition,
	SamplePosition,
	CycleActive,
	CyclePoints,
	Playing,
}

TransportValidFlagSet :: bit_set[TransportValidFlags]

TransportState :: struct {
	playing: bool,
	tempo: f64,
	time_sig_numerator: i32,
	time_sig_denominator: i32,
	beat_position: f64,
	bar_position: f64,
	sample_position: i64,
	cycle_active: bool,
	cycle_start: f64,
	cycle_end: f64,
	valid: TransportValidFlagSet,
}

AudioProcessContext :: struct {
	// Host-written fields (set by the VST layer before calling process)
	sample_rate: f64,
	max_block_size: i32,
	project_time_samples: i64,
	outputs: [][]f32,
	inputs: [][]f32,
	num_channels: int,
	num_samples: int,
	param_changes: [][]ParameterChange,
	events: []b.Event,
	transport: TransportState,

	// Framework-managed fields (set during setup_processor)
	smoothers: []dsp.Smoother,
	change_indices: []int,
}

// Stable for the entire lifetime of a plugin instance
PluginProcessor :: struct {
	host: ^b.HostContext,

	controller_peer: ^PluginController,

	// User code state allocated by plugin
	// Will get reset (through setup_processor) on hotreload
	state: rawptr,
	audio_processor: ^AudioProcessContext,
}

PluginController :: struct {
	host: ^b.HostContext,

	processor_peer: ^PluginProcessor,

	// User code state allocated by plugin
	// Will get reset (through setup_controller) on hotreload
	state: rawptr,

	draw: ^DrawContext,
	ui: ^UIContext,
	mouse: b.MouseState,
	view_bounds: RectI32,
	in_draw: bool,
	last_draw_time: time.Tick,
	frame_dt: f32, // seconds since previous draw
}

FALLBACK_API :: PluginApi {
	get_plugin_descriptor  = framework_get_plugin_descriptor,

	setup_controller       = framework_setup_controller,
	draw                   = framework_draw,
	view_attached          = framework_view_attached,
	view_removed           = framework_view_removed,
	view_resized           = framework_view_resized,
	state_changed          = framework_state_changed,

	setup_processor        = framework_setup_processor,
	process_audio          = framework_process_audio,
	get_latency_samples    = framework_get_latency_samples,
	get_tail_samples       = framework_get_tail_samples,
	reset                  = framework_reset,
}

// Required procs: just pass through to the plugin vtable

framework_get_plugin_descriptor :: proc() -> PluginDescriptor {
	return plugin_api().get_plugin_descriptor()
}

framework_process_audio :: proc(plug: ^PluginProcessor) {
	if plugin_api().process_audio != nil do plugin_api().process_audio(plug)
}

framework_draw :: proc(plug: ^PluginController) {
	if plugin_api().draw != nil do plugin_api().draw(plug)
}

// Optional procs: framework does its own work, then delegates if the plugin opted in.

framework_setup_controller :: proc(plug: ^PluginController) -> rawptr {
	// fontstash points at font bytes in the hot dll, so its state is rebuilt each session
	plug.draw = new(DrawContext, plug.host.session_allocator)
	plug.draw.plugin = plug
	plug.draw.clear_color = {0, 0, 0, 1}
	font_init(&plug.draw.font_state, font_ttf, plug.host.session_allocator)
	plug.draw.initialized = true

	plug.state = nil
	if plugin_api().setup_controller != nil do plug.state = plugin_api().setup_controller(plug)
	return plug.state
}

framework_view_attached :: proc(plug: ^PluginController) {
	font_invalidate_texture(&plug.draw.font_state)
	if plug.ui == nil {
		plug.ui = new(UIContext)
		plug.ui.plugin = plug
		plug.ui.theme = THEME_JQ
	}
	if plugin_api().view_attached != nil do plugin_api().view_attached(plug)
}

framework_view_removed :: proc(plug: ^PluginController) {
	if plug.draw != nil {
		font_invalidate_texture(&plug.draw.font_state)
	}
	if plugin_api().view_removed != nil do plugin_api().view_removed(plug)
}

framework_view_resized :: proc(plug: ^PluginController, rect: RectI32) {
	plug.view_bounds = rect
	if plugin_api().view_resized != nil do plugin_api().view_resized(plug, rect)
}

framework_state_changed :: proc(plug: ^PluginController) {
	if plugin_api().state_changed != nil do plugin_api().state_changed(plug)
}

framework_setup_processor :: proc(plug: ^PluginProcessor) -> rawptr {
	actx := plug.audio_processor
	if actx == nil do return nil
	if plug.host == nil do return nil

	desc := plugin_api().get_plugin_descriptor()
	sr := f32(actx.sample_rate)
	alloc := plug.host.session_allocator

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
	actx.change_indices = make([]int, len(desc.params), alloc)
	actx.outputs = make([][]f32, desc.max_channels, alloc)
	actx.inputs = make([][]f32, desc.max_channels, alloc)

	if plugin_api().setup_processor != nil do plug.state = plugin_api().setup_processor(plug)
	return plug.state
}

framework_get_latency_samples :: proc(plug: ^PluginProcessor) -> u32 {
	return plugin_api().get_latency_samples(plug) if plugin_api().get_latency_samples != nil else 0
}

framework_get_tail_samples :: proc(plug: ^PluginProcessor) -> u32 {
	return plugin_api().get_tail_samples(plug) if plugin_api().get_tail_samples != nil else 0
}

framework_reset :: proc(plug: ^PluginProcessor) {
	if plug.state == nil do return
	if plugin_api().reset != nil do plugin_api().reset(plug)
	if plug.audio_processor != nil {
		for &s in plug.audio_processor.smoothers {
			dsp.smoother_reset(&s)
		}
	}
}

// Instance state, saved with projects and presets. Controller thread only
// Not available in setup_controller, read it in state_changed. A missing key means use the default
// Returned bytes stay valid until the next state_set of that key or a state load

state_set :: proc(plug: ^PluginController, key: string, bytes: []u8) {
	if strings.has_prefix(key, b.RESERVED_ID_PREFIX) {
		log.errorf("state key %q uses the reserved prefix %q", key, b.RESERVED_ID_PREFIX)
		return
	}
	api := plug.host.host_api
	if api != nil && api.state_set != nil do api.state_set(api.ctx, key, bytes)
}

state_get :: proc(plug: ^PluginController, key: string) -> []u8 {
	api := plug.host.host_api
	if api == nil || api.state_get == nil do return nil
	return api.state_get(api.ctx, key)
}

// default_* falls back to min_*, then DEFAULT_VIEW_*. min_*/max_* stay zero
resolve_view_config :: proc(v: ViewConfig) -> (cfg: ViewConfig) {
	cfg = v
	if cfg.default_width == 0 do cfg.default_width = cfg.min_width if cfg.min_width > 0 else DEFAULT_VIEW_WIDTH
	if cfg.default_height == 0 do cfg.default_height = cfg.min_height if cfg.min_height > 0 else DEFAULT_VIEW_HEIGHT
	return
}

// Lifecycle (not hot loaded)

plugin_init_processor :: proc(plugin: ^PluginProcessor) {
	desc := plugin_api().get_plugin_descriptor()
	if plugin.audio_processor == nil {
		plugin.audio_processor = new(AudioProcessContext)
	}
	if plugin.audio_processor.param_changes == nil {
		plugin.audio_processor.param_changes = make([][]ParameterChange, len(desc.params))
	}
}


// Processing

DEFAULT_SMOOTH_MS :: f32(5.0)
NO_SMOOTHING :: f32(-1)

// Utilities

// Splits a process block at note event boundaries
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
		changes := actx.param_changes[p]
		for actx.change_indices[p] < len(changes) && changes[actx.change_indices[p]].sample_offset <= i32(sample) {
			dsp.smoother_set_target(&actx.smoothers[p], f32(changes[actx.change_indices[p]].value))
			actx.change_indices[p] += 1
		}
	}
	for &s in actx.smoothers {
		dsp.smoother_next(&s)
	}
}

smoothed_read :: proc(actx: ^AudioProcessContext, param: $P) -> f32 where intrinsics.type_is_enum(P) {
	return actx.smoothers[int(param)].current
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

@test
test_param_table_follows_enum_order :: proc(t: ^testing.T) {
	TestParam :: enum { First, Second }
	// rows out of order on purpose
	table := [TestParam]b.ParamDescriptor {
		.Second = {name = "second"},
		.First = {name = "first"},
	}
	params := param_table(&table)
	testing.expect_value(t, len(params), 2)
	testing.expect_value(t, params[TestParam.First].name, "first")
	testing.expect_value(t, params[TestParam.Second].name, "second")
}
