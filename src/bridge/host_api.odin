package bridge

HostHandle :: distinct rawptr

HostApi :: struct {
	ctx: HostHandle,
	
	// param enum index, not the host id
	param_edit_start:  proc(ctx: HostHandle, param_index: i32),
	param_edit_change: proc(ctx: HostHandle, param_index: i32, normalized_value: f64),
	param_edit_end:    proc(ctx: HostHandle, param_index: i32),

	// instance state, controller thread only
	state_set: proc(ctx: HostHandle, key: string, bytes: []u8),
	state_get: proc(ctx: HostHandle, key: string) -> []u8,
}
