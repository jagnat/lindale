const std = @import("std");
const vst3 = @import("vst3");

const zeroInit = std.mem.zeroInit;

const LindaleInstance = struct {
	component: vst3.IComponent,
	componentVtable: vst3.IComponentVtbl,
	audioProcessor: vst3.IAudioProcessor,
	audioProcessorVtable: vst3.IAudioProcessorVtbl,
	refCount: u32,

	pub fn create() *LindaleInstance {
		const allocator = std.heap.c_allocator;
		const instance = allocator.create(LindaleInstance) catch return null;

		instance.* = zeroInit(LindaleInstance, .{});
		instance.component.lpVtbl = &instance.componentVtable;
		instance.audioProcessor.lpVtbl = &instance.audioProcessorVtable;

		instance.componentVtable = .{

		};

		instance.audioProcessorVtable = .{

		};

		instance.refCount = 1;

		return instance;
	}
};

pub fn createFUnknownVtbl(comptime T: type, comptime inters: []const struct {iid: vst3.TUID, field: fn(*T) *anyopaque}) vst3.FUnknownVtbl {
	return vst3.FUnknownVtbl {
		.queryInterface = struct { fn impl(this: *anyopaque, iid: vst3.TUID, obj: **anyopaque) vst3.TResult {
			const inst = @fieldParentPtr("refCount", this);
			inline for (inters) |interface| {
				if (std.mem.eql(u8, &iid, &interface.iid)) {
					out.* = interface.field(inst);
					return vst3.TResult.kResultOk;
				}
			}
			out.* = null;
			return TResult.kNoInterface;
		}}.impl,
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

		info.* = vst3.PClassInfo {
			.cid = lindaleCid,
			.cardinality = vst3.kManyInstances,
			.category = [0] ** 32,
			.name = [0] ** 64,
		};

		std.mem.copy(u8, info.category[0.."Instrument".len], "Instrument");
		std.mem.copy(u8, info.name[0.."Lindale".len], "Lindale");

		return vst3.kResultOk;
	}

	pub fn createInstance(this: *anyopaque, cid: vst3.FIDString, iid: vst3.FIDString, obj: **anyopaque) vst3.TResult {
		_ = this;
		if (vst3.isSameTUID(lindaleCid, cid)) {
			var instance = LindaleInstance.create();

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
	};
	comptime var plugfact = LindalePluginFactory{
		.vtable = vtable,
	};

	const vtablePtr = vst3.IPluginFactory{.lpVtbl = &plugfact.vtable};
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
