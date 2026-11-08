package platform_specific

// TODO: Stub. VST3 on Linux must tick through the host's IRunLoop, so this is only for the standalone build

timer_create :: proc (period_ms: u32, callback: proc (timer: ^Timer), data: rawptr) -> ^Timer {
	timer := new(Timer)
	timer.time_period_ms = period_ms
	timer.callback = callback
	timer.data = data
	timer.ctx = context
	return timer
}

timer_start :: proc (timer: ^Timer) -> bool {
	return false
}

timer_running :: proc (timer: ^Timer) -> bool {
	return false
}

timer_stop :: proc (timer: ^Timer) {
}
