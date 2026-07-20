// Run a plugin as a native app without a DAW

package standalone_host

import "core:flags"
import "core:log"
import "core:os"
import "core:thread"
import "core:time"
import "base:runtime"
import "base:intrinsics"
import vm "core:mem/virtual"

import hs "../host_shared"
import "../dsp"
import "../sdk"
import plat "../platform_specific"
import "../bridge"

plugin_api: sdk.PluginApi

opts: struct {
	sample_rate: f64 `usage:"Sample rate (default 48000)"`,
	block_size: int `usage:"Block size in samples (default 512)"`,
	no_audio: bool `usage:"Don't run the audio thread"`,
}

MS_PER_FRAME :: 16
MAX_PENDING_PARAM_CHANGES :: 256

PendingParamChange :: struct {
	param_id: i32,
	normalized: f64,
}

StandaloneHost :: struct {
	desc: sdk.PluginDescriptor,
	param_descs: []bridge.ParamDescriptor,

	processor: sdk.PluginProcessor,
	processor_host_ctx: bridge.HostContext,
	processor_params: bridge.ParamValues,
	processor_frame_temp: runtime.Default_Temp_Allocator,
	processor_session_arena: vm.Arena,
	processor_generation: u64,

	controller: sdk.PluginController,
	controller_host_ctx: bridge.HostContext,
	controller_params: bridge.ParamValues,
	platform_api: bridge.PlatformApi,
	host_api: bridge.HostApi,
	controller_frame_temp: runtime.Default_Temp_Allocator,
	controller_session_arena: vm.Arena,
	controller_generation: u64,
	controller_ctx: runtime.Context,
	view_config: sdk.ViewConfig,
	renderer: bridge.Renderer,
	timer: ^plat.Timer,

	// UI thread -> audio thread param handoff
	pending: dsp.RingBuffer(PendingParamChange),
	pending_buf: [MAX_PENDING_PARAM_CHANGES]PendingParamChange,

	audio_thread: ^thread.Thread,
	audio_running: bool,
	sample_rate: f64,
	block_size: i32,
}

run :: proc() {
	flags.parse_or_exit(&opts, os.args)
	if opts.sample_rate <= 0 do opts.sample_rate = 48000
	if opts.block_size <= 0 do opts.block_size = 512

	hs.mutex_log_init(hs.get_config().runtime_folder_path, hs.PLUGIN_NAME)
	context.logger = hs.get_mutex_logger(.PluginFactory)
	log.info("Standalone host starting:", hs.PLUGIN_NAME)

	hs.hotload_init()
	plugin_api = hs.hotload_api()

	host: StandaloneHost
	host.sample_rate = opts.sample_rate
	host.block_size = i32(opts.block_size)
	init_host(&host)

	window := window_create(host.desc.name, host.view_config)
	attach_view(&host, window.parent_view)

	if !opts.no_audio {
		intrinsics.atomic_store_explicit(&host.audio_running, true, .Release)
		host.audio_thread = thread.create(audio_thread_proc)
		host.audio_thread.data = &host
		host.audio_thread.init_context = context
		thread.start(host.audio_thread)
	}

	window_run_event_loop()

	log.info("Standalone host shutting down")
	if host.audio_thread != nil {
		intrinsics.atomic_store_explicit(&host.audio_running, false, .Release)
		thread.join(host.audio_thread)
		thread.destroy(host.audio_thread)
	}
	plugin_api.view_removed(&host.controller)
	plat.timer_stop(host.timer)
	plat.renderer_destroy(host.renderer)
	hs.hotload_deinit()
	hs.mutex_log_exit()
}

// creates processor and controller in one go
init_host :: proc(host: ^StandaloneHost) {
	host.desc = plugin_api.get_plugin_descriptor()
	host.param_descs = host.desc.params

	host.processor_params.values = make([]f64, len(host.param_descs))
	for desc, i in host.param_descs {
		host.processor_params.values[i] = desc.default_value
	}
	host.processor_host_ctx.persistent_allocator = context.allocator
	runtime.default_temp_allocator_init(&host.processor_frame_temp, 1024 * 1024, host.processor_host_ctx.persistent_allocator)
	host.processor_host_ctx.frame_allocator = runtime.default_temp_allocator(&host.processor_frame_temp)
	sess_err := vm.arena_init_growing(&host.processor_session_arena)
	assert(sess_err == .None)
	host.processor_host_ctx.session_allocator = vm.arena_allocator(&host.processor_session_arena)
	host.processor_host_ctx.params = &host.processor_params
	host.processor.host = &host.processor_host_ctx
	sdk.plugin_init_processor(&host.processor)

	dsp.ring_init(&host.pending, host.pending_buf[:])

	host.controller_params.values = make([]f64, len(host.param_descs))
	for desc, i in host.param_descs {
		host.controller_params.values[i] = desc.default_value
	}
	host.controller_host_ctx.persistent_allocator = context.allocator
	runtime.default_temp_allocator_init(&host.controller_frame_temp, 4 * 1024 * 1024, host.controller_host_ctx.persistent_allocator)
	host.controller_host_ctx.frame_allocator = runtime.default_temp_allocator(&host.controller_frame_temp)
	sess_err = vm.arena_init_growing(&host.controller_session_arena)
	assert(sess_err == .None)
	host.controller_host_ctx.session_allocator = vm.arena_allocator(&host.controller_session_arena)
	host.controller_host_ctx.params = &host.controller_params
	host.host_api = bridge.HostApi {
		ctx = bridge.HostHandle(host),
		param_edit_start = sa_param_edit_start,
		param_edit_change = sa_param_edit_change,
		param_edit_end = sa_param_edit_end,
	}
	host.controller_host_ctx.host_api = &host.host_api
	host.controller.host = &host.controller_host_ctx

	host.controller_ctx = context
	host.controller_ctx.logger = hs.get_mutex_logger(.Controller)
	host.controller_ctx.temp_allocator = host.controller_host_ctx.frame_allocator

	host.view_config = sdk.resolve_view_config(host.desc.view)
	host.controller.view_bounds = {0, 0, host.view_config.default_width, host.view_config.default_height}
	sdk.plugin_init_controller(&host.controller)
	plugin_api.setup_controller(&host.controller)
	host.controller_generation = hs.hotload_generation()

	host.processor.controller_peer = &host.controller
	host.controller.processor_peer = &host.processor
}

attach_view :: proc(host: ^StandaloneHost, parent_view: rawptr) {
	bounds := host.controller.view_bounds
	host.renderer = plat.renderer_create(parent_view, bounds.w, bounds.h)

	host.platform_api = bridge.PlatformApi {
		create_texture = plat.renderer_create_texture,
		destroy_texture = plat.renderer_destroy_texture,
		upload_texture = plat.renderer_upload_texture,
		get_white_texture = plat.renderer_get_white_texture,
		get_size = plat.renderer_get_size,
		begin_frame = plat.renderer_begin_frame,
		end_frame = plat.renderer_end_frame,
		upload_instances = plat.renderer_upload_instances,
		begin_pass = plat.renderer_begin_pass,
		end_pass = plat.renderer_end_pass,
		draw = plat.renderer_draw,
	}
	host.controller_host_ctx.platform = &host.platform_api
	host.controller_host_ctx.renderer = host.renderer
	plat.renderer_set_mouse_state(host.renderer, &host.controller.mouse)
	plat.renderer_set_repaint_callback(host.renderer, sa_repaint_callback, host)

	host.controller_host_ctx.font_atlas = plat.renderer_create_texture(host.renderer, sdk.FONT_ATLAS_SIZE, sdk.FONT_ATLAS_SIZE, .R8)

	{
		context = host.controller_ctx
		plugin_api.view_attached(&host.controller)
		host.timer = plat.timer_create(MS_PER_FRAME, sa_timer_proc, host)
		plat.timer_start(host.timer)
	}
}

sa_param_edit_start :: proc(ctx: bridge.HostHandle, param_id: i32) {
}

sa_param_edit_change :: proc(ctx: bridge.HostHandle, param_id: i32, normalized_value: f64) {
	host := cast(^StandaloneHost)ctx
	dsp.ring_try_write(&host.pending, PendingParamChange{param_id, normalized_value})
}

sa_param_edit_end :: proc(ctx: bridge.HostHandle, param_id: i32) {
}

sa_frame :: proc(host: ^StandaloneHost) {
	if host.renderer == nil do return

	gen := hs.hotload_generation()
	if gen != host.controller_generation {
		host.controller_host_ctx.generation = gen
		host.controller_generation = gen
		vm.arena_free_all(&host.controller_session_arena)
		plugin_api.setup_controller(&host.controller)
	}

	// poll the renderer for window resizes
	size := plat.renderer_get_size(host.renderer)
	vb := host.controller.view_bounds
	if size.logical_width != vb.w || size.logical_height != vb.h {
		plugin_api.view_resized(&host.controller, {0, 0, size.logical_width, size.logical_height})
	}

	update_frame_dt(&host.controller)
	plugin_api.draw(&host.controller)

	free_all(context.temp_allocator)
}

sa_timer_proc :: proc(timer: ^plat.Timer) {
	host := cast(^StandaloneHost)timer.data

	// avoid fighting with input callback
	MIN_FRAME_INTERVAL :: MS_PER_FRAME * time.Millisecond
	if time.tick_since(host.controller.last_draw_time) < MIN_FRAME_INTERVAL do return

	sa_frame(host)
}

sa_repaint_callback :: proc "c" (data: rawptr) {
	host := cast(^StandaloneHost)data
	context = host.controller_ctx
	sa_frame(host)
}

update_frame_dt :: proc(plug: ^sdk.PluginController) {
	now := time.tick_now()
	if plug.last_draw_time != (time.Tick{}) {
		dt := f32(time.duration_seconds(time.tick_diff(plug.last_draw_time, now)))
		plug.frame_dt = clamp(dt, 0, 0.1)
	} else {
		plug.frame_dt = f32(MS_PER_FRAME) / 1000
	}
	plug.last_draw_time = now
}

// audio driver is null for now, calls w/ empty buffer
audio_thread_proc :: proc(t: ^thread.Thread) {
	host := cast(^StandaloneHost)t.data
	context.logger = hs.get_mutex_logger(.Processor)
	context.temp_allocator = host.processor_host_ctx.frame_allocator

	actx := host.processor.audio_processor
	actx.sample_rate = host.sample_rate
	actx.max_block_size = host.block_size
	host.processor_generation = hs.hotload_generation()
	plugin_api.setup_processor(&host.processor)

	block := int(host.block_size)
	nch := min(2, host.desc.max_channels)
	is_instrument := host.desc.plugin_type == .Instrument

	alloc := host.processor_host_ctx.persistent_allocator
	silent_inputs := make([][]f32, nch, alloc)
	scratch_outputs := make([][]f32, nch, alloc)
	for c in 0 ..< nch {
		silent_inputs[c] = make([]f32, block, alloc)
		scratch_outputs[c] = make([]f32, block, alloc)
	}
	changes := make([][1]sdk.ParameterChange, len(host.param_descs), alloc)
	drained: [MAX_PENDING_PARAM_CHANGES]PendingParamChange

	block_dur := time.Duration(f64(host.block_size) / host.sample_rate * f64(time.Second))
	next := time.tick_now()
	sample_pos: i64

	for intrinsics.atomic_load_explicit(&host.audio_running, .Acquire) {
		gen := hs.hotload_generation()
		if gen != host.processor_generation {
			host.processor_host_ctx.generation = gen
			host.processor_generation = gen
			vm.arena_free_all(&host.processor_session_arena)
			plugin_api.setup_processor(&host.processor)
		}

		for i in 0 ..< len(actx.param_changes) {
			actx.param_changes[i] = nil
		}
		for i in 0 ..< len(actx.change_indices) {
			actx.change_indices[i] = 0
		}

		n := dsp.ring_read(&host.pending, drained[:])
		for p in drained[:n] {
			idx := int(p.param_id)
			if idx < 0 || idx >= len(host.param_descs) do continue
			plain := bridge.normalized_to_param(p.normalized, host.param_descs[idx])
			host.processor_params.values[idx] = plain
			changes[idx][0] = {sample_offset = 0, value = plain}
			actx.param_changes[idx] = changes[idx][:1]
		}

		actx.events = nil
		actx.project_time_samples = sample_pos
		actx.transport.valid = {.SamplePosition, .Playing}
		actx.transport.sample_position = sample_pos
		actx.transport.playing = false

		actx.num_channels = nch
		actx.num_samples = block
		for c in 0 ..< nch {
			actx.outputs[c] = scratch_outputs[c][:]
			actx.inputs[c] = nil if is_instrument else silent_inputs[c][:]
		}

		plugin_api.process_audio(&host.processor)
		free_all(context.temp_allocator)

		sample_pos += i64(block)

		// resync if we stall
		next._nsec += i64(block_dur)
		now := time.tick_now()
		if next._nsec < now._nsec - i64(100 * time.Millisecond) {
			next = now
		} else if next._nsec > now._nsec {
			time.sleep(time.Duration(next._nsec - now._nsec))
		}
	}
}
