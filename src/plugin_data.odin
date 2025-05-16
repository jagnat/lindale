package lindale

import "core:math"
import "core:fmt"
import "core:testing"

ParamUnitType :: enum {
	Decibel,
	Hertz,
	Percentage,
	Normalized,
	None,
}

@(rodata) ParamUnitTypeStrings := [ParamUnitType]string {
	.Decibel = "dB",
	.Hertz = "Hz",
	.Percentage = "%",
	.Normalized = "",
	.None = "",
}

ParamRange :: struct {
	min, max: f64,
	stepCount: i32,
	defaultValue: f64,
	unit: ParamUnitType,
}

ParamInfo :: struct {
	id: u32,
	name: string,
	shortName: string,
	flags: u32,
	range: ParamRange,
}

@(rodata) ParamTable := [?]ParamInfo {
	ParamInfo {
		id = 0,
		name = "Gain",
		shortName = "Gain",
		flags = 0,
		range = ParamRange {
			min = -60.0,
			max = 60.0,
			stepCount = 0,
			defaultValue = 0,
			unit = .Decibel,
		}
	},
	ParamInfo {
		id = 1,
		name = "Mix",
		shortName = "Mix",
		flags = 0,
		range = ParamRange {
			min = 0.0,
			max = 100.0,
			stepCount = 0,
			defaultValue = 100.0,
			unit = .Percentage,
		}
	},
	ParamInfo {
		id = 2,
		name = "Freq",
		shortName = "Freq",
		flags = 0,
		range = ParamRange {
			min = 20,
			max = 22000.0,
			stepCount = 0,
			defaultValue = 432.0,
			unit = .Hertz,
		}
	},
}

ParamState :: struct {
	values: [len(ParamTable)]f64,
}

AudioProcessorState :: struct {
	params: ParamState

}

print_param_to_buf :: proc(buf: ^[128]u8, paramVal: f64, info: ParamInfo) {
	switch info.range.unit {
	case .Decibel: fallthrough
	case .Normalized: fallthrough
	case .None:
		fmt.bprintfln(buf^[:], "{:.3f}", paramVal)
	case .Hertz: fallthrough
	case .Percentage:
		fmt.bprintfln(buf^[:], "{:.3f}", paramVal)
	}
}

param_from_string :: proc() {

}

param_to_norm :: proc(param: f64, range: ParamRange) -> f64 {
	switch range.unit {
	case .Decibel:
		return math.remap(param, range.min, range.max, 0, 1)
	case .Hertz:
		return math.remap(math.log10(param), math.log10(range.min), math.log10(range.max), 0, 1)
	case .Percentage:
		return param / 100
	case .Normalized:
		return param
	case .None:
		return param
	}

	return param
}

norm_to_param :: proc(norm: f64, range: ParamRange) -> f64 {
	switch range.unit {
	case .Decibel:
		return math.remap(norm, 0, 1, range.min, range.max)
	case .Hertz:
		return math.pow10_f64(math.remap(norm, 0, 1, math.log10_f64(range.min), math.log10_f64(range.max)))
	case .Percentage:
		return norm * 100
	case .Normalized:
		return norm
	case .None:
		return norm
	}

	return norm
}

@(test)
test_mappings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	
}
