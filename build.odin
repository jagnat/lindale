package build

// Build 'script' for the project

import "core:fmt"
import "core:os"
import "core:flags"
import "core:strings"
import "core:text/regex"
import "core:dynlib"

Mode :: enum {
	build,
	hotbuild,
	check,
	select,
}

opts : struct {
	mode: Mode `args:"pos=0,required" usage:"build | hotbuild | check | select"`,
	plugin: string `args:"pos=1" usage:"Specify plugin name to build"`,
	release: bool `usage:"Specify a release build"`,
	no_hot: bool `usage:"No hotloading"`,
}

plugin_list: map[string]bool

// Used for mac only rn
sign_identity: string

main :: proc() {
	flags.parse_or_exit(&opts, os.args)

	sign_identity = os.get_env("LINDALE_SIGN_IDENTITY", context.allocator)

	verify_plugin()

	switch opts.mode {
		case .build:
			build_plugin()
		case .hotbuild:
			build_hotloaded()
		case .check:
			check_plugins()
		case .select:
			select_active()
	}
}

verify_plugin :: proc() {
	plugin_list = make(map[string]bool)

	// Populate list of plugins
	{
		data, e := os.read_entire_file("src/lindale/plugin_def.odin", context.allocator)
		if e != nil {
			fmt.println("Failed to read plugin_def.odin")
			os.exit(1)
		}
		it := string(data)
		r, _ := regex.create("when b\\.ACTIVE_PLUGIN == \"([\\w]+)\"")
		defer regex.destroy(r)
		for line in strings.split_lines_iterator(&it) {
			if c, s := regex.match(r, line); s {
				plugin_list[c.groups[1]] = true
			}
		}
	}

	// Fetch currently active plugin
	active_plugin: string
	{
		data, e := os.read_entire_file("src/bridge/plugin_id.odin", context.allocator)
		if e != nil {
			fmt.println("Failed to read plugin_id.odin")
			os.exit(1)
		}
		it := string(data)
		r, _ := regex.create("config\\(ACTIVE_PLUGIN, \"([\\w]+)\"")
		defer regex.destroy(r)
		g, s := regex.match(r, it)
		if !s {
			fmt.println("Couldn't match current plugin in plugin_id.odin")
			os.exit(1)
		}
		active_plugin = g.groups[1]
	}

	if opts.plugin != "" {
		if !(opts.plugin in plugin_list) {
			fmt.println("Invalid plugin! '", opts.plugin, "' does not exist in plugin_defs.odin", sep="")
			os.exit(1)
		}
	} else if opts.mode != .select {
		opts.plugin = active_plugin
	}
}

build_plugin :: proc () {
	subdir: string
	when ODIN_OS == .Windows {
		subdir = "x86_64-win"
	} else when ODIN_OS == .Darwin {
		subdir = "MacOS"
	} else {
		#assert(false, "Unsupported OS")
	}

	// Make vst3 dir if not exist
	os.make_directory_all(fmt.tprintf("out/%s.vst3/Contents/%s", opts.plugin, subdir))

	args := make([dynamic]string)
	append(&args, "odin", "build", "src/vst_host",
		fmt.tprintf("-define:ACTIVE_PLUGIN=%s", opts.plugin),
		"-build-mode:dynamic",
		fmt.tprintf("-out:out/%s.vst3/Contents/%s/%s.vst3", opts.plugin, subdir, opts.plugin),
		opts.release ? "-o:speed" : "-debug")
	if !opts.no_hot do append(&args, "-define:HOT_DLL=true")
	when ODIN_OS == .Darwin {
		append(&args, fmt.tprintf("-extra-linker-flags:-install_name @loader_path/%s", opts.plugin))
	}
	ps: os.Process_State
	exec(args[:], ps = &ps)
	if !ps.success do os.exit(1)

	if !opts.no_hot do build_hotloaded()

	when ODIN_OS == .Darwin { // All the postbuild garbage I need to do on mac
		// This is all to strip the .dylib suffix from the artifact (and debug symbols) because Odin automatically adds it
		mac_contents_path := fmt.tprintf("out/%s.vst3/Contents/MacOS", opts.plugin)
		// Move main DLL
		os.rename(fmt.tprintf("%s/%s.vst3", mac_contents_path, opts.plugin), fmt.tprintf("%s/%s", mac_contents_path, opts.plugin))
		// Release builds (-o:speed) emit no dSYM, so the rename/copy is pointless
		if !opts.release {
			// make renamed debug info directory
			os.make_directory_all(fmt.tprintf("%s/%s.dSYM/Contents/Resources/DWARF", mac_contents_path, opts.plugin))
			// copy dylib dsym into dwarf
			os.copy_file(fmt.tprintf("%s/%s.dSYM/Contents/Resources/DWARF/%s", mac_contents_path, opts.plugin, opts.plugin),
				fmt.tprintf("%s/%s.vst3.dSYM/Contents/Resources/DWARF/%s.vst3", mac_contents_path, opts.plugin, opts.plugin))
			// rm original dylib dsym directory
			os.remove_all(fmt.tprintf("%s/%s.vst3.dSYM", mac_contents_path, opts.plugin))
		}
		// Generate bundle Info.plist
		// Todo: Make some more data here be dynamic (version no.?)
bundle_info :: `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>%s</string>
	<key>CFBundleGetInfoString</key>
	<string>%s 0.0.0</string>
	<key>CFBundleIdentifier</key>
	<string>quest.jagi.%s.vst3</string>
	<key>CFBundleName</key>
	<string>%s</string>
	<key>CFBundleVersion</key>
	<string>0.0.0</string>
</dict>
</plist>
`
		err := os.write_entire_file(fmt.tprintf("out/%s.vst3/Contents/Info.plist", opts.plugin),
			fmt.tprintf(bundle_info, opts.plugin, opts.plugin, opts.plugin, opts.plugin))
		if err != nil {
			fmt.println("Failed to write info.plist!")
			os.exit(1)
		}
		// Strip old metadata
		exec({"xattr", "-cr", fmt.tprintf("out/%s.vst3", opts.plugin)})
		// Codesign bundle
		codesign(fmt.tprintf("out/%s.vst3", opts.plugin))
		// Set bundle bit
		exec({"SetFile", "-a", "B", fmt.tprintf("out/%s.vst3", opts.plugin)})
		if opts.release && sign_identity != "" do darwin_notarize_bundle()
	} else when ODIN_OS == .Windows {
	}

	symlink_plugin()
}

build_hotloaded :: proc() {
	// Create out/hot if not exist
	err := os.make_directory_all("out/hot")
	if err != nil && err != .Exist {
		fmt.println("Error creating hot directory", err)
		os.exit(1)
	}

	// Build hot dll
	ps: os.Process_State
	exec({
		"odin", "build", "src/lindale",
		"-define:HOT_DLL=true",
		fmt.tprintf("-define:ACTIVE_PLUGIN=%s", opts.plugin),
		"-build-mode:dynamic",
		fmt.tprintf("-out:out/hot/%sHot.%s", opts.plugin, dynlib.LIBRARY_FILE_EXTENSION),
		opts.release ? "-o:speed" : "-debug",
	}, ps = &ps)
	if !ps.success do os.exit(1)

	// Code sign on mac
	when ODIN_OS == .Darwin {
		codesign(fmt.tprintf("out/hot/%sHot.%s", opts.plugin, dynlib.LIBRARY_FILE_EXTENSION))
	}
}

symlink_plugin :: proc() {
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		fmt.println("Failed to get working directory!")
		os.exit(1)
	}

	when ODIN_OS == .Darwin {
		home := os.get_env("HOME", context.allocator)
		// -sfn flags replace a stale/dangling link in place, so switching plugins self-heals
		vst3_link := fmt.tprintf("%s/Library/Audio/Plug-Ins/VST3/%s.vst3", home, opts.plugin)
		exec({"ln", "-sfn", fmt.tprintf("%s/out/%s.vst3", cwd, opts.plugin), vst3_link})
		fmt.println("Linked", vst3_link)

		runtime_dir := fmt.tprintf("%s/Library/Application Support/jagi/%s", home, opts.plugin)
		os.make_directory_all(runtime_dir)
		exec({"ln", "-sfn", fmt.tprintf("%s/out/hot", cwd), fmt.tprintf("%s/hot", runtime_dir)})
		fmt.println("Linked", fmt.tprintf("%s/hot", runtime_dir))
	} else when ODIN_OS == .Windows {
		// Junctions (/J flag) need no admin, unlike symlinks
		// The rmdir drops stale junction first
		vst3_dir := fmt.tprintf("%s\\Programs\\Common\\VST3", os.get_env("LOCALAPPDATA", context.allocator))
		os.make_directory_all(vst3_dir)
		exec({"cmd", "/c", "rmdir", fmt.tprintf("%s\\%s.vst3", vst3_dir, opts.plugin)})
		exec({"cmd", "/c", "mklink", "/J", fmt.tprintf("%s\\%s.vst3", vst3_dir, opts.plugin), fmt.tprintf("%s\\out\\%s.vst3", cwd, opts.plugin)})

		runtime_dir := fmt.tprintf("%s\\jagi\\%s", os.get_env("APPDATA", context.allocator), opts.plugin)
		os.make_directory_all(runtime_dir)
		exec({"cmd", "/c", "rmdir", fmt.tprintf("%s\\hot", runtime_dir)})
		exec({"cmd", "/c", "mklink", "/J", fmt.tprintf("%s\\hot", runtime_dir), fmt.tprintf("%s\\out\\hot", cwd)})
	}
}

check_plugins :: proc() {
	fail_count := 0
	for plugin in plugin_list {
		ps: os.Process_State
		exec({
			"odin", "check", "src/lindale",
			"-no-entry-point",
			"-define:HOT_DLL=true",
			fmt.tprintf("-define:ACTIVE_PLUGIN=%s", plugin),
		}, ps = &ps)
		if !ps.success {
			fail_count += 1
			fmt.println(plugin, "FAILED")
		} else {
			fmt.println(plugin, "SUCCEEDED")
		}
	}
	if fail_count != 0 do fmt.println(fail_count, "plugin(s) failed.")
	else do fmt.println("All plugins succeed checking.")
}

select_active :: proc() {
	if opts.plugin == "" || !(opts.plugin in plugin_list) {
		fmt.println("Plugin is not a valid plugin to select!")
		os.exit(1)
	}

	plugin_id_dot_odin := `package bridge

// Selects which plugin's vtable + state types are compiled in. The default
// here is the source-of-truth. The build script 'select' mode rewrites this file.
// Override one-off with -define:ACTIVE_PLUGIN=<name>.
ACTIVE_PLUGIN :: #config(ACTIVE_PLUGIN, "%s")
`
	formatted := fmt.tprintf(plugin_id_dot_odin, opts.plugin)
	err := os.write_entire_file("src/bridge/plugin_id.odin", transmute([]byte)formatted)
	if err != nil {
		fmt.println("Error writing plugin_id.odin", err)
		os.exit(1)
	}
}

when ODIN_OS == .Darwin {
	codesign :: proc(path: string) {
		args := make([dynamic]string)
		append(&args, "codesign", "--force")
		if opts.release && sign_identity != "" {
			// Hardened runtime + secure timestamp are notarization prerequisites
			append(&args, "--options", "runtime", "--timestamp", "--sign", sign_identity)
		} else {
			append(&args, "--sign", "-")
		}
		append(&args, path)
		ps: os.Process_State
		exec(args[:], ps = &ps)
		if !ps.success {
			fmt.println("Codesign failed for", path)
			os.exit(1)
		}
	}

	darwin_notarize_bundle :: proc() {
		profile := os.get_env("LINDALE_NOTARY_PROFILE", context.allocator)
		if profile == "" {
			fmt.println("LINDALE_NOTARY_PROFILE unset, skipping notarization")
			return
		}
		bundle := fmt.tprintf("out/%s.vst3", opts.plugin)
		zip := fmt.tprintf("out/%s.vst3.zip", opts.plugin)
		// notarytool only accepts a zip/dmg/pkg, never a bare bundle
		exec({"ditto", "-c", "-k", "--keepParent", bundle, zip})
		ps: os.Process_State
		exec({"xcrun", "notarytool", "submit", zip, "--keychain-profile", profile, "--wait"}, ps = &ps)
		os.remove(zip)
		if !ps.success {
			fmt.println("Notarization failed")
			os.exit(1)
		}
		// Staple the ticket so the bundle validates offline
		exec({"xcrun", "stapler", "staple", bundle})
	}
}

exec :: proc(args: []string, ps: ^os.Process_State = nil) -> (err: os.Error) {
	// fmt.println("CMD:", args)
	desc := os.Process_Desc{
		working_dir = ".",
		command = args,
		env = nil,
		stdout = os.stdout,
		stderr = os.stderr,
	}
	os.flush(os.stdout)
	p := os.process_start(desc) or_return
	state :=  os.process_wait(p) or_return
	if ps != nil do ps^ = state

	return nil
}
