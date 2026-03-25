package bridge

EventKind :: enum u8 {
	NoteOn,
	NoteOff,
	PitchBend,
	CC,
}

NoteOn :: struct {
	note_id: i32,
	channel: i16,
	pitch: i16,
	tuning: f32,
	velocity: f32,
}

NoteOff :: struct {
	note_id: i32,
	channel: i16,
	pitch: i16,
	velocity: f32,
}

PitchBend :: struct {
	channel: i16,
	value: f32, // normalized -1 to +1
}

CC :: struct {
	channel: i16,
	controller: i16,
	value: f32, // normalized 0 to 1
}

Event :: struct {
	sample_offset: i32,
	kind: EventKind,
	using _: struct #raw_union {
		note_on: NoteOn,
		note_off: NoteOff,
		pitch_bend: PitchBend,
		cc: CC,
	},
}
