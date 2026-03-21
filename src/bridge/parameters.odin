package bridge

import "core:math"
import "core:fmt"
import "core:strconv"

ParamUnit :: enum {
	Decibel,
	Hertz,
	Percentage,
	Milliseconds,
	Normalized,
	None,
}

@(rodata) ParamUnitStrings := [ParamUnit]string {
	.Decibel = "dB",
	.Hertz = "Hz",
	.Percentage = "%",
	.Milliseconds = "ms",
	.Normalized = "",
	.None = "",
}

ParamFlag :: enum {
	Automatable,
	Read_Only,
	Wrap_Around,
	List,
	Hidden,
}
ParamFlagSet :: bit_set[ParamFlag]

ParamDescriptor :: struct {
	name: string,
	short_name: string,
	min: f64,
	max: f64,
	default_value: f64,
	step_count: i32,
	unit: ParamUnit,
	flags: ParamFlagSet,
}

ParamValues :: struct {
	values: []f64, // Plain units, indexed by parameter position
}

param_to_normalized :: proc(value: f64, desc: ParamDescriptor) -> f64 {
	switch desc.unit {
	case .Decibel:
		return math.remap(value, desc.min, desc.max, 0, 1)
	case .Hertz:
		return math.remap(math.ln_f64(value), math.ln_f64(desc.min), math.ln_f64(desc.max), 0, 1)
	case .Percentage:
		return value / 100.0
	case .Milliseconds:
		return math.remap(value, desc.min, desc.max, 0, 1)
	case .Normalized:
		return value
	case .None:
		return value
	}
	return value
}

normalized_to_param :: proc(norm: f64, desc: ParamDescriptor) -> f64 {
	switch desc.unit {
	case .Decibel:
		return math.remap(norm, 0, 1, desc.min, desc.max)
	case .Hertz:
		return math.exp_f64(math.remap(norm, 0, 1, math.ln_f64(desc.min), math.ln_f64(desc.max)))
	case .Percentage:
		return norm * 100.0
	case .Milliseconds:
		return math.remap(norm, 0, 1, desc.min, desc.max)
	case .Normalized:
		return norm
	case .None:
		return norm
	}
	return norm
}

param_format_value :: proc(value: f64, desc: ParamDescriptor, buf: []u8) -> string {
	switch desc.unit {
	case .Decibel, .Normalized, .None:
		return fmt.bprintf(buf, "{:.2f}", value)
	case .Hertz, .Percentage, .Milliseconds:
		return fmt.bprintf(buf, "{:.0f}", value)
	}
	return fmt.bprintf(buf, "{:.2f}", value)
}

param_parse_value :: proc(str: string, desc: ParamDescriptor) -> (f64, bool) {
	n, _, ok := strconv.parse_f64_prefix(str)
	if !ok do return 0, false
	return n, true
}
