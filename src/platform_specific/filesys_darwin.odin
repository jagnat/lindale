package platform_specific

import "core:os"
import "core:strings"

get_pref_path :: proc(org, app: string) -> string {
	home := os.get_env("HOME", context.allocator)
	if home == "" do return ""
	path := strings.join({home, "Library", "Application Support", org, app, ""}, "/")
	delete(home)
	return path
}
