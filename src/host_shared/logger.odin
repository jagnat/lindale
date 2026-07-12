package host_shared

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

@(private="file") // temp disable
log_init :: proc(log_folder: string) {
	// automatically zeroed
	ring_bufs := make([]LogRingBuffer, len(LogSource))
	intrinsics.atomic_store_explicit(&ctx.logger_running, true, .Release)

	// Timestamp file prefix
	timestamp_buf: [32]u8
	now := time.now()
	_ = time.to_string_yyyy_mm_dd(now, timestamp_buf[:])
	_ = time.to_string_hms(now, timestamp_buf[11:])
	timestamp_buf[10] = '_' // Separator between date and time
	timestamp_buf[13] = '-'
	timestamp_buf[16] = '-' // Replace hh:mm:ss with hh-mm-ss
	ts_str := strings.string_from_ptr(&timestamp_buf[0], 19)

	log_folder_len := len(log_folder)

	for &log_data, source in ctx.log_pools {
		copy(log_data.output_filename_buf[:], log_folder)
		copy(log_data.output_filename_buf[log_folder_len:], ts_str)
		copy(log_data.output_filename_buf[log_folder_len + len(ts_str):], "_"[:])
		copy(log_data.output_filename_buf[log_folder_len + len(ts_str)+1:], log_filename_from_source(source))

		log_data.output_filename = strings.string_from_null_terminated_ptr(
			&log_data.output_filename_buf[0],
			len(log_data.output_filename_buf))
		log_data.ring_buffer = &ring_bufs[source]
	}

	t := thread.create(log_reader_thread_proc)
	if t != nil {
		t.init_context = context
		ctx.reader_thread = t
		thread.start(t)
	}
}

@(private="file") // temp disable
log_exit :: proc() {
	if intrinsics.atomic_load_explicit(&ctx.logger_running, .Acquire) {
		intrinsics.atomic_store_explicit(&ctx.logger_running, false, .Release)
		thread.join(ctx.reader_thread)
		thread.destroy(ctx.reader_thread)
	}
}

@(private="file") // temp disable
get_logger :: proc(source: LogSource) -> runtime.Logger {
	return runtime.Logger{
		logger_proc,
		&ctx.log_pools[source],
		runtime.Logger_Level.Debug,
		nil,
	}
}


// Internal

MAX_LOG_LENGTH :: 256
LOG_BUFFER_COUNT :: 2048
FILE_BUFFER_SIZE :: 8192

Log :: [MAX_LOG_LENGTH]u8

LogSource :: enum int {
	Processor,
	Controller,
	PluginFactory,
	HotReload,
}

// One per thread
LoggerData :: struct {
	ring_buffer: ^LogRingBuffer,
	output_filename_buf: [128]u8,
	output_filename: string,
	log_write_buffer: [FILE_BUFFER_SIZE]u8,
	log_write_pos: int,
}

LoggerContext :: struct {
	reader_thread: ^thread.Thread,
	log_pools: [LogSource]LoggerData,
	logger_running : bool,
}

@(private="file")
ctx: LoggerContext

// Single producer, single consumer ring buffer
LogRingBuffer :: struct {
	// prevent false sharing by aligning to cache boundaries
	using _: struct #align(64) { write_index: int, }, // index of next write
	using _: struct #align(64) { read_index: int, }, // index of next read
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
	case .HotReload:
		return "hotreload.log"
	case:
		return "unknown.log"
	}
}

@(private)
log_write :: proc(ring_buffer: ^LogRingBuffer, msg: string) {
	if ring_buffer == nil do return

	index := ring_buffer.write_index
	next_index := (index + 1) % LOG_BUFFER_COUNT
	if next_index == intrinsics.atomic_load_explicit(&ring_buffer.read_index, .Acquire) {
		// Buffer is full, trash log
		return
	}

	loglen := len(msg)
	if loglen > MAX_LOG_LENGTH do loglen = MAX_LOG_LENGTH

	ring_buffer.buffers[index] = {}
	copy(ring_buffer.buffers[index][:], msg[:loglen])

	intrinsics.atomic_store_explicit(&ring_buffer.write_index, next_index, .Release)
}

@(private)
log_try_read :: proc(ring_buffer: ^LogRingBuffer, msg: ^Log) -> bool {
	if ring_buffer == nil do return false

	if ring_buffer.read_index != intrinsics.atomic_load_explicit(&ring_buffer.write_index, .Acquire) {
		index := ring_buffer.read_index
		msg^ = ring_buffer.buffers[index]

		intrinsics.atomic_store_explicit(&ring_buffer.read_index, (index + 1) % LOG_BUFFER_COUNT, .Release)

		return true
	}

	return false
}

LOG_FLUSH_TIME :: time.Millisecond * 1000

@(private)
log_reader_thread_proc :: proc(t: ^thread.Thread) {
	last_flush := time.now()

	for intrinsics.atomic_load_explicit(&ctx.logger_running, .Acquire) {
		msg: Log

		should_flush := time.since(last_flush) > LOG_FLUSH_TIME

		for &logger in ctx.log_pools {
			if logger.ring_buffer != nil {
				msg = {}
				has_log := log_try_read(logger.ring_buffer, &msg)

				log_str := strings.string_from_null_terminated_ptr(&msg[0], MAX_LOG_LENGTH)

				if (has_log && len(log_str) + logger.log_write_pos >= FILE_BUFFER_SIZE) || (should_flush && logger.log_write_pos > 0) {
					// Flush buffer to file
					handle, err := os.open(logger.output_filename, {.Write, .Append, .Create})
					if err == nil {
						os.write(handle, logger.log_write_buffer[:logger.log_write_pos])
						os.close(handle)
						logger.log_write_pos = 0
					}
				}

				if has_log {
					// Write to buffer
					copy(logger.log_write_buffer[logger.log_write_pos:], log_str)
					logger.log_write_pos += len(log_str)
				}
			}
		}

		if should_flush {
			last_flush = time.now()
		}

		// TODO: Add a condition flag here to wake thread when a log is written
		time.sleep(time.Millisecond * 10)
	}

	// Flush remaining buffer to file
	for &logger in ctx.log_pools {
		if logger.log_write_pos > 0 {
			handle, err := os.open(logger.output_filename, {.Write, .Create, .Append})
			if err == nil {
				os.write(handle, logger.log_write_buffer[:logger.log_write_pos])
				os.close(handle)
				logger.log_write_pos = 0
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

	if data == nil || data.ring_buffer == nil {
		return
	}

	newlog: Log
	// Construct log
	logstr := fmt.bprintln(newlog[:], "[", level, "] ", text, sep="")

	log_write(data.ring_buffer, logstr)
}

@(private)
test_stop_thread :: proc() {
	intrinsics.atomic_store_explicit(&ctx.logger_running, false, .Release)
	thread.join(ctx.reader_thread)
	thread.destroy(ctx.reader_thread)
	ctx.reader_thread = thread.create(log_reader_thread_proc)
	ctx.reader_thread.init_context = context
}

@(private)
test_start_thread :: proc() {
	intrinsics.atomic_store_explicit(&ctx.logger_running, true, .Release)
	thread.start(ctx.reader_thread)
}

@(test)
test_logger :: proc(t: ^testing.T) {

	log_init("")
	defer {
		log_exit()
		for &logger in ctx.log_pools {
			os.remove(logger.output_filename)
		}
		free_all(context.temp_allocator)
	}

	context.logger = get_logger(.Processor)

	// Test 1: Basic logging
	{
		test_msg := "Hello, logger"
		log.info(test_msg)

		time.sleep(2 * LOG_FLUSH_TIME)

		content, err := os.read_entire_file(ctx.log_pools[.Processor].output_filename, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "Failed to read log file")
		testing.expect(t, strings.contains(string(content), test_msg), "Log file does not contain expected message")
	}

	// Test 2: Buffer full handling
	{
		test_stop_thread()
		// Ring buffer stores (buffer size - 1) messages - so we can write LOG_BUFFER_COUNT - 1 messages
		for i in 0 ..< LOG_BUFFER_COUNT - 1 {
			log.debug("Message", i)
		}

		dropped_str := "This should be dropped"

		log.error(dropped_str)
		test_start_thread()

		time.sleep(2 * LOG_FLUSH_TIME)
		log.info("This should not be dropped")

		content, err := os.read_entire_file(ctx.log_pools[.Processor].output_filename, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "Failed to read log file")
		testing.expect(t, !strings.contains(string(content), dropped_str), "Dropped message found in file")
		testing.expect(t, strings.contains(string(content), fmt.tprintf("Message %d", LOG_BUFFER_COUNT - 2)), "Last log not present")
		testing.expect(t, strings.contains(string(content), "This should not be dropped"), "Post-flushed log not present")
	}

	// Test 3: Concurrent producers, one per LogSource, each writing to its own SPSC ring
	// while the reader thread drains all four in parallel. Validates per-source FIFO order.
	{
		PRODUCER_MSGS :: 200

		Producer :: struct {
			source: LogSource,
			count: int,
		}

		producers: [LogSource]Producer
		for src in LogSource {
			producers[src] = {source = src, count = PRODUCER_MSGS}
		}

		threads: [LogSource]^thread.Thread
		for src in LogSource {
			threads[src] = thread.create(proc(th: ^thread.Thread) {
				p := cast(^Producer)th.data
				context.logger = get_logger(p.source)
				for i in 0 ..< p.count {
					log.info("TSAN_MARKER", p.source, i)
				}
			})
			threads[src].data = &producers[src]
			thread.start(threads[src])
		}

		for src in LogSource {
			thread.join(threads[src])
			thread.destroy(threads[src])
		}

		// Reader pulls one msg per source per ~10ms loop; let it drain plus a flush window.
		time.sleep(3 * LOG_FLUSH_TIME)

		// Per source: parse TSAN_MARKER lines, assert seq numbers strictly increase.
		for src in LogSource {
			content_bytes, err := os.read_entire_file(ctx.log_pools[src].output_filename, allocator = context.temp_allocator)
			testing.expect(t, err == nil, "Failed to read log file")
			content := string(content_bytes)

			last_seq := -1
			seen := 0
			rest := content
			for {
				idx := strings.index(rest, "TSAN_MARKER")
				if idx < 0 do break
				rest = rest[idx:]
				// Format: "TSAN_MARKER <Source> <seq>\n"
				eol := strings.index(rest, "\n")
				if eol < 0 do break
				line := rest[:eol]
				rest = rest[eol+1:]

				space2 := strings.last_index(line, " ")
				if space2 < 0 do continue
				seq_str := line[space2+1:]
				seq := 0
				ok := true
				for ch in seq_str {
					if ch < '0' || ch > '9' { ok = false; break }
					seq = seq * 10 + int(ch - '0')
				}
				if !ok do continue

				testing.expectf(t, seq > last_seq, "non-monotonic seq for %v: %d after %d", src, seq, last_seq)
				last_seq = seq
				seen += 1
			}

			testing.expectf(t, seen == PRODUCER_MSGS, "expected %d messages for %v, got %d", PRODUCER_MSGS, src, seen)
		}
	}
}