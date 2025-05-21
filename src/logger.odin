package lindale

import "core:sys/windows"
import "core:fmt"
import "core:strings"
import "base:intrinsics"
import "core:thread"
import "core:time"

// Interface

MAX_LOG_LENGTH :: 256

debug_print :: proc(format: string, args: ..any) {
	when ODIN_OS == .Windows {
		buf: [512]u8;
		n := fmt.bprintf(buf[:], format, ..args);
		// windows.OutputDebugStringA(strings.unsafe_string_to_cstring(n));
		// windows.OutputDebugStringA("\n");
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

LoggerContext :: struct {
	readerThread: ^thread.Thread
}

ctx: LoggerContext

LogRingBuffer :: struct($RingBufSize: int) {
	// prevent false sharing by aligning to cache boundaries
	using _: struct #align(64) { writeIndex: int, }, // index of next write
	using _: struct #align(64) { readIndex: int, }, // index of next read
	buffers: [RingBufSize]Log,
}

@(private)
log_write :: proc(ringBuffer: ^LogRingBuffer($RBS), msg: string) {
	index := ringBuffer.writeIndex
	nextIndex := (index + 1) % RBS
	if nextIndex == intrinsics.atomic_load_explicit(&ringBuffer.readIndex, .Acquire) {
		// Buffer is full, trash log
		return
	}

	copy(ringBuffer.buffers[index][:], msg[:MAX_LOG_LENGTH])

	intrinsics.atomic_store_explicit(&ringBuffer.writeIndex, nextIndex, .Release)
}

@(private)
log_try_read :: proc(ringBuffer: ^LogRingBuffer, msg: ^Log) {
	if ringBuffer.readIndex != intrinsics.atomic_load_explicit(&ringBuffer.writeIndex, .Acquire) {
		index := ringBuffer.readIndex
		msg^ = strings.unsafe_string(ringBuffer.buffers[index][:])

		intrinsics.atomic_store_explicit(&ringBuffer.readIndex, (index + 1) % RBS, .Release)
	}
}

@(private)
log_reader_thread_proc :: proc(t: ^thread.Thread) {
	for {
		msg: Log
		log_try_read(ctx.ringBuffer, &msg)

		if msg != nil {
			debug_print("%s", msg[:])
		}

		time.sleep(1)
	}
}