package platform_specific

import "core:os"
import "core:strings"

// Returns "$HOME/Library/Application Support/<org>/<app>/" and ensures the
// directory exists, creating org + app levels as needed. A freshly-installed
// .vst3 may run before any build script has touched the filesystem, so the
// plugin owns this. Errors (typically "already exists") are ignored.
get_pref_path :: proc(org, app: string) -> string {
	home := os.get_env("HOME", context.allocator)
	if home == "" do return ""
	defer delete(home)

	org_dir := strings.join({home, "Library", "Application Support", org}, "/")
	defer delete(org_dir)
	os.make_directory(org_dir)

	app_dir := strings.concatenate({org_dir, "/", app})
	defer delete(app_dir)
	os.make_directory(app_dir)

	return strings.concatenate({app_dir, "/"})
}
