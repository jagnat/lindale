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

LindaleInstance :: struct {
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

createLindaleInstance :: proc() -> ^LindaleInstance {
	instance := new(LindaleInstance)
	instance.refCount = 1
	instance.component.lpVtbl = &instance.componentVtable
	instance.audioProcessor.lpVtbl = &instance.audioProcessorVtable

	return instance
}

@export GetPluginFactory :: proc "system" () -> ^vst3.IPluginFactory {
	context = runtime.default_context()

	if !pluginFactory.initialized {

			pf_queryInterface :: proc "system" (this: rawptr, iid: vst3.TUID, obj: ^rawptr) -> vst3.TResult {
				if iid == vst3.iid_FUnknown || iid == vst3.iid_IPluginFactory {
					obj^ = this
				}
				return 0
			}

			pf_addRef :: proc "system" (this: rawptr) -> u32 {
				return 1
			}

			pf_release :: proc "system" (this: rawptr) -> u32 {
				return 0
			}

			pluginFactory.vtable.queryInterface = pf_queryInterface
			pluginFactory.vtable.addRef = pf_addRef
			pluginFactory.vtable.release = pf_release


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
					instance := createLindaleInstance()

					if vst3.is_same_tuid(vst3.iid_IComponent, iid) {
						obj^ = &instance.component;
						return vst3.kResultOk;
					} else if vst3.is_same_tuid(vst3.iid_IAudioProcessor, iid) {
						obj^ = &instance.audioProcessor;
						return vst3.kResultOk;
					}

					free(instance)

					// No interface found
					obj^ = nil;
					return vst3.kNoInterface;
				}

				return vst3.kNoInterface
			}

			pluginFactory.vtable.getFactoryInfo = pf_getFactoryInfo
			pluginFactory.vtable.countClasses = pf_countClasses
			pluginFactory.vtable.getClassInfo = pf_getClassInfo


			pluginFactory.vtablePtr.lpVtbl = &pluginFactory.vtable
		pluginFactory.initialized = true
	}

	return &pluginFactory.vtablePtr
}
