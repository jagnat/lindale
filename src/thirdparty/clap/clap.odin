package clap

ClapVersion :: struct {
	// This is the major ABI and API design
	// Version 0.X.Y correspond to the development stage, API and ABI are not stable
	// Version 1.X.Y correspond to the release stage, API and ABI are stable
	major    : u32,
	minor    : u32,
	revision : u32,
} clap_version_t;


ClapPluginEntry :: struct {
	clap_version: ClapVersion, // initialized to CLAP_VERSION
	init : proc "system" (const char *plugin_path) -> c.bool,
	deinit : proc "system" (),
	// [thread-safe]
	get_factory : proc "system" (factory_id: cstring) -> rawptr,
}