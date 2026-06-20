package clap

import "core:c"
import "base:runtime"

PLUGIN_FACTORY_ID :: "clap.plugin-factory"

FEATURE_INSTRUMENT :: "instrument"
FEATURE_AUDIO_EFFECT :: "audio-effect"
FEATURE_NOTE_EFFECT :: "note-effect"
FEATURE_NOTE_DETECTOR :: "note-detector"
FEATURE_ANALYZER :: "analyzer"

BeatTime :: i64
SecTime :: i64

ClapId :: u32

NAME_SIZE :: 256

ClapVersion :: struct {
	major, minor, revision: u32,
}

VERSION :: ClapVersion{1, 2, 9}

// DLL needs to export one of these
// named `clap_entry`
PluginEntry :: struct {
	version: ClapVersion,
	init: proc "system" (plugin_path: cstring) -> c.bool,
	deinit: proc "system" (),
	get_factory: proc "system" (factory_id: cstring) -> rawptr,
}

PluginDescriptor :: struct {
	clap_version: ClapVersion,
	id: cstring,
	name: cstring,
	vendor: cstring,
	url: cstring,
	manual_url: cstring,
	support_url: cstring,
	version: cstring,
	description: cstring,

	features: [^]cstring,
}

Plugin :: struct {
	desc: ^PluginDescriptor,
	plugin_data: rawptr,

	init: proc "system" (plugin: ^Plugin) -> c.bool,
	destroy: proc "system" (plugin: ^Plugin),
	activate: proc "system" (plugin: ^Plugin, sample_rate: f64, min_frames_count, max_frames_count: u32) -> c.bool,
	deactivate: proc "system" (plugin: ^Plugin),
	start_processing: proc "system" (plugin: ^Plugin) -> c.bool,
	stop_processing: proc "system" (plugin: ^Plugin),
	reset: proc "system" (plugin: ^Plugin),
	process: proc "system" (plugin: ^Plugin, process: ^Process) -> ProcessStatus,
	get_extension: proc "system" (plugin: ^Plugin, id: cstring) -> rawptr,
	on_main_thread: proc "system" (plugin: ^Plugin),
}

ProcessStatus :: enum i32 {
	ERROR,
	CONTINUE,
	CONTINUE_IF_NOT_QUIET,
	TAIL,
	SLEEP,
}

Process :: struct {
	steady_time: i64,
	frames_count: u32,
	transport: ^EventTransport,

	audio_inputs: ^AudioBuffer,
	audio_outputs: ^AudioBuffer,
	audio_inputs_count: u32,
	audio_outputs_count: u32,

	in_events: ^InputEvents,
	out_events: ^OutputEvents,
}

Host :: struct {
	clap_version: ClapVersion,
	host_data: rawptr,
	name: cstring,
	vendor: cstring,
	url: cstring,
	version: cstring,

	get_extension: proc "system" (host: ^Host, extension_id: cstring) -> rawptr,
	request_restart: proc "system" (host: ^Host),
	request_process: proc "system" (host: ^Host),
	request_callback: proc "system" (host: ^Host),
}

EventType :: enum u16 {
	NOTE_ON = 0,
	NOTE_OFF = 1,
	NOTE_CHOKE = 2,
	NOTE_END = 3,
	NOTE_EXPRESSION = 4,
	PARAM_VALUE = 5,
	PARAM_MOD = 6,
	PARAM_GESTURE_BEGIN = 7,
	PARAM_GESTURE_END = 8,
	TRANSPORT = 9,
	MIDI = 10,
	MIDI_SYSEX = 11,
	MIDI2 = 12,
}

EventFlags :: enum u32 {
	IS_LIVE = 0,
	DONT_RECORD = 1,
}
EventFlagSet :: bit_set[EventFlags; u32]

EventHeader :: struct {
	size: u32,
	time: u32,
	space_id: u16,
	type: EventType,
	flags: EventFlagSet,
}

EventNote :: struct {
	header: EventHeader,

	note_id: i32,
	port_index: i16,
	channel: i16,
	key: i16,
	velocity: f64,
}

NoteExpression :: enum i32 {
	VOLUME,
	PAN,
	TUNING,
	VIBRATO,
	EXPRESSION,
	BRIGHTNESS,
	PRESSURE,
}

EventNoteExpression :: struct {
	header: EventHeader,
	expression_id: NoteExpression,

	note_id: i32,
	port_index: i16,
	channel: i16,
	key: i16,

	value: f64,
}

EventParamValue :: struct {
	header: EventHeader,

	param_id: ClapId,
	cookie: rawptr,

	note_id: i32,
	port_index: i16,
	channel: i16,
	key: i16,

	value: f64,
}

EventParamMod :: struct {
	header: EventHeader,

	param_id: ClapId,
	cookie: rawptr,

	note_id: i32,
	port_index: i16,
	channel: i16,
	key: i16,

	value: f64,
}

EventParamGesture :: struct {
	header: EventHeader,
	param_id: ClapId,
}

TransportFlags :: enum u32 {
	HAS_TEMPO,
	HAS_BEATS_TIMELINE,
	HAS_SECONDS_TIMELINE,
	HAS_TIME_SIGNATURE,
	IS_PLAYING,
	IS_RECORDING,
	IS_LOOP_ACTIVE,
	IS_WITHIN_PRE_ROLL,
}
TransportFlagSet :: bit_set[TransportFlags; u32]

EventTransport :: struct {
	header: EventHeader,

	flags: TransportFlagSet,

	song_pos_beats: BeatTime,
	song_pos_seconds: SecTime,

	tempo: f64,
	tempo_inc: f64,

	loop_start_beats: BeatTime,
	loop_end_beats: BeatTime,
	loop_start_seconds: SecTime,
	loop_end_seconds: SecTime,

	bar_start: BeatTime,
	bar_number: i32,

	tsig_num: u16,
	tsig_denom: u16,
}

EventMidi :: struct {
	header: EventHeader,

	port_index: u16,
	data: [3]u8,
}

EventMidiSysex :: struct {
	header: EventHeader,

	port_index: u16,
	buffer: [^]u8,
	size: u32,
}

EventMidi2 :: struct {
	header: EventHeader,

	port_index: u16,
	data: [4]u32,
}

InputEvents :: struct {
	ctx: rawptr,
	size: proc "system" (list: ^InputEvents) -> u32,
	get: proc "system" (list: ^InputEvents, index: u32) -> ^EventHeader,
}

OutputEvents :: struct {
	ctx: rawptr,
	try_push: proc "system" (list: ^OutputEvents, event: ^EventHeader) -> c.bool,
}

AudioBuffer :: struct {
	data32: [^][^]f32,
	data64: [^][^]f64,
	channel_count: u32,
	latency: u32,
	constant_mask: u64,
}

UniversalPluginId :: struct {
	abi: cstring,
	id: cstring,
}

PluginFactory :: struct {
	get_plugin_count: proc "system" (factory: ^PluginFactory) -> u32,
	get_plugin_descriptor: proc "system" (factory: ^PluginFactory, idx: u32) -> ^PluginDescriptor,
	create_plugin: proc "system" (factory: ^PluginFactory, host: ^Host, plugin_id: cstring) -> ^Plugin,
}
