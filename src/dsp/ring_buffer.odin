package dsp

import "base:intrinsics"
import "core:testing"

// SPSC (single-producer, single-consumer) lock-free ring buffer.
// Audio thread writes, UI thread reads. No locks, no allocations.
// Buffer must be power-of-2 sized, externally provided.

RingBuffer :: struct {
	data:      []Sample,
	mask:      int,
	write_pos: int, // Only producer (audio thread) writes this
	read_pos:  int, // Only consumer (UI thread) writes this
}

ring_init :: proc(r: ^RingBuffer, buffer: []Sample) {
	#assert(size_of(int) == 8 || size_of(int) == 4)
	assert(len(buffer) > 0 && len(buffer) & (len(buffer) - 1) == 0, "ring buffer size must be power of 2")
	r.data = buffer
	r.mask = len(buffer) - 1
	r.write_pos = 0
	r.read_pos = 0
	buf_clear(buffer)
}

// Audio thread: write one sample
ring_write :: proc(r: ^RingBuffer, sample: Sample) {
	pos := intrinsics.atomic_load_explicit(&r.write_pos, .Relaxed)
	r.data[pos & r.mask] = sample
	intrinsics.atomic_store_explicit(&r.write_pos, pos + 1, .Release)
}

// Audio thread: write a block of samples
ring_write_buf :: proc(r: ^RingBuffer, samples: []Sample) {
	pos := intrinsics.atomic_load_explicit(&r.write_pos, .Relaxed)
	for s in samples {
		r.data[pos & r.mask] = s
		pos += 1
	}
	intrinsics.atomic_store_explicit(&r.write_pos, pos, .Release)
}

// UI thread: how many unread samples are available
ring_available :: proc(r: ^RingBuffer) -> int {
	wp := intrinsics.atomic_load_explicit(&r.write_pos, .Acquire)
	rp := intrinsics.atomic_load_explicit(&r.read_pos, .Relaxed)
	return wp - rp
}

// UI thread: copy the most recent `count` samples into dest.
// Does NOT advance read_pos — this is a snapshot for visualization.
// Returns number of samples actually copied (may be less than count
// if fewer than count samples have been written total).
ring_read_latest :: proc(r: ^RingBuffer, dest: []Sample) -> int {
	count := len(dest)
	wp := intrinsics.atomic_load_explicit(&r.write_pos, .Acquire)
	available := min(count, wp, len(r.data))
	start := wp - available
	for i in 0 ..< available {
		dest[i] = r.data[(start + i) & r.mask]
	}
	return available
}

// UI thread: read and consume up to len(dest) samples.
// Advances read_pos. Use this for streaming consumption rather than snapshots.
// Returns number of samples actually read.
ring_read :: proc(r: ^RingBuffer, dest: []Sample) -> int {
	wp := intrinsics.atomic_load_explicit(&r.write_pos, .Acquire)
	rp := intrinsics.atomic_load_explicit(&r.read_pos, .Relaxed)
	available := min(len(dest), wp - rp)
	for i in 0 ..< available {
		dest[i] = r.data[(rp + i) & r.mask]
	}
	intrinsics.atomic_store_explicit(&r.read_pos, rp + available, .Release)
	return available
}

// Tests

@(test)
test_ring_write_read_latest :: proc(t: ^testing.T) {
	buf: [8]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	ring_write(&r, 1)
	ring_write(&r, 2)
	ring_write(&r, 3)

	dest: [4]Sample
	n := ring_read_latest(&r, dest[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, dest[0], Sample(1))
	testing.expect_value(t, dest[1], Sample(2))
	testing.expect_value(t, dest[2], Sample(3))
}

@(test)
test_ring_read_latest_more_than_available :: proc(t: ^testing.T) {
	buf: [8]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	ring_write(&r, 5)
	ring_write(&r, 6)

	dest: [8]Sample
	n := ring_read_latest(&r, dest[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, dest[0], Sample(5))
	testing.expect_value(t, dest[1], Sample(6))
}

@(test)
test_ring_read_latest_is_snapshot :: proc(t: ^testing.T) {
	buf: [8]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	ring_write(&r, 1)
	ring_write(&r, 2)

	// Reading twice gives the same result — read_pos not advanced
	dest1, dest2: [4]Sample
	n1 := ring_read_latest(&r, dest1[:])
	n2 := ring_read_latest(&r, dest2[:])
	testing.expect_value(t, n1, n2)
	for i in 0 ..< n1 {
		testing.expect_value(t, dest1[i], dest2[i])
	}
}

@(test)
test_ring_write_buf :: proc(t: ^testing.T) {
	buf: [8]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	samples := [4]Sample{10, 20, 30, 40}
	ring_write_buf(&r, samples[:])

	dest: [4]Sample
	n := ring_read_latest(&r, dest[:])
	testing.expect_value(t, n, 4)
	for i in 0 ..< 4 {
		testing.expect_value(t, dest[i], samples[i])
	}
}

@(test)
test_ring_wraparound :: proc(t: ^testing.T) {
	buf: [4]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	// Write 6 samples into a 4-slot buffer — wraps around
	for i in 0 ..< 6 {
		ring_write(&r, Sample(i))
	}

	// Latest 4 should be 2, 3, 4, 5
	dest: [4]Sample
	n := ring_read_latest(&r, dest[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, dest[0], Sample(2))
	testing.expect_value(t, dest[1], Sample(3))
	testing.expect_value(t, dest[2], Sample(4))
	testing.expect_value(t, dest[3], Sample(5))
}

@(test)
test_ring_read_consume :: proc(t: ^testing.T) {
	buf: [8]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	ring_write(&r, 1)
	ring_write(&r, 2)
	ring_write(&r, 3)

	// Consume 2
	dest: [2]Sample
	n := ring_read(&r, dest[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, dest[0], Sample(1))
	testing.expect_value(t, dest[1], Sample(2))

	// Only 1 left
	testing.expect_value(t, ring_available(&r), 1)

	dest2: [4]Sample
	n2 := ring_read(&r, dest2[:])
	testing.expect_value(t, n2, 1)
	testing.expect_value(t, dest2[0], Sample(3))
}

@(test)
test_ring_empty :: proc(t: ^testing.T) {
	buf: [4]Sample
	r: RingBuffer
	ring_init(&r, buf[:])

	testing.expect_value(t, ring_available(&r), 0)

	dest: [4]Sample
	testing.expect_value(t, ring_read_latest(&r, dest[:]), 0)
	testing.expect_value(t, ring_read(&r, dest[:]), 0)
}
