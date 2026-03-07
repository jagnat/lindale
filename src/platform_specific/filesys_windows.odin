package platform_specific

import "core:os"
import "core:strings"

get_pref_path :: proc(org, app: string) -> string {
	appdata := os.get_env("APPDATA", context.allocator)
	if appdata == "" do return ""
	path := strings.join({appdata, org, app, ""}, "\\")
	delete(appdata)
	return path
}
