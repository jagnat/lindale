package dsp

import "core:math"
import "core:testing"

DelayLine :: struct {
	buffer:       []Sample,
	write_pos:    int,
	length:       int,
	allpass_state: Sample,
}

// Buffer is externally provided — caller manages memory
delay_init :: proc(d: ^DelayLine, buffer: []Sample) {
	d.buffer = buffer
	d.length = len(buffer)
	d.write_pos = 0
	d.allpass_state = 0
	buf_clear(buffer)
}

delay_write :: proc(d: ^DelayLine, input: Sample) {
	d.buffer[d.write_pos] = input
	d.write_pos = (d.write_pos + 1) %% d.length
}

delay_read :: proc(d: ^DelayLine, delay_samples: int) -> Sample {
	pos := (d.write_pos - delay_samples) %% d.length
	return d.buffer[pos]
}

delay_read_frac :: proc(d: ^DelayLine, delay_samples: f32, interp: InterpolationType = .Linear) -> Sample {
	read_pos := f32(d.write_pos) - delay_samples
	// Normalize to positive range
	for read_pos < 0 {
		read_pos += f32(d.length)
	}

	switch interp {
	case .None:
		return d.buffer[int(read_pos) %% d.length]
	case .Linear:
		return interp_linear(d.buffer, read_pos)
	case .Cubic:
		return interp_cubic(d.buffer, read_pos)
	}
	return 0
}

// Write input and read at delay_samples offset
delay_process :: proc(d: ^DelayLine, input: Sample, delay_samples: int) -> Sample {
	out := delay_read(d, delay_samples)
	delay_write(d, input)
	return out
}

delay_clear :: proc(d: ^DelayLine) {
	buf_clear(d.buffer)
	d.write_pos = 0
	d.allpass_state = 0
}

// Tests

@(test)
test_delay_write_read :: proc(t: ^testing.T) {
	buf: [16]Sample
	d: DelayLine
	delay_init(&d, buf[:])

	delay_write(&d, 0.5)
	// Reading 1 sample back should return what we just wrote
	val := delay_read(&d, 1)
	testing.expect(t, math.abs(val - 0.5) < 1e-6)
}

@(test)
test_delay_process :: proc(t: ^testing.T) {
	buf: [8]Sample
	d: DelayLine
	delay_init(&d, buf[:])

	// Write 1.0 then read it back after 3 samples of delay
	delay_write(&d, 1.0)
	delay_write(&d, 0.0)
	delay_write(&d, 0.0)

	val := delay_read(&d, 3)
	testing.expect(t, math.abs(val - 1.0) < 1e-6)
}

@(test)
test_delay_fractional :: proc(t: ^testing.T) {
	buf: [16]Sample
	d: DelayLine
	delay_init(&d, buf[:])

	delay_write(&d, 0.0)
	delay_write(&d, 1.0)
	delay_write(&d, 0.0)

	// 1.5 samples back should interpolate between 1.0 and 0.0
	val := delay_read_frac(&d, 1.5, .Linear)
	testing.expect(t, math.abs(val - 0.5) < 1e-5)
}
