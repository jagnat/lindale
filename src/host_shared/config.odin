package host_shared

import plat "../platform_specific"
import b "../bridge"
import lin "../lindale"

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
			runtimeFolderPath = plat.get_pref_path("jagi", "asdfasdf"),
		}
	}
	return &config
}
