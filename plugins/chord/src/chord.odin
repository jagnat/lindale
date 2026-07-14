package chord

import "../../../src/sdk"

@(export)
get_plugin_api :: proc() -> sdk.PluginApi {
	return sdk.FALLBACK_API
}
@(init)
_register :: proc "contextless" () {
	sdk.register_plugin(chord_api)
}

@(rodata) chord_param_table := [?]sdk.ParamDescriptor {
}

ChordControllerState :: struct {
	axiom: string,
	production: string,
}

ChordProcessorState :: struct {

}

chord_get_plugin_descriptor :: proc() -> sdk.PluginDescriptor {
	return {
		name = "Chord",
		vendor = "jagi studios",
		version = "0.0.1",
		plugin_type = .Effect,
		params = chord_param_table[:],
		max_channels = 2,
		view = {
			min_width = 640, min_height = 480,
			resizable = true,
		}
	}
}

chord_process_audio :: proc(plug: ^sdk.PluginProcessor) {

}

chord_draw :: proc(plug: ^sdk.PluginController) {
	sdk.draw_set_clear_color(plug.draw, sdk.ColorF32{0.13, 0.1, 0.1, 1})
	sdk.draw_clear(plug.draw)

	x :f32= 0.0
	y :f32= 0.0

	sdk.draw_push_pill(plug.draw, {0, 0}, {100, 100}, 2, {255, 255, 255, 255})

	sdk.draw_submit(plug.draw)
}

chord_setup_controller :: proc(plug: ^sdk.PluginController) -> rawptr {
	return rawptr(new(ChordControllerState))
}

chord_setup_processor :: proc(plug: ^sdk.PluginProcessor) -> rawptr {
	return rawptr(new(ChordProcessorState))
}

chord_api :: sdk.PluginApi {
	get_plugin_descriptor = chord_get_plugin_descriptor,
	process_audio         = chord_process_audio,
	draw                  = chord_draw,

	setup_controller      = chord_setup_controller,
	view_attached         = nil,
	view_removed          = nil,
	view_resized          = nil,

	setup_processor       = chord_setup_processor,
	get_latency_samples   = nil,
	get_tail_samples      = nil,
	reset                 = nil,
}
