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

macTimerCallback :: proc "c" (timerRef: CFTimerRef, info: rawptr) {
	timer := cast(^Timer)info
	context = timer.ctx

	timer->callback()
}

MacTimer :: struct {
	callback: proc "c" (timer: CFTimerRef, info: rawptr),
	timer: CFRunLoopTimerRef,
}

timer_create :: proc (periodMs: u32, callback: proc (timer: ^Timer), data: rawptr) -> ^Timer {
	timer := new(Timer)
	timer.timePeriodMs = periodMs
	timer.callback = callback
	timer.data = data
	timer.ctx = context
	#assert(size_of(MacTimer) <= size_of(timer.platformTimerMem))
	macTimer: ^MacTimer = cast(^MacTimer)&timer.platformTimerMem
	macTimer.callback = macTimerCallback
	return timer
}

timer_start :: proc (timer: ^Timer) -> bool {
	macTimer: ^MacTimer = cast(^MacTimer)&timer.platformTimerMem
	if macTimer.timer != nil do return false

	timerCtx: CFRunLoopTimerContext
	timerCtx.info = timer
	currentTime := CFAbsoluteTimeGetCurrent()
	macTimer.timer = CFRunLoopTimerCreate(
		nil,
		cast(CFAbsoluteTime)(currentTime + f64(timer.timePeriodMs) * 0.001),
		f64(timer.timePeriodMs) * 0.001,
		0,
		0,
		macTimer.callback,
		&timerCtx
	)
	if macTimer.timer != nil {
		CFRunLoopAddTimer(CFRunLoopGetCurrent(), macTimer.timer, kCFRunLoopCommonModes)
		return true
	}

	return false
}

timer_running :: proc(timer: ^Timer) -> bool {
	macTimer: ^MacTimer = cast(^MacTimer)&timer.platformTimerMem
	return macTimer.timer != nil
}

timer_stop :: proc (timer: ^Timer) {
	macTimer: ^MacTimer = cast(^MacTimer)&timer.platformTimerMem
	if macTimer.timer != nil {
		CFRunLoopTimerInvalidate(macTimer.timer)
		CoreFoundation.CFRelease(cast(CoreFoundation.TypeRef)macTimer.timer)
		macTimer.timer = nil
	}
}
