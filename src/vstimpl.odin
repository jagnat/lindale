package lindale

import "thirdparty/vst3"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:unicode/utf16"
import "base:runtime"
import "base:builtin"
import "core:sys/windows"

lindaleProcessorCid := vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4)
lindaleControllerCid := vst3.SMTG_INLINE_UID(0x1DD0528c, 0x269247AA, 0x85210051, 0xDAB98786)

debug_print :: proc(format: string, args: ..any) {
	when ODIN_OS == .Windows {
		buf: [512]u8;
		n := fmt.bprintf(buf[:], format, ..args);
		windows.OutputDebugStringA(strings.unsafe_string_to_cstring(n));
		windows.OutputDebugStringA("\n");
	}
}

LindalePluginFactory :: struct {
	vtablePtr: vst3.IPluginFactory3,
	vtable: vst3.IPluginFactory3Vtbl,
	initialized: bool,
	ctx: runtime.Context,
}

LindaleProcessor :: struct {
	component: vst3.IComponent,
	componentVtable: vst3.IComponentVtbl,
	audioProcessor: vst3.IAudioProcessor,
	audioProcessorVtable: vst3.IAudioProcessorVtbl,
	processContextRequirements: vst3.IProcessContextRequirements,
	processContextRequirementsVtable: vst3.IProcessContextRequirementsVtbl,
	refCount: u32,

	// Temp
	sampleRate: f64
}

LindaleController :: struct {
	editController: vst3.IEditController,
	editControllerVtable: vst3.IEditControllerVtbl,
	editController2: vst3.IEditController2,
	editController2Vtable: vst3.IEditController2Vtbl,
	refCount: u32
}

pluginFactory: LindalePluginFactory

@export InitModule :: proc "system" () -> c.bool {
	context = runtime.default_context()
	debug_print("Lindale: InitModule")
	return true
}

@export InitDll :: proc "system" () -> c.bool {
	context = runtime.default_context()
	debug_print("Lindale: InitDll")
	return true
}

@export DeinitModule :: proc "system" () -> c.bool {
	context = runtime.default_context()
	debug_print("Lindale: DeinitModule")
	return true
}

@export ExitDll :: proc "system" () -> c.bool {
	context = runtime.default_context()
	debug_print("Lindale: ExitDll")
	return true
}

createLindaleProcessor :: proc() -> ^LindaleProcessor {
	debug_print("Lindale: createLindaleProcessor")
	instance := new(LindaleProcessor)
	instance.refCount = 0

	instance.componentVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lp_comp_queryInterface,
			addRef = lp_comp_addRef,
			release = lp_comp_release,
		},

		initialize = lp_initialize,
		terminate = lp_terminate,

		getControllerClassId = lp_getControllerClassId,
		setIoMode = lp_setIoMode,
		getBusCount = lp_getBusCount,
		getBusInfo = lp_getBusInfo,
		getRoutingInfo = lp_getRoutingInfo,
		activateBus = lp_activateBus,
		setActive = lp_setActive,
		setState = lp_setState,
		getState = lp_getState,
	}

	instance.audioProcessorVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lp_ap_queryInterface,
			addRef = lp_ap_addRef,
			release = lp_ap_release,
		},

		setBusArrangements = lp_setBusArrangements,
		getBusArrangement = lp_getBusArrangement,
		canProcessSampleSize = lp_canProcessSampleSize,
		getLatencySamples = lp_getLatencySamples,
		setupProcessing = lp_setupProcessing,
		setProcessing = lp_setProcessing,
		process = lp_process,
		getTailSamples = lp_getTailSamples,
	}

	instance.processContextRequirementsVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lp_pcr_queryInterface,
			addRef = lp_pcr_addRef,
			release = lp_pcr_release,
		},
		getProcessContextRequirements = lp_getProcessContextRequirements,
	}

	instance.component.lpVtbl = &instance.componentVtable
	instance.audioProcessor.lpVtbl = &instance.audioProcessorVtable
	instance.processContextRequirements.lpVtbl = &instance.processContextRequirementsVtable

	// Universal LindaleProcessor queryInterface
	lp_queryInterfaceImplementation :: proc(this: ^LindaleProcessor, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		debug_print("iid: {:x}", iid)
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
		context = pluginFactory.ctx
		debug_print("Lindale: lp_comp_queryInterface")
		instance := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")

		return lp_queryInterfaceImplementation(instance, iid, obj)
	}
	lp_comp_addRef :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_comp_addRef")
		instance := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		instance.refCount += 1
		return instance.refCount
	}
	lp_comp_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_comp_release")
		instance := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		instance.refCount -= 1
		if instance.refCount == 0 {
			debug_print("Lindale: lp_comp_release free")
			free(instance)
		}
		return instance.refCount
	}
	lp_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_initialize")
		return vst3.kResultOk
	}
	lp_terminate :: proc "system" (this: rawptr) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_terminate")
		return vst3.kResultOk
	}
	lp_getControllerClassId :: proc "system" (this: rawptr, classId: ^vst3.TUID) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_getControllerClassId")
		classId^ = lindaleControllerCid
		return vst3.kResultOk
	}
	lp_setIoMode :: proc "system" (this: rawptr, mode: vst3.IoMode) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getBusCount :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection) -> i32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_getBusCount")
		if type == .Audio {
			if dir == .Input || dir == .Output {
				return 1
			}
		}
		return 0
	}
	lp_getBusInfo :: proc "system" (
		this: rawptr,
		type: vst3.MediaType,
		dir: vst3.BusDirection,
		index: i32,
		bus: ^vst3.BusInfo
	) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_getBusInfo")

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
	lp_getRoutingInfo :: proc "system" (this: rawptr, inInfo, outInfo: ^vst3.RoutingInfo) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_getRoutingInfo")
		return vst3.kResultOk
	}
	lp_activateBus :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection, index: i32, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_setActive :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_setState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getState :: proc "system" (this: rawptr, state: ^vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}

	// IAudioProcessor
	lp_ap_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_ap_queryInterface")
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")

		return lp_queryInterfaceImplementation(instance, iid, obj)
	}
	lp_ap_addRef :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_ap_addRef")
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		instance.refCount += 1
		return instance.refCount
	}
	lp_ap_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_ap_release")
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		instance.refCount -= 1
		if instance.refCount == 0 {
			free(instance)
		}
		return instance.refCount
	}
	lp_setBusArrangements :: proc "system" (
		this: rawptr,
		inputs: ^vst3.SpeakerArrangement,
		numIns: i32,
		outputs: ^vst3.SpeakerArrangement,
		numOuts: i32
	) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getBusArrangement :: proc "system" (
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
	lp_canProcessSampleSize :: proc "system" (this: rawptr, sss: vst3.SymbolicSampleSize) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_canProcessSampleSize")
		if sss == .Sample32 {
			return vst3.kResultOk
		}
		return vst3.kNotImplemented
	}
	lp_getLatencySamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}
	lp_setupProcessing :: proc "system" (this: rawptr, setup: ^vst3.ProcessSetup) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_setupProcessing")
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")

		instance.sampleRate = setup.sampleRate

		return vst3.kResultOk
	}
	lp_setProcessing :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}

	lp_process :: proc "system" (this: rawptr, data: ^vst3.ProcessData) -> vst3.TResult {
		context = pluginFactory.ctx
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		freq :: 440.0
		numSamples := data.numSamples
		numOutputs := data.numOutputs
		outputs := data.outputs
		samplesPerHalfPeriod := cast(i32)(instance.sampleRate / (2 * freq))

		@(static) squarePhase : i32 = 0

		for s in 0..< numSamples {
			val : f32= squarePhase < samplesPerHalfPeriod ? 0.2 : -0.2
			squarePhase += 1
			if squarePhase >= 2 * samplesPerHalfPeriod do squarePhase = 0

			for i in 0 ..< numOutputs {
				bufs := outputs[i].channelBuffers32
				numChannels := outputs[i].numChannels
				for c in 0..<numChannels {
					out := bufs[c]
					out[s] = val
				}
			}
		}

		return vst3.kResultOk
	}
	lp_getTailSamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}

	// IProcessContextRequirements
	lp_pcr_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_pcr_queryInterface")
		instance := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")

		return lp_queryInterfaceImplementation(instance, iid, obj)
	}

	lp_pcr_addRef :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_pcr_addRef")
		instance := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")
		instance.refCount += 1
		return instance.refCount
	}

	lp_pcr_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_pcr_release")
		instance := container_of(cast(^vst3.IProcessContextRequirements)this, LindaleProcessor, "processContextRequirements")
		instance.refCount -= 1
		if instance.refCount == 0 {
			free(instance)
		}
		return instance.refCount
	}

	lp_getProcessContextRequirements :: proc "system" (this: rawptr) -> vst3.IProcessContextRequirementsFlagSet {
		context = pluginFactory.ctx
		debug_print("Lindale: lp_getProcessContextRequirements")

		return {.None}
	}


	return instance
}

createLindaleController :: proc () -> ^LindaleController {
	debug_print("Lindale: createLindaleController")
	instance := new(LindaleController)
	instance.refCount = 0

	instance.editController.lpVtbl = &instance.editControllerVtable
	instance.editController2.lpVtbl = &instance.editController2Vtable

	instance.editControllerVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lc_ec1_queryInterface,
			addRef = lc_ec1_addRef,
			release = lc_ec1_release,
		},

		initialize = lc_initialize,
		terminate = lc_terminate,

		setComponentState = lc_setComponentState,
		setState = lc_setState,
		getState = lc_getState,
		getParameterCount = lc_getParameterCount,
		getParameterInfo = lc_getParameterInfo,
		getParamStringByValue = lc_getParamStringByValue,
		getParamValueByString = lc_getParamValueByString,
		normalizedParamToPlain = lc_normalizedParamToPlain,
		plainParamToNormalized = lc_plainParamToNormalized,
		getParamNormalized = lc_getParamNormalized,
		setParamNormalized = lc_setParamNormalized,
		setComponentHandler = lc_setComponentHandler,
		createView = lc_createView,
	}

	instance.editController2Vtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lc_ec2_queryInterface,
			addRef = lc_ec2_addRef,
			release = lc_ec2_release,
		},

		setKnobMode = lc_setKnobMode,
		openHelp = lc_openHelp,
		openAboutBox = lc_openAboutBox,
	}

	// Universal queryInterface
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
	lc_ec1_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_queryInterface")
		instance := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")

		return lc_queryInterface(instance, iid, obj)
	}
	lc_ec1_addRef :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_addRef")
		instance := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		instance.refCount += 1
		return instance.refCount
	}
	lc_ec1_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_release")
		instance := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		instance.refCount -= 1
		if instance.refCount == 0 {
			free(instance)
		}
		return instance.refCount
	}
	lc_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_terminate  :: proc "system" (this: rawptr) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_setComponentState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_setState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_getState :: proc "system" (this: rawptr, state: ^ vst3.IBStream) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_getParameterCount :: proc "system" (this: rawptr) -> i32 {
		return 0
	}
	lc_getParameterInfo :: proc "system" (this: rawptr, paramIndex: i32, info: ^vst3.ParameterInfo) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_getParamStringByValue :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue, str: vst3.String128) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_getParamValueByString :: proc "system" (this: rawptr, id: vst3.ParamID, str: ^vst3.TChar, valueNormalized: ^vst3.ParamValue) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_normalizedParamToPlain :: proc "system" (this: rawptr, id: vst3.ParamID, valueNormalized: vst3.ParamValue) -> vst3.ParamValue {
		return 0
	}
	lc_plainParamToNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, plainValue: vst3.ParamValue) -> vst3.ParamValue {
		return 0
	}
	lc_getParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID) -> vst3.ParamValue {
		return 0
	}
	lc_setParamNormalized :: proc "system" (this: rawptr, id: vst3.ParamID, value: vst3.ParamValue) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_setComponentHandler :: proc "system" (this: rawptr, handler: ^vst3.IComponentHandler) -> vst3.TResult {
		return vst3.kResultOk
	}
	lc_createView :: proc "system" (this: rawptr, name: vst3.FIDString) -> ^vst3.IPlugView {
		return nil
	}

	// EditController2
	lc_ec2_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_ec2_queryInterface")
		instance := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")

		return lc_queryInterface(instance, iid, obj)
	}
	lc_ec2_addRef :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_ec2_addRef")
		instance := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		instance.refCount += 1
		return instance.refCount
	}
	lc_ec2_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_ec2_release")
		instance := container_of(cast(^vst3.IEditController2)this, LindaleController, "editController2")
		instance.refCount -= 1
		if instance.refCount == 0 {
			free(instance)
		}
		return instance.refCount
	}
	lc_setKnobMode :: proc "system" (this: rawptr, mode: vst3.KnobMode) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_setKnobMode")
		return vst3.kResultOk
	}
	lc_openHelp :: proc "system" (this: rawptr, onlyCheck: vst3.TBool) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_openHelp")
		return vst3.kResultOk
	}
	lc_openAboutBox :: proc "system" (this: rawptr, onlyCheck: vst3.TBool) -> vst3.TResult {
		context = pluginFactory.ctx
		debug_print("Lindale: lc_openAboutBox")
		return vst3.kResultOk
	}

	return instance
}

@export GetPluginFactory :: proc "system" () -> ^vst3.IPluginFactory3 {
	context = runtime.default_context()

	debug_print("Lindale: GetPluginFactory")

	if !pluginFactory.initialized {
		pf_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
			context = pluginFactory.ctx
			debug_print("Lindale: pf_queryInterface")
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
			debug_print("Lindale: pf_addRef")
			return 1
		}

		pf_release :: proc "system" (this: rawptr) -> u32 {
			context = pluginFactory.ctx
			debug_print("Lindale: pf_release")
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
			debug_print("Lindale: getFactoryInfo")
			copy(info.vendor[:], "JagI")
			copy(info.url[:], "jagi.quest")
			copy(info.email[:], "jagi@jagi.quest")
			info.flags = 0
			return vst3.kResultOk
		}

		pf_countClasses :: proc "system" (this: rawptr) -> i32 {
			context = pluginFactory.ctx
			debug_print("Lindale: countClasses")
			return 2 // LindaleProcessor and LindaleController
		}

		pf_getClassInfo :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo) -> vst3.TResult {
			context = pluginFactory.ctx
			debug_print("Lindale: getClassInfo")
			if index >= 2 {
				debug_print("Lindale: getClassInfo index >= 2")
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
			debug_print("Lindale: createInstance")

			cidPtr: [^]u8 = cast([^]u8)cid
			cidAry := cidPtr[0:16]

			debug_print("cid: {:x}", cidAry)
			debug_print("processorCid: {:x}", lindaleProcessorCid)
			debug_print("controllerCid: {:x}", lindaleControllerCid)

			if vst3.is_same_tuid(&lindaleProcessorCid, cid) {
				processor := createLindaleProcessor()

				if vst3.is_same_tuid(&vst3.iid_IComponent, iid) {
					debug_print("Lindale: CreateInstance iComponent")
					obj^ = &processor.component;
					processor.componentVtable.funknown.addRef(&processor.component);
					return vst3.kResultOk;
				} else if vst3.is_same_tuid(&vst3.iid_IAudioProcessor, iid) {
					debug_print("Lindale: CreateInstance audioProcessor")
					obj^ = &processor.audioProcessor;
					processor.audioProcessorVtable.funknown.addRef(&processor.audioProcessor);
					return vst3.kResultOk;
				}

				free(processor)

				debug_print("Lindale: CreateInstance noiid")

				// No interface found
				obj^ = nil;
				return vst3.kNoInterface;

			} else if vst3.is_same_tuid(&lindaleControllerCid, cid) {
				controller := createLindaleController()

				if vst3.is_same_tuid(&vst3.iid_IEditController, iid) {
					debug_print("Lindale: CreateInstance editController")
					obj^ = &controller.editController
					controller.editControllerVtable.funknown.addRef(&controller.editController)
					return vst3.kResultOk
				}

				free(controller)
				obj^ = nil
				return vst3.kNoInterface
			}

			debug_print("Lindale: CreateInstance nocid")

			return vst3.kNoInterface
		}

		pf_getClassInfo2 :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo2) -> vst3.TResult {
			context = pluginFactory.ctx
			debug_print("Lindale: getClassInfo2 with index {:d}", index)
			if index >= 2 {
				debug_print("Lindale: getClassInfo2 index >= 2")
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
			debug_print("Lindale: getClassInfoUnicode with index {:d}", index)
			if index >= 2 {
				debug_print("Lindale: getClassInfoU index >= 2")
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
			debug_print("Lindale: setHostContext")
			return vst3.kResultOk
		}

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