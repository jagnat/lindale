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
	log_exit()
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
	params: ParamState,
	sampleRate: f64,
	ctx: runtime.Context,
}

dirty_disgusting_global_analysis: lin.AnalysisTransfer

createLindaleProcessor :: proc() -> ^LindaleProcessor {
	log.info("createLindaleProcessor")
	processor := new(LindaleProcessor)
	processor.refCount = 0

	processor.componentVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lp_comp_queryInterface,
			addRef = lp_comp_addRef,
			release = lp_comp_release,
		},

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
		funknown = vst3.FUnknownVtbl {
			queryInterface = lp_ap_queryInterface,
			addRef = lp_ap_addRef,
			release = lp_ap_release,
		},

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
		funknown = vst3.FUnknownVtbl {
			queryInterface = lp_pcr_queryInterface,
			addRef = lp_pcr_addRef,
			release = lp_pcr_release,
		},
		getProcessContextRequirements = lp_pcr_getProcessContextRequirements,
	}

	processor.component.lpVtbl = &processor.componentVtable
	processor.audioProcessor.lpVtbl = &processor.audioProcessorVtable
	processor.processContextRequirements.lpVtbl = &processor.processContextRequirementsVtable

	processor.ctx = context
	processor.ctx.logger = get_logger(.Processor)

	processor.plugin = lin.plugin_init({.Audio})

	for i in 0..<len(processor.params.values) {
		processor.params.values[i] = param_to_norm(ParamTable[i].range.defaultValue, ParamTable[i].range)
	}

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
			ctx.lpVtbl.addRef(ctx)
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
		numOutputs := data.numOutputs
		outputs := data.outputs
		inputs := data.inputs

		// Fetch parameter updates
		if data.inputParameterChanges != nil && data.inputParameterChanges.lpVtbl != nil {
			paramCount := data.inputParameterChanges.lpVtbl.getParameterCount(data.inputParameterChanges)

			for i in 0..<paramCount {
				paramQueue := data.inputParameterChanges.lpVtbl.getParameterData(data.inputParameterChanges, i)
				if paramQueue != nil && paramQueue.lpVtbl != nil {
					paramId := paramQueue.lpVtbl.getParameterId(paramQueue)
					pointCount := paramQueue.lpVtbl.getPointCount(paramQueue)
					if pointCount > 0 {
						sampleOffs: i32
						normParam : f64
						result := paramQueue.lpVtbl.getPoint(paramQueue, pointCount - 1, &sampleOffs, &normParam)
						if result == vst3.kResultOk {
							processor.params.values[paramId] = normParam
						}
					}
				}
			}
		}

		freq := norm_to_param(processor.params.values[2], ParamTable[2].range)
		samplesPerHalfPeriod := cast(i32)(processor.sampleRate / (2 * freq))

		mix := f32(processor.params.values[1]) // keep mix normalized, 0 to 1

		@(static) squarePhase : i32 = 0

		// Generate output buffer
		for s in 0..< numSamples {
			AMPLITUDE :: 0.01
			squareVal : f32= squarePhase < samplesPerHalfPeriod ? AMPLITUDE : -AMPLITUDE
			squarePhase += 1
			if squarePhase >= 2 * samplesPerHalfPeriod do squarePhase = 0

			for i in 0 ..< numOutputs {
				outputBufs := outputs[i].channelBuffers32
				numChannels := outputs[i].numChannels
				inputBufs := inputs[i].channelBuffers32

				for c in 0..<numChannels {
					inVal : f32 = 0
					if data.numInputs > 0 && inputs[i].numChannels > c {
						inVal = inputs[i].channelBuffers32[c][s]
					}
					out := outputBufs[c]
					out[s] = mix * squareVal + (1 - mix) * inVal
					if c == 0 {
						dirty_disgusting_global_analysis.buf[dirty_disgusting_global_analysis.writeIndex] = out[s]
						dirty_disgusting_global_analysis.writeIndex = (dirty_disgusting_global_analysis.writeIndex + 1) % lin.ANALYSIS_BUFFER_SIZE
					}
				}
			}
		}

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
	paramState: ParamState,
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
		funknown = vst3.FUnknownVtbl {
			queryInterface = lc_ec_queryInterface,
			addRef = lc_ec_addRef,
			release = lc_ec_release,
		},

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
		funknown = vst3.FUnknownVtbl {
			queryInterface = lc_ec2_queryInterface,
			addRef = lc_ec2_addRef,
			release = lc_ec2_release,
		},

		setKnobMode = lc_ec2_setKnobMode,
		openHelp = lc_ec2_openHelp,
		openAboutBox = lc_ec2_openAboutBox,
	}

	controller.ctx = context
	controller.ctx.logger = get_logger(.Controller)

	for i in 0..<len(controller.paramState.values) {
		controller.paramState.values[i] = param_to_norm(ParamTable[i].range.defaultValue, ParamTable[i].range)
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
		return len(ParamTable)
	}
	lc_ec_getParameterInfo :: proc "system" (this: rawptr, paramIndex: i32, info: ^vst3.ParameterInfo) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx

		if paramIndex >= len(ParamTable) {
			return vst3.kInvalidArgument
		}

		paramInfo := ParamTable[paramIndex]

		info^ = vst3.ParameterInfo {
			id = paramInfo.id,
			stepCount = paramInfo.range.stepCount,
			defaultNormalizedValue = param_to_norm(paramInfo.range.defaultValue, paramInfo.range),
			unitId = vst3.kRootUnitId,
			flags = {.kCanAutomate,},
		}

		utf16.encode_string(info.title[:], paramInfo.name)
		utf16.encode_string(info.shortTitle[:], paramInfo.shortName)
		utf16.encode_string(info.units[:], ParamUnitTypeStrings[paramInfo.range.unit])

		return vst3.kResultOk
	}
	lc_ec_getParamStringByValue :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue, str: ^vst3.String128) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx

		buffer: [128]u8
		paramVal := norm_to_param(valueNormalized, ParamTable[id].range)
		print_param_to_buf(&buffer, paramVal, ParamTable[id])
		utf16.encode_string(str[:128], string(buffer[:128]))

		return vst3.kResultOk
	}
	lc_ec_getParamValueByString :: proc "system" (this: rawptr, id: vst3.ParamID, str: [^]vst3.TChar, valueNormalized: ^vst3.ParamValue) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx

		buffer: [128]u8
		utf16.decode_to_utf8(buffer[:], str[:128])
		paramVal := get_param_from_buf(&buffer)
		valueNormalized^ = param_to_norm(paramVal, ParamTable[id].range)

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
		return controller.paramState.values[id]
	}
	lc_ec_setParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, value: vst3.ParamValue) -> vst3.TResult {
		controller := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		context = controller.ctx
		controller.paramState.values[id] = value
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
		log.info("Editor opened")
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
	renderThread: ^thread.Thread,
	renderThreadRunning: bool,
}

render_thread_proc :: proc(t: ^thread.Thread) {
	view: ^LindaleView = cast(^LindaleView)t.data

	for view.renderThreadRunning {
		time.sleep(time.Millisecond * 5)

		if view.plugin != nil && view.plugin.render != nil {

			buffer2: lin.AnalysisTransfer

			{
				buffer : lin.AnalysisTransfer = dirty_disgusting_global_analysis

				// Re-linearize
				firstLen := lin.ANALYSIS_BUFFER_SIZE - buffer.writeIndex
				copy(buffer2.buf[:firstLen], buffer.buf[buffer.writeIndex:])
				copy(buffer2.buf[firstLen:], buffer.buf[:buffer.writeIndex])
			}

			// lin.plugin_do_analysis(view.plugin, &buffer2)
			// lin.plugin_draw(view.plugin)
			pluginFactory.api.do_analysis(view.plugin, &buffer2)
			pluginFactory.api.draw(view.plugin)
		}
	}
}

createLindaleView :: proc(view: ^LindaleView, plug: ^lin.Plugin) -> vst3.TResult {
	view.pluginViewVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lv_queryInterface,
			addRef = lv_addRef,
			release = lv_release,
		},

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

		if view.renderThread == nil {
			view.renderThread = thread.create(render_thread_proc)
			if view.renderThread != nil {
				view.renderThread.init_context = context
				view.renderThread.data = view
				view.renderThreadRunning = true
				thread.start(view.renderThread)
			}
		} else {
			log.warn("Render thread already exists, not creating a new one")
		}

		log.info("lv_attached created window")
		return vst3.kResultOk
	}
	lv_removed :: proc "system" (this: rawptr) -> vst3.TResult {
		view := container_of(cast(^vst3.IPlugView)this, LindaleView, "pluginView")
		context = view.ctx
		log.info("lv_removed")

		if view.renderThread != nil && view.renderThreadRunning {
			view.renderThreadRunning = false
			thread.join(view.renderThread)
			thread.destroy(view.renderThread)
			view.renderThread = nil
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
	log_init(get_config().runtimeFolderPath)
	context.logger = get_logger(.PluginFactory)

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

		funknown := vst3.FUnknownVtbl {
			queryInterface = pf_queryInterface,
			addRef = pf_addRef,
			release = pf_release,
		}

		pluginFactory.vtable.funknown = funknown

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

				if vst3.is_same_tuid(&vst3.iid_IComponent, iid) {
					log.debug("CreateInstance iComponent")
					obj^ = &processor.component;
					processor.componentVtable.funknown.addRef(&processor.component);
					return vst3.kResultOk;
				} else if vst3.is_same_tuid(&vst3.iid_IAudioProcessor, iid) {
					log.debug("CreateInstance audioProcessor")
					obj^ = &processor.audioProcessor;
					processor.audioProcessorVtable.funknown.addRef(&processor.audioProcessor);
					return vst3.kResultOk;
				}

				free(processor)

				log.error("CreateInstance noiid")

				// No interface found
				obj^ = nil;
				return vst3.kNoInterface;

			} else if vst3.is_same_tuid(&lindaleControllerCid, cid) {
				controller := createLindaleController()

				if vst3.is_same_tuid(&vst3.iid_IEditController, iid) {
					log.info("CreateInstance editController")
					obj^ = &controller.editController
					controller.editControllerVtable.funknown.addRef(&controller.editController)
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

		result := sdl3.Init(sdl3.INIT_VIDEO | sdl3.INIT_AUDIO)
		if !result  {
			log.error("Failed to initialize SDL: ", sdl3.GetError())
			return nil
		}

		pluginFactory.api = hotload_api()

		pluginFactory.vtable.getFactoryInfo = pf_getFactoryInfo
		pluginFactory.vtable.countClasses = pf_countClasses
		pluginFactory.vtable.getClassInfo = pf_getClassInfo
		pluginFactory.vtable.createInstance = pf_createInstance

		pluginFactory.vtable.getClassInfo2 = pf_getClassInfo2

		pluginFactory.vtable.getClassInfoUnicode = pf_getClassInfoUnicode
		pluginFactory.vtable.setHostContext = pf_setHostContext

		pluginFactory.vtablePtr.lpVtbl = &pluginFactory.vtable
		pluginFactory.ctx = context
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

		result := processor.componentVtable.funknown.queryInterface(&processor.component, &testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.audioProcessorVtable.funknown.queryInterface(&processor.audioProcessor, &testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.processContextRequirementsVtable.funknown.queryInterface(&processor.processContextRequirements, &testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	startingRefCount := u32(3 * len(iidTestCases))

	// Test AddRef and Release
	refCount := processor.componentVtable.funknown.addRef(&processor.component)
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = processor.audioProcessorVtable.funknown.addRef(&processor.audioProcessor)
	testing.expect_value(t, refCount, startingRefCount + 2)

	refCount = processor.componentVtable.funknown.release(&processor.component)
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = processor.audioProcessorVtable.funknown.release(&processor.audioProcessor)
	testing.expect_value(t, refCount, startingRefCount)

	refCount = processor.componentVtable.funknown.release(&processor.component)
	testing.expect_value(t, refCount, startingRefCount - 1)
	refCount = processor.audioProcessorVtable.funknown.release(&processor.audioProcessor)
	testing.expect_value(t, refCount, startingRefCount - 2)

	invalidTuid := vst3.iid_IEditController2
	result := processor.componentVtable.funknown.queryInterface(&processor.component, &invalidTuid, &obj)
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

		result := controller.editControllerVtable.funknown.queryInterface(&controller.editController, &testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = controller.editController2Vtable.funknown.queryInterface(&controller.editController2, &testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	startingRefCount := u32(2 * len(iidTestCases))

	// Test AddRef and Release
	refCount := controller.editControllerVtable.funknown.addRef(&controller.editController)
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = controller.editController2Vtable.funknown.addRef(&controller.editController2)
	testing.expect_value(t, refCount, startingRefCount + 2)

	refCount = controller.editControllerVtable.funknown.release(&controller.editController)
	testing.expect_value(t, refCount, startingRefCount + 1)
	refCount = controller.editController2Vtable.funknown.release(&controller.editController2)
	testing.expect_value(t, refCount, startingRefCount)

	refCount = controller.editControllerVtable.funknown.release(&controller.editController)
	testing.expect_value(t, refCount, startingRefCount - 1)
	refCount = controller.editController2Vtable.funknown.release(&controller.editController2)
	testing.expect_value(t, refCount, startingRefCount - 2)

	invalidTuid := vst3.iid_IAudioProcessor
	result := controller.editControllerVtable.funknown.queryInterface(&controller.editController, &invalidTuid, &obj)
	testing.expect_value(t, result, vst3.kNoInterface)
	free_all(context.allocator)
}