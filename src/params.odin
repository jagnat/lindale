package platform

import "core:math"
import "core:fmt"
import "core:testing"
import "core:strconv"

import lin "lindale"

print_param_to_buf :: proc(buf: ^[128]u8, paramVal: f64, info: lin.ParamInfo) {
	switch info.range.unit {
	case .Decibel: fallthrough
	case .Normalized: fallthrough
	case .None:
		fmt.bprintfln(buf^[:], "{:.2f}", paramVal)
	case .Hertz: fallthrough
	case .Percentage:
		fmt.bprintfln(buf^[:], "{:.0f}", paramVal)
	}
}

get_param_from_buf :: proc(buf: ^[128]u8) -> f64 {
	n, _, ok := strconv.parse_f64_prefix(string(buf^[:]))
	if !ok do return 0
	return n
}

@test
test_param_to_norm_and_back_hertz :: proc(t: ^testing.T) {

	range := lin.ParamRange{
		min = 20.0,
		max = 20000.0,
		unit = .Hertz,
	}

	test_values := [?]f64{20.0, 100.0, 500, 1000.0, 5000.0, 10000.0, 20000.0}
	tolerance := 1e-9

	for val in test_values {
		norm := lin.param_to_norm(val, range)
		back := lin.norm_to_param(norm, range)
		diff := math.abs(val - back)
		testing.expect(t, diff <= tolerance)
	}

	test_norms := [?]f64{0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0}

	for val in test_norms {
		norm := lin.norm_to_param(val, range)
		back := lin.param_to_norm(norm, range)
		diff := math.abs(val - back)
		testing.expect(t, diff <= tolerance)
	}
}