package bridge

HostHandle :: distinct rawptr

HostApi :: struct {
	ctx: HostHandle,
	
	param_edit_start:  proc(ctx: HostHandle, param_id: i32),
	param_edit_change: proc(ctx: HostHandle, param_id: i32, normalized_value: f64),
	param_edit_end:    proc(ctx: HostHandle, param_id: i32),
}
