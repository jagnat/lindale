package host_shared

import plat "../platform_specific"

// TODO: Pull from some file at compile time?
PLUGIN_NAME :: #config(PLUGIN_NAME, "")

PlatformConfig :: struct {
	initialized: bool,
	runtimeFolderPath: string,
}

@(private)
config: PlatformConfig

get_config :: proc() -> ^PlatformConfig {
	if !config.initialized {
		config = PlatformConfig {
			initialized = true,
			runtimeFolderPath = plat.get_pref_path("jagi", PLUGIN_NAME),
		}
	}
	return &config
}
