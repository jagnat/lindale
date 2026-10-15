package host_shared

import plat "../platform_specific"
import "../sdk"

PLUGIN_ID :: #config(PLUGIN_ID, "")

PlatformConfig :: struct {
	initialized: bool,
	runtime_folder_path: string,
}

@(private)
config: PlatformConfig

get_config :: proc() -> ^PlatformConfig {
	if !config.initialized {
		config = PlatformConfig {
			initialized = true,
			runtime_folder_path = plat.get_pref_path(sdk.PLUGIN_VENDOR_ID, PLUGIN_ID),
		}
	}
	return &config
}
