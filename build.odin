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
	plugin: string `args:"pos=1" usage:"Specify plugin name to build`,
	release: bool `usage:"Specify a release build"`,
	no_hot: bool `usage:"No hotloading"`,
}

plugin_list: map[string]bool
bundle_dir: string

main :: proc() {
	flags.parse_or_exit(&opts, os.args)

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
	// clear(&command)
	// append(&command, "odin", "build", "src/vst_host")
	// if !opts.no_hot do append(&command, "-define:HOT_DLL=true")
	// append(&command, strings.concatenate({"-define:ACTIVE_PLUGIN=", opts.plugin}))
	// if !opts.release do append(&command, "-debug")
	// if opts.release do append(&command, "-o:speed")
	// append(&command, "-no-entry-point", "-build-mode:dynamic")

	bundle_dir = strings.concatenate({"out/", opts.plugin, ".vst3"})

	subdir: string
	when ODIN_OS == .Windows {
		subdir = "x86_64-win/"
	} else when ODIN_OS == .Darwin {
		subdir = "MacOS/"
	} else {
		#assert(false, "Unsupported OS")
	}

	outStr := strings.concatenate({"-out:",
		bundle_dir,
		"/Contents/",
		subdir,
		opts.plugin,
		".",
		dynlib.LIBRARY_FILE_EXTENSION})

	when ODIN_OS == .Darwin {
	} else when ODIN_OS == .Windows {
	}

	build_hotloaded()
}

build_hotloaded :: proc() {
	// Create out/hot if not exist
	err := os.make_directory("out/hot")
	if err != nil && err != .Exist {
		fmt.println("Error creating hot directory", err)
		os.exit(1)
	}

	// Build hot dll
	s := fmt.tprintf("odin build src/lindale -define:HOT_DLL=true -define:ACTIVE_PLUGIN=%s -no-entry-point -build-mode:dynamic -out:out/hot/%sHot.%s",
		opts.plugin, opts.plugin, dynlib.LIBRARY_FILE_EXTENSION)
	if opts.release do s = strings.concatenate({s, " -o:speed"})
	else do s = strings.concatenate({s, " -debug"})
	cmd, _ := strings.split(s, " ")
	err = exec(cmd)
	if err != nil do fmt.println("Error executing hotload build")

	// Code sign on mac
	when ODIN_OS == .Darwin {
		s = fmt.tprintf("codesign --force --sign - out/hot/%sHot.%s",
			opts.plugin, dynlib.LIBRARY_FILE_EXTENSION)
		cmd, _ = strings.split(s, " ")
		err = exec(cmd)
		if err != nil do fmt.println("Error codesigning")
	}
}

symlink_plugin :: proc() {

}

check_plugins :: proc() {
	failures := make(map[string]string)
	fail_count := 0
	for plugin in plugin_list {
		s := fmt.tprintf("odin check src/lindale --no-entry-point -define:HOT_DLL=true -define:ACTIVE_PLUGIN=%s", plugin)
		cmd := strings.split(s, " ")
		ps: os.Process_State
		e := exec(cmd[:], ps = &ps)
		if !ps.success {
			fail_count += 1
			fmt.println(plugin, "FAILED")
		} else {
			fmt.println(plugin, "SUCCEEDED")
		}
	}
	if fail_count != 0 do fmt.println(fail_count, "plugin(s) failed.")
	else do fmt.println("All plugins built successfully.")
}

select_active :: proc() {
	if opts.plugin == "" || !(opts.plugin in plugin_list) {
		fmt.println("Plugin is not a valid plugin to select!")
		os.exit(1)
	}

plugin_id := `package bridge

// Selects which plugin's vtable + state types are compiled in. The default
// here is the source-of-truth. The build script 'select' mode rewrites this file.
// Override one-off with -define:ACTIVE_PLUGIN=<name>.
ACTIVE_PLUGIN :: #config(ACTIVE_PLUGIN, "%s")
`

	formatted := fmt.tprintf(plugin_id, opts.plugin)
	err := os.write_entire_file("src/bridge/plugin_id.odin", transmute([]byte)formatted)
	if err != nil {
		fmt.println("Error writing plugin_id.odin", err)
		os.exit(1)
	}
}

exec :: proc(cmd: []string, working_dir: string = ".", ps: ^os.Process_State = nil) -> (err: os.Error) {
	desc := os.Process_Desc{
		working_dir = working_dir,
		command = cmd,
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
