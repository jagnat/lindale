package lindale

import "thirdparty/vst3"
import "core:c"
import "base:runtime"

lindaleCid := vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4)

LindalePluginFactory :: struct {
	vtablePtr: vst3.IPluginFactory,
	vtable: vst3.IPluginFactoryVtbl,
	initialized: bool,
}

LindaleProcessor :: struct {
	component: vst3.IComponent,
	componentVtable: vst3.IComponentVtbl,
	audioProcessor: vst3.IAudioProcessor,
	audioProcessorVtable: vst3.IAudioProcessorVtbl,
	refCount: u32,
}

pluginFactory: LindalePluginFactory

@export InitModule :: proc "system" () -> c.bool {
	return true
}

@export DeinitModule :: proc "system" () -> c.bool {
	return true
}

createLindaleProcessor :: proc() -> ^LindaleProcessor {
	instance := new(LindaleProcessor)
	instance.refCount = 1
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

	lp_comp_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IComponent {
			obj^ = this
			return vst3.kResultOk
		}
		obj^ = nil
		return vst3.kNoInterface
	}
	lp_comp_addRef :: proc "system" (this: rawptr) -> u32 {

		return 0
	}
	lp_comp_release :: proc "system" (this: rawptr) -> u32 {
		return 0
	}
	// IComponent
	lp_initialize :: proc "system" (this: rawptr, ctx: ^vst3.FUnknown) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_terminate :: proc "system" (this: rawptr) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getControllerClassId :: proc "system" (this: rawptr, classId: ^vst3.TUID) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_setIoMode :: proc "system" (this: rawptr, mode: vst3.IoMode) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getBusCount :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection) -> i32 {
		return 0
	}
	lp_getBusInfo :: proc "system" (this: rawptr, type: vst3.MediaType, dir: vst3.BusDirection, index: i32, bus: ^vst3.BusInfo) -> vst3.TResult {
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
		if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IAudioProcessor {
			obj^ = this
			return vst3.kResultOk
		}
		obj^ = nil
		return vst3.kNoInterface
	}
	lp_ap_addRef :: proc "system" (this: rawptr) -> u32 {
		return 0
	}
	lp_ap_release :: proc "system" (this: rawptr) -> u32 {
		return 0
	}
	lp_setBusArrangements :: proc "system" (this: rawptr, inputs: ^vst3.SpeakerArrangement, numIns: i32, outputs: ^vst3.SpeakerArrangement, numOuts: i32) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_getBusArrangement :: proc "system" (this: rawptr, dir: vst3.BusDirection, index: i32, arr: ^vst3.SpeakerArrangement) -> vst3.TResult {
		return vst3.kResultOk
	}
	lp_canProcessSampleSize :: proc "system" (this: rawptr, symbolicSampleSize: i32) -> vst3.TResult {
		return vst3.kResultOk
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
		return vst3.kResultOk
	}
	lp_getTailSamples :: proc "system" (this: rawptr) -> u32 {
		return 0
	}

	return instance
}

@export GetPluginFactory :: proc "system" () -> ^vst3.IPluginFactory {
	context = runtime.default_context()

	if !pluginFactory.initialized {
			pf_queryInterface :: proc "system" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.TResult {
				if iid^ == vst3.iid_FUnknown || iid^ == vst3.iid_IPluginFactory {
					obj^ = this
					return vst3.kResultOk
				}
				obj^ = nil
				return vst3.kNoInterface
			}

			pf_addRef :: proc "system" (this: rawptr) -> u32 {
				return 1
			}

			pf_release :: proc "system" (this: rawptr) -> u32 {
				return 0
			}

			funknown := vst3.FUnknownVtbl {
				queryInterface = pf_queryInterface,
				addRef = pf_addRef,
				release = pf_release,
			}

			pluginFactory.vtable.funknown = funknown

			pf_getFactoryInfo :: proc "system" (this: rawptr, info: ^vst3.PFactoryInfo) -> vst3.TResult {
				copy(info.vendor[:], "Jagi")
				copy(info.url[:], "jagi.quest")
				copy(info.email[:], "jagi@jagi.quest")
				info.flags = 0
				return vst3.kResultOk
			}

			pf_countClasses :: proc "system" (this: rawptr) -> i32 {
				return 1
			}

			pf_getClassInfo :: proc "system" (this: rawptr, index: i32, info: ^vst3.PClassInfo) -> vst3.TResult {
				if index != 0 {
					return vst3.kInvalidArgument
				}

				info^ = vst3.PClassInfo {
					cid = lindaleCid,
					cardinality = vst3.kManyInstances,
					category = {},
					name = {},
				}

				copy(info.category[:], "Instrument")
				copy(info.name[:], "Lindale")

				return vst3.kResultOk
			}

			pf_createInstance :: proc "system" (this: rawptr, cid, iid: vst3.FIDString, obj: ^rawptr) -> vst3.TResult {
				context = runtime.default_context()

				if vst3.is_same_tuid(lindaleCid, cid) {
					processor := createLindaleProcessor()

					if vst3.is_same_tuid(vst3.iid_IComponent, iid) {
						obj^ = &processor.component;
						return vst3.kResultOk;
					} else if vst3.is_same_tuid(vst3.iid_IAudioProcessor, iid) {
						obj^ = &processor.audioProcessor;
						return vst3.kResultOk;
					}

					free(processor)

					// No interface found
					obj^ = nil;
					return vst3.kNoInterface;
				}

				return vst3.kNoInterface
			}

			pluginFactory.vtable.getFactoryInfo = pf_getFactoryInfo
			pluginFactory.vtable.countClasses = pf_countClasses
			pluginFactory.vtable.getClassInfo = pf_getClassInfo
			pluginFactory.vtable.createInstance = pf_createInstance


			pluginFactory.vtablePtr.lpVtbl = &pluginFactory.vtable
		pluginFactory.initialized = true
	}

	return &pluginFactory.vtablePtr
}
