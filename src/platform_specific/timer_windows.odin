package platform_specific

import win "core:sys/windows"

WinTimer :: struct {
	callback: win.TIMERPROC,
	timer: uintptr,
}

TimerData :: struct {
	id: uintptr,
	timer: ^Timer,
}

@(private="file")
timerDataList: [64]TimerData

winTimerCallback :: proc "stdcall" (hwnd: win.HWND, umsg: u32, idEvent: uintptr, time: u32) {
	for i in 0..<len(timerDataList) {
		if timerDataList[i].id == idEvent {
			timer := timerDataList[i].timer
			context = timer.ctx
			timer->callback()
			break
		}
	}
}

timer_create :: proc (periodMs: u32, callback: proc (timer: ^Timer), data: rawptr) -> ^Timer {
	timer := new(Timer)
	timer.timePeriodMs = periodMs
	timer.callback = callback
	timer.data = data
	timer.ctx = context
	#assert(size_of(WinTimer) <= size_of(timer.platformTimerMem))
	winTimer: ^WinTimer = cast(^WinTimer)&timer.platformTimerMem
	winTimer.callback = winTimerCallback
	return timer
}

timer_start :: proc (timer: ^Timer) -> bool {
	winTimer: ^WinTimer = cast(^WinTimer)&timer.platformTimerMem

	if winTimer.timer != 0 do return false

	winTimer.timer = win.SetTimer(nil, 0, timer.timePeriodMs, winTimer.callback)
	if winTimer.timer != 0 {
		i := 0
		for i = 0; i < len(timerDataList); i += 1 {
			if timerDataList[i].id == 0 {
				timerDataList[i].id = winTimer.timer
				timerDataList[i].timer = timer
				break
			}
		}
		// TODO: Error condition if array is full (probably will never happen)
		return true
	}

	return false
}

timer_running :: proc (timer: ^Timer) -> bool {
	winTimer: ^WinTimer = cast(^WinTimer)&timer.platformTimerMem
	return winTimer.timer != 0
}

timer_stop :: proc (timer: ^Timer) {
	winTimer: ^WinTimer = cast(^WinTimer)&timer.platformTimerMem
	if winTimer.timer != 0 {
		win.KillTimer(nil, winTimer.timer)
		for i in 0..< len(timerDataList) {
			if timerDataList[i].id == winTimer.timer {
				timerDataList[i].id = 0
				timerDataList[i].timer = nil
			}
		}
		winTimer.timer = 0
	}
}
