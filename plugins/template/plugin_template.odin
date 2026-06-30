package template

import l "../../src/framework"

@(rodata) template_param_table := [?]l.ParamDescriptor {
	{
		name = "Test Param", short_name = "tp", min = 0, max = 100, default_value = 0,
		unit = .Percentage, flags = {.Automatable},
	},
}

template_get_plugin_descriptor :: proc() -> l.PluginDescriptor {
	return {
		name = "Template",
		vendor = "JagI",
		version = "0.0.1",
		plugin_type = .Effect,
		params = template_param_table[:],
		max_channels = 2,
		view = {
			min_width = 640, min_height = 480,
			resizable = true,
		}
	}
}

template_process_audio :: proc(plug: ^l.PluginProcessor) {

}

template_draw :: proc(plug: ^l.PluginController) {
	l.draw_set_clear_color(plug.draw, l.ColorF32{0.2, 0.1, 0.2, 1})
	l.draw_clear(plug.draw)

	l.draw_submit(plug.draw)
}

template_setup_controller :: proc(plug: ^l.PluginController) -> rawptr {
	return nil
}

template_setup_processor :: proc(plug: ^l.PluginProcessor) -> rawptr {
	return nil
}

template_api :: l.PluginApi {
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
