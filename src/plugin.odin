package lindale

import "base:runtime"
import "core:log"

Plugin :: struct {
	// Audio processor state
	processor: ^AudioProcessorContext,

	// UI / controller state
	render: ^RenderContext,
	draw: ^DrawContext,

	// Common state
}

PluginComponentSet :: bit_set[PluginComponent]
PluginComponent :: enum {
	Audio,
	Controller,
}

plugin_init :: proc(components: PluginComponentSet) -> ^Plugin {
	plugin := new(Plugin)
	if plugin == nil do return nil
	error := false
	defer if error do free(plugin)

	if .Audio in components {
		plugin.processor = new(AudioProcessorContext)
		if plugin.processor == nil do error = true
	}
	defer if error && plugin.processor != nil do free(plugin.processor)

	if .Controller in components {
		plugin.render = new(RenderContext)
		if plugin.render == nil do error = true

		plugin.draw = new(DrawContext)
		if plugin.draw == nil do error = true
	}
	defer if error && plugin.render != nil do free(plugin.render)
	defer if error && plugin.draw != nil do free(plugin.draw)

	if error do return nil

	if plugin.render != nil do plugin.render.plugin = plugin
	if plugin.draw != nil do plugin.draw.plugin = plugin

	return plugin
}

plugin_destroy :: proc(plug: ^Plugin) {

}

plugin_create_view :: proc(plug: ^Plugin, parentHandle: rawptr) {
	if plug.render == nil do return

	render_init_with_handle(plug.render, parentHandle)
	render_resize(plug.render, 800, 600)

	draw_init(plug.draw)
	draw_generate_random_rects(plug.draw)
}

plugin_remove_view :: proc(plug: ^Plugin) {
	render_deinit(plug.render)
}

plugin_handle_input :: proc(plug: ^Plugin) {

}

plugin_draw :: proc(plug: ^Plugin) {
	draw_upload(plug.draw)
	render_begin(plug.render)
	render_draw_rects(plug.render, true)
	render_end(plug.render)
}

plugin_param_changed :: proc(plug: ^Plugin, paramName: string) {

}

plugin_process_audio :: proc(plug: ^Plugin) {
	process(plug.processor)
}
