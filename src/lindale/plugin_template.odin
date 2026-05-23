package lindale

import b "../bridge"

when b.ACTIVE_PLUGIN == "template" {

TemplateProcessState :: struct {

}

TemplateControlState :: struct {

}

@(rodata) template_param_table := [?]b.ParamDescriptor {
	{
		name = "Test Param", short_name = "tp", min = 0, max = 100, default_value = 0,
		unit = .Percentage, flags = {.Automatable},
	},
}

template_get_plugin_descriptor :: proc() -> PluginDescriptor {
	return {
		name = "Template",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Effect,
		params = template_param_table[:],
		max_channels = 2,
	}
}

template_process_audio :: proc(plug: ^PluginProcessor) {

}

template_draw :: proc(plug: ^PluginController) {
	draw_set_clear_color(plug.draw, ColorF32{0.2, 0.1, 0.2, 1})
	draw_clear(plug.draw)

	draw_submit(plug.draw)
}

template_setup_controller :: proc(plug: ^PluginController) {

}

template_setup_processor :: proc(plug: ^PluginProcessor) {

}

template_api :: PluginApi {
	get_plugin_descriptor = template_get_plugin_descriptor,
	process_audio         = template_process_audio,
	draw                  = template_draw,

	setup_controller      = template_setup_controller,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = template_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = nil,
	reset                 = nil,
}

} // when block
