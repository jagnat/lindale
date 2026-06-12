package host_shared

import plat "../platform_specific"
import b "../bridge"

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
			runtimeFolderPath = plat.get_pref_path("jagi", b.ACTIVE_PLUGIN),
		}
	}
	return &config
}
