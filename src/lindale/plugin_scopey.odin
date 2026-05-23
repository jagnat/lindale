package lindale

import b "../bridge"

when b.ACTIVE_PLUGIN == "scopey" {

ScopeyProcessState :: struct {

}

ScopeyControlState :: struct {
	
}

@(rodata) scopey_param_table := [?]b.ParamDescriptor {
	{
		name = "Test Param", short_name = "tp", min = 0, max = 100, default_value = 0,
		unit = .Percentage, flags = {.Automatable},
	},
}

scopey_get_plugin_descriptor :: proc() -> PluginDescriptor {
	return {
		name = "Scopey",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Effect,
		params = scopey_param_table[:],
		max_channels = 2,

		view = ViewConfig {
			default_width = 640,
			default_height = 480,
			resizable = true,
		},
	}
}

scopey_process_audio :: proc(plug: ^PluginProcessor) {

}

scopey_draw :: proc(plug: ^PluginController) {
	draw_set_clear_color(plug.draw, ColorF32{0.2, 0.1, 0.2, 1})
	draw_clear(plug.draw)

	draw_submit(plug.draw)
}

scopey_setup_controller :: proc(plug: ^PluginController) {

}

scopey_setup_processor :: proc(plug: ^PluginProcessor) {

}

scopey_api :: PluginApi {
	get_plugin_descriptor = scopey_get_plugin_descriptor,
	process_audio         = scopey_process_audio,
	draw                  = scopey_draw,

	setup_controller      = scopey_setup_controller,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = scopey_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = nil,
	reset                 = nil,
}

} // when block
