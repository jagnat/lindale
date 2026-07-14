package build

// Build 'script' for the project

import "core:fmt"
import "core:crypto"
import "core:encoding/hex"
import "core:os"
import "core:flags"
import "core:dynlib"
import "core:path/filepath"

Mode :: enum {
	build,
	hotbuild,
	check,
}

opts : struct {
	mode: Mode `args:"pos=0,required" usage:"build | hotbuild | check"`,
	release: bool `usage:"Specify a release build"`,
	no_hot: bool `usage:"No hotloading"`,
}

// right now this is the WD we were invoked from but it should eventually
// come from some plugin config state (maybe in the code)
plugin: string

// Used for mac only rn
sign_identity: string

// Build-specific ID that can be used in the code
build_id: string

execute :: proc() {
	flags.parse_or_exit(&opts, os.args)

	gen_build_id()

	sign_identity = os.get_env("LINDALE_SIGN_IDENTITY", context.allocator)

	cwd, _ := os.get_working_directory(context.allocator)
	plugin = filepath.base(cwd)

	switch opts.mode {
		case .build:
			build_plugin()
		case .hotbuild:
			build_hotloaded()
		case .check:
			check_plugin()
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
	os.make_directory_all(fmt.tprintf("out/%s.vst3/Contents/%s", plugin, subdir))

	args := make([dynamic]string, allocator = context.temp_allocator)
	append(&args, "odin", "build", "vst3",
		fmt.tprintf("-define:PLUGIN_NAME='%s'", plugin),
		fmt.tprintf("-define:BUILD_ID='%s'", build_id),
		"-build-mode:dynamic",
		fmt.tprintf("-out:out/%s.vst3/Contents/%s/%s.vst3", plugin, subdir, plugin),
		opts.release ? "-o:speed" : "-debug")
	if !opts.no_hot do append(&args, "-define:HOT_DLL=true")
	when ODIN_OS == .Darwin {
		append(&args, fmt.tprintf("-extra-linker-flags:-install_name @loader_path/%s", plugin))
	}
	ps: os.Process_State
	exec(args[:], ps = &ps)
	if !ps.success {
		// fmt.println("Failed to build!", ps.exit_code)
		os.exit(1)
	}

	if !opts.no_hot do build_hotloaded()

	when ODIN_OS == .Darwin { // All the postbuild garbage I need to do on mac
		// This is all to strip the .dylib suffix from the artifact (and debug symbols) because Odin automatically adds it
		mac_contents_path := fmt.tprintf("out/%s.vst3/Contents/MacOS", plugin)
		// Move main DLL
		os.rename(fmt.tprintf("%s/%s.vst3", mac_contents_path, plugin), fmt.tprintf("%s/%s", mac_contents_path, plugin))
		// Release builds (-o:speed) emit no dSYM, so the rename/copy is pointless
		if !opts.release {
			// make renamed debug info directory
			os.make_directory_all(fmt.tprintf("%s/%s.dSYM/Contents/Resources/DWARF", mac_contents_path, plugin))
			// copy dylib dsym into dwarf
			os.copy_file(fmt.tprintf("%s/%s.dSYM/Contents/Resources/DWARF/%s", mac_contents_path, plugin, plugin),
				fmt.tprintf("%s/%s.vst3.dSYM/Contents/Resources/DWARF/%s.vst3", mac_contents_path, plugin, plugin))
			// rm original dylib dsym directory
			os.remove_all(fmt.tprintf("%s/%s.vst3.dSYM", mac_contents_path, plugin))
		}
		// Generate bundle Info.plist
		// Todo: Make some more data here be dynamic (version no.?)
BUNDLE_INFO :: `<?xml version="1.0" encoding="UTF-8"?>
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
		err := os.write_entire_file(fmt.tprintf("out/%s.vst3/Contents/Info.plist", plugin),
			fmt.tprintf(BUNDLE_INFO, plugin, plugin, plugin, plugin))
		if err != nil {
			fmt.println("Failed to write info.plist!")
			os.exit(1)
		}
		// Strip old metadata
		exec({"xattr", "-cr", fmt.tprintf("out/%s.vst3", plugin)})
		// Codesign bundle
		codesign(fmt.tprintf("out/%s.vst3", plugin))
		// Set bundle bit
		exec({"SetFile", "-a", "B", fmt.tprintf("out/%s.vst3", plugin)})
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

	// Build hot dll. Plugin code always lives in the fixed `src` subdir; `plugin`
	// (the folder name) is only an identity for output/bundle naming
	ps: os.Process_State
	exec({
		"odin", "build", "src",
		fmt.tprintf("-define:BUILD_ID='%s'", build_id),
		"-build-mode:dynamic",
		fmt.tprintf("-out:out/hot/%sHot.%s", plugin, dynlib.LIBRARY_FILE_EXTENSION),
		opts.release ? "-o:speed" : "-debug",
	}, ps = &ps)
	if !ps.success do os.exit(1)

	// Code sign on mac
	when ODIN_OS == .Darwin {
		codesign(fmt.tprintf("out/hot/%sHot.%s", plugin, dynlib.LIBRARY_FILE_EXTENSION))
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
		vst3_link := fmt.tprintf("%s/Library/Audio/Plug-Ins/VST3/%s.vst3", home, plugin)
		exec({"ln", "-sfn", fmt.tprintf("%s/out/%s.vst3", cwd, plugin), vst3_link})
		fmt.println("Linked", vst3_link)

		runtime_dir := fmt.tprintf("%s/Library/Application Support/jagi/%s", home, plugin)
		os.make_directory_all(runtime_dir)
		exec({"ln", "-sfn", fmt.tprintf("%s/out/hot", cwd), fmt.tprintf("%s/hot", runtime_dir)})
		fmt.println("Linked", fmt.tprintf("%s/hot", runtime_dir))
	} else when ODIN_OS == .Windows {
		// Junctions (/J flag) need no admin, unlike symlinks
		// The rmdir drops stale junction first
		vst3_dir := fmt.tprintf("%s\\Programs\\Common\\VST3", os.get_env("LOCALAPPDATA", context.allocator))
		os.make_directory_all(vst3_dir)
		exec({"cmd", "/c", "rmdir", fmt.tprintf("%s\\%s.vst3", vst3_dir, plugin)})
		exec({"cmd", "/c", "mklink", "/J", fmt.tprintf("%s\\%s.vst3", vst3_dir, plugin), fmt.tprintf("%s\\out\\%s.vst3", cwd, plugin)})

		runtime_dir := fmt.tprintf("%s\\jagi\\%s", os.get_env("APPDATA", context.allocator), plugin)
		os.make_directory_all(runtime_dir)
		exec({"cmd", "/c", "rmdir", fmt.tprintf("%s\\hot", runtime_dir)})
		exec({"cmd", "/c", "mklink", "/J", fmt.tprintf("%s\\hot", runtime_dir), fmt.tprintf("%s\\out\\hot", cwd)})
	}
}

check_plugin :: proc() {
	ps: os.Process_State
	exec({
		"odin", "check", "src",
		"-no-entry-point",
	}, ps = &ps)
	if !ps.success {
		fmt.println(plugin, "FAILED")
		os.exit(1)
	}
	fmt.println(plugin, "SUCCEEDED")
}

gen_build_id :: proc() {
	bytes: [8]u8
	crypto.rand_bytes(bytes[:])
	hex_str := hex.encode(bytes[:])
	build_id = string(hex_str)
	fmt.println("Build id:", build_id)
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
		bundle := fmt.tprintf("out/%s.vst3", plugin)
		zip := fmt.tprintf("out/%s.vst3.zip", plugin)
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
