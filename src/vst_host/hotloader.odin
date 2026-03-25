package platform

// import "core:os"
import "core:os"
import "core:dynlib"
import "core:thread"
import "core:time"
import "base:intrinsics"
import "core:log"
import "core:fmt"
import "core:strings"
import "core:path/filepath"

import lin "../lindale"
import b "../bridge"

// inspired by https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template/

NUM_DLLS :: 2

HOT_DLL :: #config(HOT_DLL, false)

HotloadState :: struct {
	apis: [NUM_DLLS]lin.PluginApi,
	libs: [NUM_DLLS]dynlib.Library,
	suffixes: [NUM_DLLS]int,
	idx: int,
	dllLastModTime: time.Time,
	hotload_thread: ^thread.Thread,
	initialized: bool,
	dllSuffix: int,
	lindaleHotDllBuf: [128]u8,
	lindaleHotDll: string,
	hotloadedDllFmtBuf: [128]u8,
	hotloadedDllFmt: string,
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

	ctx.lindaleHotDll = fmt.bprint(
		ctx.lindaleHotDllBuf[:],
		get_config().runtimeFolderPath,
		"hot",
		filepath.SEPARATOR,
		"LindaleHot.",
		dynlib.LIBRARY_FILE_EXTENSION, sep="")
	log.info("hotload dll:", ctx.lindaleHotDll)

	ctx.hotloadedDllFmt = fmt.bprint(
		ctx.hotloadedDllFmtBuf[:],
		get_config().runtimeFolderPath,
		"hot",
		filepath.SEPARATOR,
		"LindaleHot%03d.",
		dynlib.LIBRARY_FILE_EXTENSION, sep="")

	ctx.dllSuffix = 1
	ctx.generation = 1

	// if !_load_api() do return

	// launch thread
	ctx.hotload_thread = thread.create(_hotreload_thread_proc)
	if ctx.hotload_thread != nil {
		ctx.hotload_thread.init_context = context
		thread.start(ctx.hotload_thread)
	} else {
		log.error("Failed to create hotreload thread")
		return
	}

	ctx.initialized = true
}

hotload_api :: proc() -> lin.PluginApi {
	api : lin.PluginApi = {
		draw                   = buffer_draw,
		process_audio          = buffer_process_audio,
		view_attached          = buffer_view_attached,
		view_removed           = buffer_view_removed,
		view_resized           = buffer_view_resized,
		query_parameter_layout = buffer_query_parameter_layout,
		get_plugin_descriptor  = buffer_get_plugin_descriptor,
		get_latency_samples    = buffer_get_latency_samples,
		get_tail_samples       = buffer_get_tail_samples,
		setup_processing       = buffer_setup_processing,
		reset                  = buffer_reset,
	}

	return api

	buffer_get_latency_samples :: proc(plug: ^lin.Plugin) -> u32 {
		when !HOT_DLL {
			return lin.fallbackApi.get_latency_samples(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].get_latency_samples == nil {
				return lin.fallbackApi.get_latency_samples(plug)
			} else {
				return ctx.apis[idx].get_latency_samples(plug)
			}
		}
	}
	buffer_get_tail_samples :: proc(plug: ^lin.Plugin) -> u32 {
		when !HOT_DLL {
			return lin.fallbackApi.get_tail_samples(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].get_tail_samples == nil {
				return lin.fallbackApi.get_tail_samples(plug)
			} else {
				return ctx.apis[idx].get_tail_samples(plug)
			}
		}
	}
	buffer_query_parameter_layout :: proc() -> []b.ParamDescriptor {
		when !HOT_DLL {
			return lin.fallbackApi.query_parameter_layout()
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].query_parameter_layout == nil {
				return lin.fallbackApi.query_parameter_layout()
			} else {
				return ctx.apis[idx].query_parameter_layout()
			}
		}
	}
	buffer_draw :: proc(plug: ^lin.Plugin) {
		when !HOT_DLL {
			lin.fallbackApi.draw(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].draw == nil {
				lin.fallbackApi.draw(plug)
			} else {
				ctx.apis[idx].draw(plug)
			}
		}
	}
	buffer_process_audio :: proc(plug: ^lin.Plugin) {
		when !HOT_DLL {
			lin.fallbackApi.process_audio(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].process_audio == nil {
				lin.fallbackApi.process_audio(plug)
			} else {
				ctx.apis[idx].process_audio(plug)
			}
		}
	}
	buffer_view_attached :: proc(plug: ^lin.Plugin) {
		when !HOT_DLL {
			lin.fallbackApi.view_attached(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].draw == nil {
				lin.fallbackApi.view_attached(plug)
			} else {
				ctx.apis[idx].view_attached(plug)
			}
		}
	}
	buffer_view_removed :: proc(plug: ^lin.Plugin) {
		when !HOT_DLL {
			lin.fallbackApi.view_removed(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].draw == nil {
				lin.fallbackApi.view_removed(plug)
			} else {
				ctx.apis[idx].view_removed(plug)
			}
		}
	}
	buffer_view_resized :: proc(plug: ^lin.Plugin, rect: lin.RectI32) {
		when !HOT_DLL {
			lin.fallbackApi.view_resized(plug, rect)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].draw == nil {
				lin.fallbackApi.view_resized(plug, rect)
			} else {
				ctx.apis[idx].view_resized(plug, rect)
			}
		}
	}
	buffer_get_plugin_descriptor :: proc() -> lin.PluginDescriptor {
		when !HOT_DLL {
			return lin.fallbackApi.get_plugin_descriptor()
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].get_plugin_descriptor == nil {
				return lin.fallbackApi.get_plugin_descriptor()
			} else {
				return ctx.apis[idx].get_plugin_descriptor()
			}
		}
	}
	buffer_setup_processing :: proc(plug: ^lin.Plugin, sample_rate: f64, max_block_size: i32) {
		when !HOT_DLL {
			if lin.fallbackApi.setup_processing != nil do lin.fallbackApi.setup_processing(plug, sample_rate, max_block_size)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].setup_processing == nil {
				if lin.fallbackApi.setup_processing != nil do lin.fallbackApi.setup_processing(plug, sample_rate, max_block_size)
			} else {
				ctx.apis[idx].setup_processing(plug, sample_rate, max_block_size)
			}
		}
	}
	buffer_reset :: proc(plug: ^lin.Plugin) {
		when !HOT_DLL {
			if lin.fallbackApi.reset != nil do lin.fallbackApi.reset(plug)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].reset == nil {
				if lin.fallbackApi.reset != nil do lin.fallbackApi.reset(plug)
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
	if ctx.initialized {
		buf: [128]u8
		// Delete the hotloaded dlls
		for i in ctx.suffixes {
			if i == 0 do continue
			oldSlotFilename := fmt.bprintf(buf[:], ctx.hotloadedDllFmt, i)
			fail := os.remove(oldSlotFilename)
			if fail != nil && fail != .Not_Exist {
				log.error("Failed to remove old hotloaded dll", oldSlotFilename, "err:", fail)
			}
		}
	}
}

//////////////
// internal //
//////////////

_close_and_copy_dll :: proc(toIdx: int, newDllPath: string) -> bool {
	buf: [128]u8

	ctx.apis[toIdx] = lin.PluginApi{}
	defer free_all(context.temp_allocator)

	if ctx.libs[toIdx] != nil {
		if !dynlib.unload_library(ctx.libs[toIdx]) {
			log.error("Failed to unload hotloaded library")
		} else {
			log.info("Unloaded hotloaded library")
			ctx.libs[toIdx] = nil
		}
	} else {
		log.info("No hotloaded library to unload")
	}

	oldSlotFilename := fmt.bprintf(buf[:], ctx.hotloadedDllFmt, ctx.suffixes[toIdx])

	fail := os.remove(oldSlotFilename)
	if fail != nil && fail != .Not_Exist {
		log.error("Failed to remove old hotloaded dll", oldSlotFilename, "err:", fail)
	}

	err := os.copy_file(newDllPath, ctx.lindaleHotDll)
	if err == nil {
		log.info("Copied hotloaded dll to", newDllPath)
		return true
	} else {
		log.error("Failed to copy hotloaded dll", newDllPath, err)
		return false
	}
}

_hotreload_thread_proc :: proc(t: ^thread.Thread) {
	context.logger = get_mutex_logger(.HotReload)

	if !_load_api() do log.error("FAILED to load hotloaded dll on startup")

	for {
		modificationTime, err := os.last_write_time_by_name(ctx.lindaleHotDll)
		if err != nil {
			log.error("Failed to get modification time of hotloaded dll", err)
			time.sleep(200 * time.Millisecond)
			continue
		}

		if time.diff(ctx.dllLastModTime, modificationTime) > 0 {
			time.sleep(100 * time.Millisecond)
			if !_load_api() {
				log.error("Failed to load hotloaded API")
				time.sleep(time.Millisecond * 1000) // wait before retrying
				continue
			}
			log.info("Hotloaded API successfully")
		}

		time.sleep(time.Millisecond * 200)
	}
}

_load_api :: proc() -> bool {
	modificationTime, err := os.last_write_time_by_name(ctx.lindaleHotDll)
	if err != nil {
		log.error("Failed to get modification time of hotloaded dll", err)
		return false
	}

	buf:[128]u8
	nextDll := fmt.bprintf(buf[:], ctx.hotloadedDllFmt, ctx.dllSuffix)
	log.info("next dll:", nextDll)

	nextIdx := (ctx.idx + 1) % NUM_DLLS

	if !_close_and_copy_dll(nextIdx, nextDll) {
		log.error("Failed to copy hotloaded dll")
		return false
	}

	lib, ok := dynlib.load_library(nextDll)
	if ok && lib != nil {
		log.info("Loaded hotload library")
		ptr, found := dynlib.symbol_address(lib, "GetPluginApi")
		if found {
			log.info("Loaded GetPluginApi symbol")
			GetPluginApi := cast(proc() -> lin.PluginApi)ptr
			ctx.apis[nextIdx] = GetPluginApi()
			ctx.libs[nextIdx] = lib
			ctx.suffixes[nextIdx] = ctx.dllSuffix
			ctx.dllSuffix += 1
			intrinsics.atomic_store_explicit(&ctx.idx, nextIdx, .Release)
			intrinsics.atomic_store_explicit(&ctx.generation, ctx.generation + 1, .Release)
			// no atomic needed, only called from hotload thread besides first load
			ctx.dllLastModTime = modificationTime
			return true
		}
	}

	log.error("couldnt initialize symbols")

	return false
}
