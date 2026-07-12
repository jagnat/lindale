package platform_specific

import "base:runtime"

Timer :: struct {
	callback: proc (timer: ^Timer),
	time_period_ms: u32,
	ctx: runtime.Context,
	data: rawptr,
	platform_timer_mem: [16]int,
}

// Timer procs are system-dependent

