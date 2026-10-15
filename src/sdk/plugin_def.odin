// Start here when implementing a new plugin.
// This contains the specification of what you need
// to provide for a plugin implementation.

package sdk

import b "../bridge"

PluginType :: enum {
	Effect,
	Instrument,
}

// set from the plugin's plugin.ini by the build tool
PLUGIN_NAME :: #config(PLUGIN_NAME, "") // display name shown by hosts
PLUGIN_VERSION :: #config(PLUGIN_VERSION, "0.0.0")
PLUGIN_VENDOR :: #config(PLUGIN_VENDOR, "")
PLUGIN_VENDOR_ID :: #config(PLUGIN_VENDOR_ID, "") // reverse-DNS, used for the bundle id and runtime folder
PLUGIN_URL :: #config(PLUGIN_URL, "")
PLUGIN_EMAIL :: #config(PLUGIN_EMAIL, "")

PluginDescriptor :: struct {
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

	// Returns a reference to the controller state
	setup_controller:    proc(plug: ^PluginController) -> rawptr,
	view_attached:       proc(plug: ^PluginController),
	view_removed:        proc(plug: ^PluginController),
	view_resized:        proc(plug: ^PluginController, rect: RectI32),

	// Returns a reference to the processor state
	setup_processor:     proc(plug: ^PluginProcessor) -> rawptr,
	get_latency_samples: proc(plug: ^PluginProcessor) -> u32,
	get_tail_samples:    proc(plug: ^PluginProcessor) -> u32,
	reset:               proc(plug: ^PluginProcessor),
}
