package vst3

import "core:c"
import "core:unicode/utf16"

TResult :: i32
TSize :: i64
TUID :: [16]byte
MediaType :: i32
BusDirection :: i32
IoMode :: i32
String128 :: [128]u16
BusType :: i32
TBool :: u8
SpeakerArrangement :: u64
SampleRate :: f64
Sample32 :: f32
Sample64 :: f64
ParamID :: u32
ParamValue :: f64
TQuarterNotes :: f64
NoteExpressionTypeID :: u32
NoteExpressionValue :: f64
TSamples :: i64
FIDString :: cstring

BusInfo :: struct {
	mediaType : MediaType,
	direction: BusDirection,
	channelCount: i32,
	name: String128,
	busType: BusType,
	flags: u32,
}

RoutingInfo :: struct {
	mediaType: MediaType,
	busIndex: i32,
	channel: i32,
}

ProcessSetup :: struct {
	processMode        : i32,
	symbolicSampleSize : i32,
	maxSamplesPerBlock : i32,
	sampleRate         : SampleRate,
}

AudioBusBuffers :: struct {
	numChannels: i32,
	silenceFlags: u64,
	using _: struct #raw_union {
		channelBuffers32 : ^^Sample32,
		channelBuffers64 : ^^Sample64,
	},
}

// Events

NoteOnEvent :: struct {
	channel: i16,
	pitch: i16,
	tuning: f32,
	velocity: f32,
	length: i32,
	noteId: i32,
}

NoteOffEvent :: struct {
	channel: i16,
	pitch: i16,
	velocity: f32,
	noteId: i32,
	tuning: f32,
}

DataEvent :: struct {
	size: u32,
	type: u32,
	bytes: ^u8,
}

PolyPressureEvent :: struct {
	channel: i16,
	pitch: i16,
	pressure: f32,
	noteId: i32,
}

NoteExpressionValueEvent :: struct {
	typId: NoteExpressionTypeID,
	noteId: i32,
	value: NoteExpressionValue,
}

NoteExpressionTextEvent :: struct {
	typeId: NoteExpressionTypeID,
	noteId: i32,
	textLen: u32,
	text: cstring,
}

ChordEvent :: struct {
	root: i16,
	bassNote: i16,
	mask: i16,
	textLen: u16,
	text: cstring,
}

ScaleEvent :: struct {
	root: i16,
	mask: i16,
	textLen: u16,
	text: cstring,
}

LegacyMIDICCOutEvent :: struct {
	controlNumber: u8,
	channel: i8,
	value: i8,
	value2: i8,
}

Event :: struct {
	busIndex: i32,
	sampleOffset: i32,
	ppqPosition: TQuarterNotes,
	flags: u16,
	type: u16,
	using _: struct #raw_union {
		noteOn: NoteOnEvent,
		noteOff: NoteOffEvent,
		data: DataEvent,
		polyPressure: PolyPressureEvent,
		noteExpressionValue: NoteExpressionValueEvent,
		noteExpressionText: NoteExpressionTextEvent,
		chord: ChordEvent,
		scale: ScaleEvent,
		midiCCOut: LegacyMIDICCOutEvent,
	}
}

FrameRate :: struct {
	framesPerSecond: u32,
	flags: u32,
}

Chord :: struct {
	keyNote: u8,
	rootNote: u8,
	chordMask: i16,
}

ProcessContext :: struct {
	state: u32,
	sampleRate: f64,
	projectTimeSamples: TSamples,
	systemTime: i64,
	continousTimeSamples: TSamples,
	projectTimeMusic: TQuarterNotes,
	barPositionMusic: TQuarterNotes,
	cycleStartMusic: TQuarterNotes,
	cycleEndMusic: TQuarterNotes,
	tempo: f64,
	timeSigNumerator: i32,
	timeSigDenominator: i32,
	chord: Chord,
	smpteoffsetSubframes: i32,
	frameRate: FrameRate,
	samplesToNextClock: i32,
}

ProcessData :: struct {
	processMode: i32,
	symbolicSampleSize: i32,
	numSamples: i32,
	numInputs: i32,
	numOutputs: i32,
	inputs: ^AudioBusBuffers,
	outputs: ^AudioBusBuffers,
	inputParameterChanges: ^IParameterChanges,
	outputParameterChanges: ^IParameterChanges,
	inputEvents: ^IEventList,
	outputEvents: ^IEventList,
	processContext: ^ProcessContext,
}

PFactoryInfo :: struct {
	vendor: [64]u8,
	url: [256]u8,
	email: [128]u8,
	flags: i32,
}

PClassInfo :: struct {
	cid: TUID,
	cardinality: i32,
	category: [32]u8,
	name: [64]u8,
}

// Vtable structs

FUnknownVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef : proc "std" (this: rawptr) -> u32,
	release : proc "std" (this: rawptr) -> u32,
}

FUnknown :: struct {
	lpVtbl: ^FUnknownVtbl,
}

IBStreamVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	read  : proc "std" (this: rawptr, buffer: rawptr, numBytes: i32, numBytesRead: ^i32) -> TResult,
	write : proc "std" (this: rawptr, buffer: rawptr, numBytes: i32, numBytesWritten: ^i32) -> TResult,
	seek  : proc "std" (this: rawptr, pos: i64, mode: i32, result: ^i64) -> TResult,
	tell  : proc "std" (this: rawptr, pos: ^i64) -> TResult,
}

IBStream :: struct {
	lpVtbl: ^IBStreamVtbl,
}

IParamValueQueueVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	getParameterId : proc "std" (this: rawptr) -> ParamID,
	getPointCount : proc "std" (this: rawptr) -> i32,
	getPoint: proc "std" (this: rawptr, index: i32, sampleoffset: ^i32, value: ^ParamValue) -> TResult,
	addPoint: proc "std" (this: rawptr, sampleOffset: i32, value: ParamValue, index: ^i32) -> TResult,
}

IParamValueQueue :: struct {
	lpVtbl : ^IParamValueQueueVtbl
}

IParameterChangesVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	getParameterCount : proc "std" (this: rawptr) -> i32,
	getParameterData  : proc "std" (this: rawptr, index: i32) -> ^IParamValueQueue,
	addParameterData  : proc "std" (this: rawptr, id: ^ParamID, index: ^i32) -> ^IParamValueQueue,
}

IParameterChanges :: struct {
	lpVtbl: ^IParameterChangesVtbl
}

IEventListVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	getEventCount : proc "std" (this: rawptr) -> i32,
	getEvent      : proc "std" (this: rawptr, index: i32, e: ^Event) -> TResult,
	addEvent      : proc "std" (this: rawptr, e: ^Event) -> TResult,
}

IEventList :: struct {
	lpVtbl: ^IEventListVtbl
}

IComponentVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	initialize : proc "std" (this: rawptr, ctx: ^FUnknown) -> TResult,
	terminate  : proc "std" (this: rawptr) -> TResult,

	getControllerClassId : proc "std" (this: rawptr, classId: TUID) -> TResult,
	setIoMode            : proc "std" (this: rawptr, mode: IoMode) -> TResult,
	getBusCount          : proc "std" (this: rawptr, type: MediaType, dir: BusDirection) -> i32,
	getBusInfo           : proc "std" (this: rawptr, type: MediaType, dir: BusDirection, index: i32, bus: ^BusInfo) -> TResult,
	getRoutingInfo       : proc "std" (this: rawptr, inInfo, outInfo: ^RoutingInfo) -> TResult,
	activateBus          : proc "std" (this: rawptr, type: MediaType, dir: BusDirection, index: i32, state: TBool) -> TResult,
	setActive            : proc "std" (this: rawptr, state: TBool) -> TResult,
	setState             : proc "std" (this: rawptr, state: ^IBStream) -> TResult,
	getState             : proc "std" (this: rawptr, state: ^IBStream) -> TResult,
}

IAudioProcessorVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	setBusArrangements   : proc "std" (this: rawptr, inputs: ^SpeakerArrangement, numIns: i32, outputs: ^SpeakerArrangement, numOuts: i32) -> TResult,
	getBusArrangement    : proc "std" (this: rawptr, dir: BusDirection, index: i32, arr: ^SpeakerArrangement) -> TResult,
	canProcessSampleSize : proc "std" (this: rawptr, symbolicSampleSize: i32) -> TResult,
	getLatencySamples    : proc "std" (this: rawptr) -> u32,
	setupProcessing      : proc "std" (this: rawptr, setup: ^ProcessSetup) -> TResult,
	setProcessing        : proc "std" (this: rawptr, state: TBool) -> TResult,
	process              : proc "std" (this: rawptr, data: ^ProcessData) -> TResult,
	getTailSamples       : proc "std" (this: rawptr) -> u32,
}

IPluginFactoryVtbl :: struct {
	queryInterface : proc "std" (this: rawptr, iid: TUID, obj: ^rawptr) -> TResult,
	addRef         : proc "std" (this: rawptr) -> u32,
	release        : proc "std" (this: rawptr) -> u32,

	getFactoryInfo : proc "std" (this: rawptr, info: ^PFactoryInfo) -> TResult,
	countClasses : proc "std" (this: rawptr) -> i32,
	getClassInfo : proc "std" (this: rawptr, index: i32, info: ^PClassInfo) -> TResult,
	createInstance : proc "std" (this: rawptr, cid, iid: FIDString, obj: ^rawptr) -> TResult,
}

IPluginFactory :: struct {
	lpVtbl: ^IPluginFactoryVtbl
}