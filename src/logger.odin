package lindale

import "base:runtime"
import "base:intrinsics"
import "core:sys/windows"
import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"
import "core:log"
import "core:os"

// Interface

MAX_LOG_LENGTH :: 256

LOG_BUFFER_COUNT :: 128

debug_print :: proc(format: string, args: ..any) {
	when ODIN_OS == .Windows {
		buf: [512]u8;
		n := fmt.bprintf(buf[:], format, ..args);
		windows.OutputDebugStringA(strings.unsafe_string_to_cstring(n));
	}
}

log_init :: proc() {
	t := thread.create(log_reader_thread_proc)
	if t != nil {
		t.init_context = context
		ctx.readerThread = t
		thread.start(t)
	}
}

// Internal

Log :: [MAX_LOG_LENGTH]u8

LogSources :: enum {
	Processor,
	Controller,
}

// One per thread
LoggerData :: struct {
	ringBuffer: ^LogRingBuffer,
	outputFilename: string,
	outputFile: os.Handle,
}

LoggerContext :: struct {
	readerThread: ^thread.Thread,
	logPools: [LogSources]LoggerData,
}

ctx: LoggerContext

LogRingBuffer :: struct {
	// prevent false sharing by aligning to cache boundaries
	using _: struct #align(64) { writeIndex: int, }, // index of next write
	using _: struct #align(64) { readIndex: int, }, // index of next read
	buffers: [LOG_BUFFER_COUNT]Log,
}

@(private)
log_write :: proc(ringBuffer: ^LogRingBuffer, msg: string) {
	index := ringBuffer.writeIndex
	nextIndex := (index + 1) % LOG_BUFFER_COUNT
	if nextIndex == intrinsics.atomic_load_explicit(&ringBuffer.readIndex, .Acquire) {
		// Buffer is full, trash log
		return
	}

	copy(ringBuffer.buffers[index][:], msg[:MAX_LOG_LENGTH])

	intrinsics.atomic_store_explicit(&ringBuffer.writeIndex, nextIndex, .Release)
}

@(private)
log_try_read :: proc(ringBuffer: ^LogRingBuffer, msg: ^Log) -> bool {
	if ringBuffer.readIndex != intrinsics.atomic_load_explicit(&ringBuffer.writeIndex, .Acquire) {
		index := ringBuffer.readIndex
		msg^ = ringBuffer.buffers[index]

		intrinsics.atomic_store_explicit(&ringBuffer.readIndex, (index + 1) % LOG_BUFFER_COUNT, .Release)

		return true
	}

	return false
}

@(private)
log_reader_thread_proc :: proc(t: ^thread.Thread) {
	for {
		msg: Log

		for &logger in ctx.logPools {
			if logger.ringBuffer != nil && log_try_read(logger.ringBuffer, &msg) {
				// Write to file
				if logger.outputFile != 0 {
					newln: []u8 = {'\n'}
					os.write(logger.outputFile, msg[:])
					os.write(logger.outputFile, newln)
				}
			}
		}

		time.sleep(1)
	}
}

logger_proc :: proc(
	logger_data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location
) {
	data := cast(^LoggerData)logger_data

	if data == nil {
		return
	}

	log_write(data.ringBuffer, text)
}