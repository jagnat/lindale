package lindale

import "thirdparty/vst3"
import "core:c"

LindalePluginFactory :: struct {
	vtablePtr: vst3.IPluginFactory,
	vtable: vst3.IPluginFactoryVtbl,
	initialized: bool,
}

pluginFactory: LindalePluginFactory

@export InitModule :: proc "std" () -> c.bool {
	return true
}

@export DeinitModule :: proc "std" () -> c.bool {
	return true
}

@export GetPluginFactory :: proc "std" () -> ^vst3.IPluginFactory {
	if !pluginFactory.initialized {

			pf_queryInterface :: proc "std" (this: rawptr, iid: vst3.TUID, obj: ^rawptr) -> vst3.TResult {
				if iid == vst3.iid_FUnknown || iid == vst3.iid_IPluginFactory {
					obj^ = this
				}
				return 0
			}

			pf_addRef :: proc "std" (this: rawptr) -> u32 {
				return 1
			}

			pf_release :: proc "std" (this: rawptr) -> u32 {
				return 0
			}

			pluginFactory.vtable.queryInterface = pf_queryInterface
			pluginFactory.vtable.addRef = pf_addRef
			pluginFactory.vtable.release = pf_release


			pf_getFactoryInfo :: proc "std" (this: rawptr, info: ^vst3.PFactoryInfo) -> vst3.TResult {
				copy(info.vendor[:], "Jagi")
				copy(info.url[:], "jagi.quest")
				copy(info.email[:], "jagi@jagi.quest")
				info.flags = 0
				return vst3.kResultOk
			}

			pf_countClasses :: proc "std" (this: rawptr) -> i32 {
				return 1
			}

			pf_getClassInfo :: proc "std" (this: rawptr, index: i32, info: ^vst3.PClassInfo) -> vst3.TResult {
				if index != 0 {
					return vst3.kInvalidArgument
				}

				info^ = vst3.PClassInfo{
					
				}

				return vst3.kResultOk
			}

			pluginFactory.vtable.getFactoryInfo = pf_getFactoryInfo


			pluginFactory.vtablePtr.lpVtbl = &pluginFactory.vtable
		pluginFactory.initialized = true
	}

	return &pluginFactory.vtablePtr
}