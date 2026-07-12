package host_shared

// import "core:os"
import "core:c/libc"
import "core:os"
import "core:dynlib"
import "core:thread"
import "core:time"
import "base:intrinsics"
import "core:log"
import "core:fmt"
import "core:strings"
import "core:path/filepath"

import "../sdk"

// inspired by https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template/

NUM_DLLS :: 2

HOT_DLL :: #config(HOT_DLL, false)

HotloadState :: struct {
	apis: [NUM_DLLS]sdk.PluginApi,
	libs: [NUM_DLLS]dynlib.Library,
	suffixes: [NUM_DLLS]int,
	idx: int,
	dll_last_mod_time: time.Time,
	hotload_thread: ^thread.Thread,
	initialized: bool,
	running: bool,
	dll_suffix: int,
	lindale_hot_dll_buf: [512]u8,
	lindale_hot_dll: string,
	hotloaded_dll_fmt_buf: [512]u8,
	hotloaded_dll_fmt: string,
	generation: u64,
}
@(private="file")
ctx: HotloadState

// Call when launching a plugin instance
hotload_init :: proc() {
	when !HOT_DLL {
		return
	}

	if ctx.initialized do return

	ctx.lindale_hot_dll = fmt.bprint(
		ctx.lindale_hot_dll_buf[:],
		get_config().runtime_folder_path,
		"hot",
		filepath.SEPARATOR,
		PLUGIN_NAME, "Hot.",
		dynlib.LIBRARY_FILE_EXTENSION, sep="")
	log.info("hotload dll:", ctx.lindale_hot_dll)

	ctx.hotloaded_dll_fmt = fmt.bprint(
		ctx.hotloaded_dll_fmt_buf[:],
		get_config().runtime_folder_path,
		"hot",
		filepath.SEPARATOR,
		PLUGIN_NAME, "Hot%03d.",
		dynlib.LIBRARY_FILE_EXTENSION, sep="")

	ctx.dll_suffix = 1
	ctx.generation = 1

	// if !_load_api() do return

	ctx.hotload_thread = thread.create(_hotreload_thread_proc)
	if ctx.hotload_thread == nil {
		log.error("Failed to create hotreload thread")
		return
	}
	ctx.hotload_thread.init_context = context
	intrinsics.atomic_store_explicit(&ctx.running, true, .Release)
	thread.start(ctx.hotload_thread)

	ctx.initialized = true
}

hotload_api :: proc() -> sdk.PluginApi {
	// Initialize in order so compiler throws an error if a function is missing
	api : sdk.PluginApi = {
		buffer_get_plugin_descriptor,
		buffer_process_audio,
		buffer_draw,

		buffer_setup_controller,

		buffer_view_attached,
		buffer_view_removed,
		buffer_view_resized,

		buffer_setup_processor,
		buffer_get_latency_samples,
		buffer_get_tail_samples,
		buffer_reset,
	}

	return api

	buffer_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
		when !HOT_DLL {
			return sdk.FALLBACK_API.get_plugin_descriptor()
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].get_plugin_descriptor == nil {
				return sdk.FALLBACK_API.get_plugin_descriptor()
			} else {
				return ctx.apis[idx].get_plugin_descriptor()
			}
		}
	}

	buffer_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr{
		when !HOT_DLL {
			return sdk.FALLBACK_API.setup_controller(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].setup_controller == nil {
				return sdk.FALLBACK_API.setup_controller(plug)
			} else {
				return ctx.apis[idx].setup_controller(plug)
			}
		}
	}
	buffer_draw :: proc(plug: ^sdk.PluginController) {
		when !HOT_DLL {
			sdk.FALLBACK_API.draw(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].draw == nil {
				sdk.FALLBACK_API.draw(plug)
			} else {
				ctx.apis[idx].draw(plug)
			}
		}
	}
	buffer_view_attached :: proc(plug: ^sdk.PluginController) {
		when !HOT_DLL {
			sdk.FALLBACK_API.view_attached(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].view_attached == nil {
				sdk.FALLBACK_API.view_attached(plug)
			} else {
				ctx.apis[idx].view_attached(plug)
			}
		}
	}
	buffer_view_removed :: proc(plug: ^sdk.PluginController) {
		when !HOT_DLL {
			sdk.FALLBACK_API.view_removed(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].view_removed == nil {
				sdk.FALLBACK_API.view_removed(plug)
			} else {
				ctx.apis[idx].view_removed(plug)
			}
		}
	}
	buffer_view_resized :: proc(plug: ^sdk.PluginController, rect: sdk.RectI32) {
		when !HOT_DLL {
			sdk.FALLBACK_API.view_resized(plug, rect)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].view_resized == nil {
				sdk.FALLBACK_API.view_resized(plug, rect)
			} else {
				ctx.apis[idx].view_resized(plug, rect)
			}
		}
	}

	buffer_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
		when !HOT_DLL {
			return sdk.FALLBACK_API.setup_processor(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].setup_processor == nil {
				return sdk.FALLBACK_API.setup_processor(plug)
			} else {
				return ctx.apis[idx].setup_processor(plug)
			}
		}
	}
	buffer_process_audio :: proc(plug: ^sdk.PluginProcessor) {
		when !HOT_DLL {
			sdk.FALLBACK_API.process_audio(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].process_audio == nil {
				sdk.FALLBACK_API.process_audio(plug)
			} else {
				ctx.apis[idx].process_audio(plug)
			}
		}
	}
	buffer_get_latency_samples :: proc(plug: ^sdk.PluginProcessor) -> u32 {
		when !HOT_DLL {
			return sdk.FALLBACK_API.get_latency_samples(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].get_latency_samples == nil {
				return sdk.FALLBACK_API.get_latency_samples(plug)
			} else {
				return ctx.apis[idx].get_latency_samples(plug)
			}
		}
	}
	buffer_get_tail_samples :: proc(plug: ^sdk.PluginProcessor) -> u32 {
		when !HOT_DLL {
			return sdk.FALLBACK_API.get_tail_samples(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].get_tail_samples == nil {
				return sdk.FALLBACK_API.get_tail_samples(plug)
			} else {
				return ctx.apis[idx].get_tail_samples(plug)
			}
		}
	}
	buffer_reset :: proc(plug: ^sdk.PluginProcessor) {
		when !HOT_DLL {
			sdk.FALLBACK_API.reset(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].reset == nil {
				sdk.FALLBACK_API.reset(plug)
			} else {
				ctx.apis[idx].reset(plug)
			}
		}
	}
}

hotload_generation :: proc() -> u64 {
	return intrinsics.atomic_load_explicit(&ctx.generation, .Acquire)
}

hotload_deinit :: proc() {
	if !ctx.initialized do return

	if ctx.hotload_thread != nil {
		intrinsics.atomic_store_explicit(&ctx.running, false, .Release)
		thread.join(ctx.hotload_thread)
		thread.destroy(ctx.hotload_thread)
		ctx.hotload_thread = nil
	}

	buf: [512]u8
	for i in ctx.suffixes {
		if i == 0 do continue
		old_slot_filename := fmt.bprintf(buf[:], ctx.hotloaded_dll_fmt, i)
		fail := os.remove(old_slot_filename)
		if fail != nil && fail != .Not_Exist {
			log.error("Failed to remove old hotloaded dll", old_slot_filename, "err:", fail)
		}
		when ODIN_DEBUG do _remove_debug_info(old_slot_filename)
	}

	ctx.initialized = false
}

//////////////
// internal //
//////////////

_close_and_copy_dll :: proc(to_idx: int, new_dll_path: string) -> bool {
	buf: [512]u8

	ctx.apis[to_idx] = sdk.PluginApi{}
	defer free_all(context.temp_allocator)

	if ctx.libs[to_idx] != nil {
		if !dynlib.unload_library(ctx.libs[to_idx]) {
			log.error("Failed to unload hotloaded library")
		} else {
			log.info("Unloaded hotloaded library")
			ctx.libs[to_idx] = nil
		}
	} else {
		log.info("No hotloaded library to unload")
	}

	old_slot_filename := fmt.bprintf(buf[:], ctx.hotloaded_dll_fmt, ctx.suffixes[to_idx])

	fail := os.remove(old_slot_filename)
	if fail != nil && fail != .Not_Exist {
		log.error("Failed to remove old hotloaded dll", old_slot_filename, "err:", fail)
	}
	when ODIN_DEBUG do _remove_debug_info(old_slot_filename)

	err := os.copy_file(new_dll_path, ctx.lindale_hot_dll)
	if err == nil {
		log.info("Copied hotloaded dll to", new_dll_path)
		when ODIN_DEBUG do _copy_debug_info(ctx.lindale_hot_dll, new_dll_path)
		return true
	} else {
		log.error("Failed to copy hotloaded dll", new_dll_path, err)
		return false
	}
}

// Mac only required for now.
// Copies a dSYM bundle alongside a renamed dylib. The DWARF file inside the
// bundle must be renamed to match the new binary or LLDB won't associate it.
_copy_debug_info :: proc(src_dll, dst_dll: string) {
	when ODIN_OS == .Darwin {
		src_dsym := fmt.tprintf("%s.dSYM", src_dll)
		if !os.exists(src_dsym) do return

		dst_dsym := fmt.tprintf("%s.dSYM", dst_dll)
		cmd := fmt.ctprintf(
			"rm -rf '%s' && cp -R '%s' '%s' && mv '%s/Contents/Resources/DWARF/%s' '%s/Contents/Resources/DWARF/%s'",
			dst_dsym, src_dsym, dst_dsym,
			dst_dsym, filepath.base(src_dll),
			dst_dsym, filepath.base(dst_dll))
		if libc.system(cmd) != 0 {
			log.error("Failed to copy dSYM for", dst_dll)
		} else {
			log.info("Copied dSYM for", dst_dll)
		}
	}
}

_remove_debug_info :: proc(dll_path: string) {
	when ODIN_OS == .Darwin {
		libc.system(fmt.ctprintf("rm -rf '%s.dSYM'", dll_path))
	}
}

_hotreload_thread_proc :: proc(t: ^thread.Thread) {
	context.logger = get_mutex_logger(.HotReload)

	if !_load_api() do log.error("FAILED to load hotloaded dll on startup")

	for intrinsics.atomic_load_explicit(&ctx.running, .Acquire) {
		modification_time, err := os.last_write_time_by_name(ctx.lindale_hot_dll)
		if err != nil {
			log.error("Failed to get modification time of hotloaded dll", err)
			time.sleep(200 * time.Millisecond)
			continue
		}

		if time.diff(ctx.dll_last_mod_time, modification_time) > 0 {
			time.sleep(100 * time.Millisecond)
			if !_load_api() {
				log.error("Failed to load hotloaded API")
				time.sleep(time.Millisecond * 1000)
				continue
			}
			log.info("Hotloaded API successfully")
		}

		time.sleep(time.Millisecond * 200)
	}
}

_load_api :: proc() -> bool {
	modification_time, err := os.last_write_time_by_name(ctx.lindale_hot_dll)
	if err != nil {
		log.error("Failed to get modification time of hotloaded dll", err)
		return false
	}

	buf:[512]u8
	next_dll := fmt.bprintf(buf[:], ctx.hotloaded_dll_fmt, ctx.dll_suffix)
	log.info("next dll:", next_dll)

	next_idx := (ctx.idx + 1) % NUM_DLLS

	if !_close_and_copy_dll(next_idx, next_dll) {
		log.error("Failed to copy hotloaded dll")
		return false
	}

	lib, ok := dynlib.load_library(next_dll)
	if ok && lib != nil {
		log.info("Loaded hotload library")
		ptr, found := dynlib.symbol_address(lib, "get_plugin_api")
		if found {
			log.info("Loaded get_plugin_api symbol")
			get_plugin_api := cast(proc() -> sdk.PluginApi)ptr
			ctx.apis[next_idx] = get_plugin_api()
			ctx.libs[next_idx] = lib
			ctx.suffixes[next_idx] = ctx.dll_suffix
			ctx.dll_suffix += 1
			intrinsics.atomic_store_explicit(&ctx.idx, next_idx, .Release)
			intrinsics.atomic_store_explicit(&ctx.generation, ctx.generation + 1, .Release)
			// no atomic needed, only called from hotload thread besides first load
			ctx.dll_last_mod_time = modification_time
			return true
		}
	}

	log.error("couldnt initialize symbols")

	return false
}
