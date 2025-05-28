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
import "core:testing"

// Interface

log_init :: proc(log_folder: string) {
	// automatically zeroed
	ringBufs := make([]LogRingBuffer, len(LogSource))
	ctx.loggerRunning = true

	// Timestamp file prefix
	timestampBuf: [32]u8
	now := time.now()
	time.to_string_yyyy_mm_dd(now, timestampBuf[:])
	time.to_string_hms(now, timestampBuf[11:])
	timestampBuf[10] = '_' // Separator between date and time
	timestampBuf[13] = '-'
	timestampBuf[16] = '-' // Replace hh:mm:ss with hh-mm-ss
	tsStr := strings.string_from_ptr(&timestampBuf[0], 19)

	logFolderLen := len(log_folder)

	for &logData, source in ctx.logPools {
		copy(logData.outputFilenameBuf[:], log_folder)
		copy(logData.outputFilenameBuf[logFolderLen:], tsStr)
		copy(logData.outputFilenameBuf[logFolderLen + len(tsStr):], "_"[:])
		copy(logData.outputFilenameBuf[logFolderLen + len(tsStr)+1:], log_filename_from_source(source))

		logData.outputFilename = strings.string_from_null_terminated_ptr(
			&logData.outputFilenameBuf[0],
			len(logData.outputFilenameBuf))
		logData.ringBuffer = &ringBufs[source]
	}

	t := thread.create(log_reader_thread_proc)
	if t != nil {
		t.init_context = context
		ctx.readerThread = t
		thread.start(t)
	}
}

log_exit :: proc() {
	ctx.loggerRunning = false
	thread.join(ctx.readerThread)
	thread.destroy(ctx.readerThread)
}

get_logger :: proc(source: LogSource) -> runtime.Logger {
	return runtime.Logger{
		logger_proc,
		&ctx.logPools[source],
		runtime.Logger_Level.Debug,
		nil,
	}
}


// Internal

MAX_LOG_LENGTH :: 256
LOG_BUFFER_COUNT :: 10
FILE_BUFFER_SIZE :: 8192

Log :: [MAX_LOG_LENGTH]u8

LogSource :: enum {
	Processor,
	Controller,
	PluginFactory,
}

// One per thread
LoggerData :: struct {
	ringBuffer: ^LogRingBuffer,
	outputFilenameBuf: [128]u8,
	outputFilename: string,
	logWriteBuffer: [FILE_BUFFER_SIZE]u8,
	logWritePos: int,
}

LoggerContext :: struct {
	readerThread: ^thread.Thread,
	logPools: [LogSource]LoggerData,
	loggerRunning : bool,
}

@(private="file")
ctx: LoggerContext

// Single producer, single consumer ring buffer
LogRingBuffer :: struct {
	// prevent false sharing by aligning to cache boundaries
	using _: struct #align(64) { writeIndex: int, }, // index of next write
	using _: struct #align(64) { readIndex: int, }, // index of next read
	buffers: [LOG_BUFFER_COUNT]Log,
}

@(private)
log_filename_from_source :: proc(source: LogSource) -> string {
	switch source {
	case .Processor:
		return "processor.log"
	case .Controller:
		return "controller.log"
	case .PluginFactory:
		return "pluginfactory.log"
	case:
		return "unknown.log"
	}
}

@(private)
log_write :: proc(ringBuffer: ^LogRingBuffer, msg: string) {
	if ringBuffer == nil do return

	index := ringBuffer.writeIndex
	nextIndex := (index + 1) % LOG_BUFFER_COUNT
	if nextIndex == intrinsics.atomic_load_explicit(&ringBuffer.readIndex, .Acquire) {
		// Buffer is full, trash log
		return
	}

	loglen := len(msg)
	if loglen > MAX_LOG_LENGTH do loglen = MAX_LOG_LENGTH

	ringBuffer.buffers[index] = {}
	copy(ringBuffer.buffers[index][:], msg[:loglen])

	intrinsics.atomic_store_explicit(&ringBuffer.writeIndex, nextIndex, .Release)
}

@(private)
log_try_read :: proc(ringBuffer: ^LogRingBuffer, msg: ^Log) -> bool {
	if ringBuffer == nil do return false

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
	lastFlush := time.now()

	for ctx.loggerRunning {
		msg: Log

		shouldFlush := time.since(lastFlush) > time.Millisecond * 100

		for &logger in ctx.logPools {
			if logger.ringBuffer != nil {
				msg = {}
				hasLog := log_try_read(logger.ringBuffer, &msg)

				logStr := strings.string_from_null_terminated_ptr(&msg[0], MAX_LOG_LENGTH)

				if (hasLog && len(logStr) + logger.logWritePos >= FILE_BUFFER_SIZE) || (shouldFlush && logger.logWritePos > 0) {
					// Flush buffer to file
					handle, err := os.open(logger.outputFilename, os.O_WRONLY | os.O_CREATE | os.O_APPEND, 0o664)
					if err == nil {
						os.write(handle, logger.logWriteBuffer[:logger.logWritePos])
						os.close(handle)
						logger.logWritePos = 0
					}
				}

				if hasLog {
					// Write to buffer
					copy(logger.logWriteBuffer[logger.logWritePos:], logStr)
					logger.logWritePos += len(logStr)
				}
			}
		}

		if shouldFlush {
			lastFlush = time.now()
		}

		// Let's busy wait for now.. it's alright for testing
		// time.sleep(time.Millisecond)
	}

	// Flush remaining buffer to file
	for &logger in ctx.logPools {
		if logger.logWritePos > 0 {
			handle, err := os.open(logger.outputFilename, os.O_WRONLY | os.O_CREATE | os.O_APPEND, 0o664)
			if err == nil {
				os.write(handle, logger.logWriteBuffer[:logger.logWritePos])
				os.close(handle)
				logger.logWritePos = 0
			}
		}
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

	if data == nil || data.ringBuffer == nil {
		return
	}

	newlog: Log
	// Construct log
	logstr := fmt.bprintln(newlog[:], "[", level, "] ", text, sep="")

	log_write(data.ringBuffer, logstr)
}

@(private)
test_stop_thread :: proc() {
	ctx.loggerRunning = false
	thread.join(ctx.readerThread)
	thread.destroy(ctx.readerThread)
	ctx.readerThread = thread.create(log_reader_thread_proc)
	ctx.readerThread.init_context = context
}

@(private)
test_start_thread :: proc() {
	ctx.loggerRunning = true
	thread.start(ctx.readerThread)
}

@(test)
test_logger :: proc(t: ^testing.T) {

	log_init("")
	defer {
		log_exit()
		for &logger in ctx.logPools {
			os.remove(logger.outputFilename)
		}
		free_all(context.temp_allocator)
	}

	context.logger = get_logger(.Processor)

	// Test 1: Basic logging
	{
		test_msg := "Hello, logger"
		log.info(test_msg)

		time.sleep(time.Millisecond * 200)

		content, ok := os.read_entire_file(ctx.logPools[.Processor].outputFilename, allocator = context.temp_allocator)
		testing.expect(t, ok, "Failed to read log file")
		testing.expect(t, strings.contains(string(content), test_msg), "Log file does not contain expected message")
	}

	// Test 2: Buffer full handling
	{
		test_stop_thread()
		// Ring buffer stores (buffer size - 1) messages - so we can write LOG_BUFFER_COUNT - 1 messages
		for i in 0 ..< LOG_BUFFER_COUNT - 1 {
			log.debug("Message", i)
		}

		droppedStr := "This should be dropped"

		log.error(droppedStr)
		test_start_thread()

		time.sleep(200 * time.Millisecond)
		log.info("This should not be dropped")

		content, ok := os.read_entire_file(ctx.logPools[.Processor].outputFilename, allocator = context.temp_allocator)
		testing.expect(t, ok, "Failed to read log file")
		testing.expect(t, !strings.contains(string(content), droppedStr), "Dropped message found in file")
		testing.expect(t, strings.contains(string(content), fmt.tprintf("Message %d", LOG_BUFFER_COUNT - 2)), "Last log not present")
		testing.expect(t, strings.contains(string(content), "This should not be dropped"), "Post-flushed log not present")
	}
}