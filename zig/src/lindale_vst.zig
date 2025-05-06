const std = @import("std");
const vst3 = @import("vst3.zig");

const zeroInit = std.mem.zeroInit;

const LindaleProcessor = struct {
    component: vst3.IComponent,
    componentVtable: vst3.IComponentVtbl,
    audioProcessor: vst3.IAudioProcessor,
    audioProcessorVtable: vst3.IAudioProcessorVtbl,
    refCount: u32,
    allocator: std.mem.Allocator,

    pub fn create() ?*LindaleProcessor {
        const allocator = std.heap.page_allocator;
        const instance = allocator.create(LindaleProcessor) catch return null;

        instance.allocator = allocator;
        instance.component.lpVtbl = &instance.componentVtable;
        instance.audioProcessor.lpVtbl = &instance.audioProcessorVtable;

        instance.componentVtable = .{
            .funknown = createFUnknown(LindaleProcessor, vst3.IComponent, "component", &.{ .{
                .iid = vst3.IID.IComponent,
                .field = "component",
            }, .{
                .iid = vst3.IID.IAudioProcessor,
                .field = "audioProcessor",
            } }),
            .initialize = initialize,
            .terminate = terminate,
            .getControllerClassId = getControllerClassId,
            .setIoMode = setIoMode,
            .getBusCount = getBusCount,
            .getBusInfo = getBusInfo,
            .getRoutingInfo = getRoutingInfo,
            .activateBus = activateBus,
            .setActive = setActive,
            .setState = setState,
            .getState = getState,
        };

        instance.audioProcessorVtable = .{
            .funknown = createFUnknown(LindaleProcessor, vst3.IAudioProcessor, "audioProcessor", &.{ .{
                .iid = vst3.IID.IComponent,
                .field = "component",
            }, .{
                .iid = vst3.IID.IAudioProcessor,
                .field = "audioProcessor",
            } }),
            .setBusArrangements = setBusArrangements,
            .getBusArrangement = getBusArrangement,
            .canProcessSampleSize = canProcessSampleSize,
            .getLatencySamples = getLatencySamples,
            .setupProcessing = setupProcessing,
            .setProcessing = setProcessing,
            .process = process,
            .getTailSamples = getTailSamples,
        };

        instance.refCount = 1;

        return instance;
    }

    // ================================
    // IComponent Functions
    // ================================
    fn initialize(this: *anyopaque, ctx: *vst3.FUnknown) callconv(.C) vst3.TResult {
        _ = this;
        _ = ctx;
        return vst3.TResult.kResultOk;
    }
    fn terminate(this: *anyopaque) callconv(.C) vst3.TResult {
        _ = this;
        return vst3.TResult.kResultOk;
    }
    fn getControllerClassId(this: *anyopaque, classId: vst3.TUIDParam) callconv(.C) vst3.TResult {
        _ = this;
        _ = classId;
        return vst3.TResult.kResultOk;
    }
    fn setIoMode(this: *anyopaque, mode: vst3.IoMode) callconv(.C) vst3.TResult {
        _ = this;
        _ = mode;
        return vst3.TResult.kResultOk;
    }
    fn getBusCount(this: *anyopaque, mediaType: vst3.MediaType, dir: vst3.BusDirection) callconv(.C) i32 {
        _ = this;
        _ = mediaType;
        _ = dir;
        return 0;
    }
    fn getBusInfo(this: *anyopaque, mediaType: vst3.MediaType, dir: vst3.BusDirection, index: i32, bus: *vst3.BusInfo) callconv(.C) vst3.TResult {
        _ = this;
        _ = mediaType;
        _ = dir;
        _ = index;
        _ = bus;
        return vst3.TResult.kResultOk;
    }
    fn getRoutingInfo(this: *anyopaque, inInfo: *vst3.RoutingInfo, outInfo: *vst3.RoutingInfo) callconv(.C) vst3.TResult {
        _ = this;
        _ = inInfo;
        _ = outInfo;
        return vst3.TResult.kResultOk;
    }
    fn activateBus(this: *anyopaque, mediaType: vst3.MediaType, dir: vst3.BusDirection, index: i32, state: vst3.TBool) callconv(.C) vst3.TResult {
        _ = this;
        _ = mediaType;
        _ = dir;
        _ = index;
        _ = state;
        return vst3.TResult.kResultOk;
    }
    fn setActive(this: *anyopaque, state: vst3.TBool) callconv(.C) vst3.TResult {
        _ = this;
        _ = state;
        return vst3.TResult.kResultOk;
    }
    fn setState(this: *anyopaque, state: *vst3.IBStream) callconv(.C) vst3.TResult {
        _ = this;
        _ = state;
        return vst3.TResult.kResultOk;
    }
    fn getState(this: *anyopaque, state: *vst3.IBStream) callconv(.C) vst3.TResult {
        _ = this;
        _ = state;
        return vst3.TResult.kResultOk;
    }

    // ================================
    // IAudioProcessor functions
    // ================================
    fn setBusArrangements(this: *anyopaque, inputs: *vst3.SpeakerArrangement, numIns: i32, outputs: *vst3.SpeakerArrangement, numOuts: i32) callconv(.C) vst3.TResult {
        _ = this;
        _ = inputs;
        _ = numIns;
        _ = outputs;
        _ = numOuts;
        return vst3.TResult.kResultOk;
    }
    fn getBusArrangement(this: *anyopaque, dir: vst3.BusDirection, index: i32, arr: *vst3.SpeakerArrangement) callconv(.C) vst3.TResult {
        _ = this;
        _ = dir;
        _ = index;
        _ = arr;
        return vst3.TResult.kResultOk;
    }
    fn canProcessSampleSize(this: *anyopaque, symbolicSampleSize: i32) callconv(.C) vst3.TResult {
        _ = this;
        _ = symbolicSampleSize;
        return vst3.TResult.kResultOk;
    }
    fn getLatencySamples(this: *anyopaque) u32 {
        _ = this;
        return 0;
    }
    fn setupProcessing(this: *anyopaque, setup: *vst3.ProcessSetup) callconv(.C) vst3.TResult {
        _ = this;
        _ = setup;
        return vst3.TResult.kResultOk;
    }
    fn setProcessing(this: *anyopaque, state: vst3.TBool) callconv(.C) vst3.TResult {
        _ = this;
        _ = state;
        return vst3.TResult.kResultOk;
    }
    fn process(this: *anyopaque, data: *vst3.ProcessData) callconv(.C) vst3.TResult {
        _ = this;
        _ = data;
        return vst3.TResult.kResultOk;
    }
    fn getTailSamples(this: *anyopaque) callconv(.C) u32 {
        _ = this;
        return 0;
    }
};

const LindaleController = struct {};

pub fn createFUnknown(comptime VstClass: type, comptime FieldClass: type, comptime anchorVtableName: []const u8, comptime supportedInterfaces: []const struct { iid: vst3.TUID, field: []const u8 }) vst3.FUnknownVtbl {
    const FUnknownFuncs = struct {
        fn queryInterface(this: *anyopaque, iid: vst3.TUIDParam, obj: **anyopaque) callconv(.C) vst3.TResult {
            const fieldPtr : *FieldClass = @ptrCast(@alignCast(this));
            const parent: *VstClass = @fieldParentPtr(anchorVtableName, fieldPtr);

            if (std.mem.eql(u8, iid[0..], vst3.IID.FUnknown[0..])) {
                obj.* = this;
                return vst3.TResult.kResultOk;
            }

            inline for (supportedInterfaces) |interface| {
                if (std.mem.eql(u8, iid[0..], interface.iid[0..])) {
                    obj.* = &@field(parent.*, interface.field);
                    return vst3.TResult.kResultOk;
                }
            }
            return vst3.TResult.kNoInterface;
        }

        fn addRef(this: *anyopaque) callconv(.C) u32 {
            const fieldPtr : *FieldClass = @ptrCast(@alignCast(this));
            const parent: *VstClass = @fieldParentPtr(anchorVtableName, fieldPtr);
            parent.refCount += 1;
            return parent.refCount;
        }

        fn release(this: *anyopaque) callconv(.C) u32 {
            const fieldPtr : *FieldClass = @ptrCast(@alignCast(this));
            const parent: *VstClass = @fieldParentPtr(anchorVtableName, fieldPtr);
            parent.refCount -= 1;
            if (parent.refCount == 0) {
                parent.allocator.destroy(parent);
            }
            return parent.refCount;
        }
    };
    return vst3.FUnknownVtbl{
        .queryInterface = FUnknownFuncs.queryInterface,
        .addRef = FUnknownFuncs.addRef,
        .release = FUnknownFuncs.release,
    };
}

const LindalePluginFactory = struct {
    vtablePtr: vst3.IPluginFactory,
    vtable: vst3.IPluginFactoryVtbl,
    initialized: bool = false,

    pub fn init(self: *LindalePluginFactory) void {
        if (!self.initialized) {

            const vtablePtr = vst3.IPluginFactory{ .lpVtbl = &pluginFactory.vtable };
            self.vtablePtr = vtablePtr;
            self.initialized = true;
        }
    }

    fn buildVTable() vst3.IPluginFactoryVtbl {
            const funknown = vst3.FUnknownVtbl{
                .queryInterface = LindalePluginFactory.queryInterface,
                .addRef = LindalePluginFactory.addRef,
                .release = LindalePluginFactory.release,
            };
            const vtable = vst3.IPluginFactoryVtbl{
                .funknown = funknown,

                .getFactoryInfo = LindalePluginFactory.getFactoryInfo,
                .countClasses = LindalePluginFactory.countClasses,
                .getClassInfo = LindalePluginFactory.getClassInfo,
                .createInstance = LindalePluginFactory.createInstance,
            };

            return vtable;
    }

    pub fn queryInterface(this: *anyopaque, iid: vst3.TUIDParam, obj: **anyopaque) callconv(.C) vst3.TResult {
        if (std.mem.eql(u8, iid[0..], vst3.IID.FUnknown[0..]) or std.mem.eql(u8, iid[0..], vst3.IID.IPluginFactory[0..])) {
            obj.* = this;
            return vst3.TResult.kResultOk;
        }
        return vst3.TResult.kNoInterface;
    }

    pub fn addRef(this: *anyopaque) callconv(.C) u32 {
        _ = this;
        return 1;
    }

    pub fn release(this: *anyopaque) callconv(.C) u32 {
        _ = this;
        return 0;
    }

    pub fn getFactoryInfo(this: *anyopaque, info: *vst3.PFactoryInfo) callconv(.C) vst3.TResult {
        _ = this;
        info.* = zeroInit(vst3.PFactoryInfo, .{});
        @memcpy(info.vendor[0..4], "Jagi");
        @memcpy(info.url[0.."jagi.quest".len], "jagi.quest");
        @memcpy(info.email[0.."jagi@jagi.quest".len], "jagi@jagi.quest");

        return vst3.TResult.kResultOk;
    }

    pub fn countClasses(this: *anyopaque) callconv(.C) i32 {
        _ = this;
        return 1;
    }

    pub fn getClassInfo(this: *anyopaque, index: i32, info: *vst3.PClassInfo) callconv(.C) vst3.TResult {
        _ = this;
        if (index != 0) {
            return vst3.TResult.kInvalidArgument;
        }

        info.* = vst3.PClassInfo{
            .cid = lindaleCid,
            .cardinality = vst3.kManyInstances,
            .category = [_]u8{0} ** 32,
            .name = [_]u8{0} ** 64,
        };

        @memcpy(info.category[0.."Instrument".len], "Instrument");
        @memcpy(info.name[0.."Lindale".len], "Lindale");

        return vst3.TResult.kResultOk;
    }

    pub fn createInstance(this: *anyopaque, cid: vst3.FIDString, iid: vst3.FIDString, obj: **anyopaque) callconv(.C) vst3.TResult {
        _ = this;
        if (vst3.isSameTUID(lindaleCid, cid)) {
            var instance = LindaleProcessor.create() orelse return vst3.TResult.kInternalError;

            if (vst3.isSameTUID(vst3.IID.IComponent, iid)) {
                obj.* = &instance.component;
                return vst3.TResult.kResultOk;
            } else if (vst3.isSameTUID(vst3.IID.IAudioProcessor, iid)) {
                obj.* = &instance.audioProcessor;
                return vst3.TResult.kResultOk;
            }
        }

        return vst3.TResult.kNoInterface;
    }
};

const lindaleCid = vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4);

var pluginFactory: LindalePluginFactory = .{
    .vtable = LindalePluginFactory.buildVTable(),
    .vtablePtr = .{.lpVtbl = null},
    .initialized = false,
};

pub export fn InitModule() callconv(.C) bool {
    return true;
}

pub export fn DeinitModule() callconv(.C) bool {
    return true;
}

pub fn GetPluginFactory() callconv(.C) *anyopaque {
    pluginFactory.init();
    return @ptrCast(&pluginFactory);
}
