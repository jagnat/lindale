package clap

import "core:c"

// Implementation of extensions I care about

// Begin audio-ports

EXT_AUDIO_PORTS :: "clap.audio-ports"
PORT_MONO :: "mono"
PORT_STEREO :: "stereo"

AudioPortInfoFlags :: enum u32 {
	IS_MAIN,
	SUPPORTS_64BITS,
	PREFERS_64BITS,
	REQUIRES_COMMON_SAMPLE_SIZE,
}
AudioPortInfoFlagSet :: bit_set[AudioPortInfoFlags; u32]

AudioPortInfo :: struct {
	id: ClapId,
	name: [NAME_SIZE]c.char,
	flags: AudioPortInfoFlagSet,
	channel_count: u32,
	port_type: cstring,
	in_place_pair: ClapId,
}

PluginAudioPorts :: struct {
	count: proc "system" (plugin: ^Plugin, is_input: c.bool) -> u32,
	get: proc "system" (plugin: ^Plugin, index: u32, is_input: c.bool, info: ^AudioPortInfo) -> c.bool,
}

AudioPortsRescanFlags :: enum u32 {
	RESCAN_NAMES,
	RESCAN_FLAGS,
	RESCAN_CHANNEL_COUNT,
	RESCAN_PORT_TYPE,
	RESCAN_IN_PLACE_PAIR,
	RESCAN_LIST,
}
AudioPortsRescanFlagSet :: bit_set[AudioPortsRescanFlags; u32]

HostAudioPorts :: struct {
	is_rescan_flag_supported: proc "system" (host: ^Host, flag: AudioPortsRescanFlagSet) -> c.bool,
	rescan: proc "system" (host: ^Host, flags: AudioPortsRescanFlagSet)
}

EXT_AUDIO_PORTS_ACTIVATION :: "clap.audio-ports-activation/2"
EXT_AUDIO_PORTS_ACTIVATION_COMPAT :: "clap.audio-ports-activation/draft-2"

PluginAudioPortsActivation :: struct {
	can_activate_while_processing: proc "system" (plugin: ^Plugin) -> c.bool,
	set_active: proc "system" (plugin: ^Plugin, is_input: c.bool, port_index: u32, is_active: c.bool, sample_size: u32) -> c.bool,
}

EXT_AUDIO_PORTS_CONFIG :: "clap.audio-ports-config"
EXT_AUDIO_PORTS_CONFIG_INFO :: "clap.audio-ports-config-info/1"

AudioPortsConfig :: struct {
	id: ClapId,
	name: [NAME_SIZE]c.char,
	input_port_count, output_port_count: u32,

	has_main_input: c.bool,
	main_input_channel_count: u32,
	main_input_port_type: cstring,

	has_main_output: c.bool,
	main_output_channel_count: u32,
	main_output_port_type: cstring,
}

PluginAudioPortsConfig :: struct {
	count: proc "system" (plugin: ^Plugin) -> u32,
	get: proc "system" (plugin: ^Plugin, index: u32, config: ^AudioPortsConfig) -> c.bool,
	select: proc "system" (plugin: ^Plugin, config_id: ClapId) -> c.bool,
}

PluginAudioPortsConfigInfo :: struct {
	current_config: proc "system" (plugin: ^Plugin) -> ClapId,
	get: proc "system" (plugin: ^Plugin, config_id: ClapId, port_index: u32, is_input: c.bool, info: ^AudioPortInfo) -> c.bool,
}

HostAudioPortsConfig :: struct {
	rescan: proc "system" (host: ^Host)
}

// End audio-ports

// Begin gui

EXT_GUI :: "clap.gui"

WINDOW_API_WIN32 :: "win32"
WINDOW_API_COCOA :: "cocoa"
WINDOW_API_UIKIT :: "uikit"
WINDOW_API_X11 :: "x11"
WINDOW_API_WAYLAND :: "wayland"

Window :: struct {
	api: cstring,
	using _: struct #raw_union {
		cocoa: rawptr,
		uikit: rawptr,
		x11: c.ulong,
		win32: rawptr,
		ptr: rawptr,
	},
}

GuiResizeHints :: struct {
	can_resize_horizontally: c.bool,
	can_resize_vertically: c.bool,
	preserve_aspect_ratio: c.bool,
	aspect_ratio_width: u32,
	aspect_ratio_height: u32,
}

PluginGui :: struct {
	is_api_supported: proc "system" (plugin: ^Plugin, api: cstring, is_floating: c.bool) -> c.bool,
	get_preferred_api: proc "system" (plugin: ^Plugin, api: ^cstring, is_floating: ^c.bool) -> c.bool,
	create: proc "system" (plugin: ^Plugin, api: cstring, is_floating: c.bool) -> c.bool,
	destroy: proc "system" (plugin: ^Plugin),
	set_scale: proc "system" (plugin: ^Plugin, scale: f64) -> c.bool,
	get_size: proc "system" (plugin: ^Plugin, width, height: ^u32) -> c.bool,
	can_resize: proc "system" (plugin: ^Plugin) -> c.bool,
	get_resize_hints: proc "system" (plugin: ^Plugin, hints: ^GuiResizeHints) -> c.bool,
	adjust_size: proc "system" (plugin: ^Plugin, width, height: ^u32) -> c.bool,
	set_size: proc "system" (plugin: ^Plugin, width, height: u32) -> c.bool,
	set_parent: proc "system" (plugin: ^Plugin, window: ^Window) -> c.bool,
	set_transient: proc "system" (plugin: ^Plugin, window: ^Window) -> c.bool,
	suggest_title: proc "system" (plugin: ^Plugin, title: cstring),
	show: proc "system" (plugin: ^Plugin) -> c.bool,
	hide: proc "system" (plugin: ^Plugin) -> c.bool,
}

// End gui