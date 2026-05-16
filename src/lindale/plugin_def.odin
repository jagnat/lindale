// Start here when implementing a new plugin.
// This is where you select the 'active' plugin,
// and contains the specification of what you need
// to provide for a plugin implementation.

package lindale

import b "../bridge"

PluginType :: enum {
	Effect,
	Instrument,
}

PluginDescriptor :: struct {
	name: string,
	vendor: string,
	version:string,
	plugin_type: PluginType,
	params: []b.ParamDescriptor,
	max_channels: int,
}

PluginApi :: struct {
	// Required procs for the plugin to implement
	get_plugin_descriptor: proc() -> PluginDescriptor,
	process_audio:         proc(plug: ^PluginProcessor),
	draw:                  proc(plug: ^PluginController),

	// Optional procs the plugin can choose to implement
	setup_controller:    proc(plug: ^PluginController),
	view_attached:       proc(plug: ^PluginController),
	view_removed:        proc(plug: ^PluginController),
	view_resized:        proc(plug: ^PluginController, rect: RectI32),

	setup_processor:     proc(plug: ^PluginProcessor),
	get_latency_samples: proc(plug: ^PluginProcessor) -> u32,
	get_tail_samples:    proc(plug: ^PluginProcessor) -> u32,
	reset:               proc(plug: ^PluginProcessor),
}

// Compile-time selector to pick which plugin's vtable + state types are used.
// To add new plugins, just add all the required plugin definition structs
// and add a branch to the when clauses.
// Selected plugin can be set by changing the default here, or adding a
// compile flag: -define:ACTIVE_PLUGIN=plugin_name
// Note: Changing this and hotloading is probably a very bad idea
ACTIVE_PLUGIN :: #config(ACTIVE_PLUGIN, "synth")

when ACTIVE_PLUGIN == "synth" {
	PluginProcessState :: SynthProcessState
	PluginControlState :: SynthControlState
	active_plugin_api  :: synth_api
	param_table := synth_param_table
} else when ACTIVE_PLUGIN == "delay" {
	PluginProcessState :: DelayProcessState
	PluginControlState :: DelayControlState
	active_plugin_api  :: delay_api
	param_table := delay_param_table
} else {
	#panic("Unknown ACTIVE_PLUGIN: " + ACTIVE_PLUGIN)
}
