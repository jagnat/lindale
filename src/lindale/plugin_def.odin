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
	version: string,
	plugin_type: PluginType,
	params: []b.ParamDescriptor,
	max_channels: int,
	view: ViewConfig,
}

// Read once at controller init, not on hot reload
ViewConfig :: struct {
	default_width, default_height: i32, // falls back to min_*, then DEFAULT_VIEW_(WIDTH/HEIGHT)
	min_width, min_height: i32, // 0 = unbounded
	max_width, max_height: i32, // 0 = unbounded
	resizable: bool, // default: false
	aspect_ratio: f32, // width / height. 0 = unlocked
}

DEFAULT_VIEW_WIDTH  :: i32(800)
DEFAULT_VIEW_HEIGHT :: i32(600)

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
// To add new plugins, add the required definition structs and a branch below.
// b.ACTIVE_PLUGIN lives in bridge; rewrite it via set_plugin or override with
// -define:ACTIVE_PLUGIN=<name>. Changing it mid-session and hotloading is
// probably a very bad idea.
when b.ACTIVE_PLUGIN == "beepboop" {
	PluginProcessState :: SynthProcessState
	PluginControlState :: SynthControlState
	active_plugin_api  :: synth_api
	param_table := synth_param_table
} else when b.ACTIVE_PLUGIN == "delay" {
	PluginProcessState :: DelayProcessState
	PluginControlState :: DelayControlState
	active_plugin_api  :: delay_api
	param_table := delay_param_table
} else when b.ACTIVE_PLUGIN == "template" {
	PluginProcessState :: TemplateProcessState
	PluginControlState :: TemplateControlState
	active_plugin_api  :: template_api
	param_table := template_param_table
} else when b.ACTIVE_PLUGIN == "scopey" {
	PluginProcessState :: ScopeyProcessState
	PluginControlState :: ScopeyControlState
	active_plugin_api  :: scopey_api
	param_table := scopey_param_table
} else {
	#panic("Unknown ACTIVE_PLUGIN: " + b.ACTIVE_PLUGIN)
}
