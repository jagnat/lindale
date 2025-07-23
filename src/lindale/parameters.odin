package lindale

import "core:math"
import "core:fmt"
import "core:testing"
import "core:strconv"

ParamID :: enum {
	Gain = 0,
	Mix = 1,
	Freq = 2,
}

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

ParamFlagSet :: bit_set[ParamFlags]
ParamFlags :: enum {
	Automatable,
	ReadOnly,
	WrapAround,
	List,
	Hidden,
	ProgramChangeParam,
	BypassParam,
}

ParamInfo :: struct {
	name: string,
	shortName: string,
	range: ParamRange,
	flags: ParamFlags,
}

ParamState :: struct {
	values: [ParamID]f64, // Normalized
}

@(rodata) ParamTable := [ParamID]ParamInfo {
	.Gain =  {
		name = "Gain",
		shortName = "Gain",
		range = ParamRange {
			min = -60.0,
			max = 60.0,
			stepCount = 0,
			defaultValue = 0,
			unit = .Decibel,
		},
		flags = {}
	},
	.Mix = {
		name = "Mix",
		shortName = "Mix",
		range = ParamRange {
			min = 0.0,
			max = 100.0,
			stepCount = 0,
			defaultValue = 0.0,
			unit = .Percentage,
		},
		flags = {}
	},
	.Freq = {
		name = "Freq",
		shortName = "Freq",
		range = ParamRange {
			min = 20,
			max = 22000.0,
			stepCount = 0,
			defaultValue = 432.0,
			unit = .Hertz,
		},
		flags = {}
	},
}

param_to_norm :: proc(param: f64, range: ParamRange) -> f64 {
	switch range.unit {
	case .Decibel:
		return math.remap(param, range.min, range.max, 0, 1)
	case .Hertz:
		return math.remap(math.ln_f64(param), math.ln_f64(range.min), math.ln_f64(range.max), 0, 1)
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
		return math.exp_f64(math.remap(norm, 0, 1, math.ln_f64(range.min), math.ln_f64(range.max)))
	case .Percentage:
		return norm * 100
	case .Normalized:
		return norm
	case .None:
		return norm
	}

	return norm
}
