package lindale

ParamUnitType :: enum {
	Decibel,
	Percentage,
	Normalized,
	None,
}

ParamRange :: struct {
	min, max: f64,
	stepCount: i32,
	defaultNormalized: f64,
	unit: string,
}

ParamInfo :: struct {
	id: u32,
	name: string,
	shortName: string,
	flags: u32,
	range: ParamRange,
}

paramTable :: [?]ParamInfo {
	ParamInfo {
		id = 0,
		name = "Gain",
		shortName = "Gain",
		flags = 0,
		range = ParamRange {
			min = -60.0,
			max = 0.0,
			stepCount = 0,
			defaultNormalized = 0.5,
			unit = "dB",
		}
	},
	ParamInfo {
		id = 1,
		name = "Mix",
		shortName = "Mix",
		flags = 0,
		range = ParamRange {
			min = 0.0,
			max = 1.0,
			stepCount = 0,
			defaultNormalized = 1.0,
			unit = "%",
		}
	},
}

ParamState :: struct {
	values: [len(paramTable)]f64,
}
