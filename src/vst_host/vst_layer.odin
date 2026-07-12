//-----------------------------------------------------------------------------
// VST3 Plugin Implementation Layer
// This file interfaces with the VST3 SDK
// VST3 SDK Copyright (c) 2024, Steinberg Media Technologies GmbH
// Licensed under MIT License
// See: https://github.com/steinbergmedia/vst3sdk
//-----------------------------------------------------------------------------

package platform

import "core:c"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:unicode/utf16"
import "core:thread"
import "base:runtime"
import "base:builtin"
import "core:log"
import "core:time"
import "core:hash"
import "core:sys/windows"
import vm "core:mem/virtual"

import "../thirdparty/vst3"

import hs "../host_shared"
import "../sdk"
import plat "../platform_specific"
import "../bridge"

lindale_processor_cid := vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4)
lindale_controller_cid := vst3.SMTG_INLINE_UID(0x1DD0528c, 0x269247AA, 0x85210051, 0xDAB98786)

// Used in establishing connection between processor and controller.
lindale_connection_cid := vst3.SMTG_INLINE_UID(0xf51b3ac9, 0xb51e4e72, 0xbf2e3049, 0x787e8d4f)

// Per-plugin UID: byte [13] marks the Lindale family, bytes [14..16)
// carry a hash of the plugin token so each plugin reports distinct class UIDs.
patch_cid_for_plugin :: proc(cid: ^vst3.TUID, plugin: string) {
	h := hash.fnv32a(transmute([]byte)plugin)
	h16 := u16(h) ~ u16(h >> 16)
	cid[13] = 0x4C // 'L': Lindalë framework family
	cid[14] = u8(h16 >> 8)
	cid[15] = u8(h16)
}

LindalePluginFactory :: struct {
	vtable_ptr: vst3.IPluginFactory3,
	vtable: vst3.IPluginFactory3Vtbl,
	initialized: bool,
	ctx: runtime.Context,
	desc: sdk.PluginDescriptor,
}

plugin_factory: LindalePluginFactory
plugin_api: sdk.PluginApi

when ODIN_OS == .Darwin {
	@export bundleEntry :: proc "system" (bundle_ref: rawptr) -> c.bool {
		context = runtime.default_context()
		return true
	}

	@export bundleExit :: proc "system" () -> c.bool {
		context = plugin_factory.ctx
		log.info("bundleExit")
		deinit()
		return true
	}
} else when ODIN_OS == .Linux {
	@export ModuleEntry :: proc "system" () -> c.bool {
		context = runtime.default_context()
		log.info("ModuleEntry")
		return true
	}

	@export ModuleExit :: proc "system" () -> c.bool {
		context = plugin_factory.ctx
		log.info("ModuleExit")
		deinit()
		return true
	}
} else when ODIN_OS == .Windows {
	@export InitDll :: proc "system" () -> c.bool {
		context = runtime.default_context()
		return true
	}

	@export ExitDll :: proc "system" () -> c.bool {
		context = plugin_factory.initialized ? plugin_factory.ctx : runtime.default_context()
		log.info("ExitDll")
		deinit()
		return true
	}
}

deinit :: proc() {
	log.info("Deinitializing")
	hs.hotload_deinit()
	hs.mutex_log_exit()
}

LindaleProcessor :: struct {
	component: vst3.IComponent,
	component_vtable: vst3.IComponentVtbl,
	audio_processor: vst3.IAudioProcessor,
	audio_processor_vtable: vst3.IAudioProcessorVtbl,
	process_context_requirements: vst3.IProcessContextRequirements,
	process_context_requirements_vtable: vst3.IProcessContextRequirementsVtbl,
	connection_point: vst3.IConnectionPoint,
	connection_point_vtable: vst3.IConnectionPointVtbl,

	ref_count: u32,

	controller_link: ^LindaleController,

	plugin: sdk.PluginProcessor,
	host_ctx: bridge.HostContext,
	param_descs: []bridge.ParamDescriptor,
	param_values: bridge.ParamValues,
	bypass_param_idx: int,
	bypassed: bool,

	peer: ^vst3.IConnectionPoint,
	host_application: ^vst3.IHostApplication,
	host_context: ^vst3.FUnknown,
	ctx: runtime.Context,

	frame_temp: runtime.Default_Temp_Allocator,
	session_arena: vm.Arena,
	last_generation: u64,
}

BYPASS_PARAM_DESC :: bridge.ParamDescriptor {
	name = "Bypass", short_name = "Byp",
	min = 0.0, max = 1.0, default_value = 0.0,
	step_count = 1, unit = .Normalized,
	flags = {.Automatable},
}

create_lindale_processor :: proc() -> ^LindaleProcessor {
	log.info("create_lindale_processor")
	processor := new(LindaleProcessor)
	processor.ref_count = 0

	processor.component_vtable = {
		queryInterface = lp_comp_queryInterface,
		addRef = lp_comp_addRef,
		release = lp_comp_release,

		initialize = lp_comp_initialize,
		terminate = lp_comp_terminate,

		getControllerClassId = lp_comp_getControllerClassId,
		setIoMode = lp_comp_setIoMode,
		getBusCount = lp_comp_getBusCount,
		getBusInfo = lp_comp_getBusInfo,
		getRoutingInfo = lp_comp_getRoutingInfo,
		activateBus = lp_comp_activateBus,
		setActive = lp_comp_setActive,
		setState = lp_comp_setState,
		getState = lp_comp_getState,
	}
	processor.component.lpVtbl = &processor.component_vtable

	processor.audio_processor_vtable = {
		queryInterface = lp_ap_queryInterface,
		addRef = lp_ap_addRef,
		release = lp_ap_release,

		setBusArrangements = lp_ap_setBusArrangements,
		getBusArrangement = lp_ap_getBusArrangement,
		canProcessSampleSize = lp_ap_canProcessSampleSize,
		getLatencySamples = lp_ap_getLatencySamples,
		setupProcessing = lp_ap_setupProcessing,
		setProcessing = lp_ap_setProcessing,
		process = lp_ap_process,
		getTailSamples = lp_ap_getTailSamples,
	}
	processor.audio_processor.lpVtbl = &processor.audio_processor_vtable

	processor.process_context_requirements_vtable = {
		queryInterface = lp_pcr_queryInterface,
		addRef = lp_pcr_addRef,
		release = lp_pcr_release,
		getProcessContextRequirements = lp_pcr_getProcessContextRequirements,
	}
	processor.process_context_requirements.lpVtbl = &processor.process_context_requirements_vtable

	processor.connection_point_vtable = {
		queryInterface = lp_cp_queryInterface,
		addRef = lp_cp_addRef,
		release = lp_cp_release,

		connect = lp_cp_connect,
		disconnect = lp_cp_disconnect,
		notify = lp_cp_notify,
	}
	processor.connection_point.lpVtbl = &processor.connection_point_vtable

	processor.ctx = context
	processor.ctx.logger = hs.get_mutex_logger(.Processor)

	// Init params, and append bypass parameter
	descs := plugin_api.get_plugin_descriptor().params
	processor.param_descs = make([]bridge.ParamDescriptor, len(descs) + 1)
	copy(processor.param_descs, descs)
	processor.bypass_param_idx = len(descs)
	processor.param_descs[processor.bypass_param_idx] = BYPASS_PARAM_DESC
	processor.param_values.values = make([]f64, len(processor.param_descs))
	for desc, i in processor.param_descs {
		processor.param_values.values[i] = desc.default_value
	}

	processor.host_ctx.persistent_allocator = context.allocator

	runtime.default_temp_allocator_init(&processor.frame_temp, 1024 * 1024, processor.host_ctx.persistent_allocator)
	processor.host_ctx.frame_allocator = runtime.default_temp_allocator(&processor.frame_temp)
	processor.ctx.temp_allocator = processor.host_ctx.frame_allocator

	sess_err := vm.arena_init_growing(&processor.session_arena)
	assert(sess_err == .None)
	processor.host_ctx.session_allocator = vm.arena_allocator(&processor.session_arena)

	processor.host_ctx.params = &processor.param_values
	processor.plugin.host = &processor.host_ctx
	sdk.plugin_init_processor(&processor.plugin)

	return processor

	// Universal LindaleProcessor queryInterface
	lp_queryInterfaceImplementation :: proc(this: ^LindaleProcessor, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		log.debug("iid: {:x}", iid)
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IComponent || iid^ == vst3.iid_IPluginBase {
			obj^ = &this.component
		} else if  iid^ == vst3.iid_IAudioProcessor {
			obj^ = &this.audio_processor
		} else if iid^ == vst3.iid_IProcessContextRequirements {
			obj^ = &this.process_context_requirements
		} else if iid^ == vst3.iid_IConnectionPoint {
			obj^ = &this.connection_point
		} else if iid^ == lindale_connection_cid {
			obj^ = this
			return vst3.kResultOk // Skip ref count for connection
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		this.ref_count += 1

		return vst3.kResultOk
	}

	lp_releaseImplementation :: proc(this: ^LindaleProcessor) -> u32 {
		this.ref_count -= 1
		if this.ref_count == 0 {
			log.info("LindaleProcessor teardown")
			if this.host_application != nil {
				this.host_application->release()
			}
			if this.host_context != nil {
				this.host_context->release()
			}
			runtime.default_temp_allocator_destroy(&this.frame_temp)
			vm.arena_destroy(&this.session_arena)
			free(this)
			return 0
		}
		return this.ref_count
	}

	// IComponent
	lp_comp_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_queryInterface")

		return lp_queryInterfaceImplementation(processor, iid, obj)
	}
	lp_comp_addRef :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_addRef")
		processor.ref_count += 1
		return processor.ref_count
	}
	lp_comp_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_release")
		return lp_releaseImplementation(processor)
	}
	lp_comp_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		processor.host_context = ctx
		if ctx != nil {
			ctx->addRef()
			host_app : rawptr
			if ctx->queryInterface(&vst3.iid_IHostApplication, &host_app) == vst3.kResultOk {
				processor.host_application = cast(^vst3.IHostApplication)host_app
			}
		}
		log.info("lp_comp_initialize")
		return vst3.kResultOk
	}
	lp_comp_terminate :: proc "system" (this: rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_terminate")
		return vst3.kResultOk
	}
	lp_comp_getControllerClassId :: proc "system" (this: rawptr, classId: ^vst3.TUID) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_getControllerClassId")
		classId^ = lindale_controller_cid
		return vst3.kResultOk
	}
	lp_comp_setIoMode :: proc "system" (this: rawptr, mode: vst3.IoMode) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_comp_getBusCount :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection) -> i32 {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_getBusCount")
		is_instrument := plugin_factory.desc.plugin_type == .Instrument
		if type == .Audio {
			if dir == .Input {
				return is_instrument ? 0 : 1
			}
			if dir == .Output {
				return 1
			}
		}
		if type == .Event {
			if dir == .Input && is_instrument {
				return 1
			}
		}
		return 0
	}
	lp_comp_getBusInfo :: proc "system" (
		this: rawptr,
		type: vst3.MediaType,
		dir: vst3.BusDirection,
		index: i32,
		bus: ^vst3.BusInfo
	) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_getBusInfo")

		if index != 0 do return vst3.kInvalidArgument

		is_instrument := plugin_factory.desc.plugin_type == .Instrument

		if type == .Audio {
			if is_instrument && dir == .Input do return vst3.kInvalidArgument
			bus.mediaType = type
			bus.direction = dir
			bus.channelCount = 2
			utf16.encode_string(bus.name[:], "Main")
			bus.busType = .Main
			bus.flags = u32(vst3.BusFlags.kDefaultActive)
			return vst3.kResultOk
		}

		if type == .Event && dir == .Input && is_instrument {
			bus.mediaType = type
			bus.direction = dir
			bus.channelCount = 1
			utf16.encode_string(bus.name[:], "Event In")
			bus.busType = .Main
			bus.flags = u32(vst3.BusFlags.kDefaultActive)
			return vst3.kResultOk
		}

		return vst3.kInvalidArgument
	}
	lp_comp_getRoutingInfo :: proc "system" (this: rawptr, inInfo, outInfo: ^vst3.RoutingInfo) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_getRoutingInfo")
		return vst3.kResultOk
	}
	lp_comp_activateBus :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection, index: i32, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_comp_setActive :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		if state == 0 && plugin_api.reset != nil {
			plugin_api.reset(&processor.plugin)
		}
		return vst3.kResultOk
	}
	lp_comp_setState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		end_pos: i64
		state.seek(state, 0, 2, &end_pos) // SEEK_END
		state.seek(state, 0, 0, nil)       // SEEK_SET
		if end_pos <= 0 do return vst3.kResultOk
		data := make([]u8, end_pos)
		defer delete(data)
		bytes_read: i32
		state.read(state, raw_data(data), i32(end_pos), &bytes_read)
		hs.deserialize_params(processor.param_descs, &processor.param_values, data[:bytes_read])
		return vst3.kResultOk
	}
	lp_comp_getState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		data, ok := hs.serialize_params(processor.param_descs, &processor.param_values)
		if !ok do return vst3.kResultFalse
		defer delete(data)
		written: i32
		state.write(state, raw_data(data), i32(len(data)), &written)
		return vst3.kResultOk
	}

	// IAudioProcessor
	lp_ap_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		log.info("lp_ap_queryInterface")

		return lp_queryInterfaceImplementation(processor, iid, obj)
	}
	lp_ap_addRef :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		log.info("lp_ap_addRef")
		processor.ref_count += 1
		return processor.ref_count
	}
	lp_ap_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		log.info("lp_ap_release")
		return lp_releaseImplementation(processor)
	}
	lp_ap_setBusArrangements :: proc "system" (
		this: rawptr,
		inputs: ^vst3.SpeakerArrangement,
		numIns: i32,
		outputs: ^vst3.SpeakerArrangement,
		numOuts: i32
	) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_ap_getBusArrangement :: proc "system" (
		this: rawptr,
		dir: vst3.BusDirection,
		index: i32,
		arr: ^vst3.SpeakerArrangement
	) -> vst3.TResult {
		if arr == nil do return vst3.kInvalidArgument

		if index == 0 {
			arr^ = vst3.kStereo
		}
		return vst3.kResultOk
	}
	lp_ap_canProcessSampleSize :: proc "system" (this: rawptr, sss: vst3.SymbolicSampleSize) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		log.info("lp_ap_canProcessSampleSize")
		if sss == .Sample32 {
			return vst3.kResultOk
		}
		return vst3.kNotImplemented
	}
	lp_ap_getLatencySamples :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		return plugin_api.get_latency_samples(&processor.plugin)
	}
	lp_ap_setupProcessing :: proc "system" (this: rawptr, setup: ^vst3.ProcessSetup) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		log.info("lp_ap_setupProcessing")

		processor.plugin.audio_processor.sample_rate = setup.sampleRate
		processor.plugin.audio_processor.max_block_size = setup.maxSamplesPerBlock
		vm.arena_free_all(&processor.session_arena)
		plugin_api.setup_processor(&processor.plugin)

		return vst3.kResultOk
	}
	lp_ap_setProcessing :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_ap_process :: proc "system" (this: rawptr, data: ^vst3.ProcessData) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx

		num_samples := data.numSamples
		num_inputs := data.numInputs
		num_outputs := data.numOutputs
		outputs := data.outputs
		inputs := data.inputs

		param_changes := make([][64]sdk.ParameterChange, len(processor.param_descs), context.temp_allocator)

		audio_context := processor.plugin.audio_processor
		if data.processContext != nil {
			pc := data.processContext
			audio_context.sample_rate = pc.sampleRate
			audio_context.project_time_samples = pc.projectTimeSamples

			state_flags := transmute(vst3.ProcessingStatesFlagsSet)pc.state
			transport := &audio_context.transport
			transport.valid = {}

			transport.playing = .kPlaying in state_flags
			transport.valid += {.Playing}

			if .kTempoValid in state_flags {
				transport.tempo = pc.tempo
				transport.valid += {.Tempo}
			}
			if .kTimeSigValid in state_flags {
				transport.time_sig_numerator = pc.timeSigNumerator
				transport.time_sig_denominator = pc.timeSigDenominator
				transport.valid += {.TimeSig}
			}
			if .kProjectTimeMusicValid in state_flags {
				transport.beat_position = pc.projectTimeMusic
				transport.valid += {.BeatPosition}
			}
			if .kBarPositionValid in state_flags {
				transport.bar_position = pc.barPositionMusic
				transport.valid += {.BarPosition}
			}
			transport.sample_position = pc.projectTimeSamples
			transport.valid += {.SamplePosition}

			transport.cycle_active = .kCycleActive in state_flags
			transport.valid += {.CycleActive}

			if .kCycleValid in state_flags {
				transport.cycle_start = pc.cycleStartMusic
				transport.cycle_end = pc.cycleEndMusic
				transport.valid += {.CyclePoints}
			}
		}

		// Clear stale param_changes slices (they pointed into previous call's temp memory)
		for i in 0 ..< len(audio_context.param_changes) {
			audio_context.param_changes[i] = nil
		}

		// Reset change indices for param advancement
		for i in 0 ..< len(audio_context.change_indices) {
			audio_context.change_indices[i] = 0
		}

		// Fetch parameter updates: convert normalized host values to plain before storing
		if data.inputParameterChanges != nil && data.inputParameterChanges.lpVtbl != nil {
			param_count := data.inputParameterChanges->getParameterCount()
			for i in 0..<param_count {
				param_queue := data.inputParameterChanges->getParameterData(i)
				if param_queue != nil && param_queue.lpVtbl != nil {
					param_idx := int(param_queue->getParameterId())
					if param_idx < 0 || param_idx >= len(processor.param_descs) do continue

					// Bypass param is handled by the static layer, not forwarded
					if param_idx == processor.bypass_param_idx {
						point_count := param_queue->getPointCount()
						if point_count > 0 {
							sample_offs: i32
							norm_param: f64
							param_queue->getPoint(point_count - 1, &sample_offs, &norm_param)
							processor.bypassed = norm_param > 0.5
							processor.param_values.values[param_idx] = norm_param > 0.5 ? 1.0 : 0.0
						}
						continue
					}

					point_count := param_queue->getPointCount()
					if point_count > 0 {
						actual_count := 0
						for i in 0..< point_count {
							sample_offs: i32
							norm_param : f64
							result := param_queue->getPoint(i, &sample_offs, &norm_param)
							if result == vst3.kResultOk {
								plain_val := bridge.normalized_to_param(norm_param, processor.param_descs[param_idx])
								processor.param_values.values[param_idx] = plain_val
								param_changes[param_idx][actual_count] = sdk.ParameterChange {
									sample_offset = sample_offs,
									value = plain_val,
								}
								actual_count += 1
							}
						}
						audio_context.param_changes[param_idx] = param_changes[param_idx][:actual_count]
					}
				}
			}
		}

		// Translate VST3 events to bridge event types
		audio_context.events = nil
		if data.inputEvents != nil && data.inputEvents.lpVtbl != nil {
			event_count := data.inputEvents->getEventCount()
			if event_count > 0 {
				bridge_events := make([]bridge.Event, event_count, context.temp_allocator)
				actual_count: i32 = 0
				for i in 0 ..< event_count {
					vst3_event: vst3.Event
					if data.inputEvents->getEvent(i, &vst3_event) != vst3.kResultOk do continue
					// VST3 event type constants: 0=NoteOn, 1=NoteOff, 65535=LegacyMIDICCOut
					switch vst3_event.type {
					case 0: // kNoteOnEvent
						bridge_events[actual_count] = {
							sample_offset = vst3_event.sampleOffset,
							kind = .NoteOn,
						}
						bridge_events[actual_count].note_on = {
							note_id = vst3_event.noteOn.noteId,
							channel = vst3_event.noteOn.channel,
							pitch = vst3_event.noteOn.pitch,
							tuning = vst3_event.noteOn.tuning,
							velocity = vst3_event.noteOn.velocity,
						}
						actual_count += 1
					case 1: // kNoteOffEvent
						bridge_events[actual_count] = {
							sample_offset = vst3_event.sampleOffset,
							kind = .NoteOff,
						}
						bridge_events[actual_count].note_off = {
							note_id = vst3_event.noteOff.noteId,
							channel = vst3_event.noteOff.channel,
							pitch = vst3_event.noteOff.pitch,
							velocity = vst3_event.noteOff.velocity,
						}
						actual_count += 1
					case 65535: // kLegacyMIDICCOutEvent
						// TODO: Some hosts send pitch bend via NoteExpression instead of legacy MIDI.
						// May need IMidiMapping or NoteExpressionValueEvent for full host compatibility.
						if vst3_event.midiCCOut.controlNumber == 128 {
							// Pack 14-bit value from two 7-bit bytes for pitch bend
							raw := i32(u8(vst3_event.midiCCOut.value)) | (i32(u8(vst3_event.midiCCOut.value2)) << 7)
							normalized := clamp(f32(raw - 8192) / 8192.0, -1, 1)
							bridge_events[actual_count] = {
								sample_offset = vst3_event.sampleOffset,
								kind = .PitchBend,
							}
							bridge_events[actual_count].pitch_bend = {
								channel = i16(vst3_event.midiCCOut.channel),
								value = normalized,
							}
							actual_count += 1
						} else {
							bridge_events[actual_count] = {
								sample_offset = vst3_event.sampleOffset,
								kind = .CC,
							}
							bridge_events[actual_count].cc = {
								channel = i16(vst3_event.midiCCOut.channel),
								controller = i16(vst3_event.midiCCOut.controlNumber),
								value = f32(u8(vst3_event.midiCCOut.value)) / 127.0,
							}
							actual_count += 1
						}
					case:
						// Skip unrecognized event types
					}
				}
				if num_samples > 0 {
					for i in 0 ..< actual_count {
						bridge_events[i].sample_offset = clamp(bridge_events[i].sample_offset, 0, i32(num_samples - 1))
					}
					audio_context.events = bridge_events[:actual_count]
				}
			}
		}

		gen := hs.hotload_generation()
		if gen != processor.last_generation {
			processor.host_ctx.generation = gen
			processor.last_generation = gen
			vm.arena_free_all(&processor.session_arena)
			plugin_api.setup_processor(&processor.plugin)
		}

		audio_context.num_channels = 0
		audio_context.num_samples = 0

		// Write flat f32 buffer slices into the audio context (bus 0 only)
		desc := plugin_api.get_plugin_descriptor()
		if num_outputs > 0 {
			output := outputs[0]
			nc := min(int(output.numChannels), desc.max_channels)
			audio_context.num_channels = nc
			audio_context.num_samples = int(num_samples)
			for c in 0 ..< nc {
				audio_context.outputs[c] = output.channelBuffers32[c][:num_samples]
			}
		}
		if num_inputs > 0 {
			input := inputs[0]
			nc := min(int(input.numChannels), desc.max_channels)
			for c in 0 ..< nc {
				audio_context.inputs[c] = input.channelBuffers32[c][:num_samples]
			}
		} else {
			for c in 0 ..< audio_context.num_channels {
				audio_context.inputs[c] = nil
			}
		}

		// Bypass: copy input to output where possible, zero the rest
		if processor.bypassed {
			for i in 0 ..< min(num_inputs, num_outputs) {
				input := inputs[i]
				output := outputs[i]
				channels := min(input.numChannels, output.numChannels)
				for c in 0 ..< channels {
					for s in 0 ..< num_samples {
						output.channelBuffers32[c][s] = input.channelBuffers32[c][s]
					}
				}
				for c in channels ..< output.numChannels {
					for s in 0 ..< num_samples {
						output.channelBuffers32[c][s] = 0
					}
				}
			}
			for i in num_inputs ..< num_outputs {
				output := outputs[i]
				for c in 0 ..< output.numChannels {
					for s in 0 ..< num_samples {
						output.channelBuffers32[c][s] = 0
					}
				}
			}
			free_all(context.temp_allocator)
			return vst3.kResultOk
		}

		plugin_api.process_audio(&processor.plugin)
		free_all(context.temp_allocator)

		return vst3.kResultOk
	}
	lp_ap_getTailSamples :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audio_processor")
		context = processor.ctx
		return plugin_api.get_tail_samples(&processor.plugin)
	}

	// IProcessContextRequirements
	lp_pcr_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "process_context_requirements")
		context = processor.ctx
		log.info("lp_pcr_queryInterface")

		return lp_queryInterfaceImplementation(processor, iid, obj)
	}

	lp_pcr_addRef :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "process_context_requirements")
		context = processor.ctx
		log.info("lp_pcr_addRef")
		processor.ref_count += 1
		return processor.ref_count
	}

	lp_pcr_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "process_context_requirements")
		context = processor.ctx
		log.info("lp_pcr_release")
		return lp_releaseImplementation(processor)
	}

	lp_pcr_getProcessContextRequirements :: proc "system" (this: rawptr) -> vst3.IProcessContextRequirementsFlagSet {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "process_context_requirements")
		context = processor.ctx
		log.info("lp_getProcessContextRequirements")

		return {
			.NeedTempo,
			.NeedTimeSignature,
			.NeedTransportState,
			.NeedProjectTimeMusic,
			.NeedBarPositionMusic,
			.NeedCycleMusic,
		}
	}
	lp_cp_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IConnectionPoint)this, LindaleProcessor, "connection_point")
		context = processor.ctx
		log.info("lp_cp_queryInterface")

		return lp_queryInterfaceImplementation(processor, iid, obj)
	}
	lp_cp_addRef :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IConnectionPoint)this, LindaleProcessor, "connection_point")
		context = processor.ctx
		log.info("lp_cp_addRef")
		processor.ref_count += 1
		return processor.ref_count
	}
	lp_cp_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IConnectionPoint)this, LindaleProcessor, "connection_point")
		context = processor.ctx
		log.info("lp_cp_release")
		return lp_releaseImplementation(processor)
	}
	lp_cp_connect :: proc "system" (this: rawptr, other: ^vst3.IConnectionPoint) -> vst3.TResult {
		processor := container_of(cast(^vst3.IConnectionPoint)this, LindaleProcessor, "connection_point")
		context = processor.ctx
		log.info("lp_cp_connect")
		processor.peer = other
		return vst3.kResultOk
	}
	lp_cp_disconnect :: proc "system" (this: rawptr, other: ^vst3.IConnectionPoint) -> vst3.TResult {
		processor := container_of(cast(^vst3.IConnectionPoint)this, LindaleProcessor, "connection_point")
		context = processor.ctx
		log.info("lp_cp_disconnect")
		processor.peer = nil
		return vst3.kResultOk
	}
	// Notify may run on any thread: funnel anything bound for the audio path through a
	// lock-free queue drained at the top of lp_ap_process, never touch processor.plugin here.
	lp_cp_notify :: proc "system" (this: rawptr, message: ^vst3.IMessage) -> vst3.TResult {
		processor := container_of(cast(^vst3.IConnectionPoint)this, LindaleProcessor, "connection_point")
		context = processor.ctx
		id := message->getMessageID()
		if runtime.cstring_eq(id, "LindaleVST3EditController") {
			val: i64 = 0
			if message->getAttributes()->getInt("LindaleVST3EditController", &val) == vst3.kResultOk {
				if val != 0 {
					processor.controller_link = transmute(^LindaleController)(val)
					processor.controller_link.processor_link = processor
					// Wire up user-visible links
					processor.plugin.controller_peer = &processor.controller_link.plugin
					processor.controller_link.plugin.processor_peer = &processor.plugin

					log.info("Notify: Link to controller established in processor notify.")
				}
			}
		}
		log.info("lp_cp_notify: {}", id)
		return vst3.kResultOk
	}
}

LindaleController :: struct {
	edit_controller: vst3.IEditController,
	edit_controller_vtable: vst3.IEditControllerVtbl,
	edit_controller2: vst3.IEditController2,
	edit_controller2_vtable: vst3.IEditController2Vtbl,
	connection_point: vst3.IConnectionPoint,
	connection_point_vtable: vst3.IConnectionPointVtbl,

	ref_count: u32,

	processor_link: ^LindaleProcessor,

	plugin: sdk.PluginController,
	host_ctx: bridge.HostContext,
	platform_api: bridge.PlatformApi,
	host_api: bridge.HostApi,
	param_descs: []bridge.ParamDescriptor,
	param_values: bridge.ParamValues,
	bypass_param_idx: int,

	peer: ^vst3.IConnectionPoint,
	host_application: ^vst3.IHostApplication,
	host_context: ^vst3.FUnknown,
	component_handler: ^vst3.IComponentHandler,
	ctx: runtime.Context,
	view: LindaleView,
	view_config: sdk.ViewConfig,

	frame_temp: runtime.Default_Temp_Allocator,
	session_arena: vm.Arena,
	last_generation: u64,
}

create_lindale_controller :: proc () -> ^LindaleController {
	log.info("create_lindale_controller")
	controller := new(LindaleController)
	controller.ref_count = 0

	controller.edit_controller_vtable = {
		queryInterface = lc_ec_queryInterface,
		addRef = lc_ec_addRef,
		release = lc_ec_release,

		initialize = lc_ec_initialize,
		terminate = lc_ec_terminate,

		setComponentState = lc_ec_setComponentState,
		setState = lc_ec_setState,
		getState = lc_ec_getState,
		getParameterCount = lc_ec_getParameterCount,
		getParameterInfo = lc_ec_getParameterInfo,
		getParamStringByValue = lc_ec_getParamStringByValue,
		getParamValueByString = lc_ec_getParamValueByString,
		normalizedParamToPlain = lc_ec_normalizedParamToPlain,
		plainParamToNormalized = lc_ec_plainParamToNormalized,
		getParamNormalized = lc_ec_getParamNormalized,
		setParamNormalized = lc_ec_setParamNormalized,
		setComponentHandler = lc_ec_setComponentHandler,
		createView = lc_ec_createView,
	}
	controller.edit_controller.lpVtbl = &controller.edit_controller_vtable

	controller.edit_controller2_vtable = {
		queryInterface = lc_ec2_queryInterface,
		addRef = lc_ec2_addRef,
		release = lc_ec2_release,

		setKnobMode = lc_ec2_setKnobMode,
		openHelp = lc_ec2_openHelp,
		openAboutBox = lc_ec2_openAboutBox,
	}
	controller.edit_controller2.lpVtbl = &controller.edit_controller2_vtable

	controller.connection_point_vtable = {
		queryInterface = lc_cp_queryInterface,
		addRef = lc_cp_addRef,
		release = lc_cp_release,

		connect = lc_cp_connect,
		disconnect = lc_cp_disconnect,
		notify = lc_cp_notify,
	}
	controller.connection_point.lpVtbl = &controller.connection_point_vtable

	controller.ctx = context
	controller.ctx.logger = hs.get_mutex_logger(.Controller)

	// Init params, and append bypass parameter
	descs := plugin_api.get_plugin_descriptor().params
	controller.param_descs = make([]bridge.ParamDescriptor, len(descs) + 1)
	copy(controller.param_descs, descs)
	controller.bypass_param_idx = len(descs)
	controller.param_descs[controller.bypass_param_idx] = BYPASS_PARAM_DESC
	controller.param_values.values = make([]f64, len(controller.param_descs))
	for desc, i in controller.param_descs {
		controller.param_values.values[i] = desc.default_value
	}

	controller.host_ctx.persistent_allocator = context.allocator

	runtime.default_temp_allocator_init(&controller.frame_temp, 4 * 1024 * 1024, controller.host_ctx.persistent_allocator)
	controller.host_ctx.frame_allocator = runtime.default_temp_allocator(&controller.frame_temp)
	controller.ctx.temp_allocator = controller.host_ctx.frame_allocator

	sess_err := vm.arena_init_growing(&controller.session_arena)
	assert(sess_err == .None)
	controller.host_ctx.session_allocator = vm.arena_allocator(&controller.session_arena)

	controller.host_ctx.params = &controller.param_values
	controller.host_api = bridge.HostApi {
		ctx = bridge.HostHandle(controller),
		param_edit_start = lc_host_param_edit_start,
		param_edit_change = lc_host_param_edit_change,
		param_edit_end = lc_host_param_edit_end,
	}
	controller.host_ctx.host_api = &controller.host_api
	controller.plugin.host = &controller.host_ctx

	controller.view_config = sdk.resolve_view_config(plugin_api.get_plugin_descriptor().view)
	controller.plugin.view_bounds = {0, 0, controller.view_config.default_width, controller.view_config.default_height}

	sdk.plugin_init_controller(&controller.plugin)
	plugin_api.setup_controller(&controller.plugin)

	return controller

	lc_host_param_edit_start :: proc(ctx: bridge.HostHandle, param_id: i32) {
		controller := cast(^LindaleController)ctx
		context = controller.ctx
		if controller.component_handler == nil do return
		controller.component_handler->beginEdit(u32(param_id))
	}

	lc_host_param_edit_change :: proc(ctx: bridge.HostHandle, param_id: i32, normalized_value: f64) {
		controller := cast(^LindaleController)ctx
		context = controller.ctx
		if controller.component_handler == nil do return
		controller.component_handler->performEdit(u32(param_id), normalized_value)
	}

	lc_host_param_edit_end :: proc(ctx: bridge.HostHandle, param_id: i32) {
		controller := cast(^LindaleController)ctx
		context = controller.ctx
		if controller.component_handler == nil do return
		controller.component_handler->endEdit(u32(param_id))
	}

	lc_queryInterface :: proc (this: ^LindaleController, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IEditController || iid^ == vst3.iid_IPluginBase {
			obj^ = &this.edit_controller
		} else if iid^ == vst3.iid_IEditController2 {
			obj^ = &this.edit_controller2
		} else if iid^ == vst3.iid_IConnectionPoint {
			obj^ = &this.connection_point
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		this.ref_count += 1
		return vst3.kResultOk
	}

	lc_releaseImplementation :: proc(this: ^LindaleController) -> u32 {
		this.ref_count -= 1
		if this.ref_count == 0 {
			log.info("LindaleController teardown")
			if this.host_application != nil {
				this.host_application->release()
			}
			if this.host_context != nil {
				this.host_context->release()
			}
			runtime.default_temp_allocator_destroy(&this.frame_temp)
			vm.arena_destroy(&this.session_arena)
			free(this)
			return 0
		}
		return this.ref_count
	}

	// EditController
	lc_ec_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		log.info("lc_ec_queryInterface")

		return lc_queryInterface(controller, iid, obj)
	}
	lc_ec_addRef :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		log.info("lc_ec_addRef")
		controller.ref_count += 1
		return controller.ref_count
	}
	lc_ec_release :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		log.info("lc_ec_release")
		return lc_releaseImplementation(controller)
	}
	lc_ec_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		log.info("lc_ec_initialize")
		controller.host_context = ctx
		if ctx != nil {
			ctx->addRef()
			host_app: rawptr
			if ctx->queryInterface(&vst3.iid_IHostApplication, &host_app) == vst3.kResultOk {
				controller.host_application = cast(^vst3.IHostApplication)host_app
			}
		}
		return vst3.kResultOk
	}
	lc_ec_terminate  :: proc "system" (this: rawptr) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_setComponentState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		end_pos: i64
		state.seek(state, 0, 2, &end_pos) // SEEK_END
		state.seek(state, 0, 0, nil)       // SEEK_SET
		if end_pos <= 0 do return vst3.kResultOk
		data := make([]u8, end_pos)
		defer delete(data)
		bytes_read: i32
		state.read(state, raw_data(data), i32(end_pos), &bytes_read)
		hs.deserialize_params(controller.param_descs, &controller.param_values, data[:bytes_read])
		return vst3.kResultOk
	}
	lc_ec_setState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_getState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_getParameterCount :: proc "system" (this: rawptr) -> i32 {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		return i32(len(controller.param_descs))
	}
	lc_ec_getParameterInfo :: proc "system" (this: rawptr, paramIndex: i32, info: ^vst3.ParameterInfo) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx

		if int(paramIndex) >= len(controller.param_descs) {
			return vst3.kInvalidArgument
		}

		desc := controller.param_descs[paramIndex]

		flags := vst3.ParameterFlagSet{.kCanAutomate}
		if int(paramIndex) == controller.bypass_param_idx {
			flags += {.kIsBypass}
		}

		info^ = vst3.ParameterInfo {
			id = u32(paramIndex),
			stepCount = desc.step_count,
			defaultNormalizedValue = bridge.param_to_normalized(desc.default_value, desc),
			unitId = vst3.kRootUnitId,
			flags = flags,
		}

		utf16.encode_string(info.title[:], desc.name)
		utf16.encode_string(info.shortTitle[:], desc.short_name)
		utf16.encode_string(info.units[:], bridge.param_unit_strings[desc.unit])

		return vst3.kResultOk
	}
	lc_ec_getParamStringByValue :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue, str: ^vst3.String128) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx

		if int(id) >= len(controller.param_descs) do return vst3.kInvalidArgument
		desc := controller.param_descs[id]

		buffer: [128]u8
		plain_val := bridge.normalized_to_param(valueNormalized, desc)
		display_str := bridge.param_format_value(plain_val, desc, buffer[:])
		utf16.encode_string(str[:128], display_str)

		return vst3.kResultOk
	}
	lc_ec_getParamValueByString :: proc "system" (this: rawptr, id: vst3.ParamID, str: [^]vst3.TChar, valueNormalized: ^vst3.ParamValue) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx

		if int(id) >= len(controller.param_descs) do return vst3.kInvalidArgument
		desc := controller.param_descs[id]

		buffer: [128]u8
		utf16.decode_to_utf8(buffer[:], str[:128])
		plain_val, ok := bridge.param_parse_value(string(buffer[:]), desc)
		if !ok do return vst3.kInvalidArgument
		valueNormalized^ = bridge.param_to_normalized(plain_val, desc)

		return vst3.kResultOk
	}
	lc_ec_normalizedParamToPlain :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue) -> vst3.ParamValue {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		if int(id) >= len(controller.param_descs) do return valueNormalized
		return bridge.normalized_to_param(valueNormalized, controller.param_descs[id])
	}
	lc_ec_plainParamToNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, plainValue: vst3.ParamValue) -> vst3.ParamValue {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		if int(id) >= len(controller.param_descs) do return plainValue
		return bridge.param_to_normalized(plainValue, controller.param_descs[id])
	}
	lc_ec_getParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID) -> vst3.ParamValue {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		if int(id) >= len(controller.param_descs) do return 0
		return bridge.param_to_normalized(controller.param_values.values[id], controller.param_descs[id])
	}
	lc_ec_setParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, value: vst3.ParamValue) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		if int(id) >= len(controller.param_descs) do return vst3.kInvalidArgument
		controller.param_values.values[id] = bridge.normalized_to_param(value, controller.param_descs[id])
		return vst3.kResultOk
	}
	lc_ec_setComponentHandler :: proc "system" (this: rawptr, handler: ^vst3.IComponentHandler) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		controller.component_handler = handler
		return vst3.kResultOk
	}
	lc_ec_createView :: proc "system" (this: rawptr, name: vst3.FIDString) -> ^vst3.IPlugView {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "edit_controller")
		context = controller.ctx
		if string(name) != vst3.ViewType_kEditor {
			return nil
		}
		log.info("createView: Editor opened")
		create_lindale_view(&controller.view, &controller.plugin)
		return &controller.view.plugin_view
	}

	// EditController2
	lc_ec2_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "edit_controller2")
		context = controller.ctx
		log.info("lc_ec2_queryInterface")

		return lc_queryInterface(controller, iid, obj)
	}
	lc_ec2_addRef :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "edit_controller2")
		context = controller.ctx
		log.info("lc_ec2_addRef")
		controller.ref_count += 1
		return controller.ref_count
	}
	lc_ec2_release :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "edit_controller2")
		context = controller.ctx
		log.info("lc_ec2_release")
		return lc_releaseImplementation(controller)
	}
	lc_ec2_setKnobMode :: proc "system" (this: rawptr, mode: vst3.KnobMode) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "edit_controller2")
		context = controller.ctx
		log.info("lc_setKnobMode")
		return vst3.kResultOk
	}
	lc_ec2_openHelp :: proc "system" (this: rawptr, onlyCheck: vst3.TBool) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "edit_controller2")
		context = controller.ctx
		log.info("lc_openHelp")
		return vst3.kResultOk
	}
	lc_ec2_openAboutBox :: proc "system" (this: rawptr, onlyCheck: vst3.TBool) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "edit_controller2")
		context = controller.ctx
		log.info("lc_openAboutBox")
		return vst3.kResultOk
	}
	lc_cp_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		controller := container_of(cast(^vst3.IConnectionPoint)this, LindaleController, "connection_point")
		context = controller.ctx
		log.info("lc_cp_queryInterface")

		return lc_queryInterface(controller, iid, obj)
	}
	lc_cp_addRef :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IConnectionPoint)this, LindaleController, "connection_point")
		context = controller.ctx
		log.info("lc_cp_addRef")
		controller.ref_count += 1
		return controller.ref_count
	}
	lc_cp_release :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IConnectionPoint)this, LindaleController, "connection_point")
		context = controller.ctx
		log.info("lc_cp_release")
		return lc_releaseImplementation(controller)
	}
	lc_cp_connect :: proc "system" (this: rawptr, other: ^vst3.IConnectionPoint) -> vst3.TResult {
		controller := container_of(cast(^vst3.IConnectionPoint)this, LindaleController, "connection_point")
		context = controller.ctx
		log.info("lc_cp_connect")
		controller.peer = other
		processor: rawptr
		if other->queryInterface(&lindale_connection_cid, &processor) == vst3.kResultOk {
			controller.processor_link = cast(^LindaleProcessor)processor
			controller.processor_link.controller_link = controller
			controller.plugin.processor_peer = &controller.processor_link.plugin
			controller.processor_link.plugin.controller_peer = &controller.plugin
			log.info("lc_cp_connect: Connection with processor established.")
		} else { // Query interface on processor failed - send message to processor instead
			send_int_message(controller.host_application, controller.peer, "LindaleVST3EditController", transmute(i64)uintptr(controller))
		}
		return vst3.kResultOk
	}
	lc_cp_disconnect :: proc "system" (this: rawptr, other: ^vst3.IConnectionPoint) -> vst3.TResult {
		controller := container_of(cast(^vst3.IConnectionPoint)this, LindaleController, "connection_point")
		context = controller.ctx
		log.info("lc_cp_disconnect")
		controller.peer = nil
		return vst3.kResultOk
	}
	// notify may run on any thread: route UI mutations through the same channel as
	// component_handler callbacks, never touch view state directly here.
	lc_cp_notify :: proc "system" (this: rawptr, message: ^vst3.IMessage) -> vst3.TResult {
		controller := container_of(cast(^vst3.IConnectionPoint)this, LindaleController, "connection_point")
		context = controller.ctx
		id := message->getMessageID()
		log.info("lc_cp_notify: {}", id)
		return vst3.kResultOk
	}
}

send_int_message :: proc(host_app: ^vst3.IHostApplication, peer: ^vst3.IConnectionPoint, id: cstring, value: i64) {
	if peer == nil do return
	msg := make_message(host_app)
	if msg == nil do return
	defer msg->release()
	msg->setMessageID(id)
	msg->getAttributes()->setInt(id, value)
	peer->notify(msg)
}

// Caller owns the returned message and must release() it after sending
make_message :: proc(host_app: ^vst3.IHostApplication) -> ^vst3.IMessage {
	if host_app == nil do return nil
	obj: rawptr
	if host_app->createInstance(&vst3.iid_IMessage, &vst3.iid_IMessage, &obj) != vst3.kResultOk {
		return nil
	}
	msg := cast(^vst3.IMessage)obj
	return msg
}

LindaleView :: struct {
	plugin_view: vst3.IPlugView,
	plugin_view_vtable: vst3.IPlugViewVtbl,
	ref_count: u32,

	controller: ^LindaleController,

	plugin: ^sdk.PluginController,

	ctx: runtime.Context,
	parent: rawptr,
	timer: ^plat.Timer,

	renderer: bridge.Renderer,
}

MS_PER_FRAME :: 16

// Publish seconds since the previous draw; clamp to throw away frames if we stall
update_frame_dt :: proc (plug: ^sdk.PluginController) {
	now := time.tick_now()
	if plug.last_draw_time != (time.Tick{}) {
		dt := f32(time.duration_seconds(time.tick_diff(plug.last_draw_time, now)))
		plug.frame_dt = clamp(dt, 0, 0.1)
	} else {
		plug.frame_dt = f32(MS_PER_FRAME) / 1000
	}
	plug.last_draw_time = now
}

timer_proc :: proc (timer: ^plat.Timer) {
	view := cast(^LindaleView)timer.data
	if view.renderer == nil do return

	// Only draw if enough time has passed since last draw (avoid fighting with input callback)
	MIN_FRAME_INTERVAL :: MS_PER_FRAME * time.Millisecond
	elapsed := time.tick_since(view.plugin.last_draw_time)
	if elapsed < MIN_FRAME_INTERVAL do return

	// Check for hot-reload generation change
	gen := hs.hotload_generation()
	if gen != view.controller.last_generation {
		view.controller.host_ctx.generation = gen
		view.controller.last_generation = gen
		vm.arena_free_all(&view.controller.session_arena)
		plugin_api.setup_controller(&view.controller.plugin)
	}

	update_frame_dt(view.plugin)
	plugin_api.draw(view.plugin)

	free_all(context.temp_allocator)
}

repaint_callback :: proc "c" (data: rawptr) {
	view := cast(^LindaleView)data
	context = view.ctx
	if view.renderer == nil do return

	// Check for hot-reload generation change
	gen := hs.hotload_generation()
	if gen != view.controller.last_generation {
		view.controller.host_ctx.generation = gen
		view.controller.last_generation = gen
		vm.arena_free_all(&view.controller.session_arena)
		plugin_api.setup_controller(&view.controller.plugin)
	}

	update_frame_dt(view.plugin)
	plugin_api.draw(view.plugin)

	free_all(context.temp_allocator)
}

create_lindale_view :: proc(view: ^LindaleView, plug: ^sdk.PluginController) -> vst3.TResult {
	view.plugin_view_vtable = {
		queryInterface = lv_queryInterface,
		addRef = lv_addRef,
		release = lv_release,

		isPlatformTypeSupported = lv_isPlatformTypeSupported,
		attached = lv_attached,
		removed = lv_removed,
		onWheel = lv_onWheel,
		onKeyDown = lv_onKeyDown,
		onKeyUp = lv_onKeyUp,
		getSize = lv_getSize,
		onSize = lv_onSize,
		onFocus = lv_onFocus,
		setFrame = lv_setFrame,
		canResize = lv_canResize,
		checkSizeConstraint = lv_checkSizeConstraint,
	}
	view.plugin_view.lpVtbl = &view.plugin_view_vtable
	view.ctx = context
	view.plugin = plug
	view.timer = plat.timer_create(MS_PER_FRAME, timer_proc, view)
	view.controller = container_of(view, LindaleController, "view")

	return vst3.kResultOk

	view_queryInterface :: proc (this: ^LindaleView, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IPlugView || iid^ == vst3.iid_IPluginBase {
			obj^ = &this.plugin_view
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		this.ref_count += 1
		return vst3.kResultOk
	}

	lv_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_queryInterface")

		return view_queryInterface(view, iid, obj)
	}
	lv_addRef :: proc "system" (this: rawptr) -> u32 {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_addRef")
		view.ref_count += 1
		return view.ref_count
	}
	lv_release :: proc "system" (this: rawptr) -> u32 {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_release")
		view.ref_count -= 1
		if view.ref_count == 0 {
			// free(view)
		}
		return view.ref_count
	}
	lv_isPlatformTypeSupported :: proc "system" (this: rawptr, type: vst3.FIDString) -> vst3.TResult {
		when ODIN_OS == .Windows {
			if string(type) == vst3.kPlatformTypeHWND do return vst3.kResultOk
		}
		when ODIN_OS == .Darwin {
			if string(type) == vst3.kPlatformTypeNSView do return vst3.kResultOk
		}
		when ODIN_OS == .Linux {
			if string(type) == vst3.kPlatformTypeX11EmbedWindowID do return vst3.kResultOk
		}
		return vst3.kResultFalse
	}
	lv_attached :: proc "system" (this: rawptr, parent: rawptr, type: vst3.FIDString) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx

		when ODIN_OS == .Windows {
			if string(type) != vst3.kPlatformTypeHWND {
				log.error("lv_attached type not supported")
				return vst3.kInvalidArgument
			}
		}
		when ODIN_OS == .Darwin {
			if string(type) != vst3.kPlatformTypeNSView {
				log.error("lv_attached type not supported")
				return vst3.kInvalidArgument
			}
		}
		when ODIN_OS == .Linux {
			if string(type) != vst3.kPlatformTypeX11EmbedWindowID {
				log.error("lv_attached type not supported")
				return vst3.kInvalidArgument
			}
		}

		controller := container_of(view, LindaleController, "view")

		bounds := view.plugin.view_bounds
		view.renderer = plat.renderer_create(parent, bounds.w, bounds.h)

		controller.platform_api = bridge.PlatformApi{
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
		controller.host_ctx.platform = &controller.platform_api
		controller.host_ctx.renderer = view.renderer
		plat.renderer_set_mouse_state(view.renderer, &view.plugin.mouse)
		plat.renderer_set_repaint_callback(view.renderer, repaint_callback, view)

		controller.host_ctx.font_atlas = plat.renderer_create_texture(view.renderer, sdk.FONT_ATLAS_SIZE, sdk.FONT_ATLAS_SIZE, .R8)

		plugin_api.view_attached(view.plugin)

		if !plat.timer_running(view.timer) {
			view.parent = parent
			plat.timer_start(view.timer)
		} else {
			log.info("Timer already running")
		}

		log.info("lv_attached created window")
		return vst3.kResultOk
	}
	lv_removed :: proc "system" (this: rawptr) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_removed")

		plat.renderer_destroy(view.renderer)

		if plat.timer_running(view.timer) {
			plat.timer_stop(view.timer)
		}

		plugin_api.view_removed(view.plugin)

		return vst3.kResultOk
	}
	lv_onWheel :: proc "system" (this: rawptr, distance: f32) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_onWheel")
		// plugin_draw(view.plugin)
		return vst3.kResultOk
	}
	lv_onKeyDown :: proc "system" (this: rawptr, key: u16, keyCode: i16, modifiers: i16) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_onKeyDown")
		// plugin_draw(view.plugin)
		return vst3.kResultOk
	}
	lv_onKeyUp :: proc "system" (this: rawptr, key: u16, keyCode: i16, modifiers: i16) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_onKeyUp")
		return vst3.kResultOk
	}
	lv_getSize :: proc "system" (this: rawptr, size: ^vst3.ViewRect) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		rect := view.plugin.view_bounds
		size^ = vst3.ViewRect{
			left = 0,
			top = 0,
			right = rect.w,
			bottom = rect.h,
		}
		log.info("lv_getSize:", rect.w, rect.h)
		return vst3.kResultOk
	}
	lv_onSize :: proc "system" (this: rawptr, newSize: ^vst3.ViewRect) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		rect := sdk.RectI32{0, 0, newSize.right - newSize.left, newSize.bottom - newSize.top}
		// log.debug("lv_onSize r:", newSize.right, "l:", newSize.left, "b:", newSize.bottom, "t:", newSize.top)
		plat.renderer_resize(view.renderer, rect.w, rect.h)
		plugin_api.view_resized(view.plugin, rect)
		return vst3.kResultOk
	}
	lv_onFocus :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_onFocus")

		// plugin_draw(view.plugin)
		return vst3.kResultOk
	}
	lv_setFrame :: proc "system" (this: rawptr, frame: ^vst3.IPlugFrame) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		log.info("lv_setFrame")
		return vst3.kResultOk
	}
	lv_canResize :: proc "system" (this: rawptr) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		controller := container_of(view, LindaleController, "view")
		return vst3.kResultTrue if controller.view_config.resizable else vst3.kResultFalse
	}
	lv_checkSizeConstraint :: proc "system" (this: rawptr, rect: ^vst3.ViewRect) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "plugin_view")
		context = view.ctx
		controller := container_of(view, LindaleController, "view")
		cur := view.plugin.view_bounds
		clamp_to_view_config(rect, cur.w, cur.h, controller.view_config)
		// log.debug("lv_checkSizeConstraint -> r:", rect.right, "b:", rect.bottom)
		return vst3.kResultOk
	}
}

// Ratio-compare aspect lock : comparing deltas instead would
// flicker against hosts that anchor their drag baseline
// independently of our returned size.
clamp_to_view_config :: proc(rect: ^vst3.ViewRect, cur_w, cur_h: i32, cfg: sdk.ViewConfig) {
	w := rect.right - rect.left
	h := rect.bottom - rect.top

	if cfg.aspect_ratio > 0 && h > 0 && cur_h > 0 {
		old_ratio := f32(cur_w) / f32(cur_h)
		new_ratio := f32(w) / f32(h)
		if new_ratio > old_ratio {
			h = i32(f32(w) / cfg.aspect_ratio + 0.5)
		} else {
			w = i32(f32(h) * cfg.aspect_ratio + 0.5)
		}
	}

	// Re-snap the other dim after each clamp so it doesn't drift out of ratio
	if cfg.min_width > 0 && w < cfg.min_width {
		w = cfg.min_width
		if cfg.aspect_ratio > 0 do h = i32(f32(w) / cfg.aspect_ratio + 0.5)
	}
	if cfg.min_height > 0 && h < cfg.min_height {
		h = cfg.min_height
		if cfg.aspect_ratio > 0 do w = i32(f32(h) * cfg.aspect_ratio + 0.5)
	}
	if cfg.max_width > 0 && w > cfg.max_width {
		w = cfg.max_width
		if cfg.aspect_ratio > 0 do h = i32(f32(w) / cfg.aspect_ratio + 0.5)
	}
	if cfg.max_height > 0 && h > cfg.max_height {
		h = cfg.max_height
		if cfg.aspect_ratio > 0 do w = i32(f32(h) * cfg.aspect_ratio + 0.5)
	}

	rect.left = 0
	rect.top = 0
	rect.right = w
	rect.bottom = h
}

@export GetPluginFactory :: proc "system" () -> ^vst3.IPluginFactory3 {
	context = runtime.default_context()
	hs.mutex_log_init(hs.get_config().runtime_folder_path, hs.PLUGIN_NAME)
	context.logger = hs.get_mutex_logger(.PluginFactory)

	log.info("GetPluginFactory")

	if !plugin_factory.initialized {
		pf_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("pf_queryInterface")
			if iid^ == vst3.iid_FUnknown ||
			iid^ == vst3.iid_IPluginFactory ||
			iid^ == vst3.iid_IPluginFactory2 ||
			iid^ == vst3.iid_IPluginFactory3 {
				obj^ = this
				return vst3.kResultOk
			}
			obj^ = nil
			return vst3.kNoInterface
		}

		pf_addRef :: proc "system" (this: rawptr) -> u32 {
			context = plugin_factory.ctx
			log.info("pf_addRef")
			return 1
		}

		pf_release :: proc "system" (this: rawptr) -> u32 {
			context = plugin_factory.ctx
			log.info("pf_release")
			return 0
		}

		pf_getFactoryInfo :: proc "system" (this: rawptr, info: ^vst3.PFactoryInfo) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("getFactoryInfo")
			copy(info.vendor[:], "JagI")
			copy(info.url[:], "jagi.quest")
			copy(info.email[:], "jagi@jagi.quest")
			info.flags = 0
			return vst3.kResultOk
		}

		pf_countClasses :: proc "system" (this: rawptr) -> i32 {
			context = plugin_factory.ctx
			log.info("countClasses")
			return 2 // LindaleProcessor and LindaleController
		}

		pf_getClassInfo :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("getClassInfo")
			if index >= 2 {
				log.error("getClassInfo index >= 2")
				return vst3.kInvalidArgument
			}

			info^ = vst3.PClassInfo {
				cid = index == 0 ? lindale_processor_cid : lindale_controller_cid,
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
			}

			if index == 0 {
				copy(info.category[:], "Audio Module Class")
			} else {
				copy(info.category[:], "Component Controller Class")
			}

			copy(info.name[:], plugin_factory.desc.name)

			return vst3.kResultOk
		}

		pf_createInstance :: proc "system" (this: rawptr, cid, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("createInstance")

			cid_ptr: [^]u8 = cast([^]u8)cid
			cid_ary := cid_ptr[0:16]

			log.debug("cid: {:x}", cid_ary)
			log.debug("processorCid: {:x}", lindale_processor_cid)
			log.debug("controllerCid: {:x}", lindale_controller_cid)

			if vst3.is_same_tuid(&lindale_processor_cid, cid) {
				processor := create_lindale_processor()

				// init
				hs.hotload_init()

				if vst3.is_same_tuid(&vst3.iid_IComponent, iid) {
					log.debug("CreateInstance iComponent")
					obj^ = &processor.component;
					processor.component->addRef();
					return vst3.kResultOk;
				} else if vst3.is_same_tuid(&vst3.iid_IAudioProcessor, iid) {
					log.debug("CreateInstance audio_processor")
					obj^ = &processor.audio_processor;
					processor.audio_processor->addRef();
					return vst3.kResultOk;
				}

				free(processor)

				log.error("CreateInstance noiid")

				// No interface found
				obj^ = nil;
				return vst3.kNoInterface;

			} else if vst3.is_same_tuid(&lindale_controller_cid, cid) {
				controller := create_lindale_controller()

				// init
				hs.hotload_init()

				if vst3.is_same_tuid(&vst3.iid_IEditController, iid) {
					log.info("CreateInstance edit_controller")
					obj^ = &controller.edit_controller
					controller.edit_controller->addRef()
					return vst3.kResultOk
				}

				free(controller)
				obj^ = nil
				return vst3.kNoInterface
			}

			log.error("CreateInstance nocid")

			return vst3.kNoInterface
		}

		pf_getClassInfo2 :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo2) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("getClassInfo2 with index {:d}", index)
			if index >= 2 {
				log.error("getClassInfo2 index >= 2")
				return vst3.kInvalidArgument
			}

			desc := plugin_factory.desc
			subcat := desc.plugin_type == .Instrument ? "Instrument" : "Fx"

			info^ = vst3.PClassInfo2 {
				cid = (index == 0? lindale_processor_cid : lindale_controller_cid),
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
				classFlags = 0,
				subCategories = {},
				vendor = {},
				version = {},
				sdkVersion = {}
			}

			if index == 0 {
				copy(info.category[:], "Audio Module Class")
			} else {
				copy(info.category[:], "Component Controller Class")
			}

			copy(info.name[:], desc.name)
			copy(info.subCategories[:], subcat)
			copy(info.vendor[:], desc.vendor)
			copy(info.version[:], desc.version)
			copy(info.sdkVersion[:], "VST 3.7.0")

			return vst3.kResultOk
		}

		pf_getClassInfoUnicode :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfoW) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("getClassInfoUnicode with index {:d}", index)
			if index >= 2 {
				log.error("getClassInfoU index >= 2")
				return vst3.kInvalidArgument
			}

			desc := plugin_factory.desc
			subcat := desc.plugin_type == .Instrument ? "Instrument" : "Fx"

			info^ = vst3.PClassInfoW {
				cid = (index == 0? lindale_processor_cid : lindale_controller_cid),
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
				classFlags = 0,
				subCategories = {},
				vendor = {},
				version = {},
				sdkVersion = {}
			}

			if index == 0 {
				copy(info.category[:], "Audio Module Class")
			} else {
				copy(info.category[:], "Component Controller Class")
			}

			utf16.encode_string(info.name[:], desc.name)
			copy(info.subCategories[:], subcat)
			utf16.encode_string(info.vendor[:], desc.vendor)
			utf16.encode_string(info.version[:], desc.version)
			utf16.encode_string(info.sdkVersion[:], "VST 3.7.0")

			return vst3.kResultOk
		}

		pf_setHostContext :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
			context = plugin_factory.ctx
			log.info("setHostContext")
			return vst3.kResultOk
		}

		plugin_factory.vtable.queryInterface = pf_queryInterface
		plugin_factory.vtable.addRef = pf_addRef
		plugin_factory.vtable.release = pf_release

		plugin_factory.vtable.getFactoryInfo = pf_getFactoryInfo
		plugin_factory.vtable.countClasses = pf_countClasses
		plugin_factory.vtable.getClassInfo = pf_getClassInfo
		plugin_factory.vtable.createInstance = pf_createInstance

		plugin_factory.vtable.getClassInfo2 = pf_getClassInfo2

		plugin_factory.vtable.getClassInfoUnicode = pf_getClassInfoUnicode
		plugin_factory.vtable.setHostContext = pf_setHostContext

		plugin_factory.vtable_ptr.lpVtbl = &plugin_factory.vtable

		plugin_factory.ctx = context
		plugin_api = hs.hotload_api()
		plugin_factory.desc = plugin_api.get_plugin_descriptor()

		patch_cid_for_plugin(&lindale_processor_cid, hs.PLUGIN_NAME)
		patch_cid_for_plugin(&lindale_controller_cid, hs.PLUGIN_NAME)
		patch_cid_for_plugin(&lindale_connection_cid, hs.PLUGIN_NAME)

		plugin_factory.initialized = true
	}

	return &plugin_factory.vtable_ptr
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////////////////

@(test)
test_IsSameTuid :: proc(t: ^testing.T) {
	tuid_to_cstr :: proc (tuid: vst3.TUID, bits: ^[17]byte) {
		tuid := tuid
		bits^ = {}
		copy(bits[:16], tuid[:])
	}
	context.allocator = context.temp_allocator
	bits : [17]byte
	test_str := cast(^[16]byte)&bits[0]
	tuid_to_cstr(lindale_processor_cid, &bits)
	testing.expect(t, vst3.is_same_tuid(&lindale_processor_cid, test_str))
	tuid_to_cstr(vst3.iid_FUnknown, &bits)
	assert(!vst3.is_same_tuid(&lindale_processor_cid, test_str))
	tuid_to_cstr(vst3.iid_IComponent, &bits)
	assert(!vst3.is_same_tuid(&lindale_processor_cid, test_str))
	tuid_to_cstr(vst3.iid_IAudioProcessor, &bits)
	assert(!vst3.is_same_tuid(&lindale_processor_cid, test_str))

	free_all(context.allocator)
}

@(test)
test_lindale_processor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	processor := create_lindale_processor()
	testing.expect(t, processor != nil)
	testing.expect_value(t, processor.ref_count, 0)

	// Test QueryInterface
	iid_test_cases := []vst3.TUID {
		vst3.iid_FUnknown,
		vst3.iid_IComponent,
		vst3.iid_IPluginBase,
		vst3.iid_IAudioProcessor,
		vst3.iid_IProcessContextRequirements
	}

	obj: rawptr
	for test_case in iid_test_cases {
		test_case := test_case

		result := processor.component->queryInterface(&test_case, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.audio_processor->queryInterface(&test_case, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.process_context_requirements->queryInterface(&test_case, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	starting_ref_count := u32(3 * len(iid_test_cases))

	// Test AddRef and Release
	ref_count := processor.component->addRef()
	testing.expect_value(t, ref_count, starting_ref_count + 1)
	ref_count = processor.audio_processor->addRef()
	testing.expect_value(t, ref_count, starting_ref_count + 2)

	ref_count = processor.component->release()
	testing.expect_value(t, ref_count, starting_ref_count + 1)
	ref_count = processor.audio_processor->release()
	testing.expect_value(t, ref_count, starting_ref_count)

	ref_count = processor.component->release()
	testing.expect_value(t, ref_count, starting_ref_count - 1)
	ref_count = processor.audio_processor->release()
	testing.expect_value(t, ref_count, starting_ref_count - 2)

	invalid_tuid := vst3.iid_IEditController2
	result := processor.component->queryInterface(&invalid_tuid, &obj)
	testing.expect_value(t, result, vst3.kNoInterface)
	free_all(context.allocator)
}

@(test)
test_lindale_controller :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	controller := create_lindale_controller()
	testing.expect(t, controller != nil)
	testing.expect_value(t, controller.ref_count, 0)

	// Test QueryInterface
	iid_test_cases := []vst3.TUID {
		vst3.iid_FUnknown,
		vst3.iid_IPluginBase,
		vst3.iid_IEditController,
		vst3.iid_IEditController2,
	}

	obj: rawptr
	for test_case in iid_test_cases {
		test_case := test_case

		result := controller.edit_controller->queryInterface(&test_case, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = controller.edit_controller2->queryInterface(&test_case, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	starting_ref_count := u32(2 * len(iid_test_cases))

	// Test AddRef and Release
	ref_count := controller.edit_controller->addRef()
	testing.expect_value(t, ref_count, starting_ref_count + 1)
	ref_count = controller.edit_controller2->addRef()
	testing.expect_value(t, ref_count, starting_ref_count + 2)

	ref_count = controller.edit_controller->release()
	testing.expect_value(t, ref_count, starting_ref_count + 1)
	ref_count = controller.edit_controller2->release()
	testing.expect_value(t, ref_count, starting_ref_count)

	ref_count = controller.edit_controller->release()
	testing.expect_value(t, ref_count, starting_ref_count - 1)
	ref_count = controller.edit_controller2->release()
	testing.expect_value(t, ref_count, starting_ref_count - 2)

	invalid_tuid := vst3.iid_IAudioProcessor
	result := controller.edit_controller->queryInterface(&invalid_tuid, &obj)
	testing.expect_value(t, result, vst3.kNoInterface)
	free_all(context.allocator)
}
