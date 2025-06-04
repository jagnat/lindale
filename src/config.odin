package platform

import "vendor:sdl3"
import "core:strings"

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
			runtimeFolderPath = strings.string_from_null_terminated_ptr(sdl3.GetPrefPath("jagi", "Lindale"), 128)
		}
	}

	return &config
}