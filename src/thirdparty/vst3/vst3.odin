package vst3

import "core:c"
import "base:runtime"
import "core:unicode/utf16"
import "core:mem"

// TODO: Needs a different endianness on other platforms besides win
SMTG_INLINE_UID :: #force_inline proc (l1, l2, l3, l4: u32) -> TUID {
	return {
		(byte)((l1 & 0x000000FF)      ), (byte)((l1 & 0x0000FF00) >>  8),
		(byte)((l1 & 0x00FF0000) >> 16), (byte)((l1 & 0xFF000000) >> 24),
		(byte)((l2 & 0x00FF0000) >> 16), (byte)((l2 & 0xFF000000) >> 24),
		(byte)((l2 & 0x000000FF)      ), (byte)((l2 & 0x0000FF00) >>  8),
		(byte)((l3 & 0xFF000000) >> 24), (byte)((l3 & 0x00FF0000) >> 16),
		(byte)((l3 & 0x0000FF00) >>  8), (byte)((l3 & 0x000000FF)      ),
		(byte)((l4 & 0xFF000000) >> 24), (byte)((l4 & 0x00FF0000) >> 16),
		(byte)((l4 & 0x0000FF00) >>  8), (byte)((l4 & 0x000000FF)      )
	}
}

is_same_tuid :: proc(tuid: TUID, fid: FIDString) -> bool {
	tuid := tuid
	if runtime.cstring_len(fid) != 16 {
		return false;
	}
	tuid_slice := tuid[:]
	fid_slice  := mem.slice_ptr(cast(^u8)fid, 16)

	return mem.compare(tuid_slice, fid_slice) == 0;
}

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

// Interface identifiers
// TODO: Make actual compile time constants???
iid_FUnknown                             := SMTG_INLINE_UID (0x00000000, 0x00000000, 0xC0000000, 0x00000046)
iid_IPlugViewContentScaleSupport         := SMTG_INLINE_UID (0x65ED9690, 0x8AC44525, 0x8AADEF7A, 0x72EA703F)
iid_IPlugView                            := SMTG_INLINE_UID (0x5BC32507, 0xD06049EA, 0xA6151B52, 0x2B755B29)
iid_IPlugFrame                           := SMTG_INLINE_UID (0x367FAF01, 0xAFA94693, 0x8D4DA2A0, 0xED0882A3)
iid_Linux_IEventHandler                  := SMTG_INLINE_UID (0x561E65C9, 0x13A0496F, 0x813A2C35, 0x654D7983)
iid_Linux_IRunLoop                       := SMTG_INLINE_UID (0x18C35366, 0x97764F1A, 0x9C5B8385, 0x7A871389)
iid_IBStream                             := SMTG_INLINE_UID (0xC3BF6EA2, 0x30994752, 0x9B6BF990, 0x1EE33E9B)
iid_ISizeableStream                      := SMTG_INLINE_UID (0x04F9549E, 0xE02F4E6E, 0x87E86A87, 0x47F4E17F)
iid_INoteExpressionController            := SMTG_INLINE_UID (0xB7F8F859, 0x41234872, 0x91169581, 0x4F3721A3)
iid_IKeyswitchController                 := SMTG_INLINE_UID (0x1F2F76D3, 0xBFFB4B96, 0xB99527A5, 0x5EBCCEF4)
iid_INoteExpressionPhysicalUIMapping     := SMTG_INLINE_UID (0xB03078FF, 0x94D24AC8, 0x90CCD303, 0xD4133324)
iid_IPluginBase                          := SMTG_INLINE_UID (0x22888DDB, 0x156E45AE, 0x8358B348, 0x08190625)
iid_IPluginFactory                       := SMTG_INLINE_UID (0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F)
iid_IPluginFactory2                      := SMTG_INLINE_UID (0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB)
iid_IPluginFactory3                      := SMTG_INLINE_UID (0x4555A2AB, 0xC1234E57, 0x9B122910, 0x36878931)
iid_IComponent                           := SMTG_INLINE_UID (0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802)
iid_IAttributeList                       := SMTG_INLINE_UID (0x1E5F0AEB, 0xCC7F4533, 0xA2544011, 0x38AD5EE4)
iid_IStreamAttributes                    := SMTG_INLINE_UID (0xD6CE2FFC, 0xEFAF4B8C, 0x9E74F1BB, 0x12DA44B4)
iid_IRemapParamID                        := SMTG_INLINE_UID (0x2B88021E, 0x6286B646, 0xB49DF76A, 0x5663061C)
iid_IComponentHandler                    := SMTG_INLINE_UID (0x93A0BEA3, 0x0BD045DB, 0x8E890B0C, 0xC1E46AC6)
iid_IComponentHandler2                   := SMTG_INLINE_UID (0xF040B4B3, 0xA36045EC, 0xABCDC045, 0xB4D5A2CC)
iid_IComponentHandlerBusActivation       := SMTG_INLINE_UID (0x067D02C1, 0x5B4E274D, 0xA92D90FD, 0x6EAF7240)
iid_IProgress                            := SMTG_INLINE_UID (0x00C9DC5B, 0x9D904254, 0x91A388C8, 0xB4E91B69)
iid_IEditController                      := SMTG_INLINE_UID (0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E)
iid_IEditController2                     := SMTG_INLINE_UID (0x7F4EFE59, 0xF3204967, 0xAC27A3AE, 0xAFB63038)
iid_IMidiMapping                         := SMTG_INLINE_UID (0xDF0FF9F7, 0x49B74669, 0xB63AB732, 0x7ADBF5E5)
iid_IEditControllerHostEditing           := SMTG_INLINE_UID (0xC1271208, 0x70594098, 0xB9DD34B3, 0x6BB0195E)
iid_IComponentHandlerSystemTime          := SMTG_INLINE_UID (0xF9E53056, 0xD1554CD5, 0xB7695E1B, 0x7B0F7745)
iid_IEventList                           := SMTG_INLINE_UID (0x3A2C4214, 0x346349FE, 0xB2C4F397, 0xB9695A44)
iid_IMessage                             := SMTG_INLINE_UID (0x936F033B, 0xC6C047DB, 0xBB0882F8, 0x13C1E613)
iid_IConnectionPoint                     := SMTG_INLINE_UID (0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1)
iid_IXmlRepresentationController         := SMTG_INLINE_UID (0xA81A0471, 0x48C34DC4, 0xAC30C9E1, 0x3C8393D5)
iid_IComponentHandler3                   := SMTG_INLINE_UID (0x69F11617, 0xD26B400D, 0xA4B6B964, 0x7B6EBBAB)
iid_IContextMenuTarget                   := SMTG_INLINE_UID (0x3CDF2E75, 0x85D34144, 0xBF86D36B, 0xD7C4894D)
iid_IContextMenu                         := SMTG_INLINE_UID (0x2E93C863, 0x0C9C4588, 0x97DBECF5, 0xAD17817D)
iid_IMidiLearn                           := SMTG_INLINE_UID (0x6B2449CC, 0x419740B5, 0xAB3C79DA, 0xC5FE5C86)
iid_ChannelContext_IInfoListener         := SMTG_INLINE_UID (0x0F194781, 0x8D984ADA, 0xBBA0C1EF, 0xC011D8D0)
iid_IPrefetchableSupport                 := SMTG_INLINE_UID (0x8AE54FDA, 0xE93046B9, 0xA28555BC, 0xDC98E21E)
iid_IDataExchangeHandler                 := SMTG_INLINE_UID (0x36D551BD, 0x6FF54F08, 0xB48E830D, 0x8BD5A03B)
iid_IDataExchangeReceiver                := SMTG_INLINE_UID (0x45A759DC, 0x84FA4907, 0xABCB6175, 0x2FC786B6)
iid_IAutomationState                     := SMTG_INLINE_UID (0xB4E8287F, 0x1BB346AA, 0x83A46667, 0x68937BAB)
iid_IInterAppAudioHost                   := SMTG_INLINE_UID (0x0CE5743D, 0x68DF415E, 0xAE285BD4, 0xE2CDC8FD)
iid_IInterAppAudioConnectionNotification := SMTG_INLINE_UID (0x6020C72D, 0x5FC24AA1, 0xB0950DB5, 0xD7D6D5CF)
iid_IInterAppAudioPresetManager          := SMTG_INLINE_UID (0xADE6FCC4, 0x46C94E1D, 0xB3B49A80, 0xC93FEFDD)
iid_IAudioProcessor                      := SMTG_INLINE_UID (0x42043F99, 0xB7DA453C, 0xA569E79D, 0x9AAEC33D)
iid_IAudioPresentationLatency            := SMTG_INLINE_UID (0x309ECE78, 0xEB7D4fae, 0x8B2225D9, 0x09FD08B6)
iid_IProcessContextRequirements          := SMTG_INLINE_UID (0x2A654303, 0xEF764E3D, 0x95B5FE83, 0x730EF6D0)
iid_IHostApplication                     := SMTG_INLINE_UID (0x58E595CC, 0xDB2D4969, 0x8B6AAF8C, 0x36A664E5)
iid_IVst3ToVst2Wrapper                   := SMTG_INLINE_UID (0x29633AEC, 0x1D1C47E2, 0xBB85B97B, 0xD36EAC61)
iid_IVst3ToAUWrapper                     := SMTG_INLINE_UID (0xA3B8C6C5, 0xC0954688, 0xB0916F0B, 0xB697AA44)
iid_IVst3ToAAXWrapper                    := SMTG_INLINE_UID (0x6D319DC6, 0x60C56242, 0xB32C951B, 0x93BEF4C6)
iid_IVst3WrapperMPESupport               := SMTG_INLINE_UID (0x44149067, 0x42CF4BF9, 0x8800B750, 0xF7359FE3)
iid_IParameterFinder                     := SMTG_INLINE_UID (0x0F618302, 0x215D4587, 0xA512073C, 0x77B9D383)
iid_IUnitHandler                         := SMTG_INLINE_UID (0x4B5147F8, 0x4654486B, 0x8DAB30BA, 0x163A3C56)
iid_IUnitHandler2                        := SMTG_INLINE_UID (0xF89F8CDF, 0x699E4BA5, 0x96AAC9A4, 0x81452B01)
iid_IUnitInfo                            := SMTG_INLINE_UID (0x3D4BD6B5, 0x913A4FD2, 0xA886E768, 0xA5EB92C1)
iid_IProgramListData                     := SMTG_INLINE_UID (0x8683B01F, 0x7B354F70, 0xA2651DEC, 0x353AF4FF)
iid_IUnitData                            := SMTG_INLINE_UID (0x6C389611, 0xD391455D, 0xB870B833, 0x94A0EFDD)
iid_IPlugInterfaceSupport                := SMTG_INLINE_UID (0x4FB58B9E, 0x9EAA4E0F, 0xAB361C1C, 0xCCB56FEA)
iid_IParameterFunctionName               := SMTG_INLINE_UID (0x6D21E1DC, 0x91199D4B, 0xA2A02FEF, 0x6C1AE55C)
iid_IParamValueQueue                     := SMTG_INLINE_UID (0x01263A18, 0xED074F6F, 0x98C9D356, 0x4686F9BA)
iid_IParameterChanges                    := SMTG_INLINE_UID (0xA4779663, 0x0BB64A56, 0xB44384A8, 0x466FEB9D)

// Result codes
kNoInterface     : TResult : transmute(i32)u32(0x80004002)
kResultOk        : TResult : transmute(i32)u32(0x00000000)
kResultTrue      : TResult : transmute(i32)u32(0x00000000)
kResultFalse     : TResult : transmute(i32)u32(0x00000001)
kInvalidArgument : TResult : transmute(i32)u32(0x80070057)
kNotImplemented  : TResult : transmute(i32)u32(0x80004001)
kInternalError   : TResult : transmute(i32)u32(0x80004005)
kNotInitialized  : TResult : transmute(i32)u32(0x8000FFFF)
kOutOfMemory     : TResult : transmute(i32)u32(0x8007000E)


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

kManyInstances :: 0x7FFFFFFF // Cardinality
PClassInfo :: struct {
	cid: TUID,
	cardinality: i32,
	category: [32]u8,
	name: [64]u8,
}

// Vtable structs

FUnknownVtbl :: struct {
	queryInterface : proc "system" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> TResult,
	addRef : proc "system" (this: rawptr) -> u32,
	release : proc "system" (this: rawptr) -> u32,
}

FUnknown :: struct {
	lpVtbl: ^FUnknownVtbl,
}

IBStreamVtbl :: struct {
	funknown: FUnknownVtbl,

	read  : proc "system" (this: rawptr, buffer: rawptr, numBytes: i32, numBytesRead: ^i32) -> TResult,
	write : proc "system" (this: rawptr, buffer: rawptr, numBytes: i32, numBytesWritten: ^i32) -> TResult,
	seek  : proc "system" (this: rawptr, pos: i64, mode: i32, result: ^i64) -> TResult,
	tell  : proc "system" (this: rawptr, pos: ^i64) -> TResult,
}

IBStream :: struct {
	lpVtbl: ^IBStreamVtbl,
}

IParamValueQueueVtbl :: struct {
	funknown: FUnknownVtbl,

	getParameterId : proc "system" (this: rawptr) -> ParamID,
	getPointCount : proc "system" (this: rawptr) -> i32,
	getPoint: proc "system" (this: rawptr, index: i32, sampleoffset: ^i32, value: ^ParamValue) -> TResult,
	addPoint: proc "system" (this: rawptr, sampleOffset: i32, value: ParamValue, index: ^i32) -> TResult,
}

IParamValueQueue :: struct {
	lpVtbl : ^IParamValueQueueVtbl
}

IParameterChangesVtbl :: struct {
	funknown: FUnknownVtbl,

	getParameterCount : proc "system" (this: rawptr) -> i32,
	getParameterData  : proc "system" (this: rawptr, index: i32) -> ^IParamValueQueue,
	addParameterData  : proc "system" (this: rawptr, id: ^ParamID, index: ^i32) -> ^IParamValueQueue,
}

IParameterChanges :: struct {
	lpVtbl: ^IParameterChangesVtbl
}

IEventListVtbl :: struct {
	funknown: FUnknownVtbl,

	getEventCount : proc "system" (this: rawptr) -> i32,
	getEvent      : proc "system" (this: rawptr, index: i32, e: ^Event) -> TResult,
	addEvent      : proc "system" (this: rawptr, e: ^Event) -> TResult,
}

IEventList :: struct {
	lpVtbl: ^IEventListVtbl
}

IComponentVtbl :: struct {
	funknown: FUnknownVtbl,

	initialize : proc "system" (this: rawptr, ctx: ^FUnknown) -> TResult,
	terminate  : proc "system" (this: rawptr) -> TResult,

	getControllerClassId : proc "system" (this: rawptr, classId: ^TUID) -> TResult,
	setIoMode            : proc "system" (this: rawptr, mode: IoMode) -> TResult,
	getBusCount          : proc "system" (this: rawptr, type: MediaType, dir: BusDirection) -> i32,
	getBusInfo           : proc "system" (this: rawptr, type: MediaType, dir: BusDirection, index: i32, bus: ^BusInfo) -> TResult,
	getRoutingInfo       : proc "system" (this: rawptr, inInfo, outInfo: ^RoutingInfo) -> TResult,
	activateBus          : proc "system" (this: rawptr, type: MediaType, dir: BusDirection, index: i32, state: TBool) -> TResult,
	setActive            : proc "system" (this: rawptr, state: TBool) -> TResult,
	setState             : proc "system" (this: rawptr, state: ^IBStream) -> TResult,
	getState             : proc "system" (this: rawptr, state: ^IBStream) -> TResult,
}

IComponent :: struct {
	lpVtbl: ^IComponentVtbl
}

IAudioProcessorVtbl :: struct {
	funknown: FUnknownVtbl,

	setBusArrangements   : proc "system" (this: rawptr, inputs: ^SpeakerArrangement, numIns: i32, outputs: ^SpeakerArrangement, numOuts: i32) -> TResult,
	getBusArrangement    : proc "system" (this: rawptr, dir: BusDirection, index: i32, arr: ^SpeakerArrangement) -> TResult,
	canProcessSampleSize : proc "system" (this: rawptr, symbolicSampleSize: i32) -> TResult,
	getLatencySamples    : proc "system" (this: rawptr) -> u32,
	setupProcessing      : proc "system" (this: rawptr, setup: ^ProcessSetup) -> TResult,
	setProcessing        : proc "system" (this: rawptr, state: TBool) -> TResult,
	process              : proc "system" (this: rawptr, data: ^ProcessData) -> TResult,
	getTailSamples       : proc "system" (this: rawptr) -> u32,
}

IAudioProcessor :: struct {
	lpVtbl: ^IAudioProcessorVtbl
}

IPluginFactoryVtbl :: struct {
	funknown: FUnknownVtbl,

	getFactoryInfo : proc "system" (this: rawptr, info: ^PFactoryInfo) -> TResult,
	countClasses : proc "system" (this: rawptr) -> i32,
	getClassInfo : proc "system" (this: rawptr, index: i32, info: ^PClassInfo) -> TResult,
	createInstance : proc "system" (this: rawptr, cid, iid: FIDString, obj: ^rawptr) -> TResult,
}

IPluginFactory :: struct {
	lpVtbl: ^IPluginFactoryVtbl
}