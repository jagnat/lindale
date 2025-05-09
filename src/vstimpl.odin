package lindale

import "thirdparty/vst3"
import "core:c"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:unicode/utf16"
import "base:runtime"
import "base:builtin"
import "core:sys/windows"

lindaleProcessorCid := vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4)
lindaleControllerCid := vst3.SMTG_INLINE_UID(0x1DD0528c, 0x269247AA, 0x85210051, 0xDAB98786)

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
	refCount: u32,
}

LindaleController :: struct {
	editController: vst3.IEditController,
	editControllerVtable: vst3.IEditControllerVtbl,
	refCount: u32
}

pluginFactory: LindalePluginFactory

@export InitModule :: proc "system" () -> c.bool {
	return true
}

@export DeinitModule :: proc "system" () -> c.bool {
	return true
}

createLindaleProcessor :: proc() -> ^LindaleProcessor {
	windows.OutputDebugStringA("Lindale: createLindaleProcessor")
	instance := new(LindaleProcessor)
	instance.refCount = 0
	instance.component.lpVtbl = &instance.componentVtable
	instance.audioProcessor.lpVtbl = &instance.audioProcessorVtable

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

	// IComponent
	lp_comp_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		instance := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IComponent {
			obj^ = &instance.component
		} else if  iid^ == vst3.iid_IAudioProcessor {
			obj^ = &instance.audioProcessor
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		lp_comp_addRef(this)

		return vst3.kResultOk
	}
	lp_comp_addRef :: proc "system" (this: rawptr) -> u32 {
		instance := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		instance.refCount += 1
		return instance.refCount
	}
	lp_comp_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		instance := container_of(cast(^vst3.IComponent)this, LindaleProcessor, "component")
		instance.refCount -= 1
		if instance.refCount == 0 {
			free(instance)
		}
		return instance.refCount
	}
	lp_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_terminate :: proc "system" (this: rawptr) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getControllerClassId :: proc "system" (this: rawptr, classId: ^vst3.TUID) -> vst3.TResult {
		classId^ = lindaleControllerCid
		return vst3.kResultOk
	}
	lp_setIoMode :: proc "system" (this: rawptr, mode: vst3.IoMode) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getBusCount :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection) -> i32 {
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
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IAudioProcessor{
			obj^ = &instance.audioProcessor
		} else if  iid^ == vst3.iid_IComponent {
			obj^ = &instance.component
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		lp_ap_addRef(this)

		return vst3.kResultOk
	}
	lp_ap_addRef :: proc "system" (this: rawptr) -> u32 {
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		instance.refCount += 1
		return instance.refCount
	}
	lp_ap_release :: proc "system" (this: rawptr) -> u32 {
		context = pluginFactory.ctx
		instance := container_of(cast(^vst3.IAudioProcessor)this, LindaleProcessor, "audioProcessor")
		instance.refCount -= 1
		if instance.refCount == 0 {
			free(instance)
		}
		return instance.refCount
	}
	lp_setBusArrangements :: proc "system" (this: rawptr, inputs: ^vst3.SpeakerArrangement, numIns: i32, outputs: ^vst3.SpeakerArrangement, numOuts: i32) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getBusArrangement :: proc "system" (this: rawptr, dir: vst3.BusDirection, index: i32, arr: ^vst3.SpeakerArrangement) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_canProcessSampleSize :: proc "system" (this: rawptr, sss: vst3.SymbolicSampleSize) -> vst3.TResult {
		if sss == .Sample32 {
			return vst3.kResultOk
		}
		return vst3.kNotImplemented
	}
	lp_getLatencySamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}
	lp_setupProcessing :: proc "system" (this: rawptr, setup: ^vst3.ProcessSetup) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_setProcessing :: proc "system" (this: rawptr, state: vst3.TBool) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_process :: proc "system" (this: rawptr, data: ^vst3.ProcessData) -> vst3.TResult {
		context = pluginFactory.ctx
		numSamples := data.numSamples
		numOutputs := data.numOutputs
		outputs := data.outputs

		for i in 0 ..< numOutputs {
			bufs := outputs[i].channelBuffers32
			numChannels := outputs[i].numChannels
			for c in 0..<numChannels {
				out := bufs[c]
				slice.zero(out[:numSamples])
			}
		}

		return vst3.kResultOk
	}
	lp_getTailSamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}

	return instance
}

createLindaleController :: proc () -> ^LindaleController {
	windows.OutputDebugStringA("Lindale: createLindaleController")
	instance := new(LindaleController)
	instance.refCount = 0
	instance.editController.lpVtbl = &instance.editControllerVtable

	instance.editControllerVtable = {
		funknown = vst3.FUnknownVtbl {
			queryInterface = lc_queryInterface,
			addRef = lc_addRef,
			release = lc_release,
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

	lc_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		instance := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IEditController {
			obj^ = &instance.editController
		} else {
			obj^ = nil
			return vst3.kNoInterface
		}

		lc_addRef(this)

		return vst3.kResultOk
	}
	lc_addRef :: proc "system" (this: rawptr) -> u32 {
		instance := container_of(cast(^vst3.IEditController)this, LindaleController, "editController")
		instance.refCount += 1
		return instance.refCount
	}
	lc_release :: proc "system" (this: rawptr) -> u32 {
		context = runtime.default_context()
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

	return instance
}

@export GetPluginFactory :: proc "system" () -> ^vst3.IPluginFactory3 {
	context = runtime.default_context()

	windows.OutputDebugStringA("Lindale: GetPluginFactory")

	if !pluginFactory.initialized {
		pf_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: pf_queryInterface")
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
			windows.OutputDebugStringA("Lindale: pf_addRef")
			return 1
		}

		pf_release :: proc "system" (this: rawptr) -> u32 {
			windows.OutputDebugStringA("Lindale: pf_release")
			return 1
		}

		funknown := vst3.FUnknownVtbl {
			queryInterface = pf_queryInterface,
			addRef = pf_addRef,
			release = pf_release,
		}

		pluginFactory.vtable.funknown = funknown

		pf_getFactoryInfo :: proc "system" (this: rawptr, info: ^vst3.PFactoryInfo) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: getFactoryInfo")
			copy(info.vendor[:], "JagI")
			copy(info.url[:], "jagi.quest")
			copy(info.email[:], "jagi@jagi.quest")
			info.flags = 0
			return vst3.kResultOk
		}

		pf_countClasses :: proc "system" (this: rawptr) -> i32 {
			windows.OutputDebugStringA("Lindale: countClasses")
			return 2 // LindaleProcessor and LindaleController
		}

		pf_getClassInfo :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: getClassInfo")
			if index >= 2 {
				return vst3.kInvalidArgument
			}

			info^ = vst3.PClassInfo {
				cid = index == 0 ? lindaleProcessorCid : lindaleControllerCid,
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
			}

			copy(info.category[:], "Audio Module Class")
			copy(info.name[:], "Lindale")

			return vst3.kResultOk
		}

		pf_createInstance :: proc "system" (this: rawptr, cid: vst3.FIDString, iid: vst3.FIDString, obj: ^rawptr) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: createInstance")
			context = pluginFactory.ctx
			windows.OutputDebugStringA("Lindale: createInstance after runtime init")

			if vst3.is_same_tuid(lindaleProcessorCid, cid) {
				processor := createLindaleProcessor()

				if vst3.is_same_tuid(vst3.iid_IComponent, iid) {
					windows.OutputDebugStringA("Lindale: CreateInstance iComponent")
					obj^ = &processor.component;
					return vst3.kResultOk;
				} else if vst3.is_same_tuid(vst3.iid_IAudioProcessor, iid) {
					windows.OutputDebugStringA("Lindale: CreateInstance audioProcessor")
					obj^ = &processor.audioProcessor;
					return vst3.kResultOk;
				}

				free(processor)

				windows.OutputDebugStringA("Lindale: CreateInstance noiid")

				// No interface found
				obj^ = nil;
				return vst3.kNoInterface;

			} else if vst3.is_same_tuid(lindaleControllerCid, cid) {
				controller := createLindaleController()

				if vst3.is_same_tuid(vst3.iid_IEditController, iid) {
					obj^ = &controller.editController
					return vst3.kResultOk
				}

				free(controller)
				obj^ = nil
				return vst3.kNoInterface
			}

			windows.OutputDebugStringA("Lindale: CreateInstance nocid")

			return vst3.kNoInterface
		}

		pf_getClassInfo2 :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo2) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: getClassInfo2")
			if index >= 2 {
				return vst3.kInvalidArgument
			}

			info^ = vst3.PClassInfo2 {
				cid = index == 0? lindaleProcessorCid : lindaleControllerCid,
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
				classFlags = 0,
				subCategories = {},
				vendor = {},
				version = {},
				sdkVersion = {}
			}

			copy(info.category[:], "Audio Module Class")
			copy(info.name[:], "Lindale")
			copy(info.subCategories[:], "Fx")
			copy(info.vendor[:], "JagI")
			copy(info.version[:], "0.0.1")
			copy(info.sdkVersion[:], "VST 3.7.13")

			return vst3.kResultOk
		}

		pf_getClassInfoUnicode :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfoW) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: getClassInfoUnicode")
			context = pluginFactory.ctx
			if index >= 2 {
				return vst3.kInvalidArgument
			}
			info^ = vst3.PClassInfoW {
				cid = index == 0? lindaleProcessorCid : lindaleControllerCid,
				cardinality = vst3.kManyInstances,
				category = {},
				name = {},
				classFlags = 0,
				subCategories = {},
				vendor = {},
				version = {},
				sdkVersion = {}
			}

			copy(info.category[:], "Audio Module Class")
			utf16.encode_string(info.name[:], "Lindale")
			copy(info.subCategories[:], "Fx")
			utf16.encode_string(info.vendor[:], "JagI")
			utf16.encode_string(info.version[:], "0.0.1")
			utf16.encode_string(info.sdkVersion[:], "VST 3.7.13")

			return vst3.kResultOk
		}

		pf_setHostContext :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
			windows.OutputDebugStringA("Lindale: setHostContext")
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

	windows.OutputDebugStringA("Lindale: GetPluginFactory returnin vtablePtr")
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
	testStr : cstring = cast(cstring)&bits[0]
	tuidToCstr(lindaleProcessorCid, &bits)
	testing.expect(t, vst3.is_same_tuid(lindaleProcessorCid, testStr))
	tuidToCstr(vst3.iid_FUnknown, &bits)
	assert(!vst3.is_same_tuid(lindaleProcessorCid, testStr))
	tuidToCstr(vst3.iid_IComponent, &bits)
	assert(!vst3.is_same_tuid(lindaleProcessorCid, testStr))
	tuidToCstr(vst3.iid_IAudioProcessor, &bits)
	assert(!vst3.is_same_tuid(lindaleProcessorCid, testStr))

	free_all(context.allocator)
}

@(test)
test_CreateLindaleProcessor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	processor := createLindaleProcessor()
	testing.expect(t, processor != nil)
	testing.expect(t, processor.refCount == 1)

	// Test QueryInterface
	iidTestCases := []vst3.TUID{vst3.iid_FUnknown, vst3.iid_IComponent, vst3.iid_IAudioProcessor}
	obj: rawptr
	for testCase in iidTestCases {
		testCase := testCase

		result := processor.componentVtable.funknown.queryInterface(&processor.component, &testCase, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)

		result = processor.audioProcessorVtable.funknown.queryInterface(&processor.audioProcessor, &vst3.iid_FUnknown, &obj)
		testing.expect_value(t, result, vst3.kResultOk)
		testing.expect(t, obj != nil)
	}

	// Test AddRef and Release
	refCount := processor.componentVtable.funknown.addRef(&processor.component)
	testing.expect_value(t, refCount, 7)
	refCount = processor.audioProcessorVtable.funknown.addRef(&processor.audioProcessor)
	testing.expect_value(t, refCount, 8)

	refCount = processor.componentVtable.funknown.release(&processor.component)
	testing.expect_value(t, refCount, 7)
	refCount = processor.audioProcessorVtable.funknown.release(&processor.audioProcessor)
	testing.expect_value(t, refCount, 6)

	refCount = processor.componentVtable.funknown.release(&processor.component)
	testing.expect_value(t, refCount, 5)
	refCount = processor.audioProcessorVtable.funknown.release(&processor.audioProcessor)
	testing.expect_value(t, refCount, 4)

	invalidTuid := vst3.iid_FUnknown + 1
	result := processor.componentVtable.funknown.queryInterface(&processor.component, &invalidTuid, &obj)
	testing.expect_value(t, result, vst3.kNoInterface)
	free_all(context.allocator)
}