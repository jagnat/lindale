package platform_specific

import "core:time"

// Linux has no OS timer that fires on the UI thread, so timers are polled by
// whoever owns the event loop. The VST3 build has to tick through the host's IRunLoop instead

LinuxTimer :: struct {
	next_fire: time.Tick,
	running: bool,
}

@(private="file")
active_timers: [64]^Timer

timer_create :: proc (period_ms: u32, callback: proc (timer: ^Timer), data: rawptr) -> ^Timer {
	timer := new(Timer)
	timer.time_period_ms = period_ms
	timer.callback = callback
	timer.data = data
	timer.ctx = context
	#assert(size_of(LinuxTimer) <= size_of(timer.platform_timer_mem))
	return timer
}

timer_start :: proc (timer: ^Timer) -> bool {
	linux_timer := cast(^LinuxTimer)&timer.platform_timer_mem
	if linux_timer.running do return false

	for &slot in active_timers {
		if slot == nil {
			slot = timer
			linux_timer.running = true
			linux_timer.next_fire = time.tick_add(time.tick_now(), time.Duration(timer.time_period_ms) * time.Millisecond)
			return true
		}
	}
	// TODO: Error condition if array is full (probably will never happen)
	return false
}

timer_running :: proc (timer: ^Timer) -> bool {
	linux_timer := cast(^LinuxTimer)&timer.platform_timer_mem
	return linux_timer.running
}

timer_stop :: proc (timer: ^Timer) {
	linux_timer := cast(^LinuxTimer)&timer.platform_timer_mem
	if !linux_timer.running do return
	for &slot in active_timers {
		if slot == timer do slot = nil
	}
	linux_timer.running = false
}

// Fires due timers. Returns ms until the next one is due, -1 if none are running
timer_poll :: proc () -> i32 {
	wait: i32 = -1
	for i in 0..<len(active_timers) {
		timer := active_timers[i]
		if timer == nil do continue
		linux_timer := cast(^LinuxTimer)&timer.platform_timer_mem
		period := time.Duration(timer.time_period_ms) * time.Millisecond

		now := time.tick_now()
		if time.tick_diff(now, linux_timer.next_fire) <= 0 {
			// Schedule from now rather than the missed deadline so a stall doesn't cause a burst
			linux_timer.next_fire = time.tick_add(now, period)
			context = timer.ctx
			timer->callback()
			// callback may have stopped it
			if active_timers[i] != timer do continue
		}

		remaining := time.tick_diff(time.tick_now(), linux_timer.next_fire)
		ms := max(i32((remaining + time.Millisecond - 1) / time.Millisecond), 0)
		if wait < 0 || ms < wait do wait = ms
	}
	return wait
}

