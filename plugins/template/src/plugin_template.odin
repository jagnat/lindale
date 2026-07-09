package template

import "../../../src/sdk"

@(export)
GetPluginApi :: proc() -> sdk.PluginApi {
	return sdk.fallbackApi
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(template_api)
}

@(rodata) template_param_table := [?]sdk.ParamDescriptor {
	{
		name = "Test Param", short_name = "tp", min = 0, max = 100, default_value = 0,
		unit = .Percentage, flags = {.Automatable},
	},
}

template_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
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

template_process_audio :: proc(plug: ^sdk.PluginProcessor) {

}

template_draw :: proc(plug: ^sdk.PluginController) {
	sdk.draw_set_clear_color(plug.draw, sdk.ColorF32{0.2, 0.1, 0.2, 1})
	sdk.draw_clear(plug.draw)

	sdk.draw_submit(plug.draw)
}

template_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr {
	return nil
}

template_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	return nil
}

template_api :: sdk.PluginApi {
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
