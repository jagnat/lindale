package clap_layer

import "../thirdparty/clap"

import "core:c"
import "base:runtime"

// CLAP_EXPORT extern const clap_plugin_entry_t clap_entry;
@export clap_entry := clap.PluginEntry {
	version = clap.VERSION,
	init = clap_init,
	deinit = clap_deinit,
	get_factory = clap_get_plugin_factory,
}

plugin_desc := clap.PluginDescriptor {
}

clap_init :: proc "system" (plugin_path: cstring) -> c.bool {
	return true
}

clap_deinit :: proc "system" () {
}

clap_get_plugin_factory :: proc "system" (factory_id: cstring) -> rawptr {
	context = runtime.default_context();
	factory := new(clap.PluginFactory)

	factory^ = clap.PluginFactory {
	}

	pf_get_plugin_count :: proc "system" (factory: ^clap.PluginFactory) -> u32 {
		return 1
	}

	pf_get_plugin_descriptor :: proc "system" (factory: ^clap.PluginFactory, idx: u32) -> ^clap.PluginDescriptor {
		return &plugin_desc
	}

	pf_create_plugin :: proc "system" (factory: ^clap.PluginFactory, host: ^clap.Host, plugin_id: cstring) -> ^clap.Plugin {
		return 
	}

	return factory
}
