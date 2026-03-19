package bridge

HostContext :: distinct rawptr

HostApi :: struct {
	ctx: HostContext,
	
	param_edit_start:  proc(ctx: HostContext, param_id: i32),
	param_edit_change: proc(ctx: HostContext, param_id: i32, normalized_value: f64),
	param_edit_end:    proc(ctx: HostContext, param_id: i32),
}
