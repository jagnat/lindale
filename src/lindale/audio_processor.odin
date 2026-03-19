package lindale

SampleSize :: enum {
	F32,
	F64,
}

AudioBufferGroup :: struct {
	using _: struct #raw_union {
		buffers32: [][]f32,
		buffers64: [][]f64,
	},
	sampleSize: SampleSize,
	silenceFlags: u64,
}

ParameterChange :: struct {
	sampleOffset: i32,
	value: f64,
}

AudioProcessorContext :: struct {
	inputBuffers:  []AudioBufferGroup,
	outputBuffers: []AudioBufferGroup,

	paramChanges: [][]ParameterChange,

	sampleRate: f64,
	projectTimeSamples: i64,

	squarePhase: i32,
}
