package platform

import "core:os"
import "core:os/os2"
import "core:dynlib"
import "core:thread"
import "base:intrinsics"
import "core:log"
import "core:time"
import "core:fmt"
import "core:strings"
import "core:path/filepath"

import lin "lindale"

import "vendor:sdl3"

// inspired by https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template/

NUM_DLLS :: 2

HOT_DLL :: #config(HOT_DLL, false)

HotloadState :: struct {
	apis: [NUM_DLLS]lin.PluginApi,
	libs: [NUM_DLLS]dynlib.Library,
	suffixes: [NUM_DLLS]int,
	idx: int,
	dllLastModTime: os.File_Time,
	hotload_thread: ^thread.Thread,
	initialized: bool,
	dllSuffix: int,
	lindaleHotDllBuf: [128]u8,
	lindaleHotDll: string,
	hotloadedDllFmtBuf: [128]u8,
	hotloadedDllFmt: string,
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
		do_analysis = buffer_do_analysis,
		draw = buffer_draw,
		process_audio = buffer_process_audio,
		view_attached = buffer_view_attached,
		view_removed = buffer_view_removed,
		view_resized = buffer_view_resized,
	}

	return api

	buffer_do_analysis :: proc(plug: ^lin.Plugin, transfer: ^lin.AnalysisTransfer) {
		when !HOT_DLL {
			// lin.plugin_do_analysis(plug, transfer)
			lin.fallbackApi.do_analysis(plug, transfer)
		} else {
			idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].do_analysis == nil {
				lin.fallbackApi.do_analysis(plug, transfer)
			} else {
				ctx.apis[idx].do_analysis(plug, transfer)
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
			if idx < 0 || idx >= len(ctx.apis) || ctx.apis[idx].draw == nil {
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

	err := os2.copy_file(newDllPath, ctx.lindaleHotDll)
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

		if modificationTime > ctx.dllLastModTime {
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
			// no atomic needed, only called from hotload thread besides first load
			ctx.dllLastModTime = modificationTime
			return true
		}
	}

	log.error("couldnt initialize symbols")

	return false
}