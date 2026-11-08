package platform_specific

import "core:os"
import "core:strings"

// Returns "$XDG_DATA_HOME/<org>/<app>/" (default ~/.local/share). Errors ignored
get_pref_path :: proc(org, app: string) -> string {
	base := os.get_env("XDG_DATA_HOME", context.allocator)
	if base == "" {
		delete(base)
		home := os.get_env("HOME", context.allocator)
		if home == "" do return ""
		defer delete(home)
		base = strings.concatenate({home, "/.local/share"})
	}
	defer delete(base)

	org_dir := strings.join({base, org}, "/")
	defer delete(org_dir)
	os.make_directory_all(org_dir)

	app_dir := strings.concatenate({org_dir, "/", app})
	defer delete(app_dir)
	os.make_directory(app_dir)

	return strings.concatenate({app_dir, "/"})
}
