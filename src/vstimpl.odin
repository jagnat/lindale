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
				
				return 0
			}
		pluginFactory.initialized = true
	}

	return &pluginFactory.vtablePtr
}