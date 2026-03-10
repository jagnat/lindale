package platform

import plat "../platform_specific"

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
			runtimeFolderPath = plat.get_pref_path("jagi", "Lindale"),
		}
	}
	return &config
}
