package host_shared

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

// Logging enabled for debug and disabled for release, but can be
// enabled for release using -define:LINDALE_LOG=true
LOG_ENABLED :: #config(LINDALE_LOG, ODIN_DEBUG)

// Interface

mutex_log_init :: proc(log_folder: string, log_name: string) {
	when !LOG_ENABLED do return
	if intrinsics.atomic_load_explicit(&ctx.logger_running, .Acquire) do return

	// Timestamp file prefix
	timestamp_buf: [32]u8
	now := time.now()
	_ = time.to_string_yyyy_mm_dd(now, timestamp_buf[:])
	_ = time.to_string_hms(now, timestamp_buf[11:])
	timestamp_buf[10] = '_' // Separator between date and time
	timestamp_buf[13] = '-'
	timestamp_buf[16] = '-' // Replace hh:mm:ss with hh-mm-ss
	ts_str := strings.string_from_ptr(&timestamp_buf[0], 19)

	ctx.output_filename = fmt.bprintf(
		ctx.output_filename_buf[:], "%s%s_%s.log", log_folder, ts_str, log_name)

	t := thread.create(log_mutex_reader_thread_proc)
	if t != nil {
		t.init_context = context
		ctx.reader_thread = t
		intrinsics.atomic_store_explicit(&ctx.logger_running, true, .Release)
		thread.start(t)
	}
}

mutex_log_exit :: proc() {
	if intrinsics.atomic_load_explicit(&ctx.logger_running, .Acquire) {
		intrinsics.atomic_store_explicit(&ctx.logger_running, false, .Release)
		thread.join(ctx.reader_thread)
		thread.destroy(ctx.reader_thread)
		ctx.reader_thread = nil
	}
}

get_mutex_logger :: proc(source: LogSource) -> runtime.Logger {
	when !LOG_ENABLED do return log.nil_logger()
	return runtime.Logger{
		mutex_logger_proc,
		transmute(rawptr)source,
		runtime.Logger_Level.Debug,
		nil,
	}
}

// Internal

MutexLoggerContext :: struct {
	log_buf: LogRingBuffer,
	reader_thread: ^thread.Thread,
	lock: sync.Atomic_Mutex,
	output_filename_buf: [512]u8,
	output_filename: string,
	logger_running : bool,
	log_write_buffer: [FILE_BUFFER_SIZE]u8,
	log_write_pos: int,
}

@(private="file")
ctx: MutexLoggerContext

@(private)
mutex_log_write :: proc(msg: string) {
	if sync.atomic_mutex_guard(&ctx.lock) {
		index := ctx.log_buf.write_index
		next_index := (index + 1) % LOG_BUFFER_COUNT
		if next_index == ctx.log_buf.read_index do return // trash log if buf is full
		loglen := len(msg)
		if loglen > MAX_LOG_LENGTH do loglen = MAX_LOG_LENGTH
		ctx.log_buf.buffers[index] = {}
		copy(ctx.log_buf.buffers[index][:], msg[:loglen])
		ctx.log_buf.write_index = next_index
	}
}

@(private)
mutex_log_try_read :: proc(msg: ^Log) -> bool {
	read_index := ctx.log_buf.read_index
	write_index := 0
	if sync.atomic_mutex_guard(&ctx.lock) {
		write_index = ctx.log_buf.write_index
	}

	if read_index != write_index {
		msg^ = ctx.log_buf.buffers[read_index]
		if sync.atomic_mutex_guard(&ctx.lock) {
			ctx.log_buf.read_index = (read_index + 1) % LOG_BUFFER_COUNT
		}
		return true
	}

	return false
}

@(private)
mutex_log_flush :: proc() {
	if ctx.log_write_pos == 0 do return
	handle, err := os.open(ctx.output_filename, {.Write, .Create, .Append})
	if err == nil {
		os.write(handle, ctx.log_write_buffer[:ctx.log_write_pos])
		os.close(handle)
		ctx.log_write_pos = 0
	}
}

@(private)
log_mutex_reader_thread_proc :: proc(t: ^thread.Thread) {
	last_flush := time.now()

	for intrinsics.atomic_load_explicit(&ctx.logger_running, .Acquire) {
		msg: Log

		should_flush := time.since(last_flush) > LOG_FLUSH_TIME

		for mutex_log_try_read(&msg) {
			should_flush = time.since(last_flush) > LOG_FLUSH_TIME
			log_str := strings.string_from_null_terminated_ptr(&msg[0], MAX_LOG_LENGTH)

			if len(log_str) + ctx.log_write_pos >= FILE_BUFFER_SIZE || should_flush {
				mutex_log_flush()
			}

			fmt.print(log_str)

			// Write to buffer
			copy(ctx.log_write_buffer[ctx.log_write_pos:], log_str)
			ctx.log_write_pos += len(log_str)
		}

		if should_flush && ctx.log_write_pos > 0 {
			mutex_log_flush()
			last_flush = time.now()
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
	intrinsics.atomic_store_explicit(&ctx.logger_running, false, .Release)
	thread.join(ctx.reader_thread)
	thread.destroy(ctx.reader_thread)
	ctx.reader_thread = thread.create(log_mutex_reader_thread_proc)
	ctx.reader_thread.init_context = context
}

@(private)
test_start_mutex_thread :: proc() {
	intrinsics.atomic_store_explicit(&ctx.logger_running, true, .Release)
	thread.start(ctx.reader_thread)
}

@(test)
test_mutex_logger :: proc(t: ^testing.T) {

	mutex_log_init("", "test")
	defer {
		mutex_log_exit()
		os.remove(ctx.output_filename)
		free_all(context.temp_allocator)
	}

	context.logger = get_mutex_logger(.Processor)

	// Test 1: Basic logging
	{
		test_msg := "Hello, logger"
		log.info(test_msg)

		time.sleep(2 * LOG_FLUSH_TIME)

		content, err := os.read_entire_file(ctx.output_filename, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "Failed to read log file")
		testing.expect(t, strings.contains(string(content), test_msg), "Log file does not contain expected message")
	}

	// Test 2: Buffer full handling
	{
		test_stop_mutex_thread()
		// Ring buffer stores (buffer size - 1) messages - so we can write LOG_BUFFER_COUNT - 1 messages
		for i in 0 ..< LOG_BUFFER_COUNT - 1 {
			log.debug("Message", i)
		}

		dropped_str := "This should be dropped"

		log.error(dropped_str)
		test_start_mutex_thread()

		time.sleep(2 * LOG_FLUSH_TIME)
		log.info("This should not be dropped")

		content, err := os.read_entire_file(ctx.output_filename, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "Failed to read log file")
		testing.expect(t, !strings.contains(string(content), dropped_str), "Dropped message found in file")
		testing.expect(t, strings.contains(string(content), fmt.tprintf("Message %d", LOG_BUFFER_COUNT - 2)), "Last log not present")
		testing.expect(t, strings.contains(string(content), "This should not be dropped"), "Post-flushed log not present")
	}

	// Test 3: Concurrent producers sharing the single mutex-protected ring.
	// All four sources funnel into one file; per-source seqs must remain in order.
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
				context.logger = get_mutex_logger(p.source)
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

		time.sleep(3 * LOG_FLUSH_TIME)

		content_bytes, err := os.read_entire_file(ctx.output_filename, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "Failed to read log file")
		content := string(content_bytes)

		// Per source: walk lines containing "TSAN_MARKER <source>", check seqs are monotonic.
		for src in LogSource {
			tag := fmt.tprintf("TSAN_MARKER %v", src)
			last_seq := -1
			seen := 0
			rest := content
			for {
				idx := strings.index(rest, tag)
				if idx < 0 do break
				rest = rest[idx:]
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
