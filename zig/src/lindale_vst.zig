const std = @import("std");
const vst3 = @import("vst3.zig");

const zeroInit = std.mem.zeroInit;

const LindaleProcessor = struct {
    component: vst3.IComponent,
    componentVtable: vst3.IComponentVtbl,
    audioProcessor: vst3.IAudioProcessor,
    audioProcessorVtable: vst3.IAudioProcessorVtbl,
    refCount: u32,

    pub fn create() *LindaleProcessor {
        const allocator = std.heap.c_allocator;
        const instance = allocator.create(LindaleProcessor) catch return null;

        instance.* = zeroInit(LindaleProcessor, .{});
        instance.component.lpVtbl = &instance.componentVtable;
        instance.audioProcessor.lpVtbl = &instance.audioProcessorVtable;

        instance.componentVtable = .{
            .funknown = createFUnknown(LindaleProcessor, "component", &.{ .{
                .iid = vst3.IID.IComponent,
                .field = "component",
            }, .{
                .iid = vst3.IID.IAudioProcessor,
                .field = "audioProcessor",
            } }),
        };

        instance.audioProcessorVtable = .{
            .funknown = createFUnknown(LindaleProcessor, "audioProcessor", &.{ .{
                .iid = vst3.IID.IComponent,
                .field = "component",
            }, .{
                .iid = vst3.IID.IAudioProcessor,
                .field = "audioProcessor",
            } }),
        };

        instance.refCount = 1;

        return instance;
    }

    // FUnknown VTable functions
    pub fn queryInterface(this: *LindaleProcessor, iid: vst3.TUID, obj: **anyopaque) vst3.TResult {
        if (iid == vst3.IID.FUnknown or iid == vst3.IID.IComponent or iid == vst3.IID.IAudioProcessor) {
            obj.* = this;
            return vst3.TResult.kResultOk;
        }
        return vst3.TResult.kNoInterface;
    }

    pub fn addRef(this: *LindaleProcessor) vst3.TResult {
        this.refCount += 1;
        return this.refCount;
    }

    pub fn release(this: *LindaleProcessor) vst3.TResult {
        this.refCount -= 1;
        if (this.refCount == 0) {
            const allocator = std.heap.c_allocator;
            allocator.destroy(this);
        }
        return this.refCount;
    }
};

const LindaleController = struct {};

pub fn createFUnknown(comptime VstClass: type, comptime anchorVtableName: []const u8, comptime supportedInterfaces: []const struct { iid: vst3.TUID, field: []const u8 }) vst3.FUnknownVtbl {
    const FUnknownFuncs = struct {
        fn queryInterface(this: *anyopaque, iid: vst3.TUID, obj: **anyopaque) vst3.TResult {
            const parent: *VstClass = @fieldParentPtr(anchorVtableName, this);

            if (vst3.isSameTUID(vst3.IID.FUnknown, iid)) {
                obj.* = this;
                return vst3.kResultOk;
            }

            inline for (supportedInterfaces) |interface| {
                if (vst3.isSameTUID(interface.iid, iid)) {
                    obj.* = @field(parent.*, interface.field);
                    return vst3.kResultOk;
                }
            }
            return vst3.kNoInterface;
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

    pub fn queryInterface(this: *anyopaque, iid: vst3.TUID, obj: **anyopaque) vst3.TResult {
        if (iid == vst3.IID.FUnknown or iid == vst3.IID.IPluginFactory) {
            obj.* = this;
        }
        return 0;
    }

    pub fn addRef(this: *anyopaque) u32 {
        _ = this;
        return 1;
    }

    pub fn release(this: *anyopaque) u32 {
        _ = this;
        return 0;
    }

    pub fn getFactoryInfo(this: *anyopaque, info: *vst3.PFactoryInfo) vst3.TResult {
        _ = this;
        info.* = zeroInit(vst3.PFactoryInfo, .{});
        std.mem.copy(u8, info.vendor[0..4], "Jagi");
        std.mem.copy(u8, info.url[0.."jagi.quest".len], "jagi.quest");
        std.mem.copy(u8, info.email[0.."jagi@jagi.quest".len], "jagi@jagi.quest");
        return vst3.TResult.kResultOk;
    }

    pub fn countClasses(this: *anyopaque) i32 {
        _ = this;
        return 1;
    }

    pub fn getClassInfo(this: *anyopaque, index: i32, info: *vst3.PClassInfo) vst3.TResult {
        _ = this;
        if (index != 0) {
            return vst3.kInvalidArgument;
        }

        info.* = vst3.PClassInfo{
            .cid = lindaleCid,
            .cardinality = vst3.kManyInstances,
            .category = [0]**32,
            .name = [0]**64,
        };

        std.mem.copy(u8, info.category[0.."Instrument".len], "Instrument");
        std.mem.copy(u8, info.name[0.."Lindale".len], "Lindale");

        return vst3.kResultOk;
    }

    pub fn createInstance(this: *anyopaque, cid: vst3.FIDString, iid: vst3.FIDString, obj: **anyopaque) vst3.TResult {
        _ = this;
        if (vst3.isSameTUID(lindaleCid, cid)) {
            var instance = LindaleProcessor.create2();

            if (vst3.isSameTUID(vst3.IID.IComponent, iid)) {
                obj.* = &instance.component;
                return vst3.kResultOk;
            } else if (vst3.isSameTUID(vst3.IID.IAudioProcessor, iid)) {
                obj.* = &instance.audioProcessor;
                return vst3.kResultOk;
            }
        }
    }
};

const lindaleCid = vst3.SMTG_INLINE_UID(0x68C2EAE3, 0x418443BC, 0x80F06C5E, 0x428D44C4);

const pluginFactory = initPluginFactory();

// Compile time executed
fn initPluginFactory() LindalePluginFactory {
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
        .createInstance = LindalePluginFactory.createInstance2,
    };
    comptime var plugfact = LindalePluginFactory{
        .vtable = vtable,
    };

    const vtablePtr = vst3.IPluginFactory{ .lpVtbl = &plugfact.vtable };
    plugfact.vtablePtr = vtablePtr;
    return plugfact;
}

pub export fn InitModule() callconv(.C) bool {
    return true;
}

pub export fn DeinitModule() callconv(.C) bool {
    return true;
}

pub export fn GetPluginFactory() callconv(.C) *anyopaque {
    return @ptrCast(&pluginFactory);
}
