package platform

import "base:runtime"
import "base:intrinsics"
import "core:sys/windows"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:log"
import "core:os"
import "core:testing"

// Interface

mutex_log_init :: proc(log_folder: string) {
	if ctx.loggerRunning do return

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

	copy(ctx.outputFilenameBuf[:], log_folder)
	copy(ctx.outputFilenameBuf[logFolderLen:], tsStr)
	copy(ctx.outputFilenameBuf[logFolderLen + len(tsStr):], "_"[:])
	copy(ctx.outputFilenameBuf[logFolderLen + len(tsStr)+1:], "lindale.log")

	ctx.outputFilename = strings.string_from_null_terminated_ptr(
		&ctx.outputFilenameBuf[0],
		len(ctx.outputFilenameBuf))

	t := thread.create(log_mutex_reader_thread_proc)
	if t != nil {
		t.init_context = context
		ctx.readerThread = t
		ctx.loggerRunning = true
		thread.start(t)
	}
}

mutex_log_exit :: proc() {
	if ctx.loggerRunning {
		ctx.loggerRunning = false
		thread.join(ctx.readerThread)
		thread.destroy(ctx.readerThread)
	}
}

get_mutex_logger :: proc(source: LogSource) -> runtime.Logger {
	return runtime.Logger{
		mutex_logger_proc,
		transmute(rawptr)source,
		runtime.Logger_Level.Debug,
		nil,
	}
}

// Internal

MutexLoggerContext :: struct {
	logBuf: LogRingBuffer,
	readerThread: ^thread.Thread,
	lock: sync.Atomic_Mutex,
	outputFilenameBuf: [128]u8,
	outputFilename: string,
	loggerRunning : bool,
	logWriteBuffer: [FILE_BUFFER_SIZE]u8,
	logWritePos: int,
}

@(private="file")
ctx: MutexLoggerContext

@(private)
mutex_log_write :: proc(msg: string) {
	if sync.atomic_mutex_guard(&ctx.lock) {
		index := ctx.logBuf.writeIndex
		nextIndex := (index + 1) % LOG_BUFFER_COUNT
		if nextIndex == ctx.logBuf.readIndex do return // trash log if buf is full
		loglen := len(msg)
		if loglen > MAX_LOG_LENGTH do loglen = MAX_LOG_LENGTH
		ctx.logBuf.buffers[index] = {}
		copy(ctx.logBuf.buffers[index][:], msg[:loglen])
		ctx.logBuf.writeIndex = nextIndex
	}
}

@(private)
mutex_log_try_read :: proc(msg: ^Log) -> bool {
	readIndex := ctx.logBuf.readIndex
	writeIndex := 0
	if sync.atomic_mutex_guard(&ctx.lock) {
		writeIndex = ctx.logBuf.writeIndex
	}

	if readIndex != writeIndex {
		msg^ = ctx.logBuf.buffers[readIndex]
		if sync.atomic_mutex_guard(&ctx.lock) {
			ctx.logBuf.readIndex = (readIndex + 1) % LOG_BUFFER_COUNT
		}
		return true
	}

	return false
}

@(private)
mutex_log_flush :: proc() {
	if ctx.logWritePos == 0 do return
	handle, err := os.open(ctx.outputFilename, os.O_WRONLY | os.O_CREATE | os.O_APPEND, 0o664)
	if err == nil {
		os.write(handle, ctx.logWriteBuffer[:ctx.logWritePos])
		os.close(handle)
		ctx.logWritePos = 0
	}
}

@(private)
log_mutex_reader_thread_proc :: proc(t: ^thread.Thread) {
	lastFlush := time.now()

	for ctx.loggerRunning {
		msg: Log

		shouldFlush := time.since(lastFlush) > LOG_FLUSH_TIME

		for mutex_log_try_read(&msg) {
			shouldFlush = time.since(lastFlush) > LOG_FLUSH_TIME
			logStr := strings.string_from_null_terminated_ptr(&msg[0], MAX_LOG_LENGTH)

			if len(logStr) + ctx.logWritePos >= FILE_BUFFER_SIZE || shouldFlush {
				mutex_log_flush()
			}

			fmt.println(logStr)

			// Write to buffer
			copy(ctx.logWriteBuffer[ctx.logWritePos:], logStr)
			ctx.logWritePos += len(logStr)
		}

		if shouldFlush && ctx.logWritePos > 0 {
			mutex_log_flush()
			lastFlush = time.now()
		}

		// TODO: Add a condition flag here to wake thread when a log is written
		time.sleep(time.Millisecond * 10)
	}

	// Flush remaining buffer to file
	mutex_log_flush()
}

mutex_logger_proc :: proc(
	logger_data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location
) {
	source := transmute(LogSource)logger_data

	newlog: Log
	// Construct log
	logstr := fmt.bprintln(newlog[:], "[", source, "][", level, "] ", text, sep="")

	mutex_log_write(logstr)
}

@(private)
test_stop_mutex_thread :: proc() {
	ctx.loggerRunning = false
	thread.join(ctx.readerThread)
	thread.destroy(ctx.readerThread)
	ctx.readerThread = thread.create(log_reader_thread_proc)
	ctx.readerThread.init_context = context
}

@(private)
test_start_mutex_thread :: proc() {
	ctx.loggerRunning = true
	thread.start(ctx.readerThread)
}

@(test)
test_mutex_logger :: proc(t: ^testing.T) {

	mutex_log_init("")
	defer {
		mutex_log_exit()
		os.remove(ctx.outputFilename)
		free_all(context.temp_allocator)
	}

	context.logger = get_mutex_logger(.Processor)

	// Test 1: Basic logging
	{
		test_msg := "Hello, logger"
		log.info(test_msg)

		time.sleep(2 * LOG_FLUSH_TIME)

		content, ok := os.read_entire_file(ctx.outputFilename, allocator = context.temp_allocator)
		testing.expect(t, ok, "Failed to read log file")
		testing.expect(t, strings.contains(string(content), test_msg), "Log file does not contain expected message")
	}

	// Test 2: Buffer full handling
	{
		test_stop_mutex_thread()
		// Ring buffer stores (buffer size - 1) messages - so we can write LOG_BUFFER_COUNT - 1 messages
		for i in 0 ..< LOG_BUFFER_COUNT - 1 {
			log.debug("Message", i)
		}

		droppedStr := "This should be dropped"

		log.error(droppedStr)
		test_start_mutex_thread()

		time.sleep(2 * LOG_FLUSH_TIME)
		log.info("This should not be dropped")

		content, ok := os.read_entire_file(ctx.outputFilename, allocator = context.temp_allocator)
		testing.expect(t, ok, "Failed to read log file")
		testing.expect(t, !strings.contains(string(content), droppedStr), "Dropped message found in file")
		testing.expect(t, strings.contains(string(content), fmt.tprintf("Message %d", LOG_BUFFER_COUNT - 2)), "Last log not present")
		testing.expect(t, strings.contains(string(content), "This should not be dropped"), "Post-flushed log not present")
	}
}
