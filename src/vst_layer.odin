package platform

import "thirdparty/vst3"
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
import "core:sys/windows"

import "vendor:sdl3"

import lin "lindale"
import plat "platform_specific"

lindaleProcessorCid := vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4)
lindaleControllerCid := vst3.SMTG_INLINE_UID(0x1DD0528c, 0x269247AA, 0x85210051, 0xDAB98786)

LindalePluginFactory :: struct {
	vtablePtr: vst3.IPluginFactory3,
	vtable: vst3.IPluginFactory3Vtbl,
	initialized: bool,
	ctx: runtime.Context,
	api: lin.PluginApi,
}

pluginFactory: LindalePluginFactory

when ODIN_OS == .Darwin {
	@export bundleEntry :: proc "system" (bundleRef: rawptr) -> c.bool {
		context = runtime.default_context()
		return true
	}

	@export bundleExit :: proc "system" () -> c.bool {
		context = pluginFactory.ctx
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
		context = pluginFactory.ctx
		log.info("ModuleExit")
		deinit()
		return true
	}
} else when ODIN_OS == .Windows {
	// @(fini)
	// WindowsExit :: proc () {
	// 	context = pluginFactory.ctx
	// 	deinit()
	// }
}

deinit :: proc() {
	log.info("Deinitializing")
	hotload_deinit()
	mutex_log_exit()
}

LindaleProcessor :: struct {
	component: vst3.IComponent,
	componentVtable: vst3.IComponentVtbl,
	audioProcessor: vst3.IAudioProcessor,
	audioProcessorVtable: vst3.IAudioProcessorVtbl,
	processContextRequirements: vst3.IProcessContextRequirements,
	processContextRequirementsVtable: vst3.IProcessContextRequirementsVtbl,
	// connectionPoint: vst3.IConnectionPoint,
	// connectionPointVtable: vst3.IConnectionPointVtbl,
	refCount: u32,

	plugin: ^lin.Plugin,

	// controllerConnection: ^vst3.IConnectionPoint,
	hostContext: ^vst3.FUnknown,

	// Context
	params: lin.ParamState,
	sampleRate: f64,
	ctx: runtime.Context,
}

createLindaleProcessor :: proc() -> ^LindaleProcessor {
	log.info("createLindaleProcessor")
	processor := new(LindaleProcessor)
	processor.refCount = 0

	processor.componentVtable = {
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

	processor.audioProcessorVtable = {
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

	processor.processContextRequirementsVtable = {
		queryInterface = lp_pcr_queryInterface,
		addRef = lp_pcr_addRef,
		release = lp_pcr_release,
		getProcessContextRequirements = lp_pcr_getProcessContextRequirements,
	}

	processor.component.lpVtbl = &processor.componentVtable
	processor.audioProcessor.lpVtbl = &processor.audioProcessorVtable
	processor.processContextRequirements.lpVtbl = &processor.processContextRequirementsVtable

	processor.ctx = context
	processor.ctx.logger = get_mutex_logger(.Processor)

	processor.plugin = lin.plugin_init({.Audio})

	for i in lin.ParamID {
		processor.params.values[i] = lin.param_to_norm(lin.ParamTable[i].range.defaultValue, lin.ParamTable[i].range)
	}

	gross_global_buffer_ptr = &processor.plugin.gross_global_glob

	return processor

	// Universal LindaleProcessor queryInterface
	lp_queryInterfaceImplementation :: proc(this: ^LindaleProcessor, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		log.debug("iid: {:x}", iid)
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IComponent || iid^ == vst3.iid_IPluginBase {
			obj^ = &this.component
		} else if  iid^ == vst3.iid_IAudioProcessor {
			obj^ = &this.audioProcessor
		} else if iid^ == vst3.iid_IProcessContextRequirements {
			obj^ = &this.processContextRequirements
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		this.refCount += 1

		return vst3.kResultOk
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
		processor.refCount += 1
		return processor.refCount
	}
	lp_comp_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_release")
		processor.refCount -= 1
		if processor.refCount == 0 {
			log.info("lp_comp_release free")
			free(processor)
		}
		return processor.refCount
	}
	lp_comp_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		processor.hostContext = ctx
		if ctx != nil {
			ctx->addRef()
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
		classId^ = lindaleControllerCid
		return vst3.kResultOk
	}
	lp_comp_setIoMode :: proc "system" (this: rawptr, mode: vst3.IoMode) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_comp_getBusCount :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection) -> i32 {
		processor := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		context = processor.ctx
		log.info("lp_comp_getBusCount")
		if type == .Audio {
			if dir == .Input || dir == .Output {
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

		if type != .Audio || index != 0 {
			return vst3.kInvalidArgument
		}

		bus.mediaType = type
		bus.direction = dir
		bus.channelCount = 2
		utf16.encode_string(bus.name[:], "Main")
		bus.busType = .Main
		bus.flags = 0

		return vst3.kResultOk
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
		return vst3.kResultOk
	}
	lp_comp_setState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_comp_getState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}

	// IAudioProcessor
	lp_ap_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		context = processor.ctx
		log.info("lp_ap_queryInterface")

		return lp_queryInterfaceImplementation(processor, iid, obj)
	}
	lp_ap_addRef :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		context = processor.ctx
		log.info("lp_ap_addRef")
		processor.refCount += 1
		return processor.refCount
	}
	lp_ap_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		context = processor.ctx
		log.info("lp_ap_release")
		processor.refCount -= 1
		if processor.refCount == 0 {
			free(processor)
		}
		return processor.refCount
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
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		context = processor.ctx
		log.info("lp_ap_canProcessSampleSize")
		if sss == .Sample32 {
			return vst3.kResultOk
		}
		return vst3.kNotImplemented
	}
	lp_ap_getLatencySamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}
	lp_ap_setupProcessing :: proc "system" (this: rawptr, setup: ^vst3.ProcessSetup) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		context = processor.ctx
		log.info("lp_ap_setupProcessing")

		processor.sampleRate = setup.sampleRate

		return vst3.kResultOk
	}
	lp_ap_setProcessing :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_ap_process :: proc "system" (this: rawptr, data: ^vst3.ProcessData) -> vst3.TResult {
		processor := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		context = processor.ctx

		numSamples := data.numSamples
		numInputs := data.numInputs
		numOutputs := data.numOutputs
		outputs := data.outputs
		inputs := data.inputs

		// TODO: Dynamically allocate?
		groups: [32]lin.AudioBufferGroup
		channelSlices: [64][]u8 // we will cast slice to the right type later
		paramChanges: [lin.ParamID][64]lin.ParameterChange
		channelSliceBumpIdx: i32

		audioContext := processor.plugin.audioProcessor
		if data.processContext != nil {
			audioContext.sampleRate = data.processContext.sampleRate
			audioContext.projectTimeSamples = data.processContext.projectTimeSamples
		}
		audioContext.lastParamState = processor.params

		// Fetch parameter updates
		if data.inputParameterChanges != nil && data.inputParameterChanges.lpVtbl != nil {
			paramCount := data.inputParameterChanges->getParameterCount()
			for i in 0..<paramCount {
				paramQueue := data.inputParameterChanges->getParameterData(i)
				if paramQueue != nil && paramQueue.lpVtbl != nil {
					paramId := cast(lin.ParamID)(paramQueue->getParameterId())
					pointCount := paramQueue->getPointCount()
					if pointCount > 0 {
						actualCount := 0
						for i in 0..< pointCount {
							sampleOffs: i32
							normParam : f64
							result := paramQueue->getPoint(i, &sampleOffs, &normParam)
							if result == vst3.kResultOk {
								processor.params.values[paramId] = normParam
								paramChanges[paramId][actualCount] = lin.ParameterChange {
									sampleOffset = sampleOffs,
									value = normParam,
								}
								actualCount += 1
							}
						}
						audioContext.paramChanges[paramId] = paramChanges[paramId][:actualCount]
					}
				}
			}
		}

		audioContext.inputBuffers = groups[:numInputs]
		audioContext.outputBuffers = groups[numInputs:numInputs + numOutputs]

		// Convert input buffers to slices
		for i in 0..< numInputs {
			input := inputs[i]
			inputChannelCount := input.numChannels
			audioContext.inputBuffers[i].silenceFlags = input.silenceFlags
			audioContext.inputBuffers[i].sampleSize = data.symbolicSampleSize == .Sample32? .F32 : .F64
			channels := channelSlices[channelSliceBumpIdx:channelSliceBumpIdx+inputChannelCount]
			channelSliceBumpIdx += inputChannelCount

			if data.symbolicSampleSize == .Sample32 {
				audioContext.inputBuffers[i].buffers32 = transmute([][]f32)channels
				for j in 0..<inputChannelCount {
					audioContext.inputBuffers[i].buffers32[j] = input.channelBuffers32[j][:data.numSamples]
				}
			} else {
				audioContext.inputBuffers[i].buffers64 = transmute([][]f64)channels
				for j in 0..<inputChannelCount {
					audioContext.inputBuffers[i].buffers64[j] = input.channelBuffers64[j][:data.numSamples]
				}
			}
		}

		// Convert output buffers to slices
		for i in 0..< numOutputs {
			output := outputs[i]
			outputChannelCount := output.numChannels
			audioContext.outputBuffers[i].silenceFlags = output.silenceFlags
			audioContext.outputBuffers[i].sampleSize = data.symbolicSampleSize == .Sample32? .F32 : .F64
			channels := channelSlices[channelSliceBumpIdx:channelSliceBumpIdx+outputChannelCount]
			channelSliceBumpIdx += outputChannelCount

			if data.symbolicSampleSize == .Sample32 {
				audioContext.outputBuffers[i].buffers32 = transmute([][]f32)channels
				for j in 0..<outputChannelCount {
					audioContext.outputBuffers[i].buffers32[j] = output.channelBuffers32[j][:data.numSamples]
				}
			} else {
				audioContext.outputBuffers[i].buffers64 = transmute([][]f64)channels
				for j in 0..<outputChannelCount {
					audioContext.outputBuffers[i].buffers64[j] = output.channelBuffers64[j][:data.numSamples]
				}
			}
		}

		// Invoke hot-loaded audio process function
		pluginFactory.api.process_audio(processor.plugin)

		return vst3.kResultOk
	}
	lp_ap_getTailSamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}

	// IProcessContextRequirements
	lp_pcr_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")
		context = processor.ctx
		log.info("lp_pcr_queryInterface")

		return lp_queryInterfaceImplementation(processor, iid, obj)
	}

	lp_pcr_addRef :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")
		context = processor.ctx
		log.info("lp_pcr_addRef")
		processor.refCount += 1
		return processor.refCount
	}

	lp_pcr_release :: proc "system" (this: rawptr) -> u32 {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")
		context = processor.ctx
		log.info("lp_pcr_release")
		processor.refCount -= 1
		if processor.refCount == 0 {
			free(processor)
		}
		return processor.refCount
	}

	lp_pcr_getProcessContextRequirements :: proc "system" (this: rawptr) -> vst3.IProcessContextRequirementsFlagSet {
		processor := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")
		context = processor.ctx
		log.info("lp_getProcessContextRequirements")

		return {}
	}
}

LindaleController :: struct {
	editController: vst3.IEditController,
	editControllerVtable: vst3.IEditControllerVtbl,
	editController2: vst3.IEditController2,
	editController2Vtable: vst3.IEditController2Vtbl,

	refCount: u32,

	plugin: ^lin.Plugin,

	// Context
	paramState: lin.ParamState,
	ctx: runtime.Context,
	view: LindaleView,
}

createLindaleController :: proc () -> ^LindaleController {
	log.info("createLindaleController")
	controller := new(LindaleController)
	controller.refCount = 0

	controller.editController.lpVtbl = &controller.editControllerVtable
	controller.editController2.lpVtbl = &controller.editController2Vtable

	controller.editControllerVtable = {
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

	controller.editController2Vtable = {
		queryInterface = lc_ec2_queryInterface,
		addRef = lc_ec2_addRef,
		release = lc_ec2_release,

		setKnobMode = lc_ec2_setKnobMode,
		openHelp = lc_ec2_openHelp,
		openAboutBox = lc_ec2_openAboutBox,
	}

	controller.ctx = context
	controller.ctx.logger = get_mutex_logger(.Controller)

	for i in lin.ParamID {
		controller.paramState.values[i] = lin.param_to_norm(lin.ParamTable[i].range.defaultValue, lin.ParamTable[i].range)
	}

	controller.plugin = lin.plugin_init({.Controller})

	return controller

	lc_queryInterface :: proc (this: ^LindaleController, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IEditController || iid^ == vst3.iid_IPluginBase {
			obj^ = &this.editController
		} else if iid^ == vst3.iid_IEditController2 {
			obj^ = &this.editController2
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		this.refCount += 1
		return vst3.kResultOk
	}

	// EditController
	lc_ec_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		log.info("lc_queryInterface")

		return lc_queryInterface(controller, iid, obj)
	}
	lc_ec_addRef :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		log.info("lc_addRef")
		controller.refCount += 1
		return controller.refCount
	}
	lc_ec_release :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		log.info("lc_release")
		controller.refCount -= 1
		if controller.refCount == 0 {
			free(controller)
		}
		return controller.refCount
	}
	lc_ec_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {

		return vst3.kResultOk
	}
	lc_ec_terminate  :: proc "system" (this: rawptr) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_setComponentState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_setState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_getState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_getParameterCount :: proc "system" (this: rawptr) -> i32 {
		return len(lin.ParamTable)
	}
	lc_ec_getParameterInfo :: proc "system" (this: rawptr, paramIndex: i32, info: ^vst3.ParameterInfo) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx

		if paramIndex >= len(lin.ParamTable) {
			return vst3.kInvalidArgument
		}

		paramId := cast(lin.ParamID)paramIndex

		paramInfo := lin.ParamTable[paramId]

		info^ = vst3.ParameterInfo {
			id = cast(u32)paramId,
			stepCount = paramInfo.range.stepCount,
			defaultNormalizedValue = lin.param_to_norm(paramInfo.range.defaultValue, paramInfo.range),
			unitId = vst3.kRootUnitId,
			flags = {.kCanAutomate,},
		}

		utf16.encode_string(info.title[:], paramInfo.name)
		utf16.encode_string(info.shortTitle[:], paramInfo.shortName)
		utf16.encode_string(info.units[:], lin.ParamUnitTypeStrings[paramInfo.range.unit])

		return vst3.kResultOk
	}
	lc_ec_getParamStringByValue :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue, str: ^vst3.String128) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx

		paramId := cast(lin.ParamID)id

		buffer: [128]u8
		paramVal := lin.norm_to_param(valueNormalized, lin.ParamTable[paramId].range)
		lin.vst3_print_param_to_buf(&buffer, paramVal, lin.ParamTable[paramId])
		utf16.encode_string(str[:128], string(buffer[:128]))

		return vst3.kResultOk
	}
	lc_ec_getParamValueByString :: proc "system" (this: rawptr, id: vst3.ParamID, str: [^]vst3.TChar, valueNormalized: ^vst3.ParamValue) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx

		paramId := cast(lin.ParamID)id

		buffer: [128]u8
		utf16.decode_to_utf8(buffer[:], str[:128])
		paramVal := lin.vst3_get_param_from_buf(&buffer)
		valueNormalized^ = lin.param_to_norm(paramVal, lin.ParamTable[paramId].range)

		return vst3.kResultOk
	}
	lc_ec_normalizedParamToPlain :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue) -> vst3.ParamValue {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		return valueNormalized
	}
	lc_ec_plainParamToNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, plainValue: vst3.ParamValue) -> vst3.ParamValue {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		return plainValue
	}
	lc_ec_getParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID) -> vst3.ParamValue {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		paramId := cast(lin.ParamID)id
		return controller.paramState.values[paramId]
	}
	lc_ec_setParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, value: vst3.ParamValue) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		paramId := cast(lin.ParamID)id
		controller.paramState.values[paramId] = value
		return vst3.kResultOk
	}
	lc_ec_setComponentHandler :: proc "system" (this: rawptr, handler: ^vst3.IComponentHandler) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_ec_createView :: proc "system" (this: rawptr, name: vst3.FIDString) -> ^vst3.IPlugView {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		if string(name) != vst3.ViewType_kEditor {
			return nil
		}
		log.info("createView: Editor opened")
		createLindaleView(&controller.view, controller.plugin)
		return &controller.view.pluginView
	}

	// EditController2
	lc_ec2_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		context = controller.ctx
		log.info("lc_ec2_queryInterface")

		return lc_queryInterface(controller, iid, obj)
	}
	lc_ec2_addRef :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		context = controller.ctx
		log.info("lc_ec2_addRef")
		controller.refCount += 1
		return controller.refCount
	}
	lc_ec2_release :: proc "system" (this: rawptr) -> u32 {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		context = controller.ctx
		log.info("lc_ec2_release")
		controller.refCount -= 1
		if controller.refCount == 0 {
			free(controller)
		}
		return controller.refCount
	}
	lc_ec2_setKnobMode :: proc "system" (this: rawptr, mode: vst3.KnobMode) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		context = controller.ctx
		log.info("lc_setKnobMode")
		return vst3.kResultOk
	}
	lc_ec2_openHelp :: proc "system" (this: rawptr, onlyCheck: vst3.TBool) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		context = controller.ctx
		log.info("lc_openHelp")
		return vst3.kResultOk
	}
	lc_ec2_openAboutBox :: proc "system" (this: rawptr, onlyCheck: vst3.TBool) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		context = controller.ctx
		log.info("lc_openAboutBox")
		return vst3.kResultOk
	}
}

LindaleView :: struct {
	pluginView: vst3.IPlugView,
	pluginViewVtable: vst3.IPlugViewVtbl,
	refCount: u32,

	plugin: ^lin.Plugin,

	ctx: runtime.Context,
	parent: rawptr,
	timer: ^plat.Timer,
}

gross_global_buffer_ptr: ^lin.AnalysisTransfer

timer_proc :: proc (timer: ^plat.Timer) {
	view := cast(^LindaleView)timer.data

	event: sdl3.Event
	view.plugin.flipColor = false

	for sdl3.PollEvent(&event) {
		log.info("event with type: ", event.type)
	}

	if view.plugin != nil && view.plugin.render != nil {

		buffer2: lin.AnalysisTransfer

		if gross_global_buffer_ptr != nil {

			// Re-linearize
			firstLen := lin.ANALYSIS_BUFFER_SIZE - gross_global_buffer_ptr.writeIndex
			copy(buffer2.buf[:firstLen], gross_global_buffer_ptr.buf[gross_global_buffer_ptr.writeIndex:])
			copy(buffer2.buf[firstLen:], gross_global_buffer_ptr.buf[:gross_global_buffer_ptr.writeIndex])
		}

		// lin.plugin_do_analysis(view.plugin, &buffer2)
		// lin.plugin_draw(view.plugin)
		pluginFactory.api.do_analysis(view.plugin, &buffer2)
		pluginFactory.api.draw(view.plugin)

		free_all(context.temp_allocator)
	}
}

createLindaleView :: proc(view: ^LindaleView, plug: ^lin.Plugin) -> vst3.TResult {
	view.pluginViewVtable = {
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
	view.pluginView.lpVtbl = &view.pluginViewVtable
	view.ctx = context
	view.plugin = plug
	view.timer = plat.timer_create(30 /* ms */, timer_proc, view)

	return vst3.kResultOk

	view_queryInterface :: proc (this: ^LindaleView, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IPlugView || iid^ == vst3.iid_IPluginBase {
			obj^ = &this.pluginView
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		this.refCount += 1
		return vst3.kResultOk
	}

	lv_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_queryInterface")

		return view_queryInterface(view, iid, obj)
	}
	lv_addRef :: proc "system" (this: rawptr) -> u32 {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_addRef")
		view.refCount += 1
		return view.refCount
	}
	lv_release :: proc "system" (this: rawptr) -> u32 {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_release")
		view.refCount -= 1
		if view.refCount == 0 {
			// free(view)
		}
		return view.refCount
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
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
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

		lin.plugin_create_view(view.plugin, parent)

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
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_removed")

		if plat.timer_running(view.timer) {
			plat.timer_stop(view.timer)
		}

		lin.plugin_remove_view(view.plugin)

		return vst3.kResultOk
	}
	lv_onWheel :: proc "system" (this: rawptr, distance: f32) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_onWheel")
		// plugin_draw(view.plugin)
		return vst3.kResultOk
	}
	lv_onKeyDown :: proc "system" (this: rawptr, key: u16, keyCode: i16, modifiers: i16) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_onKeyDown")
		// plugin_draw(view.plugin)
		return vst3.kResultOk
	}
	lv_onKeyUp :: proc "system" (this: rawptr, key: u16, keyCode: i16, modifiers: i16) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_onKeyUp")
		return vst3.kResultOk
	}
	lv_getSize :: proc "system" (this: rawptr, size: ^vst3.ViewRect) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_getSize")
		size^ = vst3.ViewRect{
			left = 0,
			top = 0,
			right = 800,
			bottom = 600,
		}
		return vst3.kResultOk
	}
	lv_onSize :: proc "system" (this: rawptr, newSize: ^vst3.ViewRect) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_onSize")
		return vst3.kResultOk
	}
	lv_onFocus :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_onFocus")

		// plugin_draw(view.plugin)
		return vst3.kResultOk
	}
	lv_setFrame :: proc "system" (this: rawptr, frame: ^vst3.IPlugFrame) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_setFrame")
		return vst3.kResultOk
	}
	lv_canResize :: proc "system" (this: rawptr) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_canResize")
		return vst3.kResultFalse
	}
	lv_checkSizeConstraint :: proc "system" (this: rawptr, rect: ^vst3.ViewRect) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_checkSizeConstraint")
		return vst3.kResultOk
	}
}

@export GetPluginFactory :: proc "system" () -> ^vst3.IPluginFactory3 {
	context = runtime.default_context()
	mutex_log_init(get_config().runtimeFolderPath)
	context.logger = get_mutex_logger(.PluginFactory)

	log.info("GetPluginFactory")

	if !pluginFactory.initialized {
		pf_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
			context = pluginFactory.ctx
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
			context = pluginFactory.ctx
			log.info("pf_addRef")
			return 1
		}

		pf_release :: proc "system" (this: rawptr) -> u32 {
			context = pluginFactory.ctx
			log.info("pf_release")
			return 0
		}

		pf_getFactoryInfo :: proc "system" (this: rawptr, info: ^vst3.PFactoryInfo) -> vst3.TResult {
			context = pluginFactory.ctx
			log.info("getFactoryInfo")
			copy(info.vendor[:], "JagI")
			copy(info.url[:], "jagi.quest")
			copy(info.email[:], "jagi@jagi.quest")
			info.flags = 0
			return vst3.kResultOk
		}

		pf_countClasses :: proc "system" (this: rawptr) -> i32 {
			context = pluginFactory.ctx
			log.info("countClasses")
			return 2 // LindaleProcessor and LindaleController
		}

		pf_getClassInfo :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo) -> vst3.TResult {
			context = pluginFactory.ctx
			log.info("getClassInfo")
			if index >= 2 {
				log.error("getClassInfo index >= 2")
				return vst3.kInvalidArgument
			}

			info^ = vst3.PClassInfo {
				cid = index == 0 ? lindaleProcessorCid : lindaleControllerCid,
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
			}

			if index == 0 {
				copy(info.category[:], "Audio Module Class")
			} else {
				copy(info.category[:], "Component Controller Class")
			}

			copy(info.name[:], "Lindale")

			return vst3.kResultOk
		}

		pf_createInstance :: proc "system" (this: rawptr, cid, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
			context = pluginFactory.ctx
			log.info("createInstance")

			cidPtr: [^]u8 = cast([^]u8)cid
			cidAry := cidPtr[0:16]

			log.debug("cid: {:x}", cidAry)
			log.debug("processorCid: {:x}", lindaleProcessorCid)
			log.debug("controllerCid: {:x}", lindaleControllerCid)

			if vst3.is_same_tuid(&lindaleProcessorCid, cid) {
				processor := createLindaleProcessor()

				// init
				hotload_init()

				if vst3.is_same_tuid(&vst3.iid_IComponent, iid) {
					log.debug("CreateInstance iComponent")
					obj^ = &processor.component;
					processor.component->addRef();
					return vst3.kResultOk;
				} else if vst3.is_same_tuid(&vst3.iid_IAudioProcessor, iid) {
					log.debug("CreateInstance audioProcessor")
					obj^ = &processor.audioProcessor;
					processor.audioProcessor->addRef();
					return vst3.kResultOk;
				}

				free(processor)

				log.error("CreateInstance noiid")

				// No interface found
				obj^ = nil;
				return vst3.kNoInterface;

			} else if vst3.is_same_tuid(&lindaleControllerCid, cid) {
				controller := createLindaleController()

				// init
				hotload_init()

				if vst3.is_same_tuid(&vst3.iid_IEditController, iid) {
					log.info("CreateInstance editController")
					obj^ = &controller.editController
					controller.editController->addRef()
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
			context = pluginFactory.ctx
			log.info("getClassInfo2 with index {:d}", index)
			if index >= 2 {
				log.error("getClassInfo2 index >= 2")
				return vst3.kInvalidArgument
			}

			info^ = vst3.PClassInfo2 {
				cid = (index == 0? lindaleProcessorCid : lindaleControllerCid),
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

			copy(info.name[:], "Lindale")
			copy(info.subCategories[:], "Fx")
			copy(info.vendor[:], "JagI")
			copy(info.version[:], "0.0.1")
			copy(info.sdkVersion[:], "VST 3.7.0")

			return vst3.kResultOk
		}

		pf_getClassInfoUnicode :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfoW) -> vst3.TResult {
			context = pluginFactory.ctx
			log.info("getClassInfoUnicode with index {:d}", index)
			if index >= 2 {
				log.error("getClassInfoU index >= 2")
				return vst3.kInvalidArgument
			}
			info^ = vst3.PClassInfoW {
				cid = (index == 0? lindaleProcessorCid : lindaleControllerCid),
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
			
			utf16.encode_string(info.name[:], "Lindale")
			copy(info.subCategories[:], "Fx")
			utf16.encode_string(info.vendor[:], "JagI")
			utf16.encode_string(info.version[:], "0.0.1")
			utf16.encode_string(info.sdkVersion[:], "VST 3.7.0")

			return vst3.kResultOk
		}

		pf_setHostContext :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
			context = pluginFactory.ctx
			log.info("setHostContext")
			return vst3.kResultOk
		}

		result := sdl3.Init(sdl3.INIT_VIDEO)
		if !result {
			log.error("Failed to initialize SDL: ", sdl3.GetError())
			return nil
		}

		pluginFactory.vtable.queryInterface = pf_queryInterface
		pluginFactory.vtable.addRef = pf_addRef
		pluginFactory.vtable.release = pf_release

		pluginFactory.vtable.getFactoryInfo = pf_getFactoryInfo
		pluginFactory.vtable.countClasses = pf_countClasses
		pluginFactory.vtable.getClassInfo = pf_getClassInfo
		pluginFactory.vtable.createInstance = pf_createInstance

		pluginFactory.vtable.getClassInfo2 = pf_getClassInfo2

		pluginFactory.vtable.getClassInfoUnicode = pf_getClassInfoUnicode
		pluginFactory.vtable.setHostContext = pf_setHostContext

		pluginFactory.vtablePtr.lpVtbl = &pluginFactory.vtable

		pluginFactory.ctx = context
		pluginFactory.api = hotload_api()
		pluginFactory.initialized = true
	}

	return &pluginFactory.vtablePtr
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////////////////

@(test)
test_IsSameTuid :: proc(t: ^testing.T) {
	tuidToCstr :: proc (tuid: vst3.TUID, bits: ^[17]byte) {
		tuid := tuid
		bits^ = {}
		copy(bits[:16], tuid[:])
	}
	context.allocator = context.temp_allocator
	bits : [17]byte
	testStr := cast(^[16]byte)&bits[0]
	tuidToCstr(lindaleProcessorCid, &bits)
	testing.expect(t, vst3.is_same_tuid(&lindaleProcessorCid, testStr))
	tuidToCstr(vst3.iid_FUnknown, &bits)
	assert(!vst3.is_same_tuid(&lindaleProcessorCid, testStr))
	tuidToCstr(vst3.iid_IComponent, &bits)
	assert(!vst3.is_same_tuid(&lindaleProcessorCid, testStr))
	tuidToCstr(vst3.iid_IAudioProcessor, &bits)
	assert(!vst3.is_same_tuid(&lindaleProcessorCid, testStr))

	free_all(context.allocator)
}

@(test)
test_lindaleProcessor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	processor := createLindaleProcessor()
	testing.expect(t, processor != nil)
	testing.expect_value(t, processor.refCount, 0)

	// Test QueryInterface
	iidTestCases := []vst3.TUID {
		vst3.iid_FUnknown,
		vst3.iid_IComponent,
		vst3.iid_IPluginBase,
		vst3.iid_IAudioProcessor,
		vst3.iid_IProcessContextRequirements
	}

	obj: rawptr
	for testCase in iidTestCases {
		testCase := testCase

		result := processor.component->queryInterface(&testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.audioProcessor->queryInterface(&testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.processContextRequirements->queryInterface(&testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	startingRefCount := u32(3 * len(iidTestCases))

	// Test AddRef and Release
	refCount := processor.component->addRef()
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = processor.audioProcessor->addRef()
	testing.expect_value(t, refCount, startingRefCount + 2)

	refCount = processor.component->release()
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = processor.audioProcessor->release()
	testing.expect_value(t, refCount, startingRefCount)

	refCount = processor.component->release()
	testing.expect_value(t, refCount, startingRefCount - 1)
	refCount = processor.audioProcessor->release()
	testing.expect_value(t, refCount, startingRefCount - 2)

	invalidTuid := vst3.iid_IEditController2
	result := processor.component->queryInterface(&invalidTuid, &obj)
	testing.expect_value(t, result, vst3.kNoInterface)
	free_all(context.allocator)
}

@(test)
test_lindaleController :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	controller := createLindaleController()
	testing.expect(t, controller != nil)
	testing.expect_value(t, controller.refCount, 0)

	// Test QueryInterface
	iidTestCases := []vst3.TUID {
		vst3.iid_FUnknown,
		vst3.iid_IPluginBase,
		vst3.iid_IEditController,
		vst3.iid_IEditController2,
	}

	obj: rawptr
	for testCase in iidTestCases {
		testCase := testCase

		result := controller.editController->queryInterface(&testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = controller.editController2->queryInterface(&testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	startingRefCount := u32(2 * len(iidTestCases))

	// Test AddRef and Release
	refCount := controller.editController->addRef()
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = controller.editController2->addRef()
	testing.expect_value(t, refCount, startingRefCount + 2)

	refCount = controller.editController->release()
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = controller.editController2->release()
	testing.expect_value(t, refCount, startingRefCount)

	refCount = controller.editController->release()
	testing.expect_value(t, refCount, startingRefCount - 1)
	refCount = controller.editController2->release()
	testing.expect_value(t, refCount, startingRefCount - 2)

	invalidTuid := vst3.iid_IAudioProcessor
	result := controller.editController->queryInterface(&invalidTuid, &obj)
	testing.expect_value(t, result, vst3.kNoInterface)
	free_all(context.allocator)
}