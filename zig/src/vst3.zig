// From VST3 C API
// https://github.com/steinbergmedia/vst3_c_api/blob/master/vst3_c_api.h

const std = @import("std");

// ====================================
//               Data
// ====================================

pub const TResult = enum(i32) {
    kNoInterface     = @bitCast(@as(u32, 0x80004002)),
    kResultOk        = @bitCast(@as(u32, 0x00000000)),
    // kResultTrue      = @bitCast(@as(u32, 0x00000000)),
    kResultFalse     = @bitCast(@as(u32, 0x00000001)),
    kInvalidArgument = @bitCast(@as(u32, 0x80070057)),
    kNotImplemented  = @bitCast(@as(u32, 0x80004001)),
    kInternalError   = @bitCast(@as(u32, 0x80004005)),
    kNotInitialized  = @bitCast(@as(u32, 0x8000FFFF)),
    kOutOfMemory     = @bitCast(@as(u32, 0x8007000E)),
};

pub const TSize = i64;
pub const TUID = [16]u8;
pub const TUIDParam = *[16]u8;
pub const MediaType = i32;
pub const BusDirection = i32;
pub const IoMode = i32;
pub const String128 = [128:0]u16;
pub const BusType = i32;
pub const TBool = u8;
pub const SpeakerArrangement = u64;
pub const SampleRate = f64;
pub const Sample32 = f32;
pub const Sample64 = f64;
pub const ParamID = u32;
pub const ParamValue = f64;
pub const TQuarterNotes = f64;
pub const NoteExpressionTypeID = u32;
pub const NoteExpressionValue = f64;
pub const TSamples = i64;
pub const FIDString = [*:0]u8;

/// Constructs a 16-byte VST3-style UID with Microsoft GUID byte order
pub fn SMTG_INLINE_UID(comptime l1: u32, comptime l2: u32, comptime l3: u32, comptime l4: u32) TUID {
    return [_]u8{ (l1 & 0x000000FF), (l1 & 0x0000FF00) >> 8, (l1 & 0x00FF0000) >> 16, (l1 & 0xFF000000) >> 24, (l2 & 0x00FF0000) >> 16, (l2 & 0xFF000000) >> 24, (l2 & 0x000000FF), (l2 & 0x0000FF00) >> 8, (l3 & 0xFF000000) >> 24, (l3 & 0x00FF0000) >> 16, (l3 & 0x0000FF00) >> 8, (l3 & 0x000000FF), (l4 & 0xFF000000) >> 24, (l4 & 0x00FF0000) >> 16, (l4 & 0x0000FF00) >> 8, (l4 & 0x000000FF) };
}

pub fn isSameTUID(tuid: TUID, fid: FIDString) bool {
    const len = std.mem.len(fid);
    if (len != 16) return false;

    const fidSlice = fid[0..16];
    return std.mem.eql(u8, &tuid, fidSlice);
}

pub const IID = struct {
    pub const FUnknown = SMTG_INLINE_UID(0x00000000, 0x00000000, 0xC0000000, 0x00000046);
    pub const IPlugViewContentScaleSupport = SMTG_INLINE_UID(0x65ED9690, 0x8AC44525, 0x8AADEF7A, 0x72EA703F);
    pub const IPlugView = SMTG_INLINE_UID(0x5BC32507, 0xD06049EA, 0xA6151B52, 0x2B755B29);
    pub const IPlugFrame = SMTG_INLINE_UID(0x367FAF01, 0xAFA94693, 0x8D4DA2A0, 0xED0882A3);
    pub const Linux_IEventHandler = SMTG_INLINE_UID(0x561E65C9, 0x13A0496F, 0x813A2C35, 0x654D7983);
    pub const Linux_IRunLoop = SMTG_INLINE_UID(0x18C35366, 0x97764F1A, 0x9C5B8385, 0x7A871389);
    pub const IBStream = SMTG_INLINE_UID(0xC3BF6EA2, 0x30994752, 0x9B6BF990, 0x1EE33E9B);
    pub const ISizeableStream = SMTG_INLINE_UID(0x04F9549E, 0xE02F4E6E, 0x87E86A87, 0x47F4E17F);
    pub const INoteExpressionController = SMTG_INLINE_UID(0xB7F8F859, 0x41234872, 0x91169581, 0x4F3721A3);
    pub const IKeyswitchController = SMTG_INLINE_UID(0x1F2F76D3, 0xBFFB4B96, 0xB99527A5, 0x5EBCCEF4);
    pub const INoteExpressionPhysicalUIMapping = SMTG_INLINE_UID(0xB03078FF, 0x94D24AC8, 0x90CCD303, 0xD4133324);
    pub const IPluginBase = SMTG_INLINE_UID(0x22888DDB, 0x156E45AE, 0x8358B348, 0x08190625);
    pub const IPluginFactory = SMTG_INLINE_UID(0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F);
    pub const IPluginFactory2 = SMTG_INLINE_UID(0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB);
    pub const IPluginFactory3 = SMTG_INLINE_UID(0x4555A2AB, 0xC1234E57, 0x9B122910, 0x36878931);
    pub const IComponent = SMTG_INLINE_UID(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802);
    pub const IAttributeList = SMTG_INLINE_UID(0x1E5F0AEB, 0xCC7F4533, 0xA2544011, 0x38AD5EE4);
    pub const IStreamAttributes = SMTG_INLINE_UID(0xD6CE2FFC, 0xEFAF4B8C, 0x9E74F1BB, 0x12DA44B4);
    pub const IRemapParamID = SMTG_INLINE_UID(0x2B88021E, 0x6286B646, 0xB49DF76A, 0x5663061C);
    pub const IComponentHandler = SMTG_INLINE_UID(0x93A0BEA3, 0x0BD045DB, 0x8E890B0C, 0xC1E46AC6);
    pub const IComponentHandler2 = SMTG_INLINE_UID(0xF040B4B3, 0xA36045EC, 0xABCDC045, 0xB4D5A2CC);
    pub const IComponentHandlerBusActivation = SMTG_INLINE_UID(0x067D02C1, 0x5B4E274D, 0xA92D90FD, 0x6EAF7240);
    pub const IProgress = SMTG_INLINE_UID(0x00C9DC5B, 0x9D904254, 0x91A388C8, 0xB4E91B69);
    pub const IEditController = SMTG_INLINE_UID(0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E);
    pub const IEditController2 = SMTG_INLINE_UID(0x7F4EFE59, 0xF3204967, 0xAC27A3AE, 0xAFB63038);
    pub const IMidiMapping = SMTG_INLINE_UID(0xDF0FF9F7, 0x49B74669, 0xB63AB732, 0x7ADBF5E5);
    pub const IEditControllerHostEditing = SMTG_INLINE_UID(0xC1271208, 0x70594098, 0xB9DD34B3, 0x6BB0195E);
    pub const IComponentHandlerSystemTime = SMTG_INLINE_UID(0xF9E53056, 0xD1554CD5, 0xB7695E1B, 0x7B0F7745);
    pub const IEventList = SMTG_INLINE_UID(0x3A2C4214, 0x346349FE, 0xB2C4F397, 0xB9695A44);
    pub const IMessage = SMTG_INLINE_UID(0x936F033B, 0xC6C047DB, 0xBB0882F8, 0x13C1E613);
    pub const IConnectionPoint = SMTG_INLINE_UID(0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1);
    pub const IXmlRepresentationController = SMTG_INLINE_UID(0xA81A0471, 0x48C34DC4, 0xAC30C9E1, 0x3C8393D5);
    pub const IComponentHandler3 = SMTG_INLINE_UID(0x69F11617, 0xD26B400D, 0xA4B6B964, 0x7B6EBBAB);
    pub const IContextMenuTarget = SMTG_INLINE_UID(0x3CDF2E75, 0x85D34144, 0xBF86D36B, 0xD7C4894D);
    pub const IContextMenu = SMTG_INLINE_UID(0x2E93C863, 0x0C9C4588, 0x97DBECF5, 0xAD17817D);
    pub const IMidiLearn = SMTG_INLINE_UID(0x6B2449CC, 0x419740B5, 0xAB3C79DA, 0xC5FE5C86);
    pub const ChannelContext_IInfoListener = SMTG_INLINE_UID(0x0F194781, 0x8D984ADA, 0xBBA0C1EF, 0xC011D8D0);
    pub const IPrefetchableSupport = SMTG_INLINE_UID(0x8AE54FDA, 0xE93046B9, 0xA28555BC, 0xDC98E21E);
    pub const IDataExchangeHandler = SMTG_INLINE_UID(0x36D551BD, 0x6FF54F08, 0xB48E830D, 0x8BD5A03B);
    pub const IDataExchangeReceiver = SMTG_INLINE_UID(0x45A759DC, 0x84FA4907, 0xABCB6175, 0x2FC786B6);
    pub const IAutomationState = SMTG_INLINE_UID(0xB4E8287F, 0x1BB346AA, 0x83A46667, 0x68937BAB);
    pub const IInterAppAudioHost = SMTG_INLINE_UID(0x0CE5743D, 0x68DF415E, 0xAE285BD4, 0xE2CDC8FD);
    pub const IInterAppAudioConnectionNotification = SMTG_INLINE_UID(0x6020C72D, 0x5FC24AA1, 0xB0950DB5, 0xD7D6D5CF);
    pub const IInterAppAudioPresetManager = SMTG_INLINE_UID(0xADE6FCC4, 0x46C94E1D, 0xB3B49A80, 0xC93FEFDD);
    pub const IAudioProcessor = SMTG_INLINE_UID(0x42043F99, 0xB7DA453C, 0xA569E79D, 0x9AAEC33D);
    pub const IAudioPresentationLatency = SMTG_INLINE_UID(0x309ECE78, 0xEB7D4fae, 0x8B2225D9, 0x09FD08B6);
    pub const IProcessContextRequirements = SMTG_INLINE_UID(0x2A654303, 0xEF764E3D, 0x95B5FE83, 0x730EF6D0);
    pub const IHostApplication = SMTG_INLINE_UID(0x58E595CC, 0xDB2D4969, 0x8B6AAF8C, 0x36A664E5);
    pub const IVst3ToVst2Wrapper = SMTG_INLINE_UID(0x29633AEC, 0x1D1C47E2, 0xBB85B97B, 0xD36EAC61);
    pub const IVst3ToAUWrapper = SMTG_INLINE_UID(0xA3B8C6C5, 0xC0954688, 0xB0916F0B, 0xB697AA44);
    pub const IVst3ToAAXWrapper = SMTG_INLINE_UID(0x6D319DC6, 0x60C56242, 0xB32C951B, 0x93BEF4C6);
    pub const IVst3WrapperMPESupport = SMTG_INLINE_UID(0x44149067, 0x42CF4BF9, 0x8800B750, 0xF7359FE3);
    pub const IParameterFinder = SMTG_INLINE_UID(0x0F618302, 0x215D4587, 0xA512073C, 0x77B9D383);
    pub const IUnitHandler = SMTG_INLINE_UID(0x4B5147F8, 0x4654486B, 0x8DAB30BA, 0x163A3C56);
    pub const IUnitHandler2 = SMTG_INLINE_UID(0xF89F8CDF, 0x699E4BA5, 0x96AAC9A4, 0x81452B01);
    pub const IUnitInfo = SMTG_INLINE_UID(0x3D4BD6B5, 0x913A4FD2, 0xA886E768, 0xA5EB92C1);
    pub const IProgramListData = SMTG_INLINE_UID(0x8683B01F, 0x7B354F70, 0xA2651DEC, 0x353AF4FF);
    pub const IUnitData = SMTG_INLINE_UID(0x6C389611, 0xD391455D, 0xB870B833, 0x94A0EFDD);
    pub const IPlugInterfaceSupport = SMTG_INLINE_UID(0x4FB58B9E, 0x9EAA4E0F, 0xAB361C1C, 0xCCB56FEA);
    pub const IParameterFunctionName = SMTG_INLINE_UID(0x6D21E1DC, 0x91199D4B, 0xA2A02FEF, 0x6C1AE55C);
    pub const IParamValueQueue = SMTG_INLINE_UID(0x01263A18, 0xED074F6F, 0x98C9D356, 0x4686F9BA);
    pub const IParameterChanges = SMTG_INLINE_UID(0xA4779663, 0x0BB64A56, 0xB44384A8, 0x466FEB9D);
};

pub const BusInfo = struct {
    mediaType: MediaType,
    direction: BusDirection,
    channelCount: i32,
    name: String128,
    busType: BusType,
    flags: u32,
};

pub const RoutingInfo = struct {
    mediaType: MediaType,
    busIndex: i32,
    channel: i32,
};

pub const ProcessSetup = struct {
    processMode: i32,
    symbolicSampleSize: i32,
    maxSamplesPerBlock: i32,
    sampleRate: SampleRate,
};

pub const AudioBusBuffers = struct {
    numChannels: i32,
    silenceFlags: u64,
    buffers: union(enum) {
        channelBuffers32: **Sample32,
        channelBuffers64: **Sample64,
    },
};

pub const NoteOnEvent = struct {
    channel: i16,
    pitch: i16,
    tuning: f32,
    velocity: f32,
    length: i32,
    noteId: i32,
};

pub const NoteOffEvent = struct {
    channel: i16,
    pitch: i16,
    velocity: f32,
    noteId: i32,
    tuning: f32,
};

pub const DataEvent = struct {
    size: u32,
    type: u32,
    bytes: *u8,
};

pub const PolyPressureEvent = struct {
    channel: i16,
    pitch: i16,
    pressure: f32,
    noteId: i32,
};

pub const NoteExpressionValueEvent = struct {
    typId: NoteExpressionTypeID,
    noteId: i32,
    value: NoteExpressionValue,
};

pub const NoteExpressionTextEvent = struct {
    typeId: NoteExpressionTypeID,
    noteId: i32,
    textLen: u32,
    text: *u8,
};

pub const ChordEvent = struct {
    root: i16,
    bassNote: i16,
    mask: i16,
    textLen: u16,
    text: *u8,
};

pub const ScaleEvent = struct {
    root: i16,
    mask: i16,
    textLen: u16,
    text: *u8,
};

pub const LegacyMIDICCOutEvent = struct {
    controlNumber: u8,
    channel: i8,
    value: i8,
    value2: i8,
};

pub const Event = struct { busIndex: i32, sampleOffset: i32, ppqPosition: TQuarterNotes, flags: u16, type: u16, event: union(enum) {
    noteOn: NoteOnEvent,
    noteOff: NoteOffEvent,
    data: DataEvent,
    polyPressure: PolyPressureEvent,
    noteExpressionValue: NoteExpressionValueEvent,
    noteExpressionText: NoteExpressionTextEvent,
    chord: ChordEvent,
    scale: ScaleEvent,
    midiCCOut: LegacyMIDICCOutEvent,
} };

pub const FrameRate = struct {
    framesPerSecond: u32,
    flags: u32,
};

pub const Chord = struct {
    keyNote: u8,
    rootNote: u8,
    chordMask: i16,
};

pub const ProcessContext = struct {
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
};

pub const ProcessData = struct {
    processMode: i32,
    symbolicSampleSize: i32,
    numSamples: i32,
    numInputs: i32,
    numOutputs: i32,
    inputs: *AudioBusBuffers,
    outputs: *AudioBusBuffers,
    inputParameterChanges: *IParameterChanges,
    outputParameterChanges: *IParameterChanges,
    inputEvents: *IEventList,
    outputEvents: *IEventList,
    processContext: *ProcessContext,
};

pub const PFactoryInfo = struct {
    vendor: [64]u8,
    url: [256]u8,
    email: [128]u8,
    flags: i32,
};

pub const kManyInstances = 0x7FFFFFFF; // Cardinality
pub const PClassInfo = struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
};

// ====================================
//               VTables
// ====================================

pub const FUnknownVtbl = struct {
    queryInterface: *const fn (this: *anyopaque, iid: TUIDParam, obj: **anyopaque) callconv(.C) TResult,
    addRef: *const fn (this: *anyopaque) callconv(.C) u32,
    release: *const fn (this: *anyopaque) callconv(.C) u32,
};

pub const FUnknown = struct {
    lpVtbl: *FUnknownVtbl,
};

pub const IBStreamVtbl = struct {
    funknown: FUnknownVtbl,

    read: *const fn (this: *anyopaque, buffer: *anyopaque, numBytes: i32, numBytesRead: *i32) callconv(.C) TResult,
    write: *const fn (this: *anyopaque, buffer: *anyopaque, numBytes: i32, numBytesWritten: *i32) callconv(.C) TResult,
    seek: *const fn (this: *anyopaque, pos: i64, mode: i32, result: *i64) callconv(.C) TResult,
    tell: *const fn (this: *anyopaque, pos: *i64) callconv(.C) TResult,
};

pub const IBStream = struct {
    lpVtbl: *IBStreamVtbl,
};

pub const IParamValueQueueVtbl = struct {
    funknown: FUnknownVtbl,

    getParameterId: *const fn (this: *anyopaque) callconv(.C) ParamID,
    getPointCount: *const fn (this: *anyopaque) callconv(.C) i32,
    getPoint: *const fn (this: *anyopaque, index: i32, sampleoffset: *i32, value: *ParamValue) callconv(.C) TResult,
    addPoint: *const fn (this: *anyopaque, sampleOffset: i32, value: ParamValue, index: *i32) callconv(.C) TResult,
};

pub const IParamValueQueue = struct { lpVtbl: *IParamValueQueueVtbl };

pub const IParameterChangesVtbl = struct {
    funknown: FUnknownVtbl,

    getParameterCount: *const fn (this: *anyopaque) callconv(.C) i32,
    getParameterData: *const fn (this: *anyopaque, index: i32) callconv(.C) *IParamValueQueue,
    addParameterData: *const fn (this: *anyopaque, id: *ParamID, index: *i32) callconv(.C) *IParamValueQueue,
};

pub const IParameterChanges = struct { lpVtbl: *IParameterChangesVtbl };

pub const IEventListVtbl = struct {
    funknown: FUnknownVtbl,

    getEventCount: *const fn (this: *anyopaque) i32,
    getEvent: *const fn (this: *anyopaque, index: i32, e: *Event) callconv(.C) TResult,
    addEvent: *const fn (this: *anyopaque, e: *Event) callconv(.C) TResult,
};

pub const IEventList = struct { lpVtbl: *IEventListVtbl };

pub const IComponentVtbl = struct {
    funknown: FUnknownVtbl,

    initialize: *const fn (this: *anyopaque, ctx: *FUnknown) callconv(.C) TResult,
    terminate: *const fn (this: *anyopaque) callconv(.C) TResult,

    getControllerClassId: *const fn (this: *anyopaque, classId: TUIDParam) callconv(.C) TResult,
    setIoMode: *const fn (this: *anyopaque, mode: IoMode) callconv(.C) TResult,
    getBusCount: *const fn (this: *anyopaque, mediaType: MediaType, dir: BusDirection) callconv(.C) i32,
    getBusInfo: *const fn (this: *anyopaque, mediaType: MediaType, dir: BusDirection, index: i32, bus: *BusInfo) callconv(.C) TResult,
    getRoutingInfo: *const fn (this: *anyopaque, inInfo: *RoutingInfo, outInfo: *RoutingInfo) callconv(.C) TResult,
    activateBus: *const fn (this: *anyopaque, mediaType: MediaType, dir: BusDirection, index: i32, state: TBool) callconv(.C) TResult,
    setActive: *const fn (this: *anyopaque, state: TBool) callconv(.C) TResult,
    setState: *const fn (this: *anyopaque, state: *IBStream) callconv(.C) TResult,
    getState: *const fn (this: *anyopaque, state: *IBStream) callconv(.C) TResult,
};

pub const IComponent = struct { lpVtbl: *IComponentVtbl };

pub const IAudioProcessorVtbl = struct {
    funknown: FUnknownVtbl,

    setBusArrangements: *const fn (this: *anyopaque, inputs: *SpeakerArrangement, numIns: i32, outputs: *SpeakerArrangement, numOuts: i32) callconv(.C) TResult,
    getBusArrangement: *const fn (this: *anyopaque, dir: BusDirection, index: i32, arr: *SpeakerArrangement) callconv(.C) TResult,
    canProcessSampleSize: *const fn (this: *anyopaque, symbolicSampleSize: i32) callconv(.C) TResult,
    getLatencySamples: *const fn (this: *anyopaque) u32,
    setupProcessing: *const fn (this: *anyopaque, setup: *ProcessSetup) callconv(.C) TResult,
    setProcessing: *const fn (this: *anyopaque, state: TBool) callconv(.C) TResult,
    process: *const fn (this: *anyopaque, data: *ProcessData) callconv(.C) TResult,
    getTailSamples: *const fn (this: *anyopaque) callconv(.C) u32,
};

pub const IAudioProcessor = struct { lpVtbl: *IAudioProcessorVtbl };

pub const IPluginFactoryVtbl = struct {
    funknown: FUnknownVtbl,

    getFactoryInfo: *const fn (this: *anyopaque, info: *PFactoryInfo) callconv(.C) TResult,
    countClasses: *const fn (this: *anyopaque) callconv(.C) i32,
    getClassInfo: *const fn (this: *anyopaque, index: i32, info: *PClassInfo) callconv(.C) TResult,
    createInstance: *const fn (this: *anyopaque, cid: FIDString, iid: FIDString, obj: **anyopaque) callconv(.C) TResult,
};

pub const IPluginFactory = struct { lpVtbl: ?*IPluginFactoryVtbl };
