package platform_specific

import "core:sys/darwin/CoreFoundation"
import "core:sys/darwin/Foundation"

foreign import CF "system:CoreFoundation.framework"

CFRunLoopRef           :: rawptr
CFRunLoopTimerRef      :: rawptr
CFTimerRef             :: rawptr
CFTimeInterval         :: f64
CFAbsoluteTime         :: f64
CFRunLoopTimerCallBack :: #type proc "c" (timer: CFRunLoopTimerRef, info: rawptr)
CFRunLoopMode          :: cstring
CFIndex                :: i64

CFRunLoopTimerContext :: struct {
	version: CFIndex,
	info: rawptr,
	retain          : proc "system" (info: rawptr) -> rawptr,
	release         : proc "system" (info: rawptr),
	copyDescription : proc "system" (info: rawptr) -> cstring,
}

@(default_calling_convention="c")
foreign CF {
	CFRunLoopGetCurrent :: proc() -> CFRunLoopRef ---
	CFRunLoopTimerCreate :: proc(
		alloc: rawptr,
		fireDate: CFAbsoluteTime,
		interval: CFTimeInterval,
		flags: CoreFoundation.OptionFlags,
		order: CoreFoundation.Index,
		callout: CFRunLoopTimerCallBack,
		ctx: rawptr) -> CFRunLoopTimerRef ---
	CFRunLoopAddTimer :: proc(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: CFRunLoopMode) ---
	CFRunLoopRemoveTimer :: proc(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: CFRunLoopMode) ---
	CFRunLoopRun :: proc() ---
	CFRunLoopStop :: proc(rl: CFRunLoopRef) ---
	CFAbsoluteTimeGetCurrent :: proc() -> CFTimeInterval ---
	CFRunLoopTimerInvalidate :: proc(timer: CFRunLoopTimerRef) ---

	kCFRunLoopDefaultMode : CFRunLoopMode
	kCFRunLoopCommonModes : CFRunLoopMode
}

MacTimer :: struct {
	callback: proc "c" (timer: CFTimerRef, info: rawptr),
	timer: CFRunLoopTimerRef,
}

mac_timer_callback :: proc "c" (timer_ref: CFTimerRef, info: rawptr) {
	timer := cast(^Timer)info
	context = timer.ctx

	timer->callback()
}

timer_create :: proc (period_ms: u32, callback: proc (timer: ^Timer), data: rawptr) -> ^Timer {
	timer := new(Timer)
	timer.time_period_ms = period_ms
	timer.callback = callback
	timer.data = data
	timer.ctx = context
	#assert(size_of(MacTimer) <= size_of(timer.platform_timer_mem))
	mac_timer: ^MacTimer = cast(^MacTimer)&timer.platform_timer_mem
	mac_timer.callback = mac_timer_callback
	return timer
}

timer_start :: proc (timer: ^Timer) -> bool {
	mac_timer: ^MacTimer = cast(^MacTimer)&timer.platform_timer_mem
	if mac_timer.timer != nil do return false

	timer_ctx: CFRunLoopTimerContext
	timer_ctx.info = timer
	current_time := CFAbsoluteTimeGetCurrent()
	mac_timer.timer = CFRunLoopTimerCreate(
		nil,
		cast(CFAbsoluteTime)(current_time + f64(timer.time_period_ms) * 0.001),
		f64(timer.time_period_ms) * 0.001,
		0,
		0,
		mac_timer.callback,
		&timer_ctx
	)
	if mac_timer.timer != nil {
		CFRunLoopAddTimer(CFRunLoopGetCurrent(), mac_timer.timer, kCFRunLoopCommonModes)
		return true
	}

	return false
}

timer_running :: proc(timer: ^Timer) -> bool {
	mac_timer: ^MacTimer = cast(^MacTimer)&timer.platform_timer_mem
	return mac_timer.timer != nil
}

timer_stop :: proc (timer: ^Timer) {
	mac_timer: ^MacTimer = cast(^MacTimer)&timer.platform_timer_mem
	if mac_timer.timer != nil {
		CFRunLoopTimerInvalidate(mac_timer.timer)
		CoreFoundation.CFRelease(cast(CoreFoundation.TypeRef)mac_timer.timer)
		mac_timer.timer = nil
	}
}
