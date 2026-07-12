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
timer_data_list: [64]TimerData

win_timer_callback :: proc "stdcall" (hwnd: win.HWND, umsg: u32, idEvent: uintptr, time: u32) {
	for i in 0..<len(timer_data_list) {
		if timer_data_list[i].id == idEvent {
			timer := timer_data_list[i].timer
			context = timer.ctx
			timer->callback()
			break
		}
	}
}

timer_create :: proc (period_ms: u32, callback: proc (timer: ^Timer), data: rawptr) -> ^Timer {
	timer := new(Timer)
	timer.time_period_ms = period_ms
	timer.callback = callback
	timer.data = data
	timer.ctx = context
	#assert(size_of(WinTimer) <= size_of(timer.platform_timer_mem))
	win_timer: ^WinTimer = cast(^WinTimer)&timer.platform_timer_mem
	win_timer.callback = win_timer_callback
	return timer
}

timer_start :: proc (timer: ^Timer) -> bool {
	win_timer: ^WinTimer = cast(^WinTimer)&timer.platform_timer_mem

	if win_timer.timer != 0 do return false

	win_timer.timer = win.SetTimer(nil, 0, timer.time_period_ms, win_timer.callback)
	if win_timer.timer != 0 {
		i := 0
		for i = 0; i < len(timer_data_list); i += 1 {
			if timer_data_list[i].id == 0 {
				timer_data_list[i].id = win_timer.timer
				timer_data_list[i].timer = timer
				break
			}
		}
		// TODO: Error condition if array is full (probably will never happen)
		return true
	}

	return false
}

timer_running :: proc (timer: ^Timer) -> bool {
	win_timer: ^WinTimer = cast(^WinTimer)&timer.platform_timer_mem
	return win_timer.timer != 0
}

timer_stop :: proc (timer: ^Timer) {
	win_timer: ^WinTimer = cast(^WinTimer)&timer.platform_timer_mem
	if win_timer.timer != 0 {
		win.KillTimer(nil, win_timer.timer)
		for i in 0..< len(timer_data_list) {
			if timer_data_list[i].id == win_timer.timer {
				timer_data_list[i].id = 0
				timer_data_list[i].timer = nil
			}
		}
		win_timer.timer = 0
	}
}
