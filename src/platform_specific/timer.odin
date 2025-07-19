package platform_specific

import "base:runtime"

Timer :: struct {
	callback: proc (timer: ^Timer),
	timePeriodMs: u32,
	ctx: runtime.Context,
	data: rawptr,
	platformTimerMem: [16]int,
}

// Timer procs are system-dependent

