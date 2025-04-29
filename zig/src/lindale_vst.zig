const std = @import("std");
const vst3 = @import("vst3");

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
		info.* = std.mem.zeroInit(vst3.PFactoryInfo, .{});
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

	// pub fn createInstance(this: *anyopaque, cid: vst3.FIDString, iid: vst3.FIDString, obj: **anyopaque) vst3.TResult {

	// }
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

// pub export fn GetPluginFactory() callconv(.C) *anyopaque {
	// return @ptrCast(*anyopaque, &plugin_factory);
// }
