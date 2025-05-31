package plugin

import "core:os"
import "core:os/os2"
import "core:dynlib"
import "core:thread"
import "base:intrinsics"
import "core:log"
import "core:time"
import "core:fmt"

import pl "hotloaded"

// inspired by https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template/

hotload_dll_path :: "/Users/jagi/Programming/lindale/out/hot/LindaleHot.dylib"
hotloaded_dll_0 :: "/Users/jagi/Programming/lindale/out/hot/LindaleInFlight1.dylib"
hotloaded_dll_1 :: "/Users/jagi/Programming/lindale/out/hot/LindaleInFlight2.dylib"

NUM_DLLS :: 2000

// @(rodata)
// hotloadedDllPaths := [2]string{hotloaded_dll_0, hotloaded_dll_1}

HotloadState :: struct {
	apis: [NUM_DLLS]pl.PluginApi,
	libs: [NUM_DLLS]dynlib.Library,
	idx: int,
	dllLastModTime: os.File_Time,
	hotload_thread: ^thread.Thread,
	initialized: bool
}
@(private="file")
ctx: HotloadState

// Only thing needed by plugin implementation
// then just use the returned api
hotload_init :: proc() -> pl.PluginApi {
	if ctx.initialized do return _get_buffer_api()

	if !_load_api() do return pl.PluginApi{}

	// launch thread
	ctx.hotload_thread = thread.create(hotreload_thread_proc)
	if ctx.hotload_thread != nil {
		ctx.hotload_thread.init_context = context
		thread.start(ctx.hotload_thread)
	} else {
		log.error("Failed to create hotreload thread")
		return pl.PluginApi{}
	}

	ctx.initialized = true

	return _get_buffer_api()
}

//////////////
// internal //
//////////////

_close_and_copy_dll :: proc(toIdx: int) -> bool {
	ctx.apis[toIdx] = pl.PluginApi{}
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

	filename := fmt.tprintf("/Users/jagi/Programming/lindale/out/hot/LindaleInFlight%03d.dylib", toIdx)

	fail := os.remove(filename)
	if fail != nil && fail != .Not_Exist && fail != .ENOENT {
		log.error("Failed to remove old hotloaded dll", filename, "err:", fail)
	}

	err := os2.copy_file(filename, hotload_dll_path)
	if err == nil {
		log.info("Copied hotloaded dll to", filename)
		return true
	} else {
		log.error("Failed to copy hotloaded dll to %s: %v", hotload_dll_path, err)
		return false
	}
}

hotreload_thread_proc :: proc(t: ^thread.Thread) {
	context.logger = get_logger(.HotReload)

	for {
		modificationTime, err := os.last_write_time_by_name(hotload_dll_path)
		if err != nil {
			log.error("Failed to get modification time of hotloaded dll", err)
			time.sleep(time.Millisecond * 1000) // wait before retrying
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

		time.sleep(time.Millisecond * 100)
		// log.info("Checking for hotloaded dll changes...")
	}
}

HotLoaderProc :: struct {
	__handle: dynlib.Library,
	GetPluginApi : proc () -> pl.PluginApi,
}

_load_api :: proc() -> bool {
	modificationTime, err := os.last_write_time_by_name(hotload_dll_path)
	if err != nil {
		log.error("Failed to get modification time of hotloaded dll", err)
		return false
	}

	nextIdx := (ctx.idx + 1) % NUM_DLLS

	if !_close_and_copy_dll(nextIdx) {
		log.error("Failed to copy hotloaded dll")
		return false
	}
	hotloader: HotLoaderProc = {}

	filepath := fmt.tprintf("/Users/jagi/Programming/lindale/out/hot/LindaleInFlight%03d.dylib", nextIdx)

	lib, ok := dynlib.load_library(filepath)
	if ok && lib != nil {
		log.info("Got to loader proc")
		ptr, found := dynlib.symbol_address(lib, "GetPluginApi")
		if found {
			log.info("Loaded symbol")
			hotloader.GetPluginApi = cast(proc() -> pl.PluginApi)ptr
			ctx.apis[nextIdx] = hotloader.GetPluginApi()
			ctx.libs[nextIdx] = lib
			intrinsics.atomic_store_explicit(&ctx.idx, nextIdx, .Release)
			// no atomic needed, only called from hotload thread besides first load
			ctx.dllLastModTime = modificationTime
			return true
		}
	}

	// _, ok := dynlib.initialize_symbols(&hotloader, hotloadedDllPaths[nextIdx])
	// if ok && hotloader.GetPluginApi != nil {
	// 	log.info("Got to loader proc")
	// 	ctx.apis[nextIdx] = hotloader.GetPluginApi()
	// 	ctx.libs[nextIdx] = hotloader.__handle
	// 	intrinsics.atomic_store_explicit(&ctx.idx, nextIdx, .Release)
	// 	// no atomic needed, only called from hotload thread besides first load
	// 	ctx.dllLastModTime = modificationTime
	// 	return true
	// }

	log.error("couldnt initialize sybmols")

	return false
}

_get_buffer_api :: proc() -> pl.PluginApi {
	api : pl.PluginApi = {
		do_analysis = buffer_do_analysis,
		draw = buffer_draw,
	}

	return api

	buffer_do_analysis :: proc(plug: ^pl.Plugin, transfer: ^pl.AnalysisTransfer) {
		idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
		if idx < 0 || idx >= len(ctx.apis) {
			return
		}
		api := ctx.apis[idx]
		if api.do_analysis != nil {
			api.do_analysis(plug, transfer)
		}
	}
	buffer_draw :: proc(plug: ^pl.Plugin) {
		idx := intrinsics.atomic_load_explicit(&ctx.idx, .Acquire)
		if idx < 0 || idx >= len(ctx.apis) {
			return
		}
		api := ctx.apis[idx]
		if api.draw != nil {
			api.draw(plug)
		}
	}
}